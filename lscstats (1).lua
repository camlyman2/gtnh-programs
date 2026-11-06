--[[
  lscstats.lua  -  LSC Charge Cycle Monitor (GTNH / OpenComputers)

  Companion to lscfuel.lua. Watches the SAME Redstone I/O block that
  lscfuel drives. The fuel signal is "ON" when lscfuel is outputting a
  redstone signal (strength > 0) - that is what turns the fluid
  regulators (benzene + combustion promoter) on - and "OFF" at 0.

    OFF -> ON  = charging cycle START (timestamp logged)
    ON  -> OFF = charging cycle STOP  (timestamp logged)

  Keeps the last 8 completed cycles on disk, shows the current and
  previous cycle, and graphs Nitrobenzene used per cycle
  (duration in seconds x burn rate in L/s). The burn rate is editable
  on screen and saved between restarts.

  Timestamps are REAL-WORLD US Eastern time (EST/EDT, DST handled
  automatically). OpenComputers' os.time()/os.date() use in-game time,
  so the real clock is read from a file's lastModified time instead.

  Needs: tier 3 GPU + tier 3 screen (160x50), keyboard on the screen
  (for typing a new rate), and network access to the Redstone I/O.
  Exit with Ctrl+C.
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  -- Address (full or first few characters) of the Redstone I/O block
  -- lscfuel uses. nil = auto, only works if exactly ONE redstone
  -- component is visible to this computer (a redstone card counts!).
  RS_ADDRESS = nil,

  -- Side number lscfuel outputs on (0=bottom 1=top 2=back 3=front
  -- 4=right 5=left). nil = signal is ON if ANY side is outputting.
  RS_SIDE = nil,

  -- Nitrobenzene burn rate in L per second. Only used the very first
  -- run; after that change it on screen (it is saved to DATA_FILE).
  DEFAULT_RATE = 4000,

  MAX_CYCLES = 8,              -- cycles kept in the log / graph
  MIN_CYCLE_SECONDS = 0,       -- ignore cycles shorter than this (e.g. 2 to drop misclicks)
  POLL_INTERVAL = 0.25,        -- seconds between redstone checks
  CLOCK_OFFSET_SECONDS = 0,    -- add/subtract if the server's clock is wrong
  DATA_FILE = "/home/lscstats.dat",
}

--------------------------------------------------------------- MODULES
local component     = require("component")
local computer      = require("computer")
local event         = require("event")
local filesystem    = require("filesystem")
local serialization = require("serialization")
local unicode       = require("unicode")
local term          = require("term")

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

---------------------------------------------------------------- COLORS
local C = {
  bg      = 0x0B0B0B,
  panel   = 0x161616,
  panel2  = 0x1E1E1E,   -- alternating table rows
  header  = 0x0E2A38,
  text    = 0xE6E6E6,
  dim     = 0x8C8C8C,
  dark    = 0x000000,
  accent  = 0x00C8FF,
  good    = 0x3FE06A,
  warn    = 0xFFB000,
  bad     = 0xFF4D4D,
  nb      = 0xFFD84A,   -- nitrobenzene yellow
  grid    = 0x333333,
  axis    = 0x6E6E6E,
  button  = 0x2E4A5A,
  buttonH = 0x00799C,
}

------------------------------------------------------------ COMPONENTS
local gpu = component.gpu

local function findRedstone()
  if CONFIG.RS_ADDRESS then
    local full = component.get(CONFIG.RS_ADDRESS, "redstone")
    if not full then
      error("No redstone component matches RS_ADDRESS '" .. CONFIG.RS_ADDRESS .. "'", 0)
    end
    return component.proxy(full)
  end
  local list = {}
  for addr in component.list("redstone") do list[#list + 1] = addr end
  if #list == 0 then
    error("No redstone component found. Connect this computer to the Redstone I/O block's network.", 0)
  elseif #list > 1 then
    local msg = "More than one redstone component found. Set CONFIG.RS_ADDRESS to one of:\n"
    for _, a in ipairs(list) do msg = msg .. "  " .. a .. "\n" end
    error(msg, 0)
  end
  return component.proxy(list[1])
end

local rs = findRedstone()
local SIDE_NAMES = { [0] = "bottom", "top", "back", "front", "right", "left" }

local signalError = false
local function readSignal(previous)
  local ok, result = pcall(function()
    if CONFIG.RS_SIDE then
      return (rs.getOutput(CONFIG.RS_SIDE) or 0) > 0
    end
    for s = 0, 5 do
      if (rs.getOutput(s) or 0) > 0 then return true end
    end
    return false
  end)
  signalError = not ok
  if ok then return result end
  return previous   -- keep last known state if the block is unreachable
end

------------------------------------------------------- REAL-WORLD TIME
-- Writing a file stamps it with the server's real clock (ms since 1970,
-- timezone independent). That is our real-time source.
local TIME_PATHS = { "/tmp/.lscstats_clock", "/home/.lscstats_clock" }
local clockOK, lastRealS, lastRealUp = false, nil, nil

local function readFileClock()
  for _, p in ipairs(TIME_PATHS) do
    local f = io.open(p, "w")
    if f then
      f:write(tostring(computer.uptime()))
      f:close()
      local v = filesystem.lastModified(p)
      if v and v > 1e9 then
        if v > 1e11 then v = v / 1000 end   -- ms -> s
        return v
      end
    end
  end
end

local function now()
  local v = readFileClock()
  if v then
    clockOK, lastRealS, lastRealUp = true, v, computer.uptime()
    return v + CONFIG.CLOCK_OFFSET_SECONDS
  end
  if lastRealS then
    return lastRealS + (computer.uptime() - lastRealUp) + CONFIG.CLOCK_OFFSET_SECONDS
  end
  clockOK = false
  return computer.uptime()
end

-- Calendar math (proleptic Gregorian, days since 1970-01-01)
local function civilFromDays(z)
  z = z + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local d = doy - floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return y, m, d
end

local function daysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = m > 2 and m - 3 or m + 9
  local doy = floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function nthSunday(y, m, n)
  local first = daysFromCivil(y, m, 1)
  local dow = (first + 4) % 7          -- 0 = Sunday (1970-01-01 was a Thursday)
  return first + (7 - dow) % 7 + (n - 1) * 7
end

-- US Eastern DST: 2nd Sunday of March 2:00 EST -> 1st Sunday of Nov 2:00 EDT
local function isEasternDST(utc)
  local y = civilFromDays(floor(utc / 86400))
  local startUTC = nthSunday(y, 3, 2) * 86400 + 7 * 3600
  local endUTC   = nthSunday(y, 11, 1) * 86400 + 6 * 3600
  return utc >= startUTC and utc < endUTC
end

local WEEKDAYS = { [0] = "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function toEastern(utc)
  local dst = isEasternDST(utc)
  local loc = floor(utc) + (dst and -4 or -5) * 3600
  local days = floor(loc / 86400)
  local secs = loc - days * 86400
  local y, m, d = civilFromDays(days)
  return {
    year = y, month = m, day = d,
    hour = floor(secs / 3600), min = floor(secs % 3600 / 60), sec = secs % 60,
    wday = WEEKDAYS[(days + 4) % 7], tz = dst and "EDT" or "EST",
  }
end

------------------------------------------------------------ FORMATTING
local function commas(n)
  local s = string.format("%d", floor(n + 0.5))
  local k
  repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
  return s
end

local function shortL(n)
  if n >= 1e9 then return string.format("%.2fG", n / 1e9)
  elseif n >= 1e6 then return string.format("%.2fM", n / 1e6)
  elseif n >= 1e3 then return string.format("%.1fK", n / 1e3)
  else return string.format("%d", floor(n + 0.5)) end
end

local function fmtRate(r)
  if r == floor(r) then return commas(r) end
  return string.format("%.2f", r)
end

local function fmtDur(s)
  s = max(0, floor(s + 0.5))
  return string.format("%02d:%02d:%02d", floor(s / 3600), floor(s % 3600 / 60), s % 60)
end

local function fmtDurLong(s)
  s = max(0, floor(s + 0.5))
  local h, m, sec = floor(s / 3600), floor(s % 3600 / 60), s % 60
  if h > 0 then return string.format("%dh %02dm %02ds", h, m, sec) end
  if m > 0 then return string.format("%dm %02ds", m, sec) end
  return string.format("%ds", sec)
end

local function fmtStamp(t)
  if not t then return "--" end
  if not clockOK then return "uptime " .. fmtDur(t) end
  local e = toEastern(t)
  local h12 = e.hour % 12
  if h12 == 0 then h12 = 12 end
  return string.format("%02d/%02d %2d:%02d:%02d %s %s",
    e.month, e.day, h12, e.min, e.sec, e.hour < 12 and "AM" or "PM", e.tz)
end

local function fmtClock(t)
  if not clockOK then return "NO REAL CLOCK - uptime " .. fmtDur(t) end
  local e = toEastern(t)
  local h12 = e.hour % 12
  if h12 == 0 then h12 = 12 end
  return string.format("%s %02d/%02d/%04d  %2d:%02d:%02d %s %s",
    e.wday, e.month, e.day, e.year, h12, e.min, e.sec, e.hour < 12 and "AM" or "PM", e.tz)
end

----------------------------------------------------------- PERSISTENCE
local data = {
  rate = CONFIG.DEFAULT_RATE,
  cycles = {},       -- oldest first
  current = nil,     -- { id, start, approxStart }
  lastSeen = nil,    -- heartbeat, used to close a cycle that ended while offline
  lastStop = nil,
  nextId = 1,
}

local function save()
  local f = io.open(CONFIG.DATA_FILE, "w")
  if f then
    f:write(serialization.serialize(data))
    f:close()
  end
end

local function load()
  local f = io.open(CONFIG.DATA_FILE, "r")
  if not f then return end
  local raw = f:read("*a")
  f:close()
  local ok, t = pcall(serialization.unserialize, raw)
  if ok and type(t) == "table" then
    for k, v in pairs(t) do data[k] = v end
    data.cycles = data.cycles or {}
    data.nextId = data.nextId or 1
    -- older saves stored fractional seconds; round them to whole seconds
    for _, c in ipairs(data.cycles) do
      c.dur = floor(c.dur + 0.5)
      c.used = c.dur * c.rate
    end
  end
end

-------------------------------------------------------------- CYCLES
local function startCycle(t, approx)
  data.current = { id = data.nextId, start = t, approxStart = approx or nil }
  data.nextId = data.nextId + 1
  data.lastSeen = t
  save()
end

local function stopCycle(t, approx)
  local c = data.current
  if not c then return end
  data.current = nil
  local dur = max(0, floor(t - c.start + 0.5))   -- whole seconds
  if dur >= CONFIG.MIN_CYCLE_SECONDS then
    table.insert(data.cycles, {
      id = c.id, start = c.start, stop = t, dur = dur,
      rate = data.rate, used = dur * data.rate,
      approxStart = c.approxStart, approxStop = approx or nil,
    })
    while #data.cycles > CONFIG.MAX_CYCLES do table.remove(data.cycles, 1) end
  end
  data.lastStop = t
  data.lastSeen = t
  save()
end

------------------------------------------------------------ GPU HELPERS
local W, H = 160, 50
local LX, LW = 2, 58          -- left column
local RX, RW = 62, 98         -- right column
local curFG, curBG

local function fg(c) if c ~= curFG then gpu.setForeground(c); curFG = c end end
local function bg(c) if c ~= curBG then gpu.setBackground(c); curBG = c end end

local function text(x, y, s, f, b)
  if b then bg(b) end
  if f then fg(f) end
  gpu.set(x, y, s)
end

local function fill(x, y, w, h, c)
  bg(c)
  gpu.fill(x, y, w, h, " ")
end

local function fit(s, w, align)
  s = tostring(s)
  local len = unicode.len(s)
  if len > w then return unicode.sub(s, 1, w) end
  if align == "right" then return string.rep(" ", w - len) .. s end
  if align == "center" then
    local l = floor((w - len) / 2)
    return string.rep(" ", l) .. s .. string.rep(" ", w - len - l)
  end
  return s .. string.rep(" ", w - len)
end

local function textW(x, y, w, s, f, b, align) text(x, y, fit(s, w, align), f, b) end

local function panel(x, y, w, h, title, stripColor)
  fill(x, y, w, h, C.panel)
  fill(x, y, w, 1, stripColor or C.accent)
  text(x + 1, y, " " .. title .. " ", C.dark, stripColor or C.accent)
end

local function kv(x, y, w, key, val, valColor, b)
  b = b or C.panel
  local kw = 22
  textW(x, y, kw, key, C.dim, b)
  textW(x + kw, y, w - kw, val, valColor or C.text, b)
end

---------------------------------------------------------------- BUTTONS
local buttons = {}

local function addButton(id, x, y, w, label, fgc, bgc, fn)
  buttons[id] = { x = x, y = y, w = w, fn = fn }
  textW(x, y, w, label, fgc or C.text, bgc or C.button, "center")
end

local function clearButtons(prefix)
  for id in pairs(buttons) do
    if id:sub(1, #prefix) == prefix then buttons[id] = nil end
  end
end

local function handleTouch(x, y)
  for _, b in pairs(buttons) do
    if y == b.y and x >= b.x and x < b.x + b.w then b.fn(); return true end
  end
end

--------------------------------------------------- HALF-BLOCK CANVAS
-- Each screen cell holds two vertical "pixels" using the upper-half block.
local function newCanvas(w, h, c)
  local g = {}
  for y = 1, h do
    local r = {}
    for x = 1, w do r[x] = c end
    g[y] = r
  end
  return { w = w, h = h, g = g }
end

local function cset(cv, x, y, c)
  if x >= 1 and x <= cv.w and y >= 1 and y <= cv.h then cv.g[y][x] = c end
end

local function cline(cv, x0, y0, x1, y1, c)
  local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
  local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
  local err = dx + dy
  while true do
    cset(cv, x0, y0, c)
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x0 = x0 + sx end
    if e2 <= dx then err = err + dx; y0 = y0 + sy end
  end
end

local HALF = unicode.char(0x2580)  -- ▀

local function crender(cv, sx, sy)
  for r = 1, ceil(cv.h / 2) do
    local top, bot = cv.g[r * 2 - 1], cv.g[r * 2] or cv.g[r * 2 - 1]
    local x = 1
    while x <= cv.w do
      local t, b = top[x], bot[x]
      local solid = (t == b)
      local x2 = x + 1
      while x2 <= cv.w and top[x2] == t and bot[x2] == b do x2 = x2 + 1 end
      if solid then
        bg(t)
        gpu.set(sx + x - 1, sy + r - 1, string.rep(" ", x2 - x))
      else
        bg(b); fg(t)
        gpu.set(sx + x - 1, sy + r - 1, string.rep(HALF, x2 - x))
      end
      x = x2
    end
  end
end

------------------------------------------------------------ BIG DIGITS
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
  [":"] = { "0", "1", "0", "1", "0" },
}

-- 2x scale: each font pixel = 2 cells wide, 2 half-pixels tall (5 rows)
local function bigText(x, y, w, s, color, b)
  local cv = newCanvas(w, 10, b)
  local px = 1
  for i = 1, #s do
    local glyph = FONT[s:sub(i, i)]
    if glyph then
      local gw = #glyph[1]
      for gy = 1, 5 do
        for gx = 1, gw do
          if glyph[gy]:sub(gx, gx) == "1" then
            for dx = 0, 1 do
              for dy = 0, 1 do
                cset(cv, px + (gx - 1) * 2 + dx, (gy - 1) * 2 + 1 + dy, color)
              end
            end
          end
        end
      end
      px = px + gw * 2 + 2
    end
  end
  crender(cv, x, y)
end

local function bigWidth(s)
  local w = 0
  for i = 1, #s do
    local g = FONT[s:sub(i, i)]
    if g then w = w + #g[1] * 2 + 2 end
  end
  return w - 2
end

------------------------------------------------------------------ STATE
local signalOn = false
local editing, editBuf = false, ""
local resetArmedUntil = 0
local needRedraw = false   -- graph + log need a full redraw

------------------------------------------------------------------- DRAW
-- per-second refresh: overwrite the clock text only (no blanking = no flicker)
local function drawHeaderClock(t)
  textW(W - 44, 2, 42, fmtClock(t), clockOK and C.text or C.bad, C.header, "right")
end

local function drawHeader(t)
  fill(1, 1, W, 3, C.header)
  text(3, 2, "LSC CHARGE CYCLE MONITOR", C.accent, C.header)
  text(29, 2, "| Nitrobenzene / UCFE", C.dim, C.header)
  if signalOn then
    textW(64, 2, 32, "  CHARGING - FUEL SIGNAL ON  ", C.dark, C.good, "center")
  else
    textW(64, 2, 32, "  IDLE - FUEL SIGNAL OFF  ", C.text, 0x3A3A3A, "center")
  end
  drawHeaderClock(t)
end

local lastBigW = 0

-- full = true redraws the whole panel (state changes only).
-- full = false just overwrites the timer and live values every second.
local function drawCurrent(t, full)
  local x, y, w = LX, 5, LW
  local c = signalOn and data.current or nil
  if full then
    panel(x, y, w, 13, "CURRENT CHARGING CYCLE", c and C.good or C.dim)
    lastBigW = 0
    if c then
      textW(x + 2, y + 2, w - 4, "Cycle #" .. c.id .. "  -  ELAPSED", C.good, C.panel)
      kv(x + 2, y + 10, w - 4, "Started", fmtStamp(c.start) .. (c.approxStart and " ~" or ""))
    else
      textW(x + 2, y + 2, w - 4, "Waiting for lscfuel  -  IDLE FOR", C.dim, C.panel)
      kv(x + 2, y + 10, w - 4, "Last cycle stopped", fmtStamp(data.lastStop))
      textW(x + 2, y + 11, w - 4, "Next cycle starts when the fuel signal turns ON", C.dim, C.panel)
    end
  end

  local s, color, el
  if c then
    el = floor(t - c.start)                 -- whole seconds, like a stopwatch
    s, color = fmtDur(el), C.good
  else
    s = data.lastStop and fmtDur(floor(t - data.lastStop)) or "00:00:00"
    color = 0x5A5A5A
  end
  local bw = bigWidth(s)
  if bw ~= lastBigW then                    -- only clear if the width changed (e.g. 99h -> 100h)
    fill(x + 1, y + 4, w - 2, 5, C.panel)
    lastBigW = bw
  end
  bigText(x + floor((w - bw) / 2), y + 4, bw, s, color, C.panel)
  if c then
    kv(x + 2, y + 11, w - 4, "Nitrobenzene so far", commas(el * data.rate) .. " L", C.nb)
  end
end

local function drawPrevious()
  local x, y, w = LX, 19, LW
  panel(x, y, w, 10, "PREVIOUS CHARGING CYCLE", C.accent)
  local c = data.cycles[#data.cycles]
  if not c then
    textW(x + 2, y + 4, w - 4, "No completed cycles yet.", C.dim, C.panel, "center")
    return
  end
  kv(x + 2, y + 2, w - 4, "Cycle", "#" .. c.id)
  kv(x + 2, y + 3, w - 4, "Started  (OFF > ON)", fmtStamp(c.start) .. (c.approxStart and " ~" or ""))
  kv(x + 2, y + 4, w - 4, "Stopped  (ON > OFF)", fmtStamp(c.stop) .. (c.approxStop and " ~" or ""))
  kv(x + 2, y + 5, w - 4, "Total duration", fmtDurLong(c.dur) .. "  (" .. commas(c.dur) .. " s)", C.accent)
  kv(x + 2, y + 6, w - 4, "Burn rate used", fmtRate(c.rate) .. " L/s")
  kv(x + 2, y + 8, w - 4, "NITROBENZENE USED", commas(c.used) .. " L", C.nb)
end

local drawRate  -- forward

local function setRate(r)
  if r and r >= 0 then
    data.rate = r
    save()
  end
end

local function finishEdit(apply)
  if apply then setRate(tonumber(editBuf)) end
  editing, editBuf = false, ""
  drawRate()
end

drawRate = function()
  local x, y, w = LX, 30, LW
  panel(x, y, w, 8, "NITROBENZENE BURN RATE", C.nb)
  clearButtons("rate")
  if editing then
    text(x + 2, y + 2, "New rate: ", C.dim, C.panel)
    textW(x + 12, y + 2, 20, " " .. editBuf .. "_", C.dark, C.nb)
    text(x + 33, y + 2, " L/s", C.dim, C.panel)
    addButton("rateOK", x + 2, y + 4, 12, "OK", C.dark, C.good, function() finishEdit(true) end)
    addButton("rateCancel", x + 16, y + 4, 12, "CANCEL", C.text, C.bad, function() finishEdit(false) end)
    textW(x + 2, y + 6, w - 4, "Type digits on the keyboard. Enter = OK, Esc = cancel", C.dim, C.panel)
  else
    text(x + 2, y + 2, "Rate: ", C.dim, C.panel)
    textW(x + 8, y + 2, w - 10, fmtRate(data.rate) .. " L/s  (" .. commas(data.rate * 3600) .. " L/h)", C.nb, C.panel)
    local steps = { { "-1000", -1000 }, { "-100", -100 }, { "+100", 100 }, { "+1000", 1000 } }
    for i, s in ipairs(steps) do
      addButton("rate" .. i, x + 2 + (i - 1) * 10, y + 4, 9, s[1], C.text, C.button, function()
        setRate(max(0, data.rate + s[2])); drawRate()
      end)
    end
    addButton("rateType", x + 42, y + 4, 13, "TYPE VALUE", C.dark, C.nb, function()
      editing, editBuf = true, ""; drawRate()
    end)
    textW(x + 2, y + 6, w - 4, "New rate applies now; logged cycles keep their rate", C.dim, C.panel)
  end
end

local drawSummary

local function resetLog()
  data.cycles = {}
  save()
end

drawSummary = function()
  local x, y, w = LX, 39, LW
  panel(x, y, w, 11, "SUMMARY  (logged cycles)", C.accent)
  clearButtons("reset")
  local n = #data.cycles
  local totDur, totUsed, longest = 0, 0, 0
  for _, c in ipairs(data.cycles) do
    totDur, totUsed = totDur + c.dur, totUsed + c.used
    longest = max(longest, c.dur)
  end
  local period = "--"
  if n >= 2 then
    period = fmtDurLong((data.cycles[n].start - data.cycles[1].start) / (n - 1))
  end
  kv(x + 2, y + 2, w - 4, "Cycles logged", n .. " / " .. CONFIG.MAX_CYCLES)
  kv(x + 2, y + 3, w - 4, "Average duration", n > 0 and fmtDurLong(totDur / n) or "--", C.accent)
  kv(x + 2, y + 4, w - 4, "Longest cycle", n > 0 and fmtDurLong(longest) or "--")
  kv(x + 2, y + 5, w - 4, "Avg start-to-start", period)
  kv(x + 2, y + 6, w - 4, "Average NB per cycle", n > 0 and commas(totUsed / n) .. " L" or "--", C.nb)
  kv(x + 2, y + 7, w - 4, "Total NB (logged)", commas(totUsed) .. " L", C.nb)
  local armed = computer.uptime() < resetArmedUntil
  addButton("reset", x + 2, y + 9, 26, armed and "TAP AGAIN TO CONFIRM" or "RESET LOG",
    armed and C.dark or C.text, armed and C.warn or 0x5A2020, function()
      if computer.uptime() < resetArmedUntil then
        resetArmedUntil = 0
        resetLog()
        drawPrevious()
        drawSummary()
        needRedraw = true   -- graph + log redrawn by the main loop
      else
        resetArmedUntil = computer.uptime() + 4
        drawSummary()
      end
    end)
end

local function niceMax(v)
  if v <= 0 then return 1 end
  local e = 10 ^ floor(math.log(v, 10))
  for _, m in ipairs({ 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 }) do
    if v <= m * e then return m * e end
  end
  return 10 * e
end

local function drawGraph()
  local x, y, w, h = RX, 5, RW, 27
  panel(x, y, w, h, "NITROBENZENE USED PER CHARGING CYCLE  (oldest > newest)", C.nb)
  local labelW = 10
  local gx, gy = x + labelW + 2, y + 2      -- plot origin (cells)
  local cw, rows = w - labelW - 5, 21        -- plot size in cells
  local ph = rows * 2                        -- plot height in pixels
  local n = #data.cycles

  local ymax = 1
  for _, c in ipairs(data.cycles) do ymax = max(ymax, c.used) end
  ymax = niceMax(ymax * 1.05)
  local function py(v) return ph - floor(v / ymax * (ph - 2) + 0.5) end

  local cv = newCanvas(cw, ph, C.panel)
  -- grid + y labels
  for k = 0, 4 do
    local lv = ymax * k / 4
    local yy = py(lv)
    for xx = 1, cw, 2 do cset(cv, xx, yy, C.grid) end
    if n > 0 then
      textW(x + 1, gy + floor((yy - 1) / 2), labelW, shortL(lv) .. " L", C.dim, C.panel, "right")
    end
  end
  for yy = 1, ph do cset(cv, 1, yy, C.axis) end
  for xx = 1, cw do cset(cv, xx, ph, C.axis) end

  -- clear label rows under the plot
  fill(gx - 1, gy + rows, cw + 2, 3, C.panel)

  if n == 0 then
    crender(cv, gx, gy)
    textW(gx, gy + floor(rows / 2), cw, "Waiting for the first completed charging cycle...", C.dim, C.panel, "center")
    return
  end

  local pts = {}
  for i, c in ipairs(data.cycles) do
    local pxx
    if n == 1 then pxx = floor(cw / 2)
    else pxx = 5 + floor((i - 1) * (cw - 10) / (n - 1) + 0.5) end
    pts[i] = { pxx, py(c.used) }
  end
  for i = 2, n do
    cline(cv, pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2], C.nb)
  end
  for i, p in ipairs(pts) do
    local col = (i == n) and C.good or C.accent
    for dx = -1, 1 do for dy = -1, 1 do cset(cv, p[1] + dx, p[2] + dy, col) end end
  end
  crender(cv, gx, gy)

  -- x labels: cycle number, NB used, duration
  for i, c in ipairs(data.cycles) do
    local cx = gx + pts[i][1] - 1
    local function lab(row, s, col)
      local lw = unicode.len(s)
      local lx = max(gx, min(cx - floor(lw / 2), gx + cw - lw))
      text(lx, gy + rows + row, s, col, C.panel)
    end
    lab(0, "#" .. c.id, i == n and C.good or C.text)
    lab(1, shortL(c.used) .. " L", C.nb)
    lab(2, fmtDur(c.dur), C.dim)
  end
end

-- Log table columns
local COLS = {
  { "#", 6 }, { "STARTED (OFF>ON)", 22 }, { "STOPPED (ON>OFF)", 22 },
  { "DURATION", 10 }, { "RATE L/s", 10 }, { "NITROBENZENE L", 15 },
}

local function drawLogRow(row, cells, colors, b)
  local cx = RX + 2
  for i, col in ipairs(COLS) do
    textW(cx, row, col[2], cells[i] or "", colors[i] or C.text, b, i >= 4 and "right" or nil)
    cx = cx + col[2] + 1
  end
end

local LOG_Y = 33
local function drawCurrentLogRow(t)
  local row = LOG_Y + 3
  if signalOn and data.current then
    local c = data.current
    local el = floor(t - c.start)
    drawLogRow(row,
      { "#" .. c.id, fmtStamp(c.start) .. (c.approxStart and "~" or ""), "CHARGING...", fmtDur(el),
        fmtRate(data.rate), commas(el * data.rate) },
      { C.good, C.good, C.good, C.good, C.good, C.nb }, 0x10301A)
  else
    drawLogRow(row, { "--", "(no cycle running)", "", "", "", "" },
      { C.dim, C.dim }, C.panel)
  end
end

local function drawLog(t)
  local x, y, w = RX, LOG_Y, RW
  panel(x, y, w, 17, "CHARGING CYCLE LOG  (last " .. CONFIG.MAX_CYCLES .. ", newest first)", C.accent)
  local hdr = {}
  for i, col in ipairs(COLS) do hdr[i] = col[1] end
  drawLogRow(y + 2, hdr, { C.dim, C.dim, C.dim, C.dim, C.dim, C.dim }, C.panel)
  drawCurrentLogRow(t)
  local r = 0
  for i = #data.cycles, 1, -1 do
    local c = data.cycles[i]
    local b = (r % 2 == 0) and C.panel2 or C.panel
    drawLogRow(y + 4 + r,
      { "#" .. c.id, fmtStamp(c.start) .. (c.approxStart and "~" or ""),
        fmtStamp(c.stop) .. (c.approxStop and "~" or ""), fmtDur(c.dur), fmtRate(c.rate), commas(c.used) },
      { C.text, C.text, C.text, C.accent, C.dim, C.nb }, b)
    r = r + 1
  end
  for k = r, CONFIG.MAX_CYCLES - 1 do
    fill(x + 1, y + 4 + k, w - 2, 1, (k % 2 == 0) and C.panel2 or C.panel)
  end
  textW(x + 2, y + 15, w - 4, "~ = approximate time (this program was not running when the signal changed)", C.dim, C.panel)
end

local function footerStatus()
  local msg = ""
  if signalError then msg = "REDSTONE I/O NOT REACHABLE"
  elseif not clockOK then msg = "REAL CLOCK UNAVAILABLE" end
  text(W - 40, H, fit(msg, 38, "right"), C.bad, C.bg)
end

local function drawFooter()
  fill(1, H, W, 1, C.bg)
  local side = CONFIG.RS_SIDE and (SIDE_NAMES[CONFIG.RS_SIDE] or tostring(CONFIG.RS_SIDE)) or "any"
  text(2, H, "Ctrl+C: exit  |  Redstone I/O " .. rs.address:sub(1, 8) .. "  side: " .. side
    .. "  |  Data: " .. CONFIG.DATA_FILE, C.dim, C.bg)
  footerStatus()
end

local function drawAll(t)
  fill(1, 1, W, H, C.bg)
  drawHeader(t)
  drawCurrent(t, true)
  drawPrevious()
  drawRate()
  drawSummary()
  drawGraph()
  drawLog(t)
  drawFooter()
end

------------------------------------------------------------- MAIN LOOP
local oldW, oldH = gpu.getResolution()
local oldFG, oldBG = gpu.getForeground(), gpu.getBackground()

local function restoreScreen()
  gpu.setResolution(oldW, oldH)
  gpu.setForeground(oldFG)
  gpu.setBackground(oldBG)
  term.clear()
end

local function main()
  local mw, mh = gpu.maxResolution()
  if mw < W or mh < H then
    error("This program needs a tier 3 GPU and tier 3 screen (160x50).", 0)
  end
  gpu.setResolution(W, H)

  load()
  local t = now()
  signalOn = readSignal(false)
  -- reconcile with whatever happened while the program wasn't running
  if data.current and not signalOn then
    stopCycle(data.lastSeen or t, true)
  elseif not data.current and signalOn then
    startCycle(t, true)
  end
  data.lastSeen = t
  save()

  drawAll(t)
  local lastTick, lastSave = computer.uptime(), computer.uptime()

  while true do
    local ev = { event.pull(CONFIG.POLL_INTERVAL) }
    local name = ev[1]

    if name == "interrupted" then
      return
    elseif name == "touch" then
      handleTouch(ev[3], ev[4])
    elseif name == "key_down" and editing then
      local ch, code = ev[3], ev[4]
      if code == 28 or code == 156 then          -- Enter
        finishEdit(true)
      elseif code == 1 then                      -- Esc
        finishEdit(false)
      elseif code == 14 then                     -- Backspace
        editBuf = editBuf:sub(1, -2); drawRate()
      elseif ch and ch > 0 then
        local c = string.char(ch)
        if c:match("%d") or (c == "." and not editBuf:find("%.")) then
          if #editBuf < 12 then editBuf = editBuf .. c end
          drawRate()
        end
      end
    end

    -- signal edge detection
    local on = readSignal(signalOn)
    if on ~= signalOn then
      local tt = now()
      signalOn = on
      if on then startCycle(tt, false) else stopCycle(tt, false) end
      drawHeader(tt)
      drawCurrent(tt, true)
      drawPrevious()
      drawSummary()
      drawGraph()
      drawLog(tt)
      drawFooter()
      lastTick = computer.uptime()
    end

    if needRedraw then
      needRedraw = false
      local tt = now()
      drawGraph()
      drawLog(tt)
    end

    -- once per second: clock, timers, the live log row
    local up = computer.uptime()
    if up - lastTick >= 1 then
      lastTick = up
      local tt = now()
      drawHeaderClock(tt)
      drawCurrent(tt, false)
      drawCurrentLogRow(tt)
      footerStatus()
      if resetArmedUntil > 0 and up >= resetArmedUntil then
        resetArmedUntil = 0
        drawSummary()
      end
      if up - lastSave >= 30 then
        lastSave = up
        data.lastSeen = tt
        save()
      end
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
restoreScreen()
data.lastSeen = now()
save()
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write(tostring(err) .. "\n")
end
