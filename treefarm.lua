--[[
  treefarm.lua - Industrial Tree Farm controller for GTNH (OpenComputers)

  * Reads the log count from your AE2 network (ME Controller / ME Interface via Adapter)
  * Turns the farm ON  when logs <  lowThreshold   (100,000)
  * Turns the farm OFF when logs >= highThreshold  (1,000,000)
  * Between the two it keeps whatever state the farm is already in (hysteresis)
  * Shows a status screen: log count, control logic, craft time, EU/t, machine info

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
  -- Add entries for any modded logs your farm produces.
  logFilters = {
    { name = "minecraft:log"  },   -- oak, spruce, birch, jungle
    { name = "minecraft:log2" },   -- acacia, dark oak
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

  resolution = { 100, 32 },  -- clamped to what your GPU/screen supports

  colors = {
    background = 0x14141C,
    border     = 0x4A5078,
    text       = 0xD8DCF0,
    dim        = 0x8890B0,
    accent     = 0x2F6FDE,
    good       = 0x3FD068,
    warn       = 0xF0C030,
    bad        = 0xF05050,
  },
}

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------
local C = config.colors
local gpu = component.gpu
local W, H = 100, 32

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
-- UI PRIMITIVES
----------------------------------------------------------------
local function fit(text, width)
  text = tostring(text or "")
  local len = unicode.len(text)
  if len > width then return unicode.sub(text, 1, width) end
  return text .. string.rep(" ", width - len)
end

local function put(x, y, text, fg, bg)
  gpu.setBackground(bg or C.background)
  gpu.setForeground(fg or C.text)
  gpu.set(x, y, text)
end

local function field(x, y, width, text, fg)
  put(x, y, fit(text, width), fg)
end

local function panel(x, y, w, h, title)
  gpu.setBackground(C.background)
  gpu.setForeground(C.border)
  gpu.fill(x, y, w, h, " ")
  gpu.set(x, y, "┌" .. string.rep("─", w - 2) .. "┐")
  gpu.set(x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘")
  gpu.fill(x, y + 1, 1, h - 2, "│")
  gpu.fill(x + w - 1, y + 1, 1, h - 2, "│")
  if title then put(x + 2, y, " " .. title .. " ", C.accent) end
end

local function bar(x, y, width, fraction, color, markerFraction)
  fraction = math.max(0, math.min(1, fraction or 0))
  local filled = math.floor(width * fraction + 0.5)
  gpu.setBackground(C.background)
  gpu.setForeground(color)
  if filled > 0 then gpu.set(x, y, string.rep("█", filled)) end
  gpu.setForeground(C.border)
  if width - filled > 0 then gpu.set(x + filled, y, string.rep("░", width - filled)) end
  if markerFraction then
    local mx = x + math.min(width - 1, math.floor(width * markerFraction))
    gpu.setForeground(C.warn)
    gpu.set(mx, y, "┃")
  end
end

----------------------------------------------------------------
-- UI LAYOUT
----------------------------------------------------------------
local BAR_X, BAR_W

local function drawStatic()
  gpu.setBackground(C.background)
  gpu.fill(1, 1, W, H, " ")
  gpu.setBackground(C.accent)
  gpu.fill(1, 1, W, 1, " ")
  put(2, 1, " INDUSTRIAL TREE FARM CONTROLLER ", 0xFFFFFF, C.accent)

  panel(1, 3, W, 8, "AE2 LOG STORAGE")
  panel(1, 11, W, 5, "CONTROL LOGIC")
  panel(1, 16, W, H - 16, "INDUSTRIAL TREE FARM")

  BAR_X, BAR_W = 3, W - 4
  local markerFrac = config.lowThreshold / config.highThreshold
  put(BAR_X, 6, "0", C.dim)
  local lowLabel = "< " .. commas(config.lowThreshold) .. " = ON"
  put(BAR_X + math.floor(BAR_W * markerFrac), 6, lowLabel, C.warn)
  local highLabel = ">= " .. commas(config.highThreshold) .. " = OFF"
  put(W - 1 - #highLabel, 6, highLabel, C.dim)

  put(2, H, " Press Q to quit (farm keeps its last state) ", C.dim)
end

local function drawLogs(total, breakdown, err)
  if not total then
    field(3, 4, W - 4, "Log count unavailable: " .. tostring(err), C.bad)
    bar(BAR_X, 5, BAR_W, 0, C.bad, config.lowThreshold / config.highThreshold)
    for y = 7, 9 do field(3, y, W - 4, "") end
    return
  end
  local color = C.warn
  if total < config.lowThreshold then color = C.bad
  elseif total >= config.highThreshold then color = C.good end

  field(3, 4, W - 4, "Total logs in ME network: " .. commas(total), color)
  bar(BAR_X, 5, BAR_W, total / config.highThreshold, color, config.lowThreshold / config.highThreshold)
  for i = 1, 3 do
    local e = breakdown[i]
    if e then
      field(3, 6 + i, W - 4, string.format("  %-34s %14s", e.label:sub(1, 34), commas(e.size)), C.dim)
    else
      field(3, 6 + i, W - 4, "")
    end
  end
end

local function drawControl()
  local cmd = "UNKNOWN"
  local color = C.dim
  if state.want == true then cmd, color = "ON", C.good
  elseif state.want == false then cmd, color = "OFF", C.warn end
  field(3, 12, W - 4, "Farm command: " .. cmd .. "     (mode: " .. config.controlMode .. ")", color)
  field(3, 13, W - 4, "Reason: " .. tostring(state.reason))
  field(3, 14, W - 4, "Last action: " .. state.lastAction, C.dim)
end

local function drawFarm(fd)
  local x, w = 3, W - 4
  local top, bottom = 17, H - 2
  if not state.farm then
    field(x, top, w, "No Industrial Tree Farm found. Set config.farmAddress (see probe.lua).", C.bad)
    for y = top + 1, bottom do field(x, y, w, "") end
    return
  end

  field(x, top, w, "Machine: " .. tostring(fd.name or "?") .. "   [" .. state.farm.address:sub(1, 8) .. "]")

  local status, color
  if not fd.online then status, color = "OFFLINE / NOT RESPONDING", C.bad
  elseif fd.allowed == false then status, color = "DISABLED (work not allowed)", C.warn
  elseif fd.active then status, color = "RUNNING", C.good
  else status, color = "IDLE / WAITING", C.dim end
  field(x, top + 1, w, "Status:  " .. status, color)

  local prog, max = fd.progress or 0, fd.maxProgress or 0
  local frac = (max > 0) and (prog / max) or 0
  field(x, top + 2, 12, "Craft time:")
  bar(x + 12, top + 2, 36, frac, C.accent)
  field(x + 50, top + 2, w - 50,
    string.format("%s / %s (%d%%)", fmtSeconds(prog), fmtSeconds(max), math.floor(frac * 100)))

  field(x, top + 3, w, "EU/t (avg input): " .. (fd.euIn and commas(fd.euIn) or "n/a"))
  field(x, top + 4, w, "Recipe / machine info (from controller):", C.dim)
  for i = 1, bottom - (top + 4) do
    field(x, top + 4 + i, w, fd.lines[i] or "")
  end
end

----------------------------------------------------------------
-- MAIN LOOP
----------------------------------------------------------------
local function run()
  local maxW, maxH = gpu.maxResolution()
  W = math.min(config.resolution[1], maxW)
  H = math.min(config.resolution[2], maxH)
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
    put(W - 20, 1, fit("uptime " .. fmtUptime(computer.uptime()), 19), 0xFFFFFF, C.accent)

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
