--[[
  treefarm.lua - Industrial Tree Farm controller for GTNH (OpenComputers)

  * Reads the Oak Wood count from your AE2 network (ME Controller / ME Interface via Adapter)
  * Turns the farm ON  when logs <  lowThreshold   (100,000)
  * Turns the farm OFF when logs >= highThreshold  (1,000,000)
  * Between the two it keeps whatever state the farm is already in (hysteresis)
  * Shows a status screen: log count, control logic, craft time, EU/t, machine info

  Screen: designed for a tier 3 GPU + tier 3 screen (160x50), same style as lscstats.

  Run with:  treefarm        (if saved to /home/bin/treefarm.lua)
  Quit with: Q   (the farm keeps its last state when the program exits)
]]

local component = require("component")
local computer  = require("computer")
local event     = require("event")
local sides     = require("sides")
local term      = require("term")
local unicode   = require("unicode")

----------------------------------------------------------------
-- CONFIG  (edit this section)
----------------------------------------------------------------
local config = {
  lowThreshold   = 100000,   -- farm turns ON  when logs drop BELOW this
  highThreshold  = 1000000,  -- farm turns OFF when logs reach this
  updateInterval = 2,        -- seconds between updates

  -- Which items count as "logs". Each entry is an AE2 filter:
  --   name = "mod:item", optional damage = <meta>, optional label = "Display Name"
  -- Leaving out damage counts every variant of that item.
  -- Only Oak Wood is counted: minecraft:log with damage 0.
  -- (damage 1/2/3 = spruce/birch/jungle, minecraft:log2 = acacia/dark oak)
  logFilters = {
    { name = "minecraft:log", damage = 0 },   -- Oak Wood
  },

  -- Leave nil to auto-detect. Otherwise paste the full or partial component address.
  meAddress   = nil,
  farmAddress = nil,
  -- Used for auto-detection: matched (case-insensitive) against the machine's getName()
  farmNamePatterns = { "treefarm", "tree" },

  -- "work_allowed" = enable/disable the machine directly (like a soft mallet)
  -- "redstone"     = output a redstone signal (use with a Machine Controller cover)
  controlMode      = "work_allowed",
  redstoneAddress  = nil,
  redstoneSide     = sides.top,
  redstoneOnLevel  = 15,     -- signal that means "farm ON"
  redstoneOffLevel = 0,      -- signal that means "farm OFF"

  resolution = { 160, 50 },  -- the layout is built for 160x50 (tier 3 GPU + screen)

  colors = {                 -- lscstats palette
    bg      = 0x0B0B0B,
    panel   = 0x161616,
    panel2  = 0x1E1E1E,      -- alternating list rows
    header  = 0x0E2A38,
    text    = 0xE6E6E6,
    dim     = 0x8C8C8C,
    dark    = 0x000000,
    accent  = 0x00C8FF,
    good    = 0x3FE06A,
    warn    = 0xFFB000,
    bad     = 0xFF4D4D,
    wood    = 0xC8964B,      -- oak log brown
    track   = 0x2A2A2A,      -- empty part of bars
  },
}

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------
local C = config.colors
local gpu = component.gpu
local W, H = 160, 50

-- Call a component method safely; returns nil if missing or it errors.
local function try(proxy, method, ...)
  if not proxy then return nil end
  local fn = proxy[method]
  if not fn then return nil end
  local ok, result = pcall(fn, ...)
  if ok then return result end
  return nil
end

local function commas(n)
  local s = tostring(math.floor((n or 0) + 0.5))
  local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (r:gsub("^,", ""))
end

local function fmtSeconds(ticks)
  return string.format("%.1fs", (ticks or 0) / 20)
end

local function fmtUptime(s)
  s = math.floor(s)
  return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60)
end

----------------------------------------------------------------
-- COMPONENT DISCOVERY
----------------------------------------------------------------
local state = {
  me = nil,          -- AE2 proxy
  farm = nil,        -- { proxy=, address=, name= }
  rs = nil,          -- redstone proxy (redstone mode only)
  lastAction = "none yet",
  reason = "-",
  want = nil,
}

local function findME()
  if config.meAddress then
    local a = component.get(config.meAddress)
    if a then return component.proxy(a) end
    return nil
  end
  for _, t in ipairs({ "me_controller", "me_interface" }) do
    local a = component.list(t)()
    if a then return component.proxy(a) end
  end
  return nil
end

local function findFarm()
  if config.farmAddress then
    local a = component.get(config.farmAddress)
    if a then return { proxy = component.proxy(a), address = a } end
    return nil
  end
  for a in component.list("gt_machine") do
    local p = component.proxy(a)
    local name = try(p, "getName")
    if name then
      local lname = tostring(name):lower()
      for _, pat in ipairs(config.farmNamePatterns) do
        if lname:find(pat, 1, true) then
          return { proxy = p, address = a, name = name }
        end
      end
    end
  end
  return nil
end

local function findRS()
  if config.redstoneAddress then
    local a = component.get(config.redstoneAddress)
    if a then return component.proxy(a) end
    return nil
  end
  local a = component.list("redstone")()
  if a then return component.proxy(a) end
  return nil
end

----------------------------------------------------------------
-- DATA SOURCES
----------------------------------------------------------------
-- Returns total, breakdown(list of {label, size}), errorMessage
local function readLogs()
  if not state.me then return nil, nil, "No ME Controller/Interface found" end
  local total, per = 0, {}
  for _, filter in ipairs(config.logFilters) do
    local ok, items = pcall(state.me.getItemsInNetwork, filter)
    if not ok or type(items) ~= "table" then
      return nil, nil, "ME network unavailable"
    end
    for i = 1, (items.n or #items) do
      local it = items[i]
      if it then
        local size = it.size or 0
        total = total + size
        local label = it.label or it.name or "?"
        per[label] = (per[label] or 0) + size
      end
    end
  end
  local list = {}
  for label, size in pairs(per) do list[#list + 1] = { label = label, size = size } end
  table.sort(list, function(a, b) return a.size > b.size end)
  return total, list, nil
end

local function readFarm()
  local d = { online = false, lines = {} }
  local f = state.farm
  if not f then return d end
  local p = f.proxy
  d.name        = try(p, "getName")
  d.allowed     = try(p, "isWorkAllowed")
  d.active      = try(p, "isMachineActive")
  d.progress    = try(p, "getWorkProgress")
  d.maxProgress = try(p, "getWorkMaxProgress")
  d.euIn        = try(p, "getAverageElectricInput")
  local info = try(p, "getSensorInformation")
  if type(info) == "table" then
    for i = 1, #info do
      local line = tostring(info[i]):gsub("\194\167.", "")  -- strip Minecraft color codes
      line = line:gsub("^%s+", "")
      if line ~= "" then d.lines[#d.lines + 1] = line end
    end
  end
  d.online = (d.name ~= nil) or (d.allowed ~= nil) or (d.active ~= nil)
  return d
end

----------------------------------------------------------------
-- FARM CONTROL
----------------------------------------------------------------
local function farmEnabled()
  if config.controlMode == "redstone" then
    if not state.rs then return nil end
    local ok, lvl = pcall(state.rs.getOutput, config.redstoneSide)
    if ok and type(lvl) == "number" then
      return (lvl > 0) == (config.redstoneOnLevel > 0)
    end
    return nil
  end
  if state.farm then return try(state.farm.proxy, "isWorkAllowed") end
  return nil
end

local function setFarm(enabled)
  if config.controlMode == "redstone" then
    if not state.rs then return false, "no redstone component" end
    local level = enabled and config.redstoneOnLevel or config.redstoneOffLevel
    local ok, err = pcall(state.rs.setOutput, config.redstoneSide, level)
    return ok, err
  end
  if not state.farm then return false, "farm not found" end
  if not state.farm.proxy.setWorkAllowed then return false, "setWorkAllowed unavailable" end
  local ok, err = pcall(state.farm.proxy.setWorkAllowed, enabled)
  return ok, err
end

local function control(total)
  local current = farmEnabled()
  local want
  if total < config.lowThreshold then
    want = true
    state.reason = "logs below " .. commas(config.lowThreshold) .. " -> farm should be ON"
  elseif total >= config.highThreshold then
    want = false
    state.reason = "logs reached " .. commas(config.highThreshold) .. " -> farm should be OFF"
  else
    want = current
    state.reason = "between thresholds -> holding current state"
  end
  if want ~= nil and want ~= current then
    local ok, err = setFarm(want)
    state.lastAction = string.format("[up %s] Farm %s (logs: %s)%s",
      fmtUptime(computer.uptime()),
      want and "ENABLED" or "DISABLED",
      commas(total),
      ok and "" or (" - FAILED: " .. tostring(err)))
  end
  state.want = want
end

----------------------------------------------------------------
-- UI PRIMITIVES (lscstats style)
-- Everything that updates is drawn by overwriting with padded text,
-- never by clearing first, so nothing flickers.
----------------------------------------------------------------
local curFG, curBG
local function fg(c) if c ~= curFG then gpu.setForeground(c); curFG = c end end
local function bg(c) if c ~= curBG then gpu.setBackground(c); curBG = c end end

local function text(x, y, s, f, b)
  if b then bg(b) end
  if f then fg(f) end
  gpu.set(x, y, s)
end

local function fill(x, y, w, h, c)
  if w <= 0 or h <= 0 then return end
  bg(c)
  gpu.fill(x, y, w, h, " ")
end

local function fit(s, w, align)
  s = tostring(s or "")
  local len = unicode.len(s)
  if len > w then return unicode.sub(s, 1, w) end
  if align == "right" then return string.rep(" ", w - len) .. s end
  if align == "center" then
    local l = math.floor((w - len) / 2)
    return string.rep(" ", l) .. s .. string.rep(" ", w - len - l)
  end
  return s .. string.rep(" ", w - len)
end

local function textW(x, y, w, s, f, b, align) text(x, y, fit(s, w, align), f, b or C.panel) end

-- split a long message over several lines of width w
local function wrap(s, w, maxLines)
  local out, line = {}, ""
  for word in tostring(s):gmatch("%S+") do
    if unicode.len(line) + unicode.len(word) + 1 > w and line ~= "" then
      out[#out + 1] = line
      line = word
    else
      line = (line == "") and word or (line .. " " .. word)
    end
  end
  if line ~= "" then out[#out + 1] = line end
  while #out > maxLines do table.remove(out) end
  return out
end

local function panel(x, y, w, h, title, stripColor)
  fill(x, y, w, h, C.panel)
  fill(x, y, w, 1, stripColor or C.accent)
  text(x + 1, y, " " .. title .. " ", C.dark, stripColor or C.accent)
end

local function kv(x, y, w, key, val, valColor, kw)
  kw = kw or 18
  textW(x, y, kw, key, C.dim)
  textW(x + kw, y, w - kw, val, valColor or C.text)
end

-- coloured block with centred text (status "pill")
local function pill(x, y, w, h, label, f, b)
  fill(x, y, w, h, b)
  text(x, y + math.floor((h - 1) / 2), fit(label, w, "center"), f, b)
end

-- thick bar drawn straight to its final colours (no clearing = no flicker)
local function bar(x, y, w, h, frac, color)
  frac = math.max(0, math.min(1, frac or 0))
  local n = math.floor(frac * w + 0.5)
  if n > 0 then fill(x, y, n, h, color) end
  if w - n > 0 then fill(x + n, y, w - n, h, C.track) end
end

-- half-block canvas (2 pixels per character cell) for the big digits
local HALF = unicode.char(0x2580)
local function newCanvas(w, h, c)
  local g = {}
  for i = 1, w * h do g[i] = c end
  return { w = w, h = h, g = g }
end
local function cset(cv, x, y, c)
  if x >= 1 and x <= cv.w and y >= 1 and y <= cv.h then cv.g[(y - 1) * cv.w + x] = c end
end
local function crender(cv, sx, sy)
  local g, w = cv.g, cv.w
  for r = 1, math.ceil(cv.h / 2) do
    local ti = (r * 2 - 2) * w
    local bi = (r * 2 <= cv.h) and (r * 2 - 1) * w or ti
    local x = 1
    while x <= w do
      local t, b = g[ti + x], g[bi + x]
      local x2 = x + 1
      while x2 <= w and g[ti + x2] == t and g[bi + x2] == b do x2 = x2 + 1 end
      if t == b then
        bg(t); gpu.set(sx + x - 1, sy + r - 1, string.rep(" ", x2 - x))
      else
        bg(b); fg(t); gpu.set(sx + x - 1, sy + r - 1, string.rep(HALF, x2 - x))
      end
      x = x2
    end
  end
end

local FONT = {
  ["0"] = { "111", "101", "101", "101", "111" },
  ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "111", "001", "111", "100", "111" },
  ["3"] = { "111", "001", "111", "001", "111" },
  ["4"] = { "101", "101", "111", "001", "001" },
  ["5"] = { "111", "100", "111", "001", "111" },
  ["6"] = { "111", "100", "111", "101", "111" },
  ["7"] = { "111", "001", "001", "001", "001" },
  ["8"] = { "111", "101", "111", "101", "111" },
  ["9"] = { "111", "101", "111", "001", "111" },
  [","] = { "0", "0", "0", "1", "1" },
  ["-"] = { "000", "000", "111", "000", "000" },
}

local function bigWidth(s, xs)
  local w = 0
  for i = 1, #s do
    local g = FONT[s:sub(i, i)]
    if g then w = w + (#g[1] + 1) * xs end
  end
  return math.max(0, w - xs)
end

-- big number, 5 rows tall, centred in a box of width boxW (clears the box itself)
local function bigText(x, y, boxW, s, color, b)
  local xs = (bigWidth(s, 2) <= boxW) and 2 or 1
  local cv = newCanvas(boxW, 10, b)
  local px = math.floor((boxW - bigWidth(s, xs)) / 2) + 1
  for i = 1, #s do
    local glyph = FONT[s:sub(i, i)]
    if glyph then
      local gw = #glyph[1]
      for gy = 1, 5 do
        for gx = 1, gw do
          if glyph[gy]:sub(gx, gx) == "1" then
            for dx = 0, xs - 1 do
              cset(cv, px + (gx - 1) * xs + dx, (gy - 1) * 2 + 1, color)
              cset(cv, px + (gx - 1) * xs + dx, (gy - 1) * 2 + 2, color)
            end
          end
        end
      end
      px = px + (gw + 1) * xs
    end
  end
  crender(cv, x, y)
end

----------------------------------------------------------------
-- UI LAYOUT  (160 x 50)
----------------------------------------------------------------
local LX, LW = 2, 58       -- left column
local RX, RW = 62, 98      -- right column
local INFO_TOP, INFO_ROWS = 21, 26   -- machine info list

local function drawStatic()
  fill(1, 1, W, H, C.bg)
  fill(1, 1, W, 3, C.header)
  text(3, 2, "INDUSTRIAL TREE FARM CONTROLLER", C.accent, C.header)
  text(36, 2, "| Oak Wood / AE2", C.dim, C.header)

  panel(LX, 5, LW, 22, "AE2 OAK WOOD STORAGE", C.wood)
  panel(LX, 28, LW, 21, "CONTROL LOGIC", C.accent)
  panel(RX, 5, RW, 44, "INDUSTRIAL TREE FARM", C.good)

  -- threshold scale under the storage bar (fixed)
  local bx, bw = LX + 2, LW - 4
  local markerFrac = config.lowThreshold / config.highThreshold
  local mx = bx + math.min(bw - 1, math.floor(bw * markerFrac))
  text(bx, 20, "0", C.dim, C.panel)
  text(mx, 20, "▲", C.warn, C.panel)
  textW(bx, 21, bw, "", C.dim)
  text(math.min(mx, bx + bw - 14), 21, "< " .. commas(config.lowThreshold) .. " = ON", C.warn, C.panel)
  local highLabel = ">= " .. commas(config.highThreshold) .. " = OFF"
  text(bx + bw - unicode.len(highLabel), 20, highLabel, C.dim, C.panel)

  -- control rules (fixed)
  textW(LX + 2, 44, LW - 4, "Rules:", C.dim)
  textW(LX + 2, 45, LW - 4, "  logs <  " .. commas(config.lowThreshold) .. "   -> farm ON", C.dim)
  textW(LX + 2, 46, LW - 4, "  logs >= " .. commas(config.highThreshold) .. " -> farm OFF", C.dim)
  textW(LX + 2, 47, LW - 4, "  in between       -> keep current state", C.dim)

  -- machine info header (fixed)
  textW(RX + 2, INFO_TOP - 1, RW - 4, "RECIPE / MACHINE INFO (from controller)", C.accent)

  fill(1, H, W, 1, C.bg)
  text(2, H, "Q: quit (farm keeps its last state)  |  mode: " .. config.controlMode
    .. "  |  update every " .. config.updateInterval .. "s  |  counting: Oak Wood only", C.dim, C.bg)
end

local function drawHeader(fd)
  local label, f, b
  if not state.farm then label, f, b = "FARM NOT FOUND", C.dark, C.bad
  elseif not fd.online then label, f, b = "FARM OFFLINE", C.dark, C.bad
  elseif fd.allowed == false then label, f, b = "FARM DISABLED", C.dark, C.warn
  elseif fd.active then label, f, b = "FARM RUNNING", C.dark, C.good
  else label, f, b = "FARM IDLE", C.text, 0x3A3A3A end
  text(64, 2, fit("  " .. label .. "  ", 32, "center"), f, b)
  text(W - 24, 2, fit("uptime " .. fmtUptime(computer.uptime()), 22, "right"), C.text, C.header)
end

local function drawLogs(total, breakdown, err)
  local x, w = LX + 2, LW - 4
  if not total then
    textW(x, 7, w, "OAK WOOD IN ME NETWORK", C.dim)
    bigText(x, 9, w, "-", C.bad, C.panel)
    textW(x, 15, w, "Log count unavailable: " .. tostring(err), C.bad)
    bar(x, 17, w, 2, 0, C.bad)
    for y = 23, 25 do textW(x, y, w, "") end
    textW(x, 16, w, "")
    return
  end
  local color = C.warn
  local status = "Between thresholds"
  if total < config.lowThreshold then color, status = C.bad, "Below " .. commas(config.lowThreshold) .. " - farm should run"
  elseif total >= config.highThreshold then color, status = C.good, "Full - at or above " .. commas(config.highThreshold) end

  textW(x, 7, w, "OAK WOOD IN ME NETWORK", C.dim)
  bigText(x, 9, w, commas(total), color, C.panel)
  textW(x, 15, w, status, color, nil, "center")
  textW(x, 16, w, string.format("%.1f%% of the OFF threshold", total / config.highThreshold * 100), C.dim, nil, "center")
  bar(x, 17, w, 2, total / config.highThreshold, color)
  -- low-threshold marker drawn on top of the bar
  local mx = x + math.min(w - 1, math.floor(w * config.lowThreshold / config.highThreshold))
  local markerBg = (total / config.highThreshold * w >= mx - x + 1) and color or C.track
  text(mx, 17, "┃", C.warn, markerBg); text(mx, 18, "┃", C.warn, markerBg)

  for i = 1, 3 do
    local e = breakdown[i]
    if e then
      textW(x, 22 + i, w - 16, "  " .. e.label, C.dim)
      textW(x + w - 16, 22 + i, 16, commas(e.size), C.text, nil, "right")
    else
      textW(x, 22 + i, w, "")
    end
  end
end

local function drawControl()
  local x, w = LX + 2, LW - 4
  local cmd, f, b = "UNKNOWN", C.text, 0x3A3A3A
  if state.want == true then cmd, f, b = "ON", C.dark, C.good
  elseif state.want == false then cmd, f, b = "OFF", C.dark, C.warn end
  textW(x, 30, w, "FARM COMMAND", C.dim)
  pill(x, 31, w, 3, "FARM " .. cmd, f, b)
  kv(x, 35, w, "Mode:", config.controlMode)
  local reason = wrap("Reason: " .. tostring(state.reason), w, 2)
  for i = 1, 2 do textW(x, 36 + i, w, reason[i] or "", C.text) end
  local last = wrap("Last action: " .. state.lastAction, w, 3)
  for i = 1, 3 do textW(x, 39 + i, w, last[i] or "", C.dim) end
end

local function drawFarm(fd)
  local x, w = RX + 2, RW - 4
  if not state.farm then
    textW(x, 7, w, "No Industrial Tree Farm found. Set config.farmAddress (see probe.lua).", C.bad)
    for y = 8, 18 do textW(x, y, w, "") end
    for i = 1, INFO_ROWS do textW(x, INFO_TOP + i - 1, w, "") end
    return
  end

  kv(x, 7, w, "Machine:", tostring(fd.name or "?") .. "   [" .. state.farm.address:sub(1, 8) .. "]")

  local status, f, b
  if not fd.online then status, f, b = "OFFLINE / NOT RESPONDING", C.dark, C.bad
  elseif fd.allowed == false then status, f, b = "DISABLED (work not allowed)", C.dark, C.warn
  elseif fd.active then status, f, b = "RUNNING", C.dark, C.good
  else status, f, b = "IDLE / WAITING", C.text, 0x3A3A3A end
  textW(x, 9, 18, "Status:", C.dim)
  pill(x + 18, 9, 40, 1, status, f, b)

  local prog, max = fd.progress or 0, fd.maxProgress or 0
  local frac = (max > 0) and (prog / max) or 0
  textW(x, 11, w, "CRAFT TIME", C.dim)
  bar(x, 12, w - 30, 2, frac, C.accent)
  textW(x + w - 28, 12, 28, string.format("%s / %s", fmtSeconds(prog), fmtSeconds(max)), C.text, nil, "right")
  textW(x + w - 28, 13, 28, string.format("%d%%", math.floor(frac * 100)), C.accent, nil, "right")

  kv(x, 15, w, "EU/t (avg input):", fd.euIn and commas(fd.euIn) or "n/a", C.accent)
  textW(x, 17, w, "", C.text)

  for i = 1, INFO_ROWS do
    local rowBg = (i % 2 == 1) and C.panel2 or C.panel
    text(x, INFO_TOP + i - 1, fit("  " .. (fd.lines[i] or ""), w), C.text, rowBg)
  end
end

----------------------------------------------------------------
-- MAIN LOOP
----------------------------------------------------------------
local function run()
  local maxW, maxH = gpu.maxResolution()
  W = math.min(config.resolution[1], maxW)
  H = math.min(config.resolution[2], maxH)
  if W < 160 or H < 50 then
    error("This screen layout needs a tier 3 GPU and tier 3 screen (160x50).", 0)
  end
  gpu.setResolution(W, H)
  term.setCursorBlink(false)
  drawStatic()

  while true do
    if not state.me then state.me = findME() end
    if not state.farm then state.farm = findFarm() end
    if config.controlMode == "redstone" and not state.rs then state.rs = findRS() end

    local total, breakdown, err = readLogs()
    if err then state.me = nil end  -- force re-discovery next cycle

    local fd = readFarm()
    if total then
      control(total)
    else
      state.reason = "ME read failed -> holding current state"
      state.want = farmEnabled()
    end

    drawLogs(total, breakdown, err)
    drawControl()
    drawFarm(fd)
    drawHeader(fd)

    local ev, _, ch = event.pull(config.updateInterval)
    if ev == "key_down" and (ch == 113 or ch == 81) then break end
  end
end

local ok, err = pcall(run)

pcall(function()
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  gpu.setResolution(gpu.maxResolution())
  term.clear()
end)

if not ok and not tostring(err):find("interrupted") then
  io.stderr:write("treefarm crashed: " .. tostring(err) .. "\n")
end
