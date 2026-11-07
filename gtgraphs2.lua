--[[
  gtgraphs.lua  -  GT Graph Monitor (GTNH / OpenComputers)

  Four live graphs in a 2x2 grid with a taskbar at the bottom for
  swapping what each quadrant shows.

    Q2 (top left)       Time between LSC charging cycles
    Q1 (top right)      LSC "Avg EU OUT" over time
    Q3 (bottom left)    empty - reserved for a future machine
    Q4 (bottom right)   Oak Wood in AE2 over time + farm last-ON time

  TASKBAR
    Tap a quadrant (or Q1-Q4 on the taskbar) to select it, then tap a
    SOURCE to show in it and a WINDOW (1H / 6H / 24H / 7D) for time
    graphs. The layout is saved between restarts.

  DATA
    Every time series is recorded all the time (even when it is not on
    screen) into fixed-size ring buffers, one per time window:
      1H  = 720 points x 5 s      6H  = 720 points x 30 s
      24H = 720 points x 2 min    7D  = 720 points x 14 min
    Each screen column summarizes ~11 points: a min/max band plus the
    average line, so short spikes still show up. About 46 KB of RAM per
    series, and the buffers never grow. Saved to disk every 5 minutes.

    LSC readings (EU in/out, charge %, fuel signal) come from lscfuel.lua
    over wireless (port 4041) - this computer does not need to reach the
    LSC itself. The tree farm's state (running / last ON time) comes from
    treefarm2.lua over wireless (port 4042) - this computer does not need
    to reach the farm either. Oak Wood is read from the ME Interface here,
    or taken from treefarm2's broadcast when there is no ME Interface. Charging-cycle history comes from lscstats.lua (port 4040),
    or can be built here from lscfuel's fuel signal (CYCLE_SOURCE).

  Times are real-world US Eastern (EST/EDT, DST handled automatically).

  Needs: tier 3 GPU + tier 3 screen (160x50), and a Wireless Network Card
  (tier 2) to receive from lscfuel / lscstats / treefarm2. An ME
  Interface on this computer's network is optional (Oak Wood count). RAM: 2x
  tier 3 or more recommended. Exit: Ctrl+C.

  ADDING A NEW GRAPH LATER
    1. S.mykey = newSeries()                       (DATA SERIES section)
    2. seriesAdd(S.mykey, t, value, flag)          (inside poll())
    3. SOURCES.mykey = { kind = "series", ... }    (SOURCES section,
       copy the "euin" entry) and add "mykey" to SOURCE_ORDER.
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  -- ME Interface address (full or first few characters). nil = auto-detect.
  -- Optional: without one, the Oak Wood count comes from treefarm2's broadcast.
  ME_ADDRESS   = nil,

  LOG_FILTER = { name = "minecraft:log", damage = 0 },   -- Oak Wood only
  -- "active"  = farm counts as ON while it is actually running a recipe
  -- "allowed" = farm counts as ON while it is enabled (work allowed)
  FARM_ON_MODE = "active",
  -- Tree farm state from treefarm2.lua (wireless)
  FARM_PORT = 4042,            -- must match wirelessPort in treefarm2.lua
  FARM_STALE = 30,             -- seconds without a treefarm2 packet = no farm data
  -- Dashed lines on the Oak Wood graph (treefarm.lua thresholds)
  OAK_MARKERS = { { 100000, 0xFFB000 }, { 1000000, 0x3FE06A } },

  POLL_INTERVAL = 5,           -- seconds between readings
  -- Time windows. points x interval = window length. More points = more
  -- detail but more RAM (each point is ~16 bytes per series).
  WINDOWS = {
    { label = "1H",  interval = 5,   points = 720 },
    { label = "6H",  interval = 30,  points = 720 },
    { label = "24H", interval = 120, points = 720 },
    { label = "7D",  interval = 840, points = 720 },
  },

  -- LSC readings from lscfuel.lua (wireless)
  LSC_PORT = 4041,             -- must match wirelessPort in lscfuel.lua
  LSC_STALE = 30,              -- seconds without an lscfuel packet = no LSC data

  -- Charging cycles: "lscstats" = history from lscstats.lua (recommended,
  -- it already has past cycles). "lscfuel" = built here from lscfuel's
  -- fuel signal (use if lscstats isn't running).
  CYCLE_SOURCE = "lscstats",
  WIRELESS_PORT = 4040,        -- must match lscstats.lua
  LINK_STALE = 120,            -- seconds without an lscstats packet = link down
  CYCLE_ARCHIVE = 60,          -- charging cycles kept on disk
  GAP_BARS = 12,               -- bars shown on the gap graph

  -- Default layout (first run only; after that it is saved).
  -- Window number: 1 = 1H, 2 = 6H, 3 = 24H, 4 = 7D
  LAYOUT = {
    q1 = { src = "euout",  win = 2 },
    q2 = { src = "cycles", win = 2 },
    q3 = { src = "empty",  win = 2 },
    q4 = { src = "oak",    win = 2 },
  },

  SAVE_INTERVAL = 300,
  DATA_FILE = "/home/gtgraphs.dat",
  META_FILE = "/home/gtgraphs_meta.dat",
  CLOCK_OFFSET_SECONDS = 0,    -- add/subtract if the server's clock is wrong
}

--------------------------------------------------------------- MODULES
local component     = require("component")
local computer      = require("computer")
local event         = require("event")
local filesystem    = require("filesystem")
local serialization = require("serialization")
local unicode       = require("unicode")
local term          = require("term")

local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local huge = math.huge
local gpu = component.gpu

---------------------------------------------------------------- COLORS
local C = {
  bg      = 0x0B0B0B,
  panel   = 0x161616,
  panel2  = 0x1E1E1E,
  header  = 0x0E2A38,
  text    = 0xE6E6E6,
  dim     = 0x8C8C8C,
  dark    = 0x000000,
  accent  = 0x00C8FF,
  good    = 0x3FE06A,
  warn    = 0xFFB000,
  bad     = 0xFF4D4D,
  grid    = 0x333333,
  axis    = 0x6E6E6E,
  button  = 0x2E4A5A,
  track   = 0x2A2A2A,
  wood    = 0xC8964B,   -- oak log brown
  euout   = 0x00C8FF,
  euin    = 0xB07CFF,
  gap     = 0xFF8A3D,
  empty   = 0x3A3A3A,
}

local function lerp(c1, c2, f)
  f = max(0, min(1, f))
  local function ch(c, sh) return floor(c / sh) % 256 end
  local r = floor(ch(c1, 65536) + (ch(c2, 65536) - ch(c1, 65536)) * f + 0.5)
  local g = floor(ch(c1, 256) + (ch(c2, 256) - ch(c1, 256)) * f + 0.5)
  local b = floor(ch(c1, 1) + (ch(c2, 1) - ch(c1, 1)) * f + 0.5)
  return r * 65536 + g * 256 + b
end

------------------------------------------------------- REAL-WORLD TIME
-- Writing a file stamps it with the server's real clock. Re-synced every
-- 10 s; in between, time is extrapolated from computer.uptime().
local TIME_PATHS = { "/tmp/.gtgraphs_clock", "/home/.gtgraphs_clock" }
local clockOK, syncReal, syncUp = false, nil, nil

local function readFileClock()
  for _, p in ipairs(TIME_PATHS) do
    local f = io.open(p, "w")
    if f then
      f:write("t")
      f:close()
      local v = filesystem.lastModified(p)
      if v and v > 1e9 then
        if v > 1e11 then v = v / 1000 end
        return v
      end
    end
  end
end

local function now()
  local up = computer.uptime()
  if not syncUp or up - syncUp >= 10 or up < syncUp then
    local v = readFileClock()
    if v then
      clockOK, syncReal, syncUp = true, v, up
    elseif not syncReal then
      clockOK = false
      return up
    end
  end
  return syncReal + (up - syncUp) + CONFIG.CLOCK_OFFSET_SECONDS
end

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
  return first + (7 - (first + 4) % 7) % 7 + (n - 1) * 7
end

local WEEKDAYS = { [0] = "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

-- US Eastern: DST from 2nd Sunday of March 2:00 to 1st Sunday of Nov 2:00
local function toEastern(utc)
  local y = civilFromDays(floor(utc / 86400))
  local dst = utc >= nthSunday(y, 3, 2) * 86400 + 7 * 3600
          and utc <  nthSunday(y, 11, 1) * 86400 + 6 * 3600
  local loc = floor(utc) + (dst and -4 or -5) * 3600
  local days = floor(loc / 86400)
  local secs = loc - days * 86400
  local yy, mm, dd = civilFromDays(days)
  return { year = yy, month = mm, day = dd, hour = floor(secs / 3600),
           min = floor(secs % 3600 / 60), sec = secs % 60,
           wday = WEEKDAYS[(days + 4) % 7], tz = dst and "EDT" or "EST" }
end

------------------------------------------------------------ FORMATTING
local function commas(n)
  local s = string.format("%d", floor(n + 0.5))
  local k
  repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
  return s
end

local function shortNum(n)
  local a = abs(n)
  if a >= 1e15 then return string.format("%.2fP", n / 1e15)
  elseif a >= 1e12 then return string.format("%.2fT", n / 1e12)
  elseif a >= 1e9 then return string.format("%.2fG", n / 1e9)
  elseif a >= 1e6 then return string.format("%.2fM", n / 1e6)
  elseif a >= 1e3 then return string.format("%.1fK", n / 1e3) end
  return string.format("%d", floor(n + 0.5))
end

local function fmtDur(s)
  s = max(0, floor(s + 0.5))
  return string.format("%02d:%02d:%02d", floor(s / 3600), floor(s % 3600 / 60), s % 60)
end

local function fmtDurLong(s)
  s = max(0, floor(s + 0.5))
  local d, h, m, sec = floor(s / 86400), floor(s % 86400 / 3600), floor(s % 3600 / 60), s % 60
  if d > 0 then return string.format("%dd %02dh %02dm", d, h, m) end
  if h > 0 then return string.format("%dh %02dm %02ds", h, m, sec) end
  if m > 0 then return string.format("%dm %02ds", m, sec) end
  return string.format("%ds", sec)
end

-- axis labels: at most ~8 characters
local function fmtAxisDur(s)
  s = max(0, floor(s + 0.5))
  if s < 60 then return s .. "s" end
  if s < 3600 then return string.format("%dm %02ds", floor(s / 60), s % 60) end
  if s < 86400 then return string.format("%dh %02dm", floor(s / 3600), floor(s % 3600 / 60)) end
  return string.format("%dd %02dh", floor(s / 86400), floor(s % 86400 / 3600))
end

-- bar labels: at most 5 characters
local function fmtShort(s)
  s = max(0, floor(s + 0.5))
  if s < 60 then return s .. "s" end
  if s < 3600 then return floor(s / 60) .. "m" end
  if s < 86400 then return string.format("%dh%02d", floor(s / 3600), floor(s % 3600 / 60)) end
  return string.format("%dd%02d", floor(s / 86400), floor(s % 86400 / 3600))
end

local function fmtStep(iv)
  if iv < 60 then return iv .. "s" end
  if iv % 60 == 0 then return floor(iv / 60) .. "m" end
  return string.format("%dm%02ds", floor(iv / 60), iv % 60)
end

local function h12(e)
  local h = e.hour % 12
  return h == 0 and 12 or h, e.hour < 12 and "AM" or "PM"
end

local function fmtStamp(t)
  if not t then return "--" end
  if not clockOK then return "uptime " .. fmtDur(t) end
  local e = toEastern(t)
  local h, ap = h12(e)
  return string.format("%s %02d/%02d %d:%02d:%02d %s %s", e.wday, e.month, e.day, h, e.min, e.sec, ap, e.tz)
end

local function fmtClock(t)
  if not clockOK then return "NO REAL CLOCK - uptime " .. fmtDur(t) end
  local e = toEastern(t)
  local h, ap = h12(e)
  return string.format("%s %02d/%02d/%04d  %d:%02d:%02d %s %s",
    e.wday, e.month, e.day, e.year, h, e.min, e.sec, ap, e.tz)
end

local function fmtAxisTime(t, long)
  if not clockOK then return fmtShort(t) end
  local e = toEastern(t)
  if long then return string.format("%02d/%02d", e.month, e.day) end
  local h, ap = h12(e)
  return string.format("%d:%02d%s", h, e.min, ap)
end

------------------------------------------------------------ COMPONENTS
local dev = { scanAt = {} }

local function needScan(key)
  local up = computer.uptime()
  if (dev.scanAt[key] or -huge) <= up then
    dev.scanAt[key] = up + 30          -- don't search more than every 30 s
    return true
  end
end

local function proxyFor(addr, kind)
  local ok, full = pcall(component.get, addr, kind)
  if ok and full then return component.proxy(full) end
end

local function findME()
  if CONFIG.ME_ADDRESS then return proxyFor(CONFIG.ME_ADDRESS) end
  for _, t in ipairs({ "me_interface", "me_controller" }) do
    local a = component.list(t)()
    if a then return component.proxy(a) end
  end
end

local function readOak()
  if not dev.me and needScan("me") then dev.me = findME() end
  if not dev.me then return nil end
  local ok, items = pcall(dev.me.getItemsInNetwork, CONFIG.LOG_FILTER)
  if not ok or type(items) ~= "table" then dev.me = nil; return nil end
  local total = 0
  for i = 1, (items.n or #items) do
    local it = items[i]
    if it then total = total + (it.size or 0) end
  end
  return total
end

-- Tree farm state arrives from treefarm2.lua over wireless.
-- farmData = latest packet { oak, active, allowed, lastActiveAgo, ... }
local farmData, farmAt = nil, nil

local function farmFresh(t)
  return farmData ~= nil and farmAt ~= nil and t - farmAt <= CONFIG.FARM_STALE
end

-- LSC readings arrive from lscfuel.lua over wireless (this computer can't
-- reach the LSC). lscData = latest packet { percent, avgIn, avgOut, ... }
local lscData, lscAt = nil, nil

local function lscFresh(t)
  return lscData ~= nil and lscAt ~= nil and t - lscAt <= CONFIG.LSC_STALE
end

-- treefarm2 packet. Its "seconds ago" values place the last ON time in real
-- time, so a restart of this program (or a missed packet) loses nothing.
local farm   -- defined below (FARM STATE)
local function receiveFarm(payload)
  local ok, s = pcall(serialization.unserialize, payload)
  if not ok or type(s) ~= "table" then return end
  local t = now()
  farmData, farmAt = s, t
  local allowedMode = CONFIG.FARM_ON_MODE == "allowed"
  local on = allowedMode and s.allowed or s.active
  local ago = allowedMode and s.lastAllowedAgo or s.lastActiveAgo
  if on then
    if not farm.activeNow then farm.onSince = (s.runningFor and not allowedMode) and (t - s.runningFor) or t end
    farm.activeNow, farm.lastOn = true, t
  else
    farm.activeNow = false
    if ago then
      local seen = t - ago
      if not farm.lastOn or seen > farm.lastOn then farm.lastOn = seen end
    end
  end
end

----------------------------------------------------------- DATA SERIES
-- One ring buffer per window. Slot s (= floor(time / interval)) lives at
-- buf[s % n + 1]. Values are packed as round(value) * 2 + flag so a 1-bit
-- flag (farm on / LSC charging) costs no extra memory. -1 = no data.
local function newSeries()
  local s = { tiers = {} }
  for wi, w in ipairs(CONFIG.WINDOWS) do
    local buf = {}
    for i = 1, w.points do buf[i] = -1 end
    s.tiers[wi] = { buf = buf, n = w.points, iv = w.interval, last = nil,
                    acc = { slot = nil, sum = 0, cnt = 0, flag = false } }
  end
  return s
end

local function encode(v, flag)
  return floor(max(0, v) + 0.5) * 2 + (flag and 1 or 0)
end

local function tierPut(T, slot, val)
  if T.last and slot <= T.last then
    if slot > T.last - T.n then T.buf[slot % T.n + 1] = val end
    return
  end
  if T.last then
    for s2 = max(T.last + 1, slot - T.n + 1), slot - 1 do T.buf[s2 % T.n + 1] = -1 end
  end
  T.buf[slot % T.n + 1] = val
  T.last = slot
end

local function tierGet(T, slot)
  local a = T.acc
  if a.slot == slot and a.cnt > 0 then return a.sum / a.cnt, a.flag end
  if not T.last or slot > T.last or slot <= T.last - T.n then return nil end
  local e = T.buf[slot % T.n + 1]
  if e < 0 then return nil end
  local f = e % 2
  return (e - f) / 2, f == 1
end

-- v = nil records a gap (device unreadable)
local function seriesAdd(s, t, v, flag)
  for _, T in ipairs(s.tiers) do
    local slot = floor(t / T.iv)
    local a = T.acc
    if a.slot ~= slot then
      if a.slot and a.cnt > 0 then tierPut(T, a.slot, encode(a.sum / a.cnt, a.flag)) end
      a.slot, a.sum, a.cnt, a.flag = slot, 0, 0, false
    end
    if v then
      a.sum, a.cnt = a.sum + v, a.cnt + 1
      if flag then a.flag = true end
    end
  end
end

local S = {
  euout = newSeries(),
  euin  = newSeries(),
  oak   = newSeries(),
}

------------------------------------------------------- CHARGING CYCLES
local cyc = {
  list = {},          -- completed cycles { id, start, stop }, oldest first
  current = nil,      -- running cycle { id, start }
  lastStop = nil,
  signalOn = nil,     -- true charging / false idle / nil unknown
  lastPacket = nil,   -- wireless mode: time of last lscstats packet
}
local det = { charging = nil, nextId = 1 }   -- "lscfuel" cycle mode
local cycleMode = (CONFIG.CYCLE_SOURCE == "lscfuel") and "lscfuel" or "lscstats"
local wlan = nil
local lastReq = -huge

local function initLink()
  for addr in component.list("modem") do
    local m = component.proxy(addr)
    if m.isWireless() then wlan = m; break end
  end
  if not wlan then   -- a wired card also works if the computers share a cable
    local a = component.list("modem")()
    if a then wlan = component.proxy(a) end
  end
  if wlan then
    wlan.open(CONFIG.LSC_PORT)
    wlan.open(CONFIG.FARM_PORT)
    if cycleMode == "lscstats" then wlan.open(CONFIG.WIRELESS_PORT) end
  end
end

local function requestLink()
  if wlan then pcall(wlan.broadcast, CONFIG.WIRELESS_PORT, "LSCSTATS_REQ") end
  lastReq = computer.uptime()
end

local function trimCycles()
  table.sort(cyc.list, function(a, b) return a.start < b.start end)
  while #cyc.list > CONFIG.CYCLE_ARCHIVE do table.remove(cyc.list, 1) end
end

local function mergeCycles(list)
  local have = {}
  for _, c in ipairs(cyc.list) do have[tostring(c.start)] = true end
  for _, c in ipairs(list or {}) do
    if c.start and c.stop and not have[tostring(c.start)] then
      cyc.list[#cyc.list + 1] = { id = c.id, start = c.start, stop = c.stop }
      have[tostring(c.start)] = true
    end
  end
  trimCycles()
end

-- lscstats packet (cycle history)
local function receivePacket(payload)
  local ok, s = pcall(serialization.unserialize, payload)
  if not ok or type(s) ~= "table" then return end
  cyc.lastPacket = now()
  cyc.signalOn = s.signalOn and true or false
  cyc.current = s.signalOn and s.current or nil
  cyc.lastStop = s.lastStop
  mergeCycles(s.cycles)
end

-- "lscfuel" cycle mode: fuel signal OFF->ON = cycle start, ON->OFF = stop
local function detectCycle(t, on)
  if on == nil or on == det.charging then return end
  local was = det.charging
  det.charging = on
  if on then
    cyc.current = { id = det.nextId, start = t }
    det.nextId = det.nextId + 1
  elseif was ~= nil or cyc.current then
    if cyc.current then
      cyc.list[#cyc.list + 1] = { id = cyc.current.id, start = cyc.current.start, stop = t }
      trimCycles()
    end
    cyc.current, cyc.lastStop = nil, t
  end
end

-- lscfuel packet (LSC readings + fuel signal)
local function receiveFuel(payload)
  local ok, s = pcall(serialization.unserialize, payload)
  if not ok or type(s) ~= "table" then return end
  local t = now()
  lscData, lscAt = s, t
  if cycleMode == "lscfuel" then detectCycle(t, s.outputOn) end
end

local function linkUp(t)
  return cyc.lastPacket ~= nil and t - cyc.lastPacket <= CONFIG.LINK_STALE
end

-- true charging / false idle / nil unknown. lscfuel's fuel signal is the
-- most direct source; lscstats watches the same signal as a fallback.
local function chargingNow(t)
  if lscFresh(t) and lscData.outputOn ~= nil then return lscData.outputOn and true or false end
  if cycleMode == "lscstats" and linkUp(t) then return cyc.signalOn end
  return nil
end

-- idle gap = previous cycle's stop -> next cycle's start (how long a full
-- charge lasts). Skips pairs that are not back-to-back cycles.
local function computeGaps()
  local g, L = {}, cyc.list
  for i = 2, #L do
    local a, b = L[i - 1], L[i]
    local consecutive = not (a.id and b.id) or b.id == a.id + 1
    if consecutive and a.stop and b.start > a.stop then
      g[#g + 1] = { id = b.id, gap = b.start - a.stop }
    end
  end
  return g
end

------------------------------------------------------------- FARM STATE
farm = { lastOn = nil, onSince = nil, activeNow = false, known = false }

----------------------------------------------------------- PERSISTENCE
local layout = {}
for k, v in pairs(CONFIG.LAYOUT) do layout[k] = { src = v.src, win = v.win } end
local selected = "q3"

local function saveSeries()
  local f = io.open(CONFIG.DATA_FILE, "w")
  if not f then return end
  f:write("GTGRAPHS 1\n")
  for key, s in pairs(S) do
    for wi, T in ipairs(s.tiers) do
      local a = T.acc
      if a.slot and a.cnt > 0 then tierPut(T, a.slot, encode(a.sum / a.cnt, a.flag)) end
      f:write(key, " ", wi, " ", T.iv, " ", T.n, " ", T.last and string.format("%d", T.last) or "-", "\n")
      f:write(table.concat(T.buf, ","), "\n")
    end
  end
  f:close()
end

local function loadSeries()
  local f = io.open(CONFIG.DATA_FILE, "r")
  if not f then return end
  if f:read("*l") ~= "GTGRAPHS 1" then f:close(); return end
  while true do
    local h = f:read("*l")
    if not h then break end
    local body = f:read("*l")
    if not body then break end
    local key, wi, iv, n, last = h:match("^(%S+) (%d+) (%d+) (%d+) (%S+)$")
    local T = key and S[key] and S[key].tiers[tonumber(wi)]
    if T and tonumber(iv) == T.iv and tonumber(n) == T.n and last ~= "-" then
      local i = 0
      for v in body:gmatch("[^,]+") do
        i = i + 1
        if i > T.n then break end
        T.buf[i] = math.tointeger(tonumber(v)) or -1
      end
      T.last = math.tointeger(tonumber(last))
    end
  end
  f:close()
end

local function saveMeta()
  local f = io.open(CONFIG.META_FILE, "w")
  if not f then return end
  f:write(serialization.serialize({
    layout = layout, selected = selected,
    farmLastOn = farm.lastOn,
    cycles = cyc.list, current = cyc.current, lastStop = cyc.lastStop,
    detCharging = det.charging, detNextId = det.nextId,
  }))
  f:close()
end

local function loadMeta()
  local f = io.open(CONFIG.META_FILE, "r")
  if not f then return end
  local raw = f:read("*a")
  f:close()
  local ok, m = pcall(serialization.unserialize, raw)
  if not ok or type(m) ~= "table" then return end
  if type(m.layout) == "table" then
    for k, v in pairs(m.layout) do
      if layout[k] and type(v) == "table" then
        layout[k].src = v.src or layout[k].src
        layout[k].win = math.tointeger(v.win) or layout[k].win
      end
    end
  end
  if layout[m.selected or ""] then selected = m.selected end
  farm.lastOn = m.farmLastOn
  cyc.list = type(m.cycles) == "table" and m.cycles or {}
  cyc.lastStop = m.lastStop
  if cycleMode == "lscfuel" then
    cyc.current = m.current
    if m.detCharging ~= nil then det.charging = m.detCharging end
  end
  det.nextId = m.detNextId or det.nextId
end

local function saveAll()
  saveSeries()
  saveMeta()
end

------------------------------------------------------------ GPU HELPERS
local W, H = 160, 50
local curFG, curBG
local function fg(c) if c ~= curFG then gpu.setForeground(c); curFG = c end end
local function bg(c) if c ~= curBG then gpu.setBackground(c); curBG = c end end

local function text(x, y, s, f, b)
  if b then bg(b) end
  if f then fg(f) end
  gpu.set(x, y, s)
end

local function fill(x, y, w, h, c, ch)
  if w <= 0 or h <= 0 then return end
  bg(c)
  gpu.fill(x, y, w, h, ch or " ")
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

-- colored segments left, dim text right-aligned, rest padded (no flicker)
local function writeSegs(x, y, w, segs, right, b)
  b = b or C.panel
  right = right or ""
  local rw = unicode.len(right)
  local stop = x + w - rw - (rw > 0 and 1 or 0)
  local cx = x
  for _, sg in ipairs(segs) do
    local s = sg[1]
    local room = stop - cx
    if room <= 0 then break end
    if unicode.len(s) > room then s = unicode.sub(s, 1, room) end
    text(cx, y, s, sg[2], b)
    cx = cx + unicode.len(s)
  end
  if x + w - rw - cx > 0 then text(cx, y, string.rep(" ", x + w - rw - cx), nil, b) end
  if rw > 0 then text(x + w - rw, y, right, C.dim, b) end
end

-- builds one row of text with labels centered on given columns
local function labelRow(width, items)
  local chars = {}
  for i = 1, width do chars[i] = " " end
  for _, it in ipairs(items) do
    local lab = it[2]
    local lx = max(1, min(it[1] - floor(#lab / 2), width - #lab + 1))
    for i = 1, #lab do chars[lx + i - 1] = lab:sub(i, i) end
  end
  return table.concat(chars)
end

--------------------------------------------------- HALF-BLOCK CANVAS
-- Each screen cell = two vertical pixels (upper-half block, fg/bg).
local HALF = unicode.char(0x2580)

local function newCanvas(w, h, c)
  local g = {}
  for i = 1, w * h do g[i] = c end
  return { w = w, h = h, g = g }
end

local function cset(cv, x, y, c)
  if x >= 1 and x <= cv.w and y >= 1 and y <= cv.h then cv.g[(y - 1) * cv.w + x] = c end
end

local function cline(cv, x0, y0, x1, y1, c, dash)
  local dx, dy = abs(x1 - x0), -abs(y1 - y0)
  local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
  local err, k = dx + dy, 0
  while true do
    if not dash or k % dash < dash / 2 then cset(cv, x0, y0, c) end
    k = k + 1
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x0 = x0 + sx end
    if e2 <= dx then err = err + dx; y0 = y0 + sy end
  end
end

local function crender(cv, sx, sy)
  local g, w = cv.g, cv.w
  for r = 1, ceil(cv.h / 2) do
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

local function niceMax(v)
  if v <= 0 then return 1 end
  local e = 10 ^ floor(math.log(v, 10))
  for _, m in ipairs({ 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 }) do
    if v <= m * e then return m * e end
  end
  return 10 * e
end

------------------------------------------------------------- GRAPH: SERIES
-- Panel layout (h = 23):  +0 title  +1 stats  +2..+17 plot
--                         +18 flag ribbon  +19 time axis  +21 info line
local LABEL_W = 9

local function drawSeries(qk, P, q, src)
  local wi = (CONFIG.WINDOWS[q.win] and q.win) or 1
  local T = src.series.tiers[wi]
  local t = now()
  local gx, gy = P.x + LABEL_W + 2, P.y + 2
  local cw, rows = P.w - LABEL_W - 4, 16
  local ph = rows * 2
  local n = T.n
  local startSlot = floor(t / T.iv) - n + 1

  -- summarize the ring buffer into one min/max/avg per screen column
  local cmin, cmax, cavg, cflag = {}, {}, {}, {}
  local vmin, vmax, vsum, vcnt, latest, lastCol = huge, -huge, 0, 0, nil, nil
  for c = 1, cw do
    local s0 = startSlot + floor((c - 1) * n / cw)
    local s1 = max(s0, startSlot + floor(c * n / cw) - 1)
    local mn, mx, sm, ct, fl = huge, -huge, 0, 0, false
    for sl = s0, s1 do
      local v, f = tierGet(T, sl)
      if v then
        if v < mn then mn = v end
        if v > mx then mx = v end
        sm, ct = sm + v, ct + 1
        if f then fl = true end
        latest = v
      end
    end
    if ct > 0 then
      cmin[c], cmax[c], cavg[c], cflag[c] = mn, mx, sm / ct, fl
      vsum, vcnt = vsum + sm, vcnt + ct
      if mn < vmin then vmin = mn end
      if mx > vmax then vmax = mx end
      lastCol = c
    end
  end

  -- stats line
  local fmt = src.fmt
  local segs
  if vcnt > 0 then
    segs = {
      { "NOW ", C.dim }, { fmt(latest) .. (src.unit or ""), src.color },
      { "   MIN ", C.dim }, { fmt(vmin), C.text },
      { "   MAX ", C.dim }, { fmt(vmax), C.text },
      { "   AVG ", C.dim }, { fmt(vsum / vcnt), C.text },
    }
  else
    segs = { { "NO DATA YET", C.dim } }
  end
  writeSegs(P.x + 2, P.y + 1, P.w - 4, segs,
    string.format("%d pts @ %s", vcnt, fmtStep(T.iv)))

  -- plot
  local ymax = niceMax(max(vcnt > 0 and vmax or 0, 1) * 1.08)
  local function py(v) return ph - 1 - floor(v / ymax * (ph - 3) + 0.5) end

  local cv = newCanvas(cw, ph, C.panel)
  for k = 1, 4 do
    local yy = py(ymax * k / 4)
    for xx = 3, cw, 3 do cset(cv, xx, yy, C.grid) end
  end

  local base = src.color
  local band = lerp(base, C.panel, 0.4)
  local line = lerp(base, 0xFFFFFF, 0.3)
  local area = {}
  for yy = 1, ph do area[yy] = lerp(base, C.panel, 0.55 + 0.38 * yy / ph) end

  for c = 1, cw do
    if cavg[c] then
      for yy = py(cavg[c]) + 1, ph - 1 do cset(cv, c, yy, area[yy]) end
      for yy = py(cmax[c]), py(cmin[c]) do cset(cv, c, yy, band) end
    end
  end
  for _, m in ipairs(src.markers or {}) do
    if m[1] <= ymax then
      local yy = py(m[1])
      for xx = 2, cw do if xx % 4 < 2 then cset(cv, xx, yy, m[2]) end end
    end
  end
  local prevY
  for c = 1, cw do
    if cavg[c] then
      local ya = py(cavg[c])
      if prevY then cline(cv, c - 1, prevY, c, ya, line) else cset(cv, c, ya, line) end
      prevY = ya
    else
      prevY = nil
    end
  end
  for yy = 1, ph do cset(cv, 1, yy, C.axis) end
  for xx = 1, cw do cset(cv, xx, ph, C.axis) end
  if lastCol then
    local ya = py(cavg[lastCol])
    for dx = -1, 1 do for dy = -1, 1 do cset(cv, lastCol + dx, ya + dy, 0xFFFFFF) end end
  end
  crender(cv, gx, gy)

  for k = 0, 4 do
    local lv = ymax * k / 4
    textW(P.x + 1, gy + floor((py(lv) - 1) / 2), LABEL_W, (src.axisFmt or shortNum)(lv), C.dim, C.panel, "right")
  end
  if vcnt == 0 then
    local why = src.missing and src.missing() or "Waiting for the first reading..."
    textW(gx + 2, gy + floor(rows / 2) - 1, cw - 4, why, C.dim, C.panel, "center")
  end

  -- flag ribbon (farm on / LSC charging), one cell per column
  local ry = gy + rows
  textW(P.x + 1, ry, LABEL_W, src.flagLabel or "", src.flagColor or C.dim, C.panel, "right")
  local function rcol(c)
    if not cavg[c] then return C.panel2 end
    return cflag[c] and src.flagColor or C.track
  end
  fg(0); bg(C.panel)
  local x = 1
  while x <= cw do
    local col = rcol(x)
    local x2 = x + 1
    while x2 <= cw and rcol(x2) == col do x2 = x2 + 1 end
    fg(col); bg(C.panel)
    gpu.fill(gx + x - 1, ry, x2 - x, 1, unicode.char(0x2584))   -- lower half block
    x = x2
  end

  -- time axis
  local long = T.iv * n > 86400 * 1.5
  local items = {}
  for k = 0, 4 do
    local c = (k == 4) and cw or (1 + floor(k * (cw - 1) / 4))
    items[#items + 1] = { c, k == 4 and "now" or fmtAxisTime((startSlot + floor((c - 1) * n / cw)) * T.iv, long) }
  end
  textW(P.x + 1, ry + 1, LABEL_W, CONFIG.WINDOWS[wi].label .. " ", C.accent, C.panel, "right")
  text(gx, ry + 1, labelRow(cw, items), C.dim, C.panel)

  -- info line
  local s, col = src.info(t)
  textW(P.x + 2, P.y + 21, P.w - 4, s or "", col or C.text, C.panel)
end

------------------------------------------------------- GRAPH: CYCLE GAPS
-- Panel layout: +0 title  +1 stats  +2..+16 bars  +17 cycle #  +18 gap
--               +19 legend  +21 status line
local function drawCycles(qk, P, q, src)
  local t = now()
  local gaps = computeGaps()
  local shown = {}
  for i = max(1, #gaps - CONFIG.GAP_BARS + 1), #gaps do shown[#shown + 1] = gaps[i] end
  local ns = #shown
  local charging = chargingNow(t)
  local live = (charging == false and cyc.lastStop) and max(0, t - cyc.lastStop) or nil

  local sum, mn, mx = 0, huge, 0
  for _, g in ipairs(shown) do
    sum = sum + g.gap
    mn, mx = min(mn, g.gap), max(mx, g.gap)
  end
  local avg = ns > 0 and sum / ns or nil

  -- least-squares trend (seconds of gap gained/lost per cycle)
  local slope, icept
  if ns >= 3 then
    local sx, sy, sxx, sxy = 0, 0, 0, 0
    for i, g in ipairs(shown) do
      sx, sy, sxx, sxy = sx + i, sy + g.gap, sxx + i * i, sxy + i * g.gap
    end
    local d = ns * sxx - sx * sx
    if d ~= 0 then
      slope = (ns * sxy - sx * sy) / d
      icept = (sy - slope * sx) / ns
    end
  end
  local trendTxt, trendCol = "needs 3+ gaps", C.dim
  if slope and avg and avg > 0 then
    local pct = slope / avg
    if pct < -0.03 then
      trendTxt, trendCol = "-" .. fmtAxisDur(abs(slope)) .. "/cycle " .. unicode.char(0x25BC) .. " SHRINKING", C.bad
    elseif pct > 0.03 then
      trendTxt, trendCol = "+" .. fmtAxisDur(slope) .. "/cycle " .. unicode.char(0x25B2) .. " GROWING", C.good
    else
      trendTxt, trendCol = "STABLE", C.text
    end
  end

  writeSegs(P.x + 2, P.y + 1, P.w - 4, {
    { "LATEST ", C.dim }, { ns > 0 and fmtDurLong(shown[ns].gap) or "--", src.color },
    { "   AVG ", C.dim }, { avg and fmtDurLong(avg) or "--", C.text },
    { "   MIN ", C.dim }, { ns > 0 and fmtDurLong(mn) or "--", C.text },
    { "   TREND ", C.dim }, { trendTxt, trendCol },
  }, ns .. " gaps")

  -- plot
  local gx, gy = P.x + LABEL_W + 2, P.y + 2
  local cw, rows = P.w - LABEL_W - 4, 15
  local ph = rows * 2
  local ymax = niceMax(max(mx, live or 0, 60) * 1.1)
  local function py(v) return ph - 1 - floor(v / ymax * (ph - 3) + 0.5) end

  local cv = newCanvas(cw, ph, C.panel)
  for k = 1, 4 do
    local yy = py(ymax * k / 4)
    for xx = 3, cw, 3 do cset(cv, xx, yy, C.grid) end
  end

  local nb = ns + (live and 1 or 0)
  local slotW = min(10, floor((cw - 2) / max(nb, 6)))
  local barW = slotW >= 4 and slotW - 2 or max(1, slotW - 1)
  local function barX(i) return 3 + (i - 1) * slotW end
  local function barCenter(i) return barX(i) + floor(barW / 2) end

  local function barColor(ratio)
    if ratio >= 0.9 then return C.good elseif ratio >= 0.7 then return C.warn end
    return C.bad
  end

  for i, g in ipairs(shown) do
    local col = barColor(g.gap / avg)
    local yt = py(g.gap)
    local top = lerp(col, 0xFFFFFF, 0.4)
    for xx = barX(i), barX(i) + barW - 1 do
      cset(cv, xx, yt, top)
      for yy = yt + 1, ph - 1 do
        cset(cv, xx, yy, lerp(col, C.panel, 0.05 + 0.6 * (yy - yt) / max(1, ph - 1 - yt)))
      end
    end
  end
  if live then
    local i = ns + 1
    local yt = py(live)
    local hatch = lerp(C.accent, C.panel, 0.45)
    for xx = barX(i), barX(i) + barW - 1 do
      cset(cv, xx, yt, C.accent)
      for yy = yt + 1, ph - 1 do
        if (yy - yt) % 2 == 0 then cset(cv, xx, yy, hatch) end
      end
    end
  end
  if avg then
    local yy = py(avg)
    for xx = 2, cw do if xx % 4 < 2 then cset(cv, xx, yy, C.dim) end end
  end
  if slope then
    cline(cv, barCenter(1), py(max(0, icept + slope)), barCenter(ns), py(max(0, icept + slope * ns)), trendCol)
  end
  for yy = 1, ph do cset(cv, 1, yy, C.axis) end
  for xx = 1, cw do cset(cv, xx, ph, C.axis) end
  crender(cv, gx, gy)

  for k = 0, 4 do
    local lv = ymax * k / 4
    textW(P.x + 1, gy + floor((py(lv) - 1) / 2), LABEL_W, fmtAxisDur(lv), C.dim, C.panel, "right")
  end
  if nb == 0 then
    textW(gx + 2, gy + floor(rows / 2) - 1, cw - 4, "Waiting for two completed charging cycles...", C.dim, C.panel, "center")
  end

  -- labels under bars
  local ids, durs = {}, {}
  local maxLab = max(1, slotW - (slotW >= 5 and 1 or 0))
  for i, g in ipairs(shown) do
    ids[#ids + 1] = { barCenter(i), ("#" .. tostring(g.id or "?")):sub(1, maxLab) }
    durs[#durs + 1] = { barCenter(i), fmtShort(g.gap):sub(1, maxLab) }
  end
  if live then
    ids[#ids + 1] = { barCenter(ns + 1), ("now"):sub(1, maxLab) }
    durs[#durs + 1] = { barCenter(ns + 1), fmtShort(live):sub(1, maxLab) }
  end
  textW(P.x + 1, gy + rows, LABEL_W, "cycle", C.dim, C.panel, "right")
  text(gx, gy + rows, labelRow(cw, ids), C.text, C.panel)
  textW(P.x + 1, gy + rows + 1, LABEL_W, "idle", C.dim, C.panel, "right")
  text(gx, gy + rows + 1, labelRow(cw, durs), src.color, C.panel)

  local sq = unicode.char(0x25A0)
  writeSegs(P.x + 2, gy + rows + 2, P.w - 4, {
    { sq, C.good }, { " >=90% of avg  ", C.dim }, { sq, C.warn }, { " 70-90%  ", C.dim },
    { sq, C.bad }, { " <70%  ", C.dim }, { unicode.char(0x2592), C.accent }, { " idle now  ", C.dim },
    { "/", trendCol }, { " trend  ", C.dim }, { "--", C.dim }, { " avg", C.dim },
  })

  -- status line
  local left, lcol
  if charging and cyc.current then
    left = string.format("CHARGING NOW - cycle #%s, %s elapsed", tostring(cyc.current.id or "?"),
      fmtDur(t - cyc.current.start))
    lcol = C.good
  elseif charging then
    left, lcol = "CHARGING NOW", C.good
  elseif charging == false and cyc.lastStop then
    left = "IDLE " .. fmtDur(t - cyc.lastStop) .. " since last charge  (ended " .. fmtAxisTime(cyc.lastStop) .. ")"
    lcol = C.text
  else
    left, lcol = "Charging state unknown", C.dim
  end
  local right
  if not wlan then
    right = "no wireless card!"
  elseif cycleMode == "lscstats" then
    if cyc.lastPacket then right = "lscstats link, " .. fmtShort(t - cyc.lastPacket) .. " ago"
    else right = "waiting for lscstats..." end
  else
    right = lscFresh(t) and "from lscfuel fuel signal" or "waiting for lscfuel..."
  end
  writeSegs(P.x + 2, P.y + 21, P.w - 4, { { left, lcol } }, right)
end

------------------------------------------------------------ GRAPH: EMPTY
local function drawEmpty(qk, P, q, src, full)
  if not full then return end
  local cv = newCanvas(P.w - 4, 34, C.panel)
  for yy = 4, 34, 6 do for xx = 2, P.w - 4, 4 do cset(cv, xx, yy, C.panel2) end end
  crender(cv, P.x + 2, P.y + 2)
  local cy = P.y + 10
  textW(P.x + 2, cy, P.w - 4, "NO DATA SOURCE ASSIGNED", C.dim, C.panel, "center")
  textW(P.x + 2, cy + 2, P.w - 4, "Reserved for a future machine graph", C.dim, C.panel, "center")
  textW(P.x + 2, cy + 3, P.w - 4, "Tap this quadrant, then pick a SOURCE on the taskbar", C.accent, C.panel, "center")
end

---------------------------------------------------------------- SOURCES
local function lscMissing()
  if not wlan then return "No wireless card - can't receive from lscfuel" end
  if not lscData then return "Waiting for lscfuel (wireless port " .. CONFIG.LSC_PORT .. ")..." end
  if not lscFresh(now()) then return "No data from lscfuel for " .. fmtDurLong(now() - lscAt) end
end

local function lscInfo(t)
  if not wlan then return "No wireless card - install one to receive from lscfuel", C.bad end
  if not lscData then return "Waiting for lscfuel on port " .. CONFIG.LSC_PORT .. " (needs its wireless card)", C.warn end
  if not lscFresh(t) then return "lscfuel silent for " .. fmtDurLong(t - lscAt) .. " - is it running?", C.bad end
  local L = lscData
  if L.online == false then return "lscfuel reports the LSC is not responding", C.bad end
  local parts = {}
  if L.percent then parts[#parts + 1] = string.format("Stored %.1f%%", L.percent) end
  if L.avgIn then parts[#parts + 1] = "Avg IN " .. shortNum(L.avgIn) end
  if L.avgOut then parts[#parts + 1] = "Avg OUT " .. shortNum(L.avgOut) end
  if L.avgIn and L.avgOut then
    local net = L.avgIn - L.avgOut
    parts[#parts + 1] = "Net " .. (net >= 0 and "+" or "-") .. shortNum(abs(net)) .. " EU/t"
  end
  local ch = chargingNow(t)
  if ch then parts[#parts + 1] = "CHARGING" end
  return table.concat(parts, " | "), (ch and C.good or C.text)
end

local function farmInfo(t)
  if not wlan then return "No wireless card - can't receive from treefarm2", C.bad end
  if not farmData then return "Waiting for treefarm2 on port " .. CONFIG.FARM_PORT .. " (needs its wireless card)", C.warn end
  if not farmFresh(t) then
    return "treefarm2 silent for " .. fmtDurLong(t - farmAt) ..
      (farm.lastOn and ("  |  farm last ON " .. fmtStamp(farm.lastOn)) or ""), C.bad
  end
  if farmData.found == false then return "treefarm2 can't find the Industrial Tree Farm", C.bad end
  if farm.activeNow then
    return unicode.char(0x25CF) .. " FARM RUNNING NOW  -  on since " .. fmtStamp(farm.onSince), C.good
  end
  if farm.lastOn then
    return "Farm last ON: " .. fmtStamp(farm.lastOn) .. "   (" .. fmtDurLong(t - farm.lastOn) .. " ago)", C.wood
  end
  return "Farm last ON: not seen since monitoring started", C.dim
end

local SOURCES = {
  euout = {
    kind = "series", label = "LSC EU OUT", title = "LSC AVERAGE EU OUT  (total EU usage)",
    color = C.euout, series = S.euout, fmt = shortNum, unit = " EU/t",
    flagLabel = "CHARGING", flagColor = C.good, info = lscInfo, missing = lscMissing,
  },
  euin = {
    kind = "series", label = "LSC EU IN", title = "LSC AVERAGE EU IN",
    color = C.euin, series = S.euin, fmt = shortNum, unit = " EU/t",
    flagLabel = "CHARGING", flagColor = C.good, info = lscInfo, missing = lscMissing,
  },
  cycles = {
    kind = "custom", label = "CHARGE GAPS", title = "TIME BETWEEN LSC CHARGING CYCLES  (idle time a charge lasts)",
    color = C.gap, draw = drawCycles,
  },
  oak = {
    kind = "series", label = "OAK WOOD", title = "OAK WOOD IN AE2",
    color = C.wood, series = S.oak, fmt = commas, axisFmt = shortNum,
    flagLabel = "FARM ON", flagColor = C.good, markers = CONFIG.OAK_MARKERS, info = farmInfo,
    missing = function()
      if not dev.me and not farmData then return "No ME Interface here and no data from treefarm2 yet" end
    end,
  },
  empty = { kind = "custom", label = "EMPTY", title = "EMPTY SLOT", color = C.empty, draw = drawEmpty },
}
local SOURCE_ORDER = { "euout", "euin", "cycles", "oak", "empty" }
for _, s in pairs(SOURCES) do
  if s.kind == "series" then s.draw = drawSeries end
end

--------------------------------------------------------------- POLLING
local function poll()
  local t = now()

  local oak = readOak()
  local fresh = farmFresh(t)
  if oak == nil and fresh then oak = farmData.oak end      -- no ME Interface here: use treefarm2's count
  if not fresh then farm.activeNow = false end
  local active = fresh and farm.activeNow or nil

  local L = lscFresh(t) and lscData or nil
  if cycleMode == "lscstats" and not linkUp(t) and computer.uptime() - lastReq >= 60 then
    requestLink()
  end
  local chg = chargingNow(t) and true or false

  seriesAdd(S.oak, t, oak, active)
  seriesAdd(S.euout, t, L and L.avgOut, chg)
  seriesAdd(S.euin, t, L and L.avgIn, chg)
end

------------------------------------------------------------ QUADRANTS
local QUADS = { q1 = { 81, 1 }, q2 = { 1, 1 }, q3 = { 1, 25 }, q4 = { 81, 25 } }
local QORDER = { "q1", "q2", "q3", "q4" }

local function rectOf(qk)
  local q = QUADS[qk]
  return { x = q[1] + 1, y = q[2], w = 78, h = 23 }
end

local function drawStrip(qk, P, src, q)
  fill(P.x, P.y, P.w, 1, src.color)
  local tag = " " .. qk:upper() .. " "
  if selected == qk then
    text(P.x, P.y, unicode.char(0x25B6) .. tag, C.dark, 0xFFFFFF)
  else
    text(P.x, P.y, " " .. tag, C.text, lerp(src.color, 0x000000, 0.55))
  end
  text(P.x + 6, P.y, " " .. src.title .. " ", C.dark, src.color)
  if src.kind == "series" then
    local w = "[" .. (CONFIG.WINDOWS[q.win] or CONFIG.WINDOWS[1]).label .. "] "
    text(P.x + P.w - #w, P.y, w, C.dark, src.color)
  end
end

local function drawQuad(qk, full)
  local q = layout[qk]
  local src = SOURCES[q.src] or SOURCES.empty
  local P = rectOf(qk)
  if full then
    fill(P.x, P.y, P.w, P.h, C.panel)
    drawStrip(qk, P, src, q)
  end
  local ok, err = pcall(src.draw, qk, P, q, src, full)
  if not ok then textW(P.x + 2, P.y + P.h - 2, P.w - 4, "draw error: " .. tostring(err), C.bad, C.panel) end
end

---------------------------------------------------------------- TASKBAR
local buttons = {}

local function addButton(x, y, w, label, f, b, fn)
  buttons[#buttons + 1] = { x = x, y = y, w = w, fn = fn }
  textW(x, y, w, label, f, b, "center")
end

local function drawTaskStatus()
  local t = now()
  local x = 46
  local function dot(label, state)
    text(x, 50, label .. " ", C.dim, C.header)
    text(x + #label + 1, 50, unicode.char(0x25CF), state == true and C.good or (state == false and C.bad or C.dim), C.header)
    x = x + #label + 4
  end
  dot("ME", dev.me ~= nil)
  dot("FARM", wlan and farmFresh(t) or false)
  dot("LSCFUEL", wlan and lscFresh(t) or false)
  if cycleMode == "lscstats" then dot("LSCSTATS", wlan and linkUp(t) or false) end
  local free, total = computer.freeMemory(), computer.totalMemory()
  textW(x, 50, 24, string.format("RAM %dK / %dK free", floor(free / 1024), floor(total / 1024)),
    free < 65536 and C.bad or C.dim, C.header)
end

local function drawTaskClock(t)
  textW(W - 38, 50, 37, fmtClock(t), clockOK and C.text or C.bad, C.header, "right")
end

local drawTaskbar

local function selectQuad(qk)
  local old = selected
  selected = qk
  drawQuad(old, true)
  drawQuad(qk, true)
  drawTaskbar()
  saveMeta()
end

local function setSource(key)
  layout[selected].src = key
  drawQuad(selected, true)
  drawTaskbar()
  saveMeta()
end

local function setWindow(wi)
  layout[selected].win = wi
  drawQuad(selected, true)
  drawTaskbar()
  saveMeta()
end

drawTaskbar = function()
  buttons = {}
  fill(1, 49, W, 2, C.header)
  text(2, 49, "GT GRAPHS", C.accent, C.header)
  local x = 13
  text(x, 49, "SLOT", C.dim, C.header)
  x = x + 5
  for _, qk in ipairs(QORDER) do
    local on = qk == selected
    addButton(x, 49, 4, qk:upper(), on and C.dark or C.text, on and 0xFFFFFF or C.button, function() selectQuad(qk) end)
    x = x + 5
  end
  x = x + 1
  text(x, 49, "SOURCE", C.dim, C.header)
  x = x + 7
  local cur = layout[selected].src
  for _, key in ipairs(SOURCE_ORDER) do
    local s = SOURCES[key]
    local lab = " " .. s.label .. " "
    local w = unicode.len(lab)
    local on = key == cur
    addButton(x, 49, w, lab, on and C.dark or C.text, on and s.color or C.button, function() setSource(key) end)
    x = x + w + 1
  end
  textW(W - 22, 49, 21, "Ctrl+C: exit", C.dim, C.header, "right")

  x = 2
  text(x, 50, "WINDOW", C.dim, C.header)
  x = x + 7
  local isSeries = (SOURCES[cur] or SOURCES.empty).kind == "series"
  for wi, w in ipairs(CONFIG.WINDOWS) do
    local on = isSeries and layout[selected].win == wi
    local lab = " " .. w.label .. " "
    addButton(x, 50, #lab, lab, on and C.dark or (isSeries and C.text or 0x4A4A4A),
      on and C.accent or (isSeries and C.button or 0x1A2A33), function()
        if isSeries then setWindow(wi) end
      end)
    x = x + #lab + 1
  end
  drawTaskStatus()
  drawTaskClock(now())
end

local function drawAll()
  fill(1, 1, W, 48, C.bg)
  for _, qk in ipairs(QORDER) do drawQuad(qk, true) end
  drawTaskbar()
end

local function onTouch(x, y)
  if y >= 49 then
    for _, b in ipairs(buttons) do
      if y == b.y and x >= b.x and x < b.x + b.w then b.fn(); return end
    end
    return
  end
  local qk
  if y <= 24 then qk = (x <= 80) and "q2" or "q1"
  else qk = (x <= 80) and "q3" or "q4" end
  if qk ~= selected then selectQuad(qk) end
end

------------------------------------------------------------- MAIN LOOP
local oldW, oldH = gpu.getResolution()
local oldFG, oldBG = gpu.getForeground(), gpu.getBackground()

local function main()
  local mw, mh = gpu.maxResolution()
  if mw < W or mh < H then
    error("gtgraphs needs a tier 3 GPU and tier 3 screen (160x50).", 0)
  end
  gpu.setResolution(W, H)

  initLink()
  loadSeries()
  loadMeta()
  drawAll()
  if cycleMode == "lscstats" then requestLink() end
  poll()
  for _, qk in ipairs(QORDER) do drawQuad(qk, false) end
  drawTaskStatus()

  local nextPoll = computer.uptime() + CONFIG.POLL_INTERVAL
  local lastClock, lastSave = 0, computer.uptime()

  while true do
    local ev = { event.pull(0.25) }
    local name = ev[1]
    if name == "interrupted" then
      return
    elseif name == "touch" then
      onTouch(ev[3], ev[4])
    elseif name == "modem_message" and ev[4] == CONFIG.WIRELESS_PORT and ev[6] == "LSCSTATS"
        and cycleMode == "lscstats" then
      receivePacket(ev[8])
    elseif name == "modem_message" and ev[4] == CONFIG.LSC_PORT and ev[6] == "LSCFUEL" then
      receiveFuel(ev[8])
    elseif name == "modem_message" and ev[4] == CONFIG.FARM_PORT and ev[6] == "TREEFARM" then
      receiveFarm(ev[8])
    end

    local up = computer.uptime()
    if up >= nextPoll then
      nextPoll = up + CONFIG.POLL_INTERVAL
      poll()
      for _, qk in ipairs(QORDER) do drawQuad(qk, false) end
      drawTaskStatus()
    end
    if up - lastClock >= 1 then
      lastClock = up
      drawTaskClock(now())
    end
    if up - lastSave >= CONFIG.SAVE_INTERVAL then
      lastSave = up
      saveAll()
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
pcall(saveAll)
gpu.setResolution(oldW, oldH)
gpu.setForeground(oldFG)
gpu.setBackground(oldBG)
term.clear()
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write(tostring(err) .. "\n")
end
