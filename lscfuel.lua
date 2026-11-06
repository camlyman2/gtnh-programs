--[[
  lscfuel.lua - Lapotronic Supercapacitor (LSC) fuel controller for GTNH / OpenComputers

  * Reads the LSC charge % from an Adapter touching the LSC controller
  * Turns a redstone signal ON  (fluid regulators run) when charge < lowPercent  (10%)
  * Keeps it ON until charge >= highPercent (95%), then turns it OFF (hysteresis)
  * Between the two thresholds it holds whatever the output already is
  * If the LSC cannot be read, it changes nothing

  Run with:  lscfuel      (if saved as /home/bin/lscfuel.lua)
  Quit with: Q
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
  lowPercent     = 10,    -- regulators turn ON  below this charge %
  highPercent    = 95,    -- regulators turn OFF at/above this charge %
  updateInterval = 1,     -- seconds between LSC reads / control decisions
  frameInterval  = 0.25,  -- seconds between screen animation frames

  -- Leave nil to auto-detect. Otherwise paste the full or partial address.
  lscAddress      = nil,
  lscNamePatterns = { "supercapacitor" },   -- matched against getName()

  -- Redstone I/O block (or redstone card). nil = first one found.
  redstoneAddress = nil,
  -- Faces of the Redstone I/O that output the signal. List several to power
  -- several neighbours at once, e.g. { sides.top, sides.east }.
  -- Use the side test from the guide to find the right face(s).
  outputSides = { sides.top },
  onLevel     = 15,       -- signal strength that means "regulators ON"
  offLevel    = 0,        -- signal strength that means "regulators OFF"

  -- What to do with the signal when this program quits or crashes:
  --   "off"  = switch the regulators off (nothing is watching the LSC any more)
  --   "hold" = leave the signal as it is
  onExit = "off",

  resolution = { 100, 34 },

  colors = {
    background = 0x0B0F14,
    border     = 0x2A3A5A,
    text       = 0xD8DCF0,
    dim        = 0x7F8AA8,
    accent     = 0x00B7FF,
    good       = 0x3FD068,
    warn       = 0xF0C030,
    bad        = 0xF05050,
    barBg      = 0x1A2230,
    gradLow    = 0xE03030,
    gradMid    = 0xF0A020,
    gradHigh   = 0x30D060,
  },
}

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------
local C = config.colors
local gpu = component.gpu
local W, H = 100, 34

local function try(proxy, method, ...)
  if not proxy then return nil end
  local fn = proxy[method]
  if not fn then return nil end
  local ok, result = pcall(fn, ...)
  if ok then return result end
  return nil
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function commas(n)
  local s = string.format("%.0f", n or 0)
  local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (r:gsub("^,", ""))
end

local function fmtUptime(s)
  s = math.floor(s)
  return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60)
end

local function rgb(c)
  return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
end

local function mix(c1, c2, t)
  t = clamp(t, 0, 1)
  local r1, g1, b1 = rgb(c1)
  local r2, g2, b2 = rgb(c2)
  local r = math.floor(r1 + (r2 - r1) * t + 0.5)
  local g = math.floor(g1 + (g2 - g1) * t + 0.5)
  local b = math.floor(b1 + (b2 - b1) * t + 0.5)
  return r * 65536 + g * 256 + b
end

local function gradient(t)
  t = clamp(t, 0, 1)
  if t < 0.5 then return mix(C.gradLow, C.gradMid, t / 0.5) end
  return mix(C.gradMid, C.gradHigh, (t - 0.5) / 0.5)
end

----------------------------------------------------------------
-- STATE + COMPONENT DISCOVERY
----------------------------------------------------------------
local state = {
  lsc = nil,        -- { proxy=, address= }
  rs = nil,         -- redstone proxy
  rsAddress = nil,
  data = nil,       -- last LSC reading
  outputOn = nil,   -- true/false/nil (unknown)
  reason = "-",
  lastAction = "none yet",
}

local function findLSC()
  if config.lscAddress then
    local a = component.get(config.lscAddress)
    if a then return { proxy = component.proxy(a), address = a } end
    return nil
  end
  for a in component.list("gt_machine") do
    local p = component.proxy(a)
    local name = try(p, "getName")
    if name then
      local lname = tostring(name):lower()
      for _, pat in ipairs(config.lscNamePatterns) do
        if lname:find(pat, 1, true) then return { proxy = p, address = a } end
      end
    end
  end
  return nil
end

local function findRS()
  if config.redstoneAddress then
    local a = component.get(config.redstoneAddress)
    if a then return component.proxy(a), a end
    return nil
  end
  local a = component.list("redstone")()
  if a then return component.proxy(a), a end
  return nil
end

----------------------------------------------------------------
-- LSC DATA
----------------------------------------------------------------
-- The LSC reports translation keys, e.g.
--   kekztech.infodata.lapotronic_super_capacitor.used_capacity\\0.000000%
-- so we parse by key instead of showing the raw lines.

local function stripCodes(s)
  return (tostring(s):gsub("\194\167.", ""))
end

-- Number at the start of a string. Returns nil for things like "1.08x10^10".
local function leadingNumber(val)
  local s = val:gsub(",", "")
  local n, rest = s:match("^%s*(%d+%.?%d*)(.*)$")
  if not n then return nil end
  if rest:match("^%s*[xXeE%^]") then return nil end
  return tonumber(n)
end

local function digitsToNumber(s)
  if type(s) == "number" then return s end
  if type(s) ~= "string" then return nil end
  local digits = s:gsub("[^%d]", "")
  if digits == "" then return nil end
  return tonumber(digits)
end

local function parseInfo(d, info)
  for i = 1, #info do
    local line = stripCodes(info[i])
    local key, val = line:match("^(.-)\\+(.*)$")
    if not key then key, val = line, "" end

    if key:find("used_capacity", 1, true) then
      d.percent = d.percent or leadingNumber(val)
    elseif key:find("total_capacity", 1, true) then
      d.capacity = d.capacity or leadingNumber(val)
    elseif key:find("eu_stored", 1, true) then
      d.stored = d.stored or leadingNumber(val)
    elseif key:find("passive_loss", 1, true) then
      d.passive = d.passive or leadingNumber(val)
    elseif key:find("avg_eu_in.sec", 1, true) then
      d.avgIn = d.avgIn or leadingNumber(val)
    elseif key:find("avg_eu_out.sec", 1, true) then
      d.avgOut = d.avgOut or leadingNumber(val)
    elseif key:find("time_to", 1, true) then
      d.timeTo[#d.timeTo + 1] = { which = key:match("time_to%.(%w+)") or "?", text = val }
    elseif key:find("wireless_mode", 1, true) then
      d.wirelessMode = key:match("wireless_mode%.(%w+)") or val
    elseif key:find("wireless_eu", 1, true) then
      d.wirelessEU = d.wirelessEU or leadingNumber(val)
    elseif key:find("maintenance_status", 1, true) then
      d.maintenance = key:match("maintenance_status%.(%w+)") or val
    elseif key:find("capacitors", 1, true) then
      local tier, count = val:match("^(%w+)\\+(%d+)")
      if tier then d.capacitors[#d.capacitors + 1] = tier .. " x" .. count end
    end
  end
end

local function readLSC()
  local d = { online = false, capacitors = {}, timeTo = {} }
  local f = state.lsc
  if not f then return d end
  local p = f.proxy
  d.name   = try(p, "getName")
  d.active = try(p, "isMachineActive")

  local info = try(p, "getSensorInformation")
  if type(info) == "table" then parseInfo(d, info) end

  -- Fallbacks if the sensor text was missing or changed format
  if not d.stored   then d.stored   = digitsToNumber(try(p, "getStoredEUString")) end
  if not d.capacity then d.capacity = digitsToNumber(try(p, "getEUCapacityString")) end
  if not d.percent and d.stored and d.capacity and d.capacity > 0 then
    d.percent = d.stored / d.capacity * 100
  end
  if d.percent then d.percent = clamp(d.percent, 0, 100) end

  d.online = d.name ~= nil
  return d
end

----------------------------------------------------------------
-- REDSTONE CONTROL
----------------------------------------------------------------
local function outputOn()
  if not state.rs then return nil end
  local ok, lvl = pcall(state.rs.getOutput, config.outputSides[1])
  if not ok or type(lvl) ~= "number" then return nil end
  return lvl > 0
end

local function setOutput(on)
  if not state.rs then return false, "no Redstone I/O found" end
  local level = on and config.onLevel or config.offLevel
  for _, s in ipairs(config.outputSides) do
    local ok, err = pcall(state.rs.setOutput, s, level)
    if not ok then return false, tostring(err) end
  end
  return true
end

local function control(pct)
  local current = outputOn()
  local want
  if pct < config.lowPercent then
    want = true
    state.reason = string.format("charge below %g%% -> regulators should be ON", config.lowPercent)
  elseif pct >= config.highPercent then
    want = false
    state.reason = string.format("charge reached %g%% -> regulators should be OFF", config.highPercent)
  else
    want = current
    state.reason = "between thresholds -> holding current output"
  end
  if want ~= nil and want ~= current then
    local ok, err = setOutput(want)
    state.lastAction = string.format("[up %s] Regulators %s (charge %.1f%%)%s",
      fmtUptime(computer.uptime()),
      want and "ENABLED" or "DISABLED",
      pct,
      ok and "" or (" - FAILED: " .. tostring(err)))
  end
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

-- Big 3x5 block font. '#' = filled, '.' = empty.
local FONT = {
  ["0"] = { "###", "#.#", "#.#", "#.#", "###" },
  ["1"] = { ".#.", "##.", ".#.", ".#.", "###" },
  ["2"] = { "###", "..#", "###", "#..", "###" },
  ["3"] = { "###", "..#", "###", "..#", "###" },
  ["4"] = { "#.#", "#.#", "###", "..#", "..#" },
  ["5"] = { "###", "#..", "###", "..#", "###" },
  ["6"] = { "###", "#..", "###", "#.#", "###" },
  ["7"] = { "###", "..#", "..#", "..#", "..#" },
  ["8"] = { "###", "#.#", "###", "#.#", "###" },
  ["9"] = { "###", "#.#", "###", "..#", "###" },
  ["."] = { ".", ".", ".", ".", "#" },
  ["%"] = { "#.#", "..#", ".#.", "#..", "#.#" },
  ["-"] = { "...", "...", "###", "...", "..." },
}

local function drawBig(x, y, text, color)
  local rows = { "", "", "", "", "" }
  for i = 1, #text do
    local g = FONT[text:sub(i, i)] or FONT["-"]
    for r = 1, 5 do
      local line = g[r]:gsub("#", "██"):gsub("%.", "  ")
      rows[r] = rows[r] .. line .. "  "
    end
  end
  for r = 1, 5 do put(x, y + r - 1, fit(rows[r], 52), color) end
end

----------------------------------------------------------------
-- UI: THE CHARGE BAR
----------------------------------------------------------------
local BAR_X, BAR_Y, BAR_W = 4, 12, 86
local PARTIAL = { "▏", "▎", "▍", "▌", "▋", "▊", "▉" }   -- 1/8 .. 7/8 blocks

local function drawBarFrame(color)
  gpu.setBackground(C.background)
  gpu.setForeground(color)
  gpu.set(BAR_X - 1, BAR_Y - 1, "╔" .. string.rep("═", BAR_W) .. "╗")
  gpu.set(BAR_X - 1, BAR_Y + 3, "╚" .. string.rep("═", BAR_W) .. "╝")
  for r = 0, 2 do
    gpu.set(BAR_X - 1, BAR_Y + r, "║")
    gpu.set(BAR_X + BAR_W, BAR_Y + r, "║")
    gpu.set(BAR_X + BAR_W + 1, BAR_Y + r, "██")   -- battery terminal
  end
end

local function drawBar(pct, on, frame)
  pct = pct or 0
  local fill = pct / 100 * BAR_W
  local full = math.min(BAR_W, math.floor(fill))
  local eighths = (full >= BAR_W) and 0 or math.floor((fill - full) * 8)

  -- Merge neighbouring cells of the same gradient shade into runs
  local runs = {}
  for i = 0, full - 1 do
    local q = math.floor(i / BAR_W * 16)
    local last = runs[#runs]
    if last and last.q == q then
      last.n = last.n + 1
    else
      runs[#runs + 1] = { q = q, x = i, n = 1 }
    end
  end

  local emptyStart = full + (eighths > 0 and 1 or 0)
  for row = 0, 2 do
    local y = BAR_Y + row
    gpu.setBackground(C.barBg)
    for _, r in ipairs(runs) do
      gpu.setForeground(gradient((r.q + 0.5) / 16))
      gpu.set(BAR_X + r.x, y, string.rep("█", r.n))
    end
    if eighths > 0 then
      gpu.setForeground(gradient(full / BAR_W))
      gpu.set(BAR_X + full, y, PARTIAL[eighths])
    end
    if emptyStart < BAR_W then
      gpu.setForeground(C.barBg)
      gpu.set(BAR_X + emptyStart, y, string.rep(" ", BAR_W - emptyStart))
    end
  end

  -- Moving highlight while the regulators are running ("charging")
  if on and full > 3 then
    local pos = (frame * 3) % (full + 6) - 3
    for i = pos, pos + 2 do
      if i >= 0 and i < full then
        gpu.setBackground(C.barBg)
        gpu.setForeground(mix(gradient(i / BAR_W), 0xFFFFFF, 0.55))
        for row = 0, 2 do gpu.set(BAR_X + i, BAR_Y + row, "█") end
      end
    end
  end

  -- Frame pulses while running
  local frameColor = C.border
  if on then frameColor = (frame % 4 < 2) and 0x00E5FF or 0x0077AA end
  drawBarFrame(frameColor)
end

----------------------------------------------------------------
-- UI LAYOUT
----------------------------------------------------------------
local function drawStatic()
  gpu.setBackground(C.background)
  gpu.fill(1, 1, W, H, " ")
  gpu.setBackground(C.accent)
  gpu.fill(1, 1, W, 1, " ")
  put(2, 1, " LSC POWER CONTROLLER ", 0xFFFFFF, C.accent)

  panel(1, 3, W, 17, "LAPOTRONIC SUPERCAPACITOR")
  panel(1, 20, W, 8, "ENERGY FLOW")
  panel(1, 28, W, 6, "CONTROLLER")

  -- Threshold markers under the bar
  local lowX  = BAR_X + math.floor(BAR_W * config.lowPercent / 100)
  local highX = BAR_X + math.floor(BAR_W * config.highPercent / 100)
  put(lowX, 16, "▲", C.bad)
  put(highX, 16, "▲", C.good)
  put(lowX, 17, string.format("%g%%  fuel ON below", config.lowPercent), C.bad)
  local highLabel = string.format("fuel OFF at %g%%", config.highPercent)
  put(highX - #highLabel + 1, 17, highLabel, C.good)
  put(BAR_X, 17, "0%", C.dim)
  put(BAR_X + BAR_W - 4, 17, "100%", C.dim)

  put(2, H, " Press Q to quit ", C.dim)
end

local function render(frame)
  local d = state.data or { capacitors = {}, timeTo = {} }
  local pct = d.percent
  local on = state.outputOn
  local x, w = 3, W - 4

  put(W - 20, 1, fit("uptime " .. fmtUptime(computer.uptime()), 19), 0xFFFFFF, C.accent)

  -- Panel 1: stored line, big percentage, status banner, bar
  if not state.lsc then
    field(x, 4, w, "LSC not found. Set config.lscAddress (see probe.lua).", C.bad)
  elseif not d.online then
    field(x, 4, w, "LSC not responding.", C.bad)
  elseif d.stored and d.capacity then
    field(x, 4, w, "Stored: " .. commas(d.stored) .. " EU  of  " .. commas(d.capacity) .. " EU", C.text)
  else
    field(x, 4, w, "Stored: n/a", C.dim)
  end

  drawBig(4, 5, pct and string.format("%.1f%%", pct) or "--.-%", pct and gradient(pct / 100) or C.dim)

  local RX, RW = 58, W - 60
  local text, fg, bg
  if on == true then
    text, fg, bg = "FUEL REGULATORS: ON", 0x001A0A, 0x2ECC71
  elseif on == false then
    text, fg, bg = "FUEL REGULATORS: OFF", 0xFFFFFF, 0x3A4058
  else
    text, fg, bg = "REGULATOR OUTPUT: UNKNOWN", 0xFFFFFF, 0xA03030
  end
  gpu.setBackground(bg)
  gpu.fill(RX, 5, RW, 1, " ")
  gpu.fill(RX, 7, RW, 1, " ")
  local pad = math.max(0, math.floor((RW - unicode.len(text)) / 2))
  put(RX, 6, fit(string.rep(" ", pad) .. text, RW), fg, bg)

  if on == true then
    local s = ""
    for i = 0, RW - 1 do s = s .. (((i - frame) % 4 == 0) and "»" or " ") end
    put(RX, 8, fit(s, RW), C.good)
  else
    field(RX, 8, RW, "regulators idle", C.dim)
  end
  field(RX, 9, RW, string.format("ON below %g%%   |   OFF at %g%%", config.lowPercent, config.highPercent), C.dim)

  drawBar(pct, on == true, frame)

  -- Panel 2: energy flow
  local ex = 3
  field(ex, 21, w, string.format("Average input (5s):  %s      Average output (5s):  %s",
    d.avgIn and commas(d.avgIn) or "n/a", d.avgOut and commas(d.avgOut) or "n/a"))
  field(ex, 22, w, "Passive loss:  " .. (d.passive and (commas(d.passive) .. " EU/t") or "n/a"))
  if #d.timeTo > 0 then
    local t = d.timeTo[1]
    field(ex, 23, w, "Time to " .. t.which .. ":  " .. t.text)
  else
    field(ex, 23, w, "Time to empty/full:  n/a", C.dim)
  end
  field(ex, 24, w, "Capacitors:  " .. (#d.capacitors > 0 and table.concat(d.capacitors, "   ") or "n/a"))
  field(ex, 25, w, "Wireless mode:  " .. tostring(d.wirelessMode or "n/a") ..
    (d.wirelessEU and ("   (wireless EU: " .. commas(d.wirelessEU) .. ")") or ""))
  local mColor = (d.maintenance == "ok") and C.good or C.warn
  field(ex, 26, w, "Maintenance:  " .. tostring(d.maintenance or "n/a"), d.maintenance and mColor or C.dim)

  -- Panel 3: controller
  local status, sColor
  if not d.online then status, sColor = "OFFLINE", C.bad
  elseif d.active then status, sColor = "ACTIVE", C.good
  else status, sColor = "IDLE", C.dim end
  field(ex, 29, w, "LSC: " .. tostring(d.name or "?") ..
    (state.lsc and ("  [" .. state.lsc.address:sub(1, 8) .. "]") or "") .. "   status: " .. status, sColor)

  if state.rs then
    local names = {}
    for _, s in ipairs(config.outputSides) do names[#names + 1] = tostring(sides[s] or s) end
    field(ex, 30, w, "Redstone I/O: " .. state.rsAddress:sub(1, 8) .. "   output sides: " ..
      table.concat(names, ", ") .. "   ON=" .. config.onLevel .. "  OFF=" .. config.offLevel)
  else
    field(ex, 30, w, "No Redstone I/O found - regulators cannot be controlled!", C.bad)
  end
  field(ex, 31, w, "Reason: " .. tostring(state.reason))
  field(ex, 32, w, "Last action: " .. state.lastAction, C.dim)
end

----------------------------------------------------------------
-- MAIN LOOP
----------------------------------------------------------------
local function poll()
  if not state.lsc then state.lsc = findLSC() end
  if not state.rs then state.rs, state.rsAddress = findRS() end

  local d = readLSC()
  state.data = d
  if not d.online then state.lsc = nil end  -- force re-discovery

  if d.percent then
    control(d.percent)
  else
    state.reason = "LSC read failed -> holding current output"
  end
  state.outputOn = outputOn()
end

local function run()
  local maxW, maxH = gpu.maxResolution()
  W = math.min(config.resolution[1], maxW)
  H = math.min(config.resolution[2], maxH)
  BAR_W = W - 14
  gpu.setResolution(W, H)
  term.setCursorBlink(false)
  drawStatic()

  local frame = 0
  local lastPoll = -math.huge
  while true do
    if computer.uptime() - lastPoll >= config.updateInterval then
      lastPoll = computer.uptime()
      poll()
    end
    frame = frame + 1
    render(frame)
    local ev, _, ch = event.pull(config.frameInterval)
    if ev == "key_down" and (ch == 113 or ch == 81) then break end
  end
end

local ok, err = pcall(run)

if config.onExit == "off" and state.rs then
  pcall(setOutput, false)
end

pcall(function()
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  gpu.setResolution(gpu.maxResolution())
  term.clear()
end)

if not ok and not tostring(err):find("interrupted") then
  io.stderr:write("lscfuel crashed: " .. tostring(err) .. "\n")
end
