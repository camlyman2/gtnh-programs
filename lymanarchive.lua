--[[
  lymarc.lua  -  Lymanos Archive (log archive server for OpenComputers)

  A stripped-down Lymanos (Windows 98 style desktop) for a Server in a
  Server Rack. It listens to everything the other programs broadcast and
  keeps all of it on its drives, then lets you browse it like Windows
  Explorer.

  Records (no changes needed on the other computers):
    lscfuel.lua    port 4041  LSC EU in/out, EU stored, charge %, NB in AE2
    treefarm2.lua  port 4042  Oak Wood in AE2, farm running
    lscstats.lua   port 4040  every charging cycle (start, stop, NB used)

  Apps:
    File Explorer  This PC > Archive > source > year > month > day files.
                   Open a file to see its graph (min/max band + average)
                   and data table, or the cycle log for a month.
                   Gaps = time between charging cycles (like gtgraphs).
                   Storage Report = what is stored, how fast it grows,
                   and when the drives would be full.
    My Computer    storage, memory, power and hardware details
    Settings       your name, system name, lock screen, desktop color,
                   how long full-detail samples are kept

  Storage (on every archive drive, filled in order C:, D:, E: ...):
    archive/LSC Power/2026/11/2026-11-07.raw   every sample (~5 s)
    archive/LSC Power/2026/11/2026-11-07.min   1-minute average/min/max
    archive/LSC Power/2026/2026-11.q15         15-minute average/min/max
    archive/Tree Farm/...                      same layout
    archive/LSC Cycles/2026/2026-11.cyc        one line per charging cycle
                                               (incl. the idle gap before it)
  Full-detail .raw files are deleted after a few days (Settings). When the
  drives get full the oldest .raw, then .min, then .q15 files go first.
  Cycle logs are never deleted automatically.

  Storage format: if the CPU runs Lua 5.3 (shift-right-click the CPU in
  your hand until it says Lua 5.3) data is stored as packed binary
  (about half the size of text). On Lua 5.2 it falls back to text automatically.
  Both kinds of file can be read either way.

  Needs: Tier 3 Server (4x tier 3.5 RAM recommended) in a Server Rack,
  tier 3 GPU + tier 3 screen (160x50) + keyboard on the server's rack
  side, a Wireless Network Card (tier 2). Mouse + keyboard.
  Exit: Start > Shut Down or Ctrl+C (unsaved samples are written first).
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  STATS_PORT = 4040,           -- lscstats.lua (charging cycles)
  FUEL_PORT  = 4041,           -- lscfuel.lua (LSC readings)
  FARM_PORT  = 4042,           -- treefarm2.lua (Oak Wood)
  STALE_SECONDS = 75,          -- no packet for this long = that feed is offline

  ARCHIVE_DIR = "archive",     -- folder made on every archive drive
  MIN_DRIVE_BYTES = 1000000,   -- smaller drives (floppies) are never used
  EXCLUDE = {},                -- drive addresses (first few characters) never to use
  RAW_DAYS = 3,                -- default days of 5-second samples kept (Settings)
  RESERVE_KB = 256,            -- default free space kept on every drive (Settings)
  FLUSH_SECONDS = 60,          -- samples are collected in RAM and written this often
  CLEANUP_SECONDS = 600,       -- how often old .raw files are removed
  FORMAT = "auto",             -- "auto" = binary on Lua 5.3, text on 5.2; "text" = always text

  SETTINGS_FILE = "/home/lymarc_settings.dat",
  DRIVES_FILE = "/home/lymarc_drives.dat",   -- remembers drive letters
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
local gpu = component.gpu

---------------------------------------------------------------- SETTINGS
-- Values changed in the Settings app, saved as a small text table.
local SETTINGS = {
  userName = nil,       -- your name (lock screen greeting)
  systemName = "Lymanos Archive",
  lockMins = 30,        -- auto-lock after this many idle minutes (0 = never)
  lockStyle = 1,        -- lock screen color theme
  clock24 = false,      -- 24-hour clock on the taskbar and lock screen
  desk = 1,             -- desktop color
  rawDays = nil,        -- days of 5-second samples kept (nil = CONFIG.RAW_DAYS)
  reserveKB = nil,      -- free space kept on every drive (nil = CONFIG.RESERVE_KB)
}
local DESK_COLORS = {
  { "Teal", 0x008080 }, { "Navy", 0x10306A }, { "Forest", 0x2F5F3F },
  { "Plum", 0x5A2D5A }, { "Slate", 0x3A4A5A }, { "Black", 0x101010 },
}
do
  local f = io.open(CONFIG.SETTINGS_FILE, "r")
  if f then
    local raw = f:read("*a"); f:close()
    local ok, t = pcall(serialization.unserialize, raw)
    if ok and type(t) == "table" then
      for k, v in pairs(t) do if k ~= "_" then SETTINGS[k] = v end end
    end
  end
end
local function saveSettings()
  local f = io.open(CONFIG.SETTINGS_FILE, "w")
  if f then f:write(serialization.serialize(SETTINGS)); f:close() end
end

--------------------------------------------------------- 98 PALETTE
local K = {
  desk   = (DESK_COLORS[SETTINGS.desk] or DESK_COLORS[1])[2],   -- desktop color (Settings)
  face   = 0xC0C0C0,   -- window / button gray
  hi     = 0xFFFFFF,   -- bevel highlight
  sh     = 0x808080,   -- bevel shadow
  black  = 0x000000,
  white  = 0xFFFFFF,
  navy   = 0x000080,
  title2 = 0x1084D0,   -- title gradient end
  track  = 0xE0E0E0,   -- scrollbar track
  grid   = 0xC8C8C8,
  green  = 0x008000,
  red    = 0xC00000,
  yellow = 0xFFFF00,
  line   = 0x000080,
  mark   = 0xFF00FF,
  folder = 0xE8C547,
}

----------------------------------------------------------------- WIRELESS
local wlan
for addr in component.list("modem") do
  local m = component.proxy(addr)
  if m.isWireless() then wlan = m; break end
end
if not wlan then
  -- a wired network card still works if the computers share a cable network
  local a = component.list("modem")()
  if a then wlan = component.proxy(a) end
end
if not wlan then
  io.stderr:write("No network card found. Install a Wireless Network Card (tier 2).\n")
  return
end
wlan.open(CONFIG.STATS_PORT)
wlan.open(CONFIG.FUEL_PORT)
wlan.open(CONFIG.FARM_PORT)
local PLAYER_NAME = SETTINGS.userName or ("Player-" .. wlan.address:sub(1, 4))

-- ask lscstats for its log right away (it answers this computer directly)
local function requestUpdate()
  pcall(wlan.broadcast, CONFIG.STATS_PORT, "LSCSTATS_REQ")
end



------------------------------------------------------- REAL-WORLD TIME
local TIME_PATHS = { "/tmp/.lymarc_clock", "/home/.lymarc_clock" }
local clockOK = false

local function now()
  for _, p in ipairs(TIME_PATHS) do
    local f = io.open(p, "w")
    if f then
      f:write("t"); f:close()
      local v = filesystem.lastModified(p)
      if v and v > 1e9 then
        clockOK = true
        return v > 1e11 and v / 1000 or v
      end
    end
  end
  clockOK = false
  return computer.uptime()
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

local function toEastern(utc)
  local y = civilFromDays(floor(utc / 86400))
  local dst = utc >= nthSunday(y, 3, 2) * 86400 + 7 * 3600
          and utc <  nthSunday(y, 11, 1) * 86400 + 6 * 3600
  local loc = floor(utc) + (dst and -4 or -5) * 3600
  local days = floor(loc / 86400)
  local secs = loc - days * 86400
  local yy, mm, dd = civilFromDays(days)
  return { year = yy, month = mm, day = dd, hour = floor(secs / 3600),
           min = floor(secs % 3600 / 60), sec = secs % 60, tz = dst and "EDT" or "EST",
           wday = ({ [0] = "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" })[(days + 4) % 7] }
end

------------------------------------------------------------ FORMATTING
local function commas(n)
  if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then return "--" end
  local s = string.format("%d", floor(n + 0.5))
  local k
  repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
  return s
end

local function shortL(n)
  if type(n) ~= "number" or n ~= n then return "--" end
  if n >= 1e9 then return string.format("%.2fG", n / 1e9)
  elseif n >= 1e6 then return string.format("%.2fM", n / 1e6)
  elseif n >= 1e3 then return string.format("%.1fK", n / 1e3)
  else return string.format("%d", floor(n + 0.5)) end
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

local function h12(e)
  local h = e.hour % 12
  return h == 0 and 12 or h, e.hour < 12 and "AM" or "PM"
end

local senderClockOK = true
local function fmtStamp(t)
  if not t then return "--" end
  if not senderClockOK then return "uptime " .. fmtDur(t) end
  local e = toEastern(t)
  local h, ap = h12(e)
  return string.format("%02d/%02d %2d:%02d:%02d %s", e.month, e.day, h, e.min, e.sec, ap)
end

local function fmtTime(t)
  if not clockOK then return "--:--" end
  local e = toEastern(t)
  local h, ap = h12(e)
  return string.format("%d:%02d:%02d %s %s", h, e.min, e.sec, ap, e.tz)
end

local function fmtTray(t)
  if not clockOK then return "--:--" end
  local e = toEastern(t)
  if SETTINGS.clock24 then return string.format("%02d:%02d", e.hour, e.min) end
  local h, ap = h12(e)
  return string.format("%d:%02d %s", h, e.min, ap)
end

-- UTC time of 00:00 US Eastern on a date
local function easternMidnight(y, m, d)
  local guess = daysFromCivil(y, m, d) * 86400 + 5 * 3600
  local e = toEastern(guess)          -- 00:xx EST or 01:xx EDT
  return guess - e.hour * 3600 - e.min * 60
end

local function nextDay(y, m, d) return civilFromDays(daysFromCivil(y, m, d) + 1) end

local function humanBytes(n)
  if not n then return "--" end
  if n == math.huge or n ~= n then return "unlimited" end
  if n >= 1048576 then return string.format("%.2f MB", n / 1048576) end
  if n >= 1024 then return string.format("%.1f KB", n / 1024) end
  return string.format("%d B", floor(n))
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeFile(path, s)
  local f = io.open(path, "w")
  if f then f:write(s); f:close() end
end

-- Long jobs (reading big archive files) must give the computer a moment
-- now and then, or OpenComputers stops the program ("too long without
-- yielding"). This takes one waiting event and puts it straight back, so
-- no touch or wireless packet is lost.
local yieldClock = os.clock()
local function breathe(force)
  if force or os.clock() - yieldClock > 0.8 then
    local sig = table.pack(computer.pullSignal(0))
    if sig.n > 0 and sig[1] ~= nil then computer.pushSignal(table.unpack(sig, 1, sig.n)) end
    yieldClock = os.clock()
  end
end
local function breathed() yieldClock = os.clock() end


------------------------------------------------------------- GPU HELPERS
local W, H = 160, 50
local curFG, curBG
local function fg(c) if c ~= curFG then gpu.setForeground(c); curFG = c end end
local function bg(c) if c ~= curBG then gpu.setBackground(c); curBG = c end end

local function text(x, y, s, f, b)
  if b then bg(b) end
  if f then fg(f) end
  gpu.set(x, y, s)
end

local function vtext(x, y, s, f, b)
  bg(b); fg(f)
  gpu.set(x, y, s, true)
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

local function lerp(c1, c2, f)
  local function ch(c, sh) return floor(c / sh) % 256 end
  local r = floor(ch(c1, 65536) + (ch(c2, 65536) - ch(c1, 65536)) * f)
  local g = floor(ch(c1, 256) + (ch(c2, 256) - ch(c1, 256)) * f)
  local b = floor(ch(c1, 1) + (ch(c2, 1) - ch(c1, 1)) * f)
  return r * 65536 + g * 256 + b
end

-- 3D bevel box. kind = "raised" | "sunken"; edge = color behind the
-- border characters; inner = fill color inside.
local function bevel(x, y, w, h, kind, edge, inner)
  local tl, br = K.hi, K.sh
  if kind == "sunken" then tl, br = K.sh, K.hi end
  fill(x + 1, y + 1, w - 2, h - 2, inner)
  text(x, y, "┌" .. string.rep("─", w - 2), tl, edge)
  text(x + w - 1, y, "┐", br, edge)
  if h > 2 then
    vtext(x, y + 1, string.rep("│", h - 2), tl, edge)
    vtext(x + w - 1, y + 1, string.rep("│", h - 2), br, edge)
  end
  text(x, y + h - 1, "└", tl, edge)
  text(x + 1, y + h - 1, string.rep("─", w - 2) .. "┘", br, edge)
end

local function groupBox(x, y, w, h, label)
  fill(x, y, w, h, K.face)
  text(x, y, "┌" .. string.rep("─", w - 2) .. "┐", K.sh, K.face)
  vtext(x, y + 1, string.rep("│", h - 2), K.sh, K.face)
  vtext(x + w - 1, y + 1, string.rep("│", h - 2), K.sh, K.face)
  text(x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘", K.sh, K.face)
  text(x + 2, y, " " .. label .. " ", K.black, K.face)
end

local function titleBar(x, y, w, title, active)
  local c1 = active and K.navy or K.sh
  local c2 = active and K.title2 or 0xB8B8B8
  local s = fit(" " .. title, w)
  local seg = 8
  fg(K.white)
  for i = 0, w - 1, seg do
    local n = min(seg, w - i)
    bg(lerp(c1, c2, i / max(1, w - 1)))
    gpu.set(x + i, y, unicode.sub(s, i + 1, i + n))
  end
end

------------------------------------------------------------- HIT REGIONS
local regions = {}            -- normal UI
local taskRegions = {}        -- taskbar (rebuilt by drawTaskbar)
local overlay = nil           -- open menu or dialog: { regions = {...}, modal = bool }

local function region(list, x, y, w, h, fn)
  list[#list + 1] = { x = x, y = y, w = w, h = h, fn = fn }
end

local function hit(list, x, y)
  for i = #list, 1, -1 do
    local r = list[i]
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      r.fn(x, y)
      return true
    end
  end
  return false
end

local function button(list, x, y, w, label, fn, pressed)
  bevel(x, y, w, 3, pressed and "sunken" or "raised", K.face, K.face)
  textW(x + 1, y + 1, w - 2, label, K.black, K.face, "center")
  if list then region(list, x, y, w, 3, fn) end
end

--------------------------------------------------- HALF-BLOCK CANVAS
local HALF = unicode.char(0x2580)

-- All drawings share ONE reusable buffer (a flat list of colors) instead of
-- building new tables on every redraw, which made lots of garbage.
-- Only one canvas is ever in use at a time: draw it, crender it, done.
local SCRATCH = { w = 0, h = 0, g = {} }
local function newCanvas(w, h, c)
  local g = SCRATCH.g
  for i = 1, w * h do g[i] = c end
  SCRATCH.w, SCRATCH.h = w, h
  return SCRATCH
end

local function cset(cv, x, y, c)
  if x >= 1 and x <= cv.w and y >= 1 and y <= cv.h then cv.g[(y - 1) * cv.w + x] = c end
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

local function crender(cv, sx, sy)
  local g, w = cv.g, cv.w
  for r = 1, ceil(cv.h / 2) do
    local ti = (r * 2 - 2) * w                         -- offset of the top pixel row
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

---------------------------------------------------------------- ARCHIVE
-- The recorder + storage. Packets from lscfuel / treefarm2 / lscstats
-- are collected in RAM and written to the archive drives once a minute.
-- A file can end up split over two drives (one filled up mid-day) or get
-- a "~2" part (the storage format changed); readers merge them.
local ARC = (function()
local HAVE_PACK = (string.pack ~= nil and string.unpack ~= nil)
local BINARY = HAVE_PACK and CONFIG.FORMAT ~= "text"
local NAN = 0 / 0

local SOURCES = {
  { key = "lsc", folder = "LSC Power", from = "lscfuel", flagName = "Charging",
    fields = {
      { key = "avgOut",  label = "EU OUT",    long = "LSC average EU out", unit = " EU/t", color = 0x00C8FF },
      { key = "avgIn",   label = "EU IN",     long = "LSC average EU in",  unit = " EU/t", color = 0xB07CFF },
      { key = "stored",  label = "STORED",    long = "LSC EU stored",      unit = " EU",   color = 0x3FE06A },
      { key = "percent", label = "CHARGE %",  long = "LSC charge",         unit = "%",     color = 0xFFB000, pct = true },
      { key = "nitro",   label = "NB IN AE2", long = "Nitrobenzene in AE2", unit = " L",   color = 0xE8C547 },
    } },
  { key = "farm", folder = "Tree Farm", from = "treefarm2", flagName = "Running",
    fields = {
      { key = "oak", label = "OAK WOOD", long = "Oak Wood in AE2", unit = "", color = 0xC8964B },
    } },
}
local SRC = {}
for _, s in ipairs(SOURCES) do SRC[s.key] = s; SRC[s.folder] = s end
local CYCLE_FOLDER = "LSC Cycles"
local CYC_SRC = { folder = CYCLE_FOLDER }

local TIERS = {
  raw = { label = "5-second samples",   short = "5 s" },
  min = { label = "1-minute averages",  short = "1 min", step = 60 },
  q15 = { label = "15-minute averages", short = "15 min", step = 900 },
  cyc = { label = "Charging cycle log", short = "cycles" },
}
local ROLLS = { "min", "q15" }

local function safe(fn, ...)
  local ok, a, b = pcall(fn, ...)
  if ok then return a, b end
end
local function reserve() return (SETTINGS.reserveKB or CONFIG.RESERVE_KB) * 1024 end
local function rawDays() return SETTINGS.rawDays or CONFIG.RAW_DAYS end

local function listDir(path)
  local out = {}
  local ok, it = pcall(filesystem.list, path)
  if ok and it then
    for name in it do out[#out + 1] = (name:gsub("/$", "")) end
  end
  return out
end

------------------------------------------------------------- DRIVES
local where = {}            -- rel -> drive a file was last written to
local whereCount = 0
local drives, allDrives = {}, {}       -- archive drives / every drive (by letter)
local letters = {}                     -- address -> letter (saved)
do
  local raw = readFile(CONFIG.DRIVES_FILE)
  local ok, t = pcall(serialization.unserialize, raw or "")
  if ok and type(t) == "table" then letters = t end
end

local function excluded(a)
  for _, e in ipairs(CONFIG.EXCLUDE or {}) do
    if a:sub(1, #e) == e then return true end
  end
  return false
end

local function freeOf(d)
  local u = safe(d.proxy.spaceUsed)
  if u then d.used = u end
  d.free = (d.total or 0) - (d.used or 0)
  return d.free
end

local function scanDrives()
  local tmp = computer.tmpAddress and computer.tmpAddress()
  local bootProxy = filesystem.get("/")
  local boot = bootProxy and bootProxy.address
  local byAddr, order = {}, {}
  for proxy, path in filesystem.mounts() do
    local a = proxy.address
    if type(a) == "string" and a ~= tmp and safe(component.type, a) == "filesystem" then
      local d = byAddr[a]
      if not d then
        d = { address = a, proxy = proxy, path = path }
        byAddr[a] = d
        order[#order + 1] = d
      elseif path == "/" or (d.path ~= "/" and #path < #d.path) then
        d.path = path
      end
    end
  end
  for _, d in ipairs(order) do
    d.total = safe(d.proxy.spaceTotal) or 0
    d.ro = safe(d.proxy.isReadOnly) and true or false
    d.label = safe(d.proxy.getLabel)
    d.boot = (d.address == boot)
    d.archive = (not d.ro) and d.total >= CONFIG.MIN_DRIVE_BYTES and d.total ~= math.huge
      and not excluded(d.address)
    d.why = d.ro and "read-only" or (d.total < CONFIG.MIN_DRIVE_BYTES and "too small (floppy)")
      or (excluded(d.address) and "excluded in CONFIG") or nil
    d.base = filesystem.concat(d.path, CONFIG.ARCHIVE_DIR)
    freeOf(d)
  end
  -- drive letters: C: = boot drive, floppies/read-only A: B:, the rest D: E: ...
  local used, changed = {}, false
  for _, d in ipairs(order) do
    if d.boot then d.letter = "C"; used.C = true end
  end
  for _, d in ipairs(order) do
    local L = letters[d.address]
    if not d.boot and L and L ~= "C" and not used[L] then d.letter = L; used[L] = true end
  end
  for _, d in ipairs(order) do
    if not d.letter then
      local start = d.archive and 68 or 65          -- "D" or "A"
      for c = start, 90 do
        local L = string.char(c)
        if not used[L] and L ~= "C" then d.letter = L; used[L] = true; break end
      end
      d.letter = d.letter or "?"
    end
    if letters[d.address] ~= d.letter then letters[d.address] = d.letter; changed = true end
  end
  if changed then pcall(writeFile, CONFIG.DRIVES_FILE, serialization.serialize(letters)) end
  table.sort(order, function(a, b) return a.letter < b.letter end)
  allDrives, drives = order, {}
  for _, d in ipairs(order) do if d.archive then drives[#drives + 1] = d end end
  where, whereCount = {}, 0
end

local function letterOf(addr)
  for _, d in ipairs(allDrives) do if d.address == addr then return d.letter end end
end

------------------------------------------------------------- NAMES
local function dkey(t)
  local e = toEastern(t)
  return string.format("%04d-%02d-%02d", e.year, e.month, e.day), e.year, e.month
end

local function relOf(src, tier, t)
  local key, y, m = dkey(t)
  if tier == "q15" or tier == "cyc" then
    return string.format("%s/%04d/%04d-%02d.%s", src.folder, y, y, m, tier)
  end
  return string.format("%s/%04d/%02d/%s.%s", src.folder, y, m, key, tier)
end

-- "2026-11-07.min" -> "2026-11-07~2.min"
local function partName(rel, k)
  if k <= 1 then return rel end
  return (rel:gsub("(%.%w+)$", "~" .. k .. "%1"))
end

-- name -> base date text, extension  ("2026-11-07~2.min" -> "2026-11-07", "min")
local function splitName(name)
  local base, ext = name:match("^([%d%-]+)~?%d*%.(%w+)$")
  return base, ext
end

------------------------------------------------------------- FORMAT
local function recSize(n, roll) return roll and (7 + 12 * n) or (5 + 4 * n) end

local function header(binary, n, roll)
  if binary then return "LZB1" .. string.pack("<BB", n, roll and 1 or 0) end
  return "LZT1 " .. n .. " " .. (roll and 1 or 0) .. "\n"
end

local function fileFormat(full)
  local f = io.open(full, "rb")
  if not f then return nil end
  local h = f:read(4)
  f:close()
  if not h or h == "" then return nil end
  if h == "LZB1" then return "binary" end
  if h == "LZT1" then return "text" end
  return "other"
end

local function num(v)
  if v == nil or v ~= v then return "-" end
  return string.format("%.7g", v)
end

local function encode(p, binary)
  local n, out = p.n, {}
  local L = p.roll and (3 + 3 * n) or (2 + n)
  if binary then
    local fmt = p.roll and ("<I4BI2" .. string.rep("f", 3 * n)) or ("<I4B" .. string.rep("f", n))
    for i, r in ipairs(p.recs) do out[i] = string.pack(fmt, table.unpack(r, 1, L)) end
  else
    local ints = p.roll and 3 or 2
    for i, r in ipairs(p.recs) do
      local cells = {}
      for k = 1, L do cells[k] = (k <= ints) and string.format("%d", r[k]) or num(r[k]) end
      out[i] = table.concat(cells, " ") .. "\n"
    end
  end
  return out
end

------------------------------------------------------------- WRITING
local pending = {}          -- rel -> { n, roll, recs } or { text = true, lines }
local lastError, lastFlush = nil, nil
local written, flushes = 0, 0
local cleanup               -- forward

local function queue(rel, src, roll, rec)
  local p = pending[rel]
  if not p then p = { n = #src.fields, roll = roll, recs = {} }; pending[rel] = p end
  p.recs[#p.recs + 1] = rec
end

local function queueLine(rel, line)
  local p = pending[rel]
  if not p then p = { text = true, lines = {} }; pending[rel] = p end
  p.lines[#p.lines + 1] = line
end

local function pickDrive(rel, need)
  local d = where[rel]
  if d and d.archive and freeOf(d) >= need + 4096 then return d end
  for _, x in ipairs(drives) do                  -- keep adding to the drive that has it
    if filesystem.exists(x.base .. "/" .. rel) and freeOf(x) >= need + 4096 then return x end
  end
  for _, x in ipairs(drives) do                  -- else the first drive with room (fill in order)
    if freeOf(x) >= reserve() + need then return x end
  end
end

local function remember(rel, d)
  if not where[rel] then whereCount = whereCount + 1 end
  where[rel] = d
  if whereCount > 64 then where, whereCount = {}, 0 end
end

local function writeData(rel, p)
  local need = #p.recs * recSize(p.n, p.roll) * (BINARY and 1 or 3) + 64
  local d = pickDrive(rel, need)
  if not d then pcall(cleanup, true); d = pickDrive(rel, need) end
  if not d then lastError = "Archive drives are full - samples dropped"; return end
  for k = 1, 9 do
    local full = d.base .. "/" .. partName(rel, k)
    local fmt = fileFormat(full)
    local useBin
    if fmt == nil then useBin = BINARY
    elseif fmt == "text" then useBin = false
    elseif fmt == "binary" and HAVE_PACK then useBin = true end
    if useBin ~= nil then
      filesystem.makeDirectory(filesystem.path(full))
      local data = table.concat(encode(p, useBin))
      local f = io.open(full, "ab")
      if not f then lastError = "Can't write " .. full; return end
      if fmt == nil then f:write(header(useBin, p.n, p.roll)) end
      f:write(data)
      f:close()
      remember(rel, d)
      written = written + #data
      return
    end
  end
  lastError = "No usable file for " .. rel
end

local function writeText(rel, p)
  local data = table.concat(p.lines)
  local d = pickDrive(rel, #data + 128)
  if not d then pcall(cleanup, true); d = pickDrive(rel, #data + 128) end
  if not d then lastError = "Archive drives are full - cycle not saved"; return end
  local full = d.base .. "/" .. rel
  filesystem.makeDirectory(filesystem.path(full))
  local isNew = not filesystem.exists(full)
  local f = io.open(full, "a")
  if not f then lastError = "Can't write " .. full; return end
  if isNew then f:write("# Lymanos Archive cycle log: id start stop seconds rate_L/s nitrobenzene_L gap_s\n") end
  f:write(data)
  f:close()
  remember(rel, d)
  written = written + #data
end

local function flush()
  local list = {}
  for rel in pairs(pending) do list[#list + 1] = rel end
  if #list == 0 then return end
  table.sort(list)
  local todo = pending
  pending = {}
  for _, rel in ipairs(list) do
    local p = todo[rel]
    local ok, err = pcall(p.text and writeText or writeData, rel, p)
    if not ok then lastError = tostring(err) end
    breathe()
  end
  lastFlush = now()
  flushes = flushes + 1
end

------------------------------------------------------------- RECORDING
local acc = {}              -- acc[src.key][tier] = bucket being averaged
local live = {}             -- src.key -> { at, vals, flags, day, today }
local function bucketOf(src, tk)
  local a = acc[src.key]
  if not a then a = {}; acc[src.key] = a end
  local b = a[tk]
  if not b then b = { s = {}, c = {}, lo = {}, hi = {}, cnt = 0, flags = 0 }; a[tk] = b end
  return b
end

local function emit(src, tk, b)
  if not b.b or b.cnt == 0 then return end
  local rec = { b.b, b.flags, min(65535, b.cnt) }
  for i = 1, #src.fields do
    local c = b.c[i]
    if c and c > 0 then
      rec[#rec + 1] = b.s[i] / c; rec[#rec + 1] = b.lo[i]; rec[#rec + 1] = b.hi[i]
    else
      rec[#rec + 1] = NAN; rec[#rec + 1] = NAN; rec[#rec + 1] = NAN
    end
  end
  queue(relOf(src, tk, b.b), src, true, rec)
end

local function resetBucket(b, start)
  b.b, b.cnt, b.flags = start, 0, 0
  for i in pairs(b.s) do b.s[i], b.c[i], b.lo[i], b.hi[i] = nil, nil, nil, nil end
end

local function addSample(src, t, vals, flags)
  t = floor(t)
  local n = #src.fields
  local rec = { t, flags }
  for i = 1, n do
    local v = vals[i]
    rec[2 + i] = (type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge) and v or NAN
  end
  queue(relOf(src, "raw", t), src, false, rec)
  for _, tk in ipairs(ROLLS) do
    local b0 = t - t % TIERS[tk].step
    local b = bucketOf(src, tk)
    if b.b ~= b0 then
      emit(src, tk, b)
      resetBucket(b, b0)
    end
    b.cnt = b.cnt + 1
    if flags > b.flags then b.flags = flags end
    for i = 1, n do
      local v = rec[2 + i]
      if v == v then
        b.s[i] = (b.s[i] or 0) + v
        b.c[i] = (b.c[i] or 0) + 1
        if not b.lo[i] or v < b.lo[i] then b.lo[i] = v end
        if not b.hi[i] or v > b.hi[i] then b.hi[i] = v end
      end
    end
  end
  local L = live[src.key]
  if not L then L = { today = 0 }; live[src.key] = L end
  local day = dkey(t)
  if L.day ~= day then L.day, L.today = day, 0 end
  L.at, L.vals, L.flags, L.today = t, vals, flags, L.today + 1
end

local function unpackPayload(payload)
  local ok, s = pcall(serialization.unserialize, payload)
  if ok and type(s) == "table" then return s end
end

local function clockReady()
  local t = now()
  if not clockOK then lastError = "No real-world clock yet - not recording"; return nil end
  return t
end

-- lscfuel.lua packet (port 4041, "LSCFUEL")
local function onFuel(payload)
  local s = unpackPayload(payload)
  if not s then return end
  local t = clockReady()
  if not t then return end
  if s.online == false then
    local L = live.lsc or { today = 0 }
    live.lsc = L
    L.offlineAt = t
    return
  end
  addSample(SRC.lsc, t, { s.avgOut, s.avgIn, s.stored, s.percent, s.nitro }, s.outputOn and 1 or 0)
end

-- treefarm2.lua packet (port 4042, "TREEFARM")
local function onFarm(payload)
  local s = unpackPayload(payload)
  if not s or s.found == false then return end
  local t = clockReady()
  if not t then return end
  addSample(SRC.farm, t, { s.oak }, s.active and 1 or 0)
end

-- lscstats.lua packet (port 4040, "LSCSTATS"): append cycles never seen
local seen = {}
local cycleTotal, lastCycle = 0, nil
local stats = { at = nil, snap = nil, from = nil, dist = nil }
local function cycleKey(start) return string.format("%.0f", start) end

-- two cycles count as back-to-back (so the idle time between them is a real
-- "time between cycles") when their numbers follow on, or have no numbers
local function gapPair(a, b)
  local ia, ib = tonumber(a.id), tonumber(b.id)
  return not (ia and ib) or ib == ia + 1
end

local function onStats(from, dist, payload)
  local s = unpackPayload(payload)
  if not s then return false end
  stats.at, stats.snap, stats.from, stats.dist = now(), s, from, dist
  senderClockOK = s.clockOK ~= false
  if not senderClockOK then return false end
  local added = false
  local list = {}
  for _, c in ipairs(s.cycles or {}) do
    if type(c.start) == "number" and c.stop then list[#list + 1] = c end
  end
  table.sort(list, function(a, b) return a.start < b.start end)
  for _, c in ipairs(list) do
    local k = cycleKey(c.start)
    if not seen[k] then
      seen[k] = true
      -- idle time since the previous charge ended (the "time between cycles")
      local gap = "-"
      local p = lastCycle
      if p and p.stop and c.start > p.start and c.start > p.stop and gapPair(p, c) then
        gap = string.format("%.0f", c.start - p.stop)
      end
      queueLine(relOf(CYC_SRC, "cyc", c.start), string.format("%s %.3f %.3f %.0f %.6g %.0f %s\n",
        tostring(c.id or "-"), c.start, c.stop, c.dur or (c.stop - c.start), c.rate or 0, c.used or 0, gap))
      cycleTotal = cycleTotal + 1
      if not lastCycle or c.start > lastCycle.start then lastCycle = c end
      added = true
    end
  end
  return added
end

------------------------------------------------------------- READING
-- archive files of one tier covering [t0, t1], on every drive
local function filesFor(src, tier, t0, t1)
  local wanted, dirs = {}, {}
  local monthly = (tier == "q15" or tier == "cyc")
  local t = t0
  while true do
    local key, y, m = dkey(t)
    if monthly then
      wanted[string.format("%04d-%02d", y, m)] = true
      dirs[string.format("%s/%04d", src.folder, y)] = true
    else
      wanted[key] = true
      dirs[string.format("%s/%04d/%02d", src.folder, y, m)] = true
    end
    if t >= t1 then break end
    t = min(t + 21600, t1)
  end
  local out = {}
  for rd in pairs(dirs) do
    for _, d in ipairs(drives) do
      local dir = d.base .. "/" .. rd
      if filesystem.isDirectory(dir) then
        for _, name in ipairs(listDir(dir)) do
          local base, ext = splitName(name)
          if base and ext == tier and wanted[base] then out[#out + 1] = dir .. "/" .. name end
        end
      end
    end
  end
  table.sort(out)
  return out
end

-- every file with this extension under one source folder (all drives)
local function allFiles(folder, ext)
  local out = {}
  for _, d in ipairs(drives) do
    local root = d.base .. "/" .. folder
    for _, y in ipairs(listDir(root)) do
      local yd = root .. "/" .. y
      if filesystem.isDirectory(yd) then
        for _, name in ipairs(listDir(yd)) do
          local full = yd .. "/" .. name
          if filesystem.isDirectory(full) then
            for _, n2 in ipairs(listDir(full)) do
              local base, e2 = splitName(n2)
              if base and e2 == ext then out[#out + 1] = { full = full .. "/" .. n2, base = base, drive = d } end
            end
          else
            local base, e2 = splitName(name)
            if base and e2 == ext then out[#out + 1] = { full = full, base = base, drive = d } end
          end
        end
      end
      breathe()
    end
  end
  return out
end

-- calls cb(t, flags, count, avg, lo, hi) for field fi of every record
local function eachRecord(path, fi, cb)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local head = f:read(4)
  local count = 0
  if head == "LZB1" then
    if not HAVE_PACK then f:close(); return 0, "binary file needs Lua 5.3" end
    local n, tc = string.unpack("<BB", f:read(2) or "\0\0")
    if fi > n then f:close(); return 0 end
    local roll = tc == 1
    local rs = recSize(n, roll)
    local off = roll and (7 + (fi - 1) * 12) or (5 + (fi - 1) * 4)
    local buf = ""
    while true do
      local chunk = f:read(rs * 128)
      if not chunk or chunk == "" then break end
      buf = (#buf > 0) and (buf .. chunk) or chunk
      local p, L = 1, #buf
      while p + rs - 1 <= L do
        local t, fl = string.unpack("<I4B", buf, p)
        if roll then
          local cnt = string.unpack("<I2", buf, p + 5)
          local a, lo, hi = string.unpack("<fff", buf, p + off)
          cb(t, fl, cnt, a, lo, hi)
        else
          local v = string.unpack("<f", buf, p + off)
          cb(t, fl, 1, v, v, v)
        end
        p = p + rs
        count = count + 1
      end
      buf = (p <= L) and buf:sub(p) or ""
      breathe()
    end
  elseif head == "LZT1" then
    local hl = f:read("*l") or ""
    local n, tc = hl:match("(%d+)%s+(%d+)")
    n, tc = tonumber(n) or 0, tonumber(tc) or 0
    if fi > n then f:close(); return 0 end
    local roll = tc == 1
    local tk = {}
    for line in f:lines() do
      local k = 0
      for w in line:gmatch("%S+") do k = k + 1; tk[k] = w end
      if roll and k >= 3 + 3 * fi then
        local a = tonumber(tk[1 + 3 * fi])
        if a then
          cb(tonumber(tk[1]), tonumber(tk[2]) or 0, tonumber(tk[3]) or 1, a,
             tonumber(tk[2 + 3 * fi]) or a, tonumber(tk[3 + 3 * fi]) or a)
        end
      elseif not roll and k >= 2 + fi then
        local v = tonumber(tk[2 + fi])
        if v then cb(tonumber(tk[1]), tonumber(tk[2]) or 0, 1, v, v, v) end
      end
      count = count + 1
      if count % 200 == 0 then breathe() end
    end
  end
  f:close()
  return count
end

-- squeeze one field over [t0, t1) into ncol screen columns
local function aggregate(srcKey, fi, t0, t1, ncol, tierPref)
  flush()
  local src = SRC[srcKey]
  local span = max(1, t1 - t0)
  local order
  if tierPref and tierPref ~= "auto" then order = { tierPref }
  elseif span <= 8 * 3600 and t0 >= now() - rawDays() * 86400 - 86400 then order = { "raw", "min", "q15" }
  elseif span <= 12 * 86400 then order = { "min", "q15" }
  else order = { "q15", "min" } end
  local C = { n = {}, s = {}, lo = {}, hi = {}, fl = {}, ncol = ncol, t0 = t0, t1 = t1, records = 0, files = 0 }
  for c = 1, ncol do C.n[c], C.s[c], C.fl[c] = 0, 0, 0 end
  local function add(t, fl, cnt, a, lo, hi)
    if t and t >= t0 and t < t1 and a == a then
      local c = floor((t - t0) / span * ncol) + 1
      C.n[c] = C.n[c] + cnt
      C.s[c] = C.s[c] + a * cnt
      if fl and fl > 0 then C.fl[c] = C.fl[c] + cnt end
      if lo == lo and (not C.lo[c] or lo < C.lo[c]) then C.lo[c] = lo end
      if hi == hi and (not C.hi[c] or hi > C.hi[c]) then C.hi[c] = hi end
      C.records = C.records + 1
    end
  end
  for _, tier in ipairs(order) do
    local files = filesFor(src, tier, t0, t1)
    for _, path in ipairs(files) do
      local _, err = eachRecord(path, fi, add)
      if err then C.err = err end
    end
    C.tier = tier
    C.files = #files
    if C.records > 0 then break end
  end
  return C
end

-- every archived cycle with t0 <= start < t1 (t0 = nil: all of them)
local function readCycles(t0, t1)
  flush()
  local paths = {}
  if t0 then
    paths = filesFor(CYC_SRC, "cyc", t0, t1)
  else
    for _, f in ipairs(allFiles(CYCLE_FOLDER, "cyc")) do paths[#paths + 1] = f.full end
  end
  local keys, list = {}, {}
  for _, p in ipairs(paths) do
    local f = io.open(p, "r")
    if f then
      local k = 0
      for line in f:lines() do
        if line:sub(1, 1) ~= "#" then
          local id, st, sp, du, ra, us, gp = line:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) ?(%S*)")
          st = tonumber(st)
          if st and (not t0 or (st >= t0 and st < t1)) then
            local key = cycleKey(st)
            if not keys[key] then
              keys[key] = true
              list[#list + 1] = { id = tonumber(id) or id, start = st, stop = tonumber(sp),
                                  dur = tonumber(du) or 0, rate = tonumber(ra) or 0, used = tonumber(us) or 0,
                                  gap = tonumber(gp) }
            end
          end
        end
        k = k + 1
        if k % 200 == 0 then breathe() end
      end
      f:close()
    end
  end
  table.sort(list, function(a, b) return a.start < b.start end)
  return list
end

-- idle gaps ("time between cycles") for a cycle list, oldest first.
-- Uses the gap saved in the log when there is one (that also covers the
-- first cycle of a month, whose previous cycle is in last month's file).
local function gapsOf(list)
  local out = {}
  for i, c in ipairs(list) do
    local g = c.gap
    local p = list[i - 1]
    if not g and p and p.stop and c.start > p.stop and gapPair(p, c) then g = c.start - p.stop end
    if g and g > 0 then
      out[#out + 1] = { id = c.id, gap = g, start = c.start, prevStop = c.start - g, cycle = c }
    end
  end
  return out
end

-- earliest day with data for a source folder (UTC time of its midnight)
local function firstTime(folder)
  local bestDay, bestMonth
  for _, d in ipairs(drives) do
    local root = d.base .. "/" .. folder
    for _, y in ipairs(listDir(root)) do
      if y:match("^%d%d%d%d$") then
        for _, name in ipairs(listDir(root .. "/" .. y)) do
          if name:match("^%d%d$") then                       -- month folder: day files
            for _, f in ipairs(listDir(root .. "/" .. y .. "/" .. name)) do
              local base = splitName(f)
              if base and #base == 10 and (not bestDay or base < bestDay) then bestDay = base end
            end
          else                                                -- month file (.q15 / .cyc)
            local base = splitName(name)
            if base and #base == 7 and (not bestMonth or base < bestMonth) then bestMonth = base end
          end
        end
      end
    end
  end
  if bestDay and (not bestMonth or bestDay:sub(1, 7) <= bestMonth) then
    local y, m, dd = bestDay:match("(%d+)%-(%d+)%-(%d+)")
    return easternMidnight(tonumber(y), tonumber(m), tonumber(dd))
  end
  if bestMonth then
    local y, m = bestMonth:match("(%d+)%-(%d+)")
    return easternMidnight(tonumber(y), tonumber(m), 1)
  end
end

-- header facts about one archive file
local function fileInfo(full)
  local size = filesystem.size(full) or 0
  local f = io.open(full, "rb")
  if not f then return nil end
  local head = f:read(4)
  local info = { size = size }
  if head == "LZB1" and HAVE_PACK then
    local n, tc = string.unpack("<BB", f:read(2) or "\0\0")
    info.format, info.fields, info.roll = "binary (packed)", n, tc == 1
    info.records = floor((size - 6) / recSize(n, tc == 1))
  elseif head == "LZB1" then
    info.format = "binary (needs Lua 5.3 to read)"
  elseif head == "LZT1" then
    local hl = f:read("*l") or ""
    local n, tc = hl:match("(%d+)%s+(%d+)")
    info.format, info.fields, info.roll = "text", tonumber(n), tc == "1"
    local k = 0
    for _ in f:lines() do k = k + 1; if k % 500 == 0 then breathe() end end
    info.records = k
  else
    info.format = "text"
    local k, first = 0, true
    for line in f:lines() do
      if first then
        first = false
        if head and head:sub(1, 1) ~= "#" then k = k + 1 end
      elseif line:sub(1, 1) ~= "#" then
        k = k + 1
      end
      if k % 500 == 0 then breathe() end
    end
    info.records = k
  end
  f:close()
  return info
end

------------------------------------------------------------- CLEANUP
local lastClean = nil
local RANK = { raw = 1, min = 2, q15 = 3 }

local function spaceOK()
  if #drives == 0 then return true end
  for _, d in ipairs(drives) do if freeOf(d) >= reserve() * 2 then return true end end
  return false
end

-- deletes .raw files past their days; if space is short, oldest data first
cleanup = function(urgent)
  local removed, freed = 0, 0
  local cutoff = dkey(now() - rawDays() * 86400)
  local cands = {}
  for _, src in ipairs(SOURCES) do
    for ext in pairs(RANK) do
      for _, f in ipairs(allFiles(src.folder, ext)) do
        if ext == "raw" and f.base < cutoff then
          local sz = filesystem.size(f.full) or 0
          if filesystem.remove(f.full) then removed, freed = removed + 1, freed + sz end
        else
          f.rank = RANK[ext]
          cands[#cands + 1] = f
        end
      end
    end
  end
  if not spaceOK() then
    local today = dkey(now())
    table.sort(cands, function(a, b)
      if a.rank ~= b.rank then return a.rank < b.rank end
      return a.base < b.base
    end)
    for _, f in ipairs(cands) do
      if spaceOK() or removed >= 60 then break end
      if not (f.rank == 3 and f.base >= today:sub(1, 7)) then     -- never this month's 15-min file
        local sz = filesystem.size(f.full) or 0
        if filesystem.remove(f.full) then removed, freed = removed + 1, freed + sz end
      end
      breathe()
    end
    if not spaceOK() then lastError = "Archive drives are almost full" end
  end
  where, whereCount = {}, 0
  lastClean = { at = now(), removed = removed, freed = freed }
  return removed, freed
end

-- size of the archive by file kind (Disk Cleanup)
local function usage()
  local out = { raw = { 0, 0 }, min = { 0, 0 }, q15 = { 0, 0 }, cyc = { 0, 0 } }
  for _, src in ipairs(SOURCES) do
    for ext in pairs(RANK) do
      for _, f in ipairs(allFiles(src.folder, ext)) do
        out[ext][1] = out[ext][1] + 1
        out[ext][2] = out[ext][2] + (filesystem.size(f.full) or 0)
      end
    end
  end
  for _, f in ipairs(allFiles(CYCLE_FOLDER, "cyc")) do
    out.cyc[1] = out.cyc[1] + 1
    out.cyc[2] = out.cyc[2] + (filesystem.size(f.full) or 0)
  end
  return out
end

-- number of records in one archive file (exact for binary, estimated for text)
local function countRecords(full, size)
  local f = io.open(full, "rb")
  if not f then return 0, false end
  local head = f:read(4)
  local n, exact = 0, true
  if head == "LZB1" then
    local h2 = f:read(2) or "\0\0"
    local nf, tc = h2:byte(1) or 0, h2:byte(2) or 0
    n = floor((size - 6) / recSize(nf, tc == 1))
  else
    local sample = (head or "") .. (f:read(4092) or "")
    local lines, hl = 0, 0
    for line in sample:gmatch("([^\n]*)\n") do
      lines = lines + 1
      if lines == 1 and (line:sub(1, 4) == "LZT1" or line:sub(1, 1) == "#") then hl = #line + 1 end
    end
    if #sample >= size then
      n = lines - (hl > 0 and 1 or 0)                                   -- whole file read
    elseif lines > 1 then
      n = floor((size - hl) / ((#sample - hl) / (lines - (hl > 0 and 1 or 0))) + 0.5)
      exact = false
    end
  end
  f:close()
  return max(0, n), exact
end

-- everything the Storage Report shows
local function report()
  flush()
  local t = now()
  local today = dkey(t)
  local yesterday = dkey(t - 86400)
  local rows = {}
  local perDay = { raw = 0, min = 0, q15 = 0, cyc = 0 }
  local function scan(folder, ext, label, graphs)
    local r = { folder = folder, ext = ext, label = label, graphs = graphs,
                files = 0, bytes = 0, records = 0, exact = true }
    local todayB, yestB = 0, 0
    for _, f in ipairs(allFiles(folder, ext)) do
      local sz = filesystem.size(f.full) or 0
      r.files, r.bytes = r.files + 1, r.bytes + sz
      if ext ~= "cyc" then
        local n, ex = countRecords(f.full, sz)
        r.records = r.records + n
        if not ex then r.exact = false end
      end
      if not r.from or f.base < r.from then r.from = f.base end
      if not r.to or f.base > r.to then r.to = f.base end
      if f.base == yesterday then yestB = yestB + sz end
      if f.base == today then todayB = todayB + sz end
      breathe()
    end
    -- bytes added per day: yesterday's files, or today's so far scaled up
    if ext == "raw" or ext == "min" then
      local e = toEastern(t)
      local frac = (e.hour * 3600 + e.min * 60 + e.sec) / 86400
      local rate = (yestB > 0) and yestB or ((frac > 0.04) and todayB / frac or 0)
      perDay[ext] = perDay[ext] + rate
    elseif ext == "q15" then
      local e = toEastern(t)
      local mine = 0
      for _, f in ipairs(allFiles(folder, ext)) do
        if f.base == today:sub(1, 7) then mine = mine + (filesystem.size(f.full) or 0) end
      end
      local elapsed = (e.day - 1) + (e.hour * 3600 + e.min * 60) / 86400
      if elapsed > 0.04 then perDay.q15 = perDay.q15 + mine / elapsed end
    end
    rows[#rows + 1] = r
    return r
  end
  for _, src in ipairs(SOURCES) do
    for _, ext in ipairs({ "raw", "min", "q15" }) do scan(src.folder, ext, TIERS[ext].label, #src.fields) end
  end
  local cr = scan(CYCLE_FOLDER, "cyc", TIERS.cyc.label, 2)
  local cycles = readCycles(nil)
  cr.records = #cycles
  local gaps = gapsOf(cycles)
  local total, free, usable = 0, 0, 0
  for _, d in ipairs(drives) do
    freeOf(d)
    total, free = total + d.total, free + max(0, d.free)
    usable = usable + max(0, d.free - reserve())
  end
  return { at = t, rows = rows, cycles = #cycles, gaps = #gaps, perDay = perDay,
           total = total, free = free, usable = usable, firstCycle = cycles[1] }
end

------------------------------------------------------------- STARTUP / TICK
local up0 = computer.uptime()
local nextFlush, nextScan, nextClean = up0 + CONFIG.FLUSH_SECONDS, up0 + 30, up0 + 90

local function start()
  scanDrives()
  local t = now()
  local list = readCycles(nil)
  for _, c in ipairs(list) do seen[cycleKey(c.start)] = true end
  cycleTotal = #list
  lastCycle = list[#list]
  return t
end

local function tick()
  local up = computer.uptime()
  if up >= nextFlush then flush(); nextFlush = up + CONFIG.FLUSH_SECONDS end
  if up >= nextScan then scanDrives(); nextScan = up + 30 end
  if up >= nextClean then
    local ok, err = pcall(cleanup, false)
    if not ok then lastError = tostring(err) end
    nextClean = up + CONFIG.CLEANUP_SECONDS
  end
end

-- on shutdown: write the half-finished averages too
local function finalFlush()
  for _, src in ipairs(SOURCES) do
    for _, tk in ipairs(ROLLS) do
      local b = acc[src.key] and acc[src.key][tk]
      if b then emit(src, tk, b); resetBucket(b, nil) end
    end
  end
  flush()
end

local function pendingCount()
  local n = 0
  for _, p in pairs(pending) do n = n + (p.recs and #p.recs or #p.lines) end
  return n
end

local function fresh(at) return at ~= nil and now() - at <= CONFIG.STALE_SECONDS end

return {
  SOURCES = SOURCES, SRC = SRC, TIERS = TIERS, CYCLE_FOLDER = CYCLE_FOLDER,
  binary = function() return BINARY end, havePack = HAVE_PACK,
  drives = function() return drives end, allDrives = function() return allDrives end,
  scan = scanDrives, letterOf = letterOf, freeOf = freeOf, listDir = listDir, splitName = splitName,
  onFuel = onFuel, onFarm = onFarm, onStats = onStats,
  start = start, tick = tick, flush = flush, finalFlush = finalFlush, cleanup = cleanup, usage = usage,
  aggregate = aggregate, readCycles = readCycles, firstTime = firstTime, fileInfo = fileInfo,
  gapsOf = gapsOf, report = report,
  forget = function() where, whereCount = {}, 0 end,
  live = live, stats = stats, fresh = fresh, rawDays = rawDays, reserve = reserve,
  info = function()
    return { written = written, flushes = flushes, lastFlush = lastFlush, lastError = lastError,
             pending = pendingCount(), cycles = cycleTotal, lastCycle = lastCycle, lastClean = lastClean }
  end,
  clearError = function() lastError = nil end,
  anyFresh = function()
    return fresh(stats.at) or fresh(live.lsc and live.lsc.at) or fresh(live.farm and live.farm.at)
  end,
}
end)()


------------------------------------------------------------------ STATE
local running = true
local activeApp = "explorer"  -- window in front: "explorer" | "sys" | "settings" | nil (desktop)
local explorerOpen = true
local statusMsg = "Ready"
local lockedFlag = false      -- lock screen up (set by LOCK)

-- Window geometry
local WX, WY, WW, WH = 14, 2, 144, 44

local function responding() return ARC.anyFresh() end

------------------------------------------------------------- UI KIT
-- Dark "monitor" colors (same as gtgraphs / the old Logs app) for graphs.
local G = {
  bg = 0x0B0B0B, panel = 0x161616, panel2 = 0x242424, header = 0x0E2A38,
  text = 0xE6E6E6, dim = 0x8C8C8C, dark = 0x000000, accent = 0x00C8FF,
  good = 0x3FE06A, warn = 0xFFB000, bad = 0xFF4D4D, grid = 0x333333,
  axis = 0x6E6E6E, button = 0x2E4A5A, track = 0x2A2A2A, nb = 0xE8C547,
}
local UI = {}

-- colored pieces left, dim text right-aligned, the rest padded (no flicker)
function UI.segs(x, y, w, list, right, b, rcol)
  b = b or G.panel
  right = right or ""
  local rw = unicode.len(right)
  local stop = x + w - rw - (rw > 0 and 1 or 0)
  local cx = x
  for _, sg in ipairs(list) do
    local s = sg[1]
    local room = stop - cx
    if room <= 0 then break end
    if unicode.len(s) > room then s = unicode.sub(s, 1, room) end
    text(cx, y, s, sg[2], b)
    cx = cx + unicode.len(s)
  end
  if x + w - rw - cx > 0 then text(cx, y, string.rep(" ", x + w - rw - cx), nil, b) end
  if rw > 0 then text(x + w - rw, y, right, rcol or G.dim, b) end
end

-- one row of text with labels centered on given columns
function UI.labelRow(width, items)
  local chars = {}
  for i = 1, width do chars[i] = " " end
  for _, it in ipairs(items) do
    local lab = it[2]
    local len = unicode.len(lab)
    local lx = max(1, min(it[1] - floor(len / 2), width - len + 1))
    for i = 1, len do
      if lx + i - 1 >= 1 and lx + i - 1 <= width then chars[lx + i - 1] = unicode.sub(lab, i, i) end
    end
  end
  return table.concat(chars)
end

function UI.panel(x, y, w, h, title, color, right)
  fill(x, y, w, h, G.panel)
  fill(x, y, w, 1, color)
  text(x, y, " " .. title .. " ", G.dark, color)
  if right then textW(x + w - unicode.len(right) - 1, y, unicode.len(right), right, G.dark, color) end
end

function UI.niceMax(v)
  if v <= 0 then return 1 end
  local e = 10 ^ floor(math.log(v, 10))
  for _, m in ipairs({ 1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 }) do
    if v <= m * e then return m * e end
  end
  return 10 * e
end

function UI.niceMin(v)
  if v <= 0 then return 0 end
  local e = 10 ^ floor(math.log(v, 10))
  for _, m in ipairs({ 8, 6, 5, 4, 3, 2.5, 2, 1.5, 1.2, 1 }) do
    if v >= m * e then return m * e end
  end
  return 0
end

function UI.shortNum(n)
  if not n or n ~= n then return "--" end
  local a = math.abs(n)
  if a >= 1e15 then return string.format("%.2fP", n / 1e15)
  elseif a >= 1e12 then return string.format("%.2fT", n / 1e12)
  elseif a >= 1e9 then return string.format("%.2fG", n / 1e9)
  elseif a >= 1e6 then return string.format("%.2fM", n / 1e6)
  elseif a >= 1e4 then return string.format("%.1fK", n / 1e3)
  elseif a >= 100 or a == floor(a) then return string.format("%d", floor(n + 0.5)) end
  return string.format("%.2f", n)
end

function UI.fmtShort(s)        -- at most 5 characters
  s = max(0, floor(s + 0.5))
  if s < 60 then return s .. "s" end
  if s < 3600 then return floor(s / 60) .. "m" end
  if s < 86400 then return string.format("%dh%02d", floor(s / 3600), floor(s % 3600 / 60)) end
  return string.format("%dd%02d", floor(s / 86400), floor(s % 86400 / 3600))
end

function UI.stamp(t)           -- "11/06 11:56 PM"
  if not t then return "--" end
  local e = toEastern(t)
  if SETTINGS.clock24 then return string.format("%02d/%02d %02d:%02d", e.month, e.day, e.hour, e.min) end
  local h, ap = h12(e)
  return string.format("%02d/%02d %2d:%02d %s", e.month, e.day, h, e.min, ap)
end

function UI.stampSec(t)        -- "11/06 11:56:07 PM"
  if not t then return "--" end
  local e = toEastern(t)
  if SETTINGS.clock24 then return string.format("%02d/%02d %02d:%02d:%02d", e.month, e.day, e.hour, e.min, e.sec) end
  local h, ap = h12(e)
  return string.format("%02d/%02d %2d:%02d:%02d %s", e.month, e.day, h, e.min, e.sec, ap)
end

function UI.clockOnly(t)       -- "11:56 PM"
  local e = toEastern(t)
  if SETTINGS.clock24 then return string.format("%02d:%02d", e.hour, e.min) end
  local h, ap = h12(e)
  return string.format("%d:%02d %s", h, e.min, ap)
end

function UI.dateOnly(t, year)  -- "11/06" or "11/06/26"
  local e = toEastern(t)
  if year then return string.format("%02d/%02d/%02d", e.month, e.day, e.year % 100) end
  return string.format("%02d/%02d", e.month, e.day)
end

local MONTH_NAMES = { "January", "February", "March", "April", "May", "June", "July",
                      "August", "September", "October", "November", "December" }
UI.MONTHS = MONTH_NAMES

-- value of an archive field, nicely ("1,234,567 EU/t", "87.5%")
function UI.val(field, v, short)
  if not v or v ~= v then return "--" end
  if field.pct then return string.format("%.1f%%", v) end
  if short or math.abs(v) >= 1e12 then return UI.shortNum(v) .. field.unit end
  return commas(v) .. field.unit
end

-- vertical scrollbar; light = 98 style, else dark
function UI.scrollbar(x, y, h, pos, maxPos, light)
  local fgc, bgc, tr = light and K.black or G.text, light and K.face or G.button, light and K.track or G.track
  text(x, y, "▲", fgc, bgc)
  text(x, y + h - 1, "▼", fgc, bgc)
  if h > 2 then vtext(x, y + 1, string.rep("░", h - 2), light and K.face or G.axis, tr) end
  if maxPos > 0 and h > 3 then
    text(x, y + 1 + floor((h - 3) * pos / maxPos + 0.5), "█", light and K.face or G.accent, tr)
  end
end

--------------------------------------------------------------- DESKTOP
local function drawIcon(x, y, kind, label)
  if kind == "pc" then
    fill(x + 1, y, 6, 2, K.face)
    fill(x + 2, y, 4, 1, K.navy)
    fill(x + 2, y + 1, 4, 1, K.navy)
    fill(x + 2, y + 2, 4, 1, K.face)
  elseif kind == "folder" then
    fill(x + 1, y, 3, 1, K.folder)
    fill(x + 1, y + 1, 7, 2, K.folder)
    text(x + 1, y + 1, "▔▔▔▔▔▔▔", 0xFFF2A8, K.folder)
  elseif kind == "bin" then
    text(x + 2, y, "▄▄▄▄", K.sh, K.desk)
    fill(x + 2, y + 1, 4, 2, K.face)
    text(x + 2, y + 1, "║║║║", K.sh, K.face)
  end
  textW(x - 2, y + 3, 12, label, K.white, K.desk, "center")
end

local drawAll, openExplorer                              -- forward
local openSysApp, closeSysApp, sysAppOpen                -- forward (My Computer)
local openSettings, closeSettings, settingsOpen          -- forward (Settings)
local LOCK, SET, FX                                      -- lock screen, Settings, File Explorer

local function drawDesktop()
  fill(1, 1, W, 46, K.desk)
  drawIcon(3, 2, "pc", "My Computer")
  drawIcon(3, 8, "folder", "Explorer")
  drawIcon(3, 14, "bin", "Recycle Bin")
  region(regions, 1, 2, 12, 5, function() openSysApp(); drawAll() end)
  region(regions, 1, 8, 12, 5, function() openExplorer(); drawAll() end)
  -- Settings icon: a little control panel with sliders
  fill(4, 20, 8, 3, K.face)
  text(4, 20, "─●──────", K.navy, K.face)
  text(4, 21, "────●───", K.navy, K.face)
  text(4, 22, "──────●─", K.navy, K.face)
  textW(1, 23, 12, "Settings", K.white, K.desk, "center")
  region(regions, 1, 20, 12, 4, function() openSettings(); drawAll() end)
end

----------------------------------------------------------------- TASKBAR
local function drawTray()
  bevel(144, 48, 16, 3, "sunken", K.face, K.face)
  local ok = responding()
  text(146, 49, "((•))", ok and K.green or K.sh, K.face)
  textW(151, 49, 8, fmtTray(now()), K.black, K.face, "right")
end

local openStartMenu  -- forward

local function taskButton(x, w, label, app)
  local active = (activeApp == app)
  local face = active and 0xD8D8D8 or K.face
  bevel(x, 48, w, 3, active and "sunken" or "raised", K.face, face)
  textW(x + 1, 49, w - 2, label, K.black, face)
  region(taskRegions, x, 48, w, 3, function()
    if activeApp == app then activeApp = nil else activeApp = app end
    drawAll()
  end)
end

local function drawTaskbar()
  taskRegions = {}
  fill(1, 47, W, 4, K.face)
  text(1, 47, string.rep("▔", W), K.hi, K.face)
  button(taskRegions, 1, 48, 9, "◆ Start", function() openStartMenu() end, overlay and overlay.start)
  local tx = 11
  if explorerOpen then taskButton(tx, 25, " ▣ File Explorer", "explorer"); tx = tx + 26 end
  if sysAppOpen and sysAppOpen() then taskButton(tx, 25, " ▣ My Computer", "sys"); tx = tx + 26 end
  if settingsOpen and settingsOpen() then taskButton(tx, 25, " ▣ Settings", "settings") end
  drawTray()
end

-------------------------------------------------------- MENUS & DIALOGS
local dialogQueue = {}

-- show a dialog now, or after the one currently open
local function showOrQueue(fn)
  if overlay and overlay.modal then dialogQueue[#dialogQueue + 1] = fn else fn() end
end

local function nextDialogOrRedraw()
  if #dialogQueue > 0 then table.remove(dialogQueue, 1)()
  elseif running then drawAll() end
end

local function closeOverlay()
  overlay = nil
  nextDialogOrRedraw()
end

local function popupMenu(x, y, items, opts)
  opts = opts or {}
  local w = 4
  for _, it in ipairs(items) do w = max(w, unicode.len(it[1]) + 6) end
  local banner = opts.banner and 3 or 0
  local h = #items + 2
  if opts.above then y = y - h end
  overlay = { regions = {}, start = opts.start }
  drawAll(true)       -- redraw underneath, then the menu on top
  bevel(x, y, w + banner, h, "raised", K.face, K.face)
  if banner > 0 then
    -- vertical gradient banner like the classic Start menu
    for i = 1, h - 2 do
      bg(lerp(K.navy, K.title2, (i - 1) / max(1, h - 3)))
      fg(K.white)
      gpu.set(x + 1, y + i, "  ")
    end
    local word = tostring(SETTINGS.systemName or "Lymanos"):sub(1, h - 2)
    for i = 1, #word do
      local yy = y + h - 1 - #word + i - 1
      bg(lerp(K.navy, K.title2, (yy - y - 1) / max(1, h - 3)))
      gpu.set(x + 1, yy, word:sub(i, i) .. " ")
    end
  end
  for i, it in ipairs(items) do
    local iy = y + i
    if it[1] == "-" then
      text(x + 1 + banner, iy, string.rep("─", w - 2), K.sh, K.face)
    else
      textW(x + 1 + banner, iy, w - 2, "  " .. it[1], K.black, K.face)
      region(overlay.regions, x + 1 + banner, iy, w - 2, 1, function()
        overlay = { regions = {}, busy = true }
        it[2]()
        if overlay and overlay.busy then overlay = nil; nextDialogOrRedraw() end
      end)
    end
  end
end

local function dialog(title, lines, buttons)
  if lockedFlag then      -- the lock screen is up: show it after unlocking
    dialogQueue[#dialogQueue + 1] = function() dialog(title, lines, buttons) end
    return
  end
  local w = max(50, #buttons * 14 + 6)
  for _, l in ipairs(lines) do w = max(w, unicode.len(l) + 10) end
  w = min(w, W - 4)
  local h = #lines + 8
  local x, y = floor((W - w) / 2), floor((46 - h) / 2)
  overlay = { regions = {}, modal = true, reshow = function() dialog(title, lines, buttons) end }
  drawAll(true)
  bevel(x, y, w, h, "raised", K.desk, K.face)
  titleBar(x + 1, y + 1, w - 2, title, true)
  text(x + w - 4, y + 1, " X ", K.black, K.face)
  region(overlay.regions, x + w - 4, y + 1, 3, 1, closeOverlay)
  text(x + 3, y + 3, "(i)", K.white, K.navy)
  for i, l in ipairs(lines) do textW(x + 8, y + 2 + i, w - 10, l, K.black, K.face) end
  local bw = 12
  for _, b in ipairs(buttons) do bw = max(bw, unicode.len(b[1]) + 4) end
  local total = #buttons * bw + (#buttons - 1) * 2
  local bx = x + floor((w - total) / 2)
  for _, b in ipairs(buttons) do
    button(overlay.regions, bx, y + h - 4, bw, b[1], function()
      overlay = { regions = {}, modal = true, busy = true }
      if b[2] then b[2]() end
      if overlay and overlay.busy then overlay = nil; nextDialogOrRedraw() end
    end)
    bx = bx + bw + 2
  end
end

local function about()
  local inf = ARC.info()
  dialog("About " .. tostring(SETTINGS.systemName or "Lymanos Archive"), {
    tostring(SETTINGS.systemName or "Lymanos Archive") .. "  (Lymanos Archive 1.0)",
    "Records lscfuel (port " .. CONFIG.FUEL_PORT .. "), treefarm2 (port " .. CONFIG.FARM_PORT
      .. ") and lscstats (port " .. CONFIG.STATS_PORT .. ")",
    "to every archive drive, and shows it all in File Explorer.",
    "",
    "Storage format: " .. (ARC.binary() and "packed binary (Lua 5.3)" or "text (Lua 5.2 or FORMAT = text)"),
    "Archive drives: " .. #ARC.drives() .. "    Cycles archived: " .. inf.cycles,
    "Written this session: " .. humanBytes(inf.written),
  }, { { "OK" } })
end

local function confirmExit()
  dialog("Shut Down", { "Close " .. tostring(SETTINGS.systemName or "Lymanos Archive") .. "?",
    "Recording stops until it is started again.", "Unsaved samples are written to disk first." },
    { { "Yes", function() running = false end }, { "No" } })
end

local function flushNow()
  ARC.flush()
  statusMsg = "All samples written to disk"
end

openStartMenu = function()
  popupMenu(1, 47, {
    { "File Explorer", function() openExplorer() end },
    { "My Computer", function() openSysApp() end },
    { "Settings", function() openSettings() end },
    { "-" },
    { "Lock", function() LOCK.lock() end },
    { "Save Samples Now", flushNow },
    { "Request Cycle Log", function() requestUpdate(); statusMsg = "Asked lscstats for its log..." end },
    { "About...", about },
    { "-" },
    { "Shut Down...", confirmExit },
  }, { banner = true, above = true, start = true })
end


-------------------------------------------------------------- VIEWERS
-- What File Explorer shows when a file is opened:
--   graph   .raw / .min / .q15 files (or a source folder): min/max band +
--           average line over any time window, plus a data table
--   cycles  .cyc files: every charging cycle of a month (or all time)
--   text    anything else (programs, settings files), read-only
local VIEW = (function()
local X0, CW = WX + 1, WW - 2
local TB = WY + 3                 -- toolbar (3 rows)
local HY = WY + 6                 -- dark header strip
local SY = WY + WH - 2            -- status bar
local kind = nil                  -- "graph" | "cycles" | "gaps" | "report" | "text" | nil
local backFn = nil
local gapsFromCycles              -- set below (cycle log -> gap graph of the same month)

local function back()
  kind = nil
  if backFn then backFn() end
  drawAll()
end

local function toolbar(items)
  fill(X0, TB, CW, 3, K.face)
  local x = X0 + 1
  for _, it in ipairs(items) do
    if it == "gap" then x = x + 2
    else
      button(regions, x, TB, it[2], it[1], it[3], it[4])
      x = x + it[2] + 1
    end
  end
end

local function status98(parts)
  fill(X0, SY, CW, 1, K.face)
  local cx = X0 + 1
  for i, p in ipairs(parts) do
    if i > 1 then text(cx, SY, "│", K.sh, K.face); cx = cx + 2 end
    local w = (i == #parts) and (X0 + CW - cx) or (unicode.len(p) + 1)
    textW(cx, SY, w, p, K.black, K.face)
    cx = cx + w
  end
end

------------------------------------------------------------ GRAPH VIEW
local LABW = 9
local GX = X0 + LABW + 1          -- first graph column on screen
local NCOL = CW - LABW - 3        -- graph width = number of time slices
local GY, GROWS = HY + 2, 20      -- graph rows (40 pixels tall)
local XL = GY + GROWS             -- time labels
local FLY = XL + 1                -- charging / running strip
local THY = FLY + 1               -- table header
local TR0 = THY + 1               -- first table row
local TROWS = SY - TR0            -- table rows
local PRESETS = { { "1H", 3600 }, { "6H", 21600 }, { "1D", 86400 }, { "7D", 604800 },
                  { "30D", 2592000 }, { "1Y", 31536000 }, { "ALL", 0 } }
local DETAIL = { { "auto", "AUTO" }, { "raw", "5 s" }, { "min", "1 min" }, { "q15", "15 min" } }

local gv = { src = nil, fi = 1, t0 = 0, t1 = 1, live = nil, all = false, tier = "auto",
             sel = nil, C = nil, at = 0, scroll = 0 }

local function span() return gv.t1 - gv.t0 end
local function colTime(c) return gv.t0 + (c - 1) * span() / NCOL end

local function recompute()
  local t = now()
  if gv.live then
    gv.t1 = floor(t) + 1
    if gv.all then gv.t0 = min(ARC.firstTime(gv.src.folder) or (gv.t1 - 86400), gv.t1 - 3600)
    else gv.t0 = gv.t1 - gv.live end
  end
  local C = ARC.aggregate(gv.src.key, gv.fi, gv.t0, gv.t1, NCOL, gv.tier)
  local n, s, fl, lo, hi = 0, 0, 0, nil, nil
  for c = 1, NCOL do
    if C.n[c] > 0 then
      n, s, fl = n + C.n[c], s + C.s[c], fl + C.fl[c]
      if C.lo[c] and (not lo or C.lo[c] < lo) then lo = C.lo[c] end
      if C.hi[c] and (not hi or C.hi[c] > hi) then hi = C.hi[c] end
    end
  end
  C.tn, C.tavg, C.tlo, C.thi, C.tfl = n, n > 0 and s / n or nil, lo, hi, fl
  local rows = {}
  for c = NCOL, 1, -1 do if C.n[c] > 0 then rows[#rows + 1] = c end end
  C.rows = rows
  gv.C, gv.at = C, computer.uptime()
  if gv.sel and C.n[gv.sel] == 0 then gv.sel = nil end
  gv.scroll = max(0, min(gv.scroll, #rows - TROWS))
end

local function openGraph(srcKey, t0, t1, tier, fi)
  kind = "graph"
  gv.src = ARC.SRC[srcKey]
  gv.fi = fi or 1
  gv.tier = tier or "auto"
  gv.sel, gv.scroll = nil, 0
  if t0 then gv.t0, gv.t1, gv.live, gv.all = t0, t1, nil, false
  else gv.live, gv.all = 86400, false end
  recompute()
end

local function liveIfNow()
  if gv.t1 >= now() then gv.live, gv.all = span(), false end
end

local function shift(dir)
  local s = span()
  gv.t0, gv.t1, gv.live, gv.all, gv.sel = gv.t0 + dir * s, gv.t1 + dir * s, nil, false, nil
  liveIfNow()
  recompute(); drawAll()
end

local function zoom(f)
  local center = gv.sel and (colTime(gv.sel) + span() / NCOL / 2) or (gv.t0 + gv.t1) / 2
  local s = max(600, span() * f)
  gv.t0 = floor(center - s / 2)
  gv.t1 = gv.t0 + floor(s)
  gv.live, gv.all, gv.sel = nil, false, nil
  if gv.t1 >= now() then gv.t1 = floor(now()) + 1; gv.t0 = gv.t1 - floor(s); gv.live = floor(s) end
  recompute(); drawAll()
end

local function preset(p)
  if p[2] == 0 then gv.live, gv.all = 1, true else gv.live, gv.all = p[2], false end
  gv.sel, gv.scroll = nil, 0
  recompute(); drawAll()
end

local function rangeText()
  local s = span()
  local function st(t) return s <= 86400 * 2 and UI.stamp(t) or UI.dateOnly(t, true) .. " " .. UI.clockOnly(t) end
  return st(gv.t0) .. "  →  " .. (gv.live and "now" or st(gv.t1))
end

local function drawStats()
  local C, f = gv.C, gv.src.fields[gv.fi]
  local y = HY + 1
  if gv.sel then
    local c = gv.sel
    local bs = span() / NCOL
    UI.segs(X0, y, CW, {
      { " SELECTED ", G.accent }, { UI.stampSec(colTime(c)) .. " + " .. UI.fmtShort(bs) .. "   ", G.text },
      { "AVG ", G.dim }, { UI.val(f, C.s[c] / C.n[c]) .. "   ", f.color },
      { "MIN ", G.dim }, { UI.val(f, C.lo[c]) .. "   ", G.text },
      { "MAX ", G.dim }, { UI.val(f, C.hi[c]) .. "   ", G.text },
      { gv.src.flagName:upper() .. " ", G.dim }, { floor(C.fl[c] / C.n[c] * 100 + 0.5) .. "%", G.good } },
      C.n[c] .. " samples ", G.panel)
  else
    UI.segs(X0, y, CW, {
      { " " .. rangeText() .. "    ", G.text },
      { "AVG ", G.dim }, { UI.val(f, C.tavg) .. "   ", f.color },
      { "MIN ", G.dim }, { UI.val(f, C.tlo) .. "   ", G.text },
      { "MAX ", G.dim }, { UI.val(f, C.thi) .. "   ", G.text },
      { gv.src.flagName:upper() .. " ", G.dim },
      { C.tn > 0 and (floor(C.tfl / C.tn * 100 + 0.5) .. "%") or "--", G.good } },
      (ARC.TIERS[C.tier] and ARC.TIERS[C.tier].label or "") .. " ", G.panel)
  end
end

local function drawGraphArea()
  local C, f = gv.C, gv.src.fields[gv.fi]
  local ph = GROWS * 2
  fill(X0, GY, CW, GROWS + 2, G.panel)
  local lo, hi = C.tlo, C.thi
  local ymin, ymax
  if f.pct then ymin, ymax = 0, 100
  elseif not lo then ymin, ymax = 0, 1
  else
    if lo > 0 and lo > hi * 0.6 then ymin = UI.niceMin(lo * 0.98) else ymin = min(0, lo) end
    ymax = UI.niceMax(max(hi, 1) * 1.04)
    if ymax <= ymin then ymax = ymin + max(1, math.abs(ymin) * 0.1) end
  end
  local function py(v)
    local y = ph - 1 - floor((v - ymin) / (ymax - ymin) * (ph - 3) + 0.5)
    return max(1, min(ph - 1, y))
  end
  local cv = newCanvas(NCOL, ph, G.panel)
  for k = 1, 4 do
    local yy = py(ymin + (ymax - ymin) * k / 4)
    for xx = 2, NCOL, 3 do cset(cv, xx, yy, G.grid) end
  end
  local band = lerp(f.color, G.panel, 0.62)
  local lineC = lerp(f.color, 0xFFFFFF, 0.25)
  if gv.sel then
    for yy = 1, ph - 1 do cset(cv, gv.sel, yy, lerp(G.accent, G.panel, 0.7)) end
  end
  local px, pyv
  for c = 1, NCOL do
    if C.n[c] > 0 then
      local yh, yl = py(C.hi[c] or C.s[c] / C.n[c]), py(C.lo[c] or C.s[c] / C.n[c])
      for yy = yh, yl do cset(cv, c, yy, band) end
      local ya = py(C.s[c] / C.n[c])
      if px and c - px <= 3 then cline(cv, px, pyv, c, ya, lineC) else cset(cv, c, ya, lineC) end
      px, pyv = c, ya
    end
  end
  for xx = 1, NCOL do cset(cv, xx, ph, G.axis) end
  crender(cv, GX, GY)
  for k = 0, 4 do
    local lv = ymin + (ymax - ymin) * k / 4
    local lab = f.pct and (floor(lv + 0.5) .. "%") or UI.shortNum(lv)
    textW(X0, GY + floor((py(lv) - 1) / 2), LABW, lab, G.dim, G.panel, "right")
  end
  if C.tn == 0 then
    textW(GX, GY + 8, NCOL, "No " .. f.long .. " data in this window.", G.dim, G.panel, "center")
    textW(GX, GY + 9, NCOL, C.err or ("Recording starts with the first packet from " .. gv.src.from
      .. " - try a longer window (7D / ALL)."), C.err and G.bad or G.grid, G.panel, "center")
  end
  -- time labels
  local s = span()
  local function lab(t)
    if s <= 26 * 3600 then return UI.clockOnly(t) end
    if s <= 70 * 86400 then return UI.dateOnly(t) end
    return UI.dateOnly(t, true)
  end
  local items = {}
  for k = 0, 4 do
    local c = (k == 0) and 1 or floor(NCOL * k / 4)
    items[#items + 1] = { c, (k == 4 and gv.live) and "now" or lab(gv.t0 + s * (c - 1) / NCOL) }
  end
  text(GX, XL, UI.labelRow(NCOL, items), G.dim, G.panel)
  if s > 26 * 3600 and s <= 4 * 86400 then
    textW(X0, XL, LABW, UI.dateOnly(gv.t0), G.grid, G.panel, "right")
  end
  -- charging / running strip
  textW(X0, FLY, LABW, gv.src.flagName, G.dim, G.panel, "right")
  local c = 1
  while c <= NCOL do
    local function colr(i)
      if C.n[i] == 0 then return G.track end
      local fr = C.fl[i] / C.n[i]
      if fr <= 0 then return G.grid end
      return lerp(G.panel, G.good, 0.35 + 0.65 * fr)
    end
    local col = colr(c)
    local c2 = c + 1
    while c2 <= NCOL and colr(c2) == col do c2 = c2 + 1 end
    text(GX + c - 1, FLY, string.rep("▀", c2 - c), col, G.panel)
    c = c2
  end
end

local TCOLS = { { "TIME", 22 }, { "AVERAGE", 22 }, { "MIN", 22 }, { "MAX", 22 }, { "SAMPLES", 9 }, { "", 12 } }

local function drawTable()
  local C, f = gv.C, gv.src.fields[gv.fi]
  TCOLS[6][1] = gv.src.flagName:upper()
  fill(X0, THY, CW, 1, G.header)
  local cx = X0 + 1
  for i, col in ipairs(TCOLS) do
    textW(cx, THY, col[2], col[1], G.dim, G.header, i > 1 and "right" or nil)
    cx = cx + col[2] + 2
  end
  local bs = span() / NCOL
  local maxScroll = max(0, #C.rows - TROWS)
  gv.scroll = max(0, min(gv.scroll, maxScroll))
  for r = 1, TROWS do
    local c = C.rows[gv.scroll + r]
    local y = TR0 + r - 1
    local b = (c and c == gv.sel) and G.button or ((r % 2 == 0) and 0x1B1B1B or G.panel)
    if c then
      local cells = { bs >= 60 and UI.stamp(colTime(c)) or UI.stampSec(colTime(c)),
        UI.val(f, C.s[c] / C.n[c]), UI.val(f, C.lo[c]), UI.val(f, C.hi[c]), commas(C.n[c]),
        floor(C.fl[c] / C.n[c] * 100 + 0.5) .. "%" }
      local colors = { G.text, f.color, G.text, G.text, G.dim, G.good }
      cx = X0 + 1
      fill(X0, y, 1, 1, b)
      for i, col in ipairs(TCOLS) do
        textW(cx, y, col[2] + 2, cells[i] .. "  ", colors[i], b, i > 1 and "right" or nil)
        cx = cx + col[2] + 2
      end
      fill(cx, y, X0 + CW - 1 - cx, 1, b)
    else
      fill(X0, y, CW - 1, 1, G.panel)
      if r == 1 then textW(X0, y, CW - 1, "(nothing recorded in this window)", G.dim, G.panel, "center") end
    end
  end
  UI.scrollbar(X0 + CW - 1, TR0, TROWS, gv.scroll, maxScroll)
end

local function selectCol(c)
  gv.sel = (c and gv.sel ~= c) and c or nil
  if gv.sel then
    for i, rc in ipairs(gv.C.rows) do
      if rc == gv.sel then
        if i <= gv.scroll or i > gv.scroll + TROWS then gv.scroll = max(0, i - floor(TROWS / 2)) end
        break
      end
    end
  end
  drawStats(); drawGraphArea(); drawTable()
end

local function graphStatus()
  local C = gv.C
  local age = floor(computer.uptime() - gv.at)
  status98({ C.err and ("! Some files skipped: " .. C.err) or statusMsg,
    (ARC.TIERS[C.tier] and ARC.TIERS[C.tier].label or "?") .. (gv.tier == "auto" and " (auto)" or ""),
    C.files .. " file(s), " .. commas(C.records) .. " records",
    #C.rows .. " slices of " .. UI.fmtShort(span() / NCOL),
    (gv.live and "live, " or "") .. "updated " .. UI.fmtShort(age) .. " ago" })
end

local function drawGraph()
  toolbar({
    { "◄ Back", 10, back },
    "gap",
    { "◄", 5, function() shift(-1) end },
    { "►", 5, function() shift(1) end },
    { "Now", 7, function() gv.live, gv.all = span(), false; recompute(); drawAll() end, gv.live and not gv.all },
    { "Zoom +", 10, function() zoom(0.25) end },
    { "Zoom -", 10, function() zoom(4) end },
    { "Refresh", 11, function() recompute(); drawAll() end },
    "gap",
    { "1H", 6, function() preset(PRESETS[1]) end, gv.live == 3600 and not gv.all },
    { "6H", 6, function() preset(PRESETS[2]) end, gv.live == 21600 and not gv.all },
    { "1D", 6, function() preset(PRESETS[3]) end, gv.live == 86400 and not gv.all },
    { "7D", 6, function() preset(PRESETS[4]) end, gv.live == 604800 and not gv.all },
    { "30D", 7, function() preset(PRESETS[5]) end, gv.live == 2592000 and not gv.all },
    { "1Y", 6, function() preset(PRESETS[6]) end, gv.live == 31536000 and not gv.all },
    { "ALL", 7, function() preset(PRESETS[7]) end, gv.all },
  })
  -- header: source + field tabs + detail level
  fill(X0, HY, CW, 1, G.header)
  local title = "≡ " .. gv.src.folder:upper() .. "  "
  text(X0 + 1, HY, title, G.accent, G.header)
  local x = X0 + 1 + unicode.len(title)
  for i, f in ipairs(gv.src.fields) do
    local lab = " " .. f.label .. " "
    local on = (i == gv.fi)
    text(x, HY, lab, on and G.dark or G.text, on and f.color or G.button)
    region(regions, x, HY, unicode.len(lab), 1, function() gv.fi = i; recompute(); drawAll() end)
    x = x + unicode.len(lab) + 1
  end
  local dx = X0 + CW - 37
  text(dx, HY, "DETAIL ", G.dim, G.header)
  dx = dx + 7
  for _, d in ipairs(DETAIL) do
    local lab = " " .. d[2] .. " "
    local on = gv.tier == d[1]
    text(dx, HY, lab, on and G.dark or G.text, on and G.accent or G.button)
    region(regions, dx, HY, unicode.len(lab), 1, function() gv.tier = d[1]; recompute(); drawAll() end)
    dx = dx + unicode.len(lab) + 1
  end
  drawStats()
  drawGraphArea()
  region(regions, GX, GY, NCOL, GROWS + 2, function(px)
    local c = max(1, min(NCOL, px - GX + 1))
    if gv.C.n[c] == 0 then        -- snap to the nearest slice with data
      for d = 1, 6 do
        if c - d >= 1 and gv.C.n[c - d] > 0 then c = c - d; break end
        if c + d <= NCOL and gv.C.n[c + d] > 0 then c = c + d; break end
      end
    end
    if gv.C.n[c] > 0 then selectCol(c) end
  end)
  drawTable()
  for r = 1, TROWS do
    region(regions, X0, TR0 + r - 1, CW - 1, 1, function()
      local c = gv.C.rows[gv.scroll + r]
      if c then selectCol(c) end
    end)
  end
  region(regions, X0 + CW - 1, TR0, 1, 1, function() gv.scroll = gv.scroll - 1; drawTable() end)
  region(regions, X0 + CW - 1, TR0 + TROWS - 1, 1, 1, function() gv.scroll = gv.scroll + 1; drawTable() end)
  graphStatus()
end

----------------------------------------------------------- CYCLES VIEW
local cy = { y = nil, m = nil, all = false, list = {}, scroll = 0, sel = nil, bars = {}, tot = {} }
local LXW = 70                         -- left table width
local RXX, RXW = X0 + LXW + 1, CW - LXW - 1
local CROWS = SY - (HY + 2) - 3        -- table rows (leaves 2 detail rows)
local CCOLS = { { "#", 6 }, { "Started", 15 }, { "Stopped", 15 }, { "Duration", 9 }, { "L/s", 7 }, { "NB used L", 11 } }

local function daysIn(y, m)
  local ny, nm = (m == 12) and y + 1 or y, m % 12 + 1
  return daysFromCivil(ny, nm, 1) - daysFromCivil(y, m, 1)
end

local function loadCycles()
  local list
  if cy.all then
    list = ARC.readCycles(nil)
  else
    local ny, nm = (cy.m == 12) and cy.y + 1 or cy.y, cy.m % 12 + 1
    list = ARC.readCycles(easternMidnight(cy.y, cy.m, 1), easternMidnight(ny, nm, 1))
  end
  cy.list = list
  -- chart: NB per day of the month, or per month (all time, last 24)
  local bars, byKey = {}, {}
  if not cy.all then
    for d = 1, daysIn(cy.y, cy.m) do
      local b = { label = tostring(d), v = 0, n = 0, key = d }
      bars[d] = b
      byKey[d] = b
    end
  end
  local tot = { n = #list, nb = 0, dur = 0, longest = 0, shortest = math.huge, gaps = 0, gapN = 0 }
  for i, c in ipairs(list) do
    local e = toEastern(c.start)
    local key = cy.all and (e.year * 12 + e.month) or e.day
    local b = byKey[key]
    if not b then
      b = { label = string.format("%02d/%02d", e.month, e.year % 100), v = 0, n = 0, key = key }
      byKey[key] = b
      bars[#bars + 1] = b
    end
    b.v, b.n = b.v + (c.used or 0), b.n + 1
    b.first = b.first or c
    tot.nb, tot.dur = tot.nb + (c.used or 0), tot.dur + (c.dur or 0)
    tot.longest, tot.shortest = max(tot.longest, c.dur or 0), min(tot.shortest, c.dur or 0)
    local p = list[i - 1]
    if p and p.stop and c.start > p.stop then
      local consecutive = not (tonumber(p.id) and tonumber(c.id)) or tonumber(c.id) == tonumber(p.id) + 1
      if consecutive then tot.gaps, tot.gapN = tot.gaps + (c.start - p.stop), tot.gapN + 1 end
    end
  end
  if cy.all then
    table.sort(bars, function(a, b) return a.key < b.key end)
    while #bars > 24 do table.remove(bars, 1) end
  end
  local busiest
  for _, b in ipairs(bars) do if b.n > 0 and (not busiest or b.v > busiest.v) then busiest = b end end
  tot.busiest = busiest
  cy.bars, cy.tot = bars, tot
  cy.scroll = 0
  if cy.sel then
    local ok = false
    for _, c in ipairs(list) do if c.start == cy.sel then ok = true end end
    if not ok then cy.sel = nil end
  end
end

local function openCycles(y, m)
  kind = "cycles"
  if y then cy.y, cy.m, cy.all = y, m, false
  else
    local e = toEastern(now())
    cy.y, cy.m, cy.all = e.year, e.month, false
  end
  cy.sel = nil
  loadCycles()
end

local function monthStep(d)
  if cy.all then
    local e = toEastern(now())
    cy.y, cy.m, cy.all = e.year, e.month, false
  else
    local k = cy.y * 12 + (cy.m - 1) + d
    cy.y, cy.m = floor(k / 12), k % 12 + 1
  end
  loadCycles(); drawAll()
end

local function periodText()
  if cy.all then return "ALL TIME" end
  return (UI.MONTHS[cy.m] or "?"):upper() .. " " .. cy.y
end

local function selectedCycle()
  if not cy.sel then return nil end
  for _, c in ipairs(cy.list) do if c.start == cy.sel then return c end end
end

local function drawCycleRows()
  local list = cy.list
  local n = #list
  local maxScroll = max(0, n - CROWS)
  cy.scroll = max(0, min(cy.scroll, maxScroll))
  for r = 1, CROWS do
    local c = list[n - cy.scroll - r + 1]
    local y = HY + 1 + r
    if c then
      local sel = c.start == cy.sel
      local b = sel and G.button or ((r % 2 == 0) and 0x1B1B1B or G.panel)
      local cells = { (sel and "►" or " ") .. "#" .. tostring(c.id or "?"), UI.stamp(c.start), UI.stamp(c.stop),
                      fmtDur(c.dur or 0), shortL(c.rate or 0), commas(c.used or 0) }
      local cx = X0 + 1
      fill(X0, y, 1, 1, b)
      for i, col in ipairs(CCOLS) do
        textW(cx, y, col[2], cells[i], i == 6 and G.nb or (i == 1 and G.accent or G.text), b, i >= 4 and "right" or nil)
        cx = cx + col[2]
        text(cx, y, " ", nil, b)
        cx = cx + 1
      end
      fill(cx, y, X0 + LXW - 1 - cx, 1, b)
    else
      fill(X0, y, LXW - 1, 1, G.panel)
      if r == 1 and n == 0 then
        textW(X0, y, LXW - 1, "No charging cycles archived for " .. periodText():lower() .. ".", G.dim, G.panel, "center")
      end
    end
  end
  UI.scrollbar(X0 + LXW - 1, HY + 2, CROWS, cy.scroll, maxScroll)
  local c = selectedCycle()
  local dy = SY - 2
  text(X0, dy - 1, string.rep("─", LXW), G.grid, G.panel)
  if c then
    UI.segs(X0 + 1, dy, LXW - 2, { { "CYCLE ", G.dim }, { "#" .. tostring(c.id or "?"), G.accent },
      { "   " .. fmtDurLong(c.dur or 0) .. "   at " .. commas(c.rate or 0) .. " L/s", G.text } })
    UI.segs(X0 + 1, dy + 1, LXW - 2, { { commas(c.used or 0) .. " L nitrobenzene", G.nb },
      { "   " .. fmtStamp(c.start) .. " → " .. fmtStamp(c.stop), G.dim } })
  else
    UI.segs(X0 + 1, dy, LXW - 2, { { "Click a cycle (or a bar) to see it here.", G.dim } })
    UI.segs(X0 + 1, dy + 1, LXW - 2, { { #cy.list .. " cycles, newest first. Scroll with the wheel.", G.dim } })
  end
end

local function pickCycle(c)
  cy.sel = (c and cy.sel ~= c.start) and c.start or nil
  if cy.sel then
    local n = #cy.list
    for i, x in ipairs(cy.list) do
      if x.start == cy.sel then
        local row = n - i + 1
        if row <= cy.scroll or row > cy.scroll + CROWS then cy.scroll = max(0, row - floor(CROWS / 2)) end
      end
    end
  end
  drawAll()
end

local function drawCycleChart()
  local P = { x = RXX, y = HY + 1, w = RXW, h = 21 }
  UI.panel(P.x, P.y, P.w, P.h, cy.all and "NITROBENZENE PER MONTH" or "NITROBENZENE PER DAY", G.nb,
    cy.tot.n .. " cycles")
  local LW8 = 8
  local gx, gy = P.x + LW8 + 1, P.y + 2
  local cw, rows = P.w - LW8 - 2, 15
  local ph = rows * 2
  local bars = cy.bars
  local mx = 0
  for _, b in ipairs(bars) do mx = max(mx, b.v) end
  local ymax = UI.niceMax(max(mx, 1) * 1.08)
  local function py(v) return ph - 1 - floor(v / ymax * (ph - 3) + 0.5) end
  local cv = newCanvas(cw, ph, G.panel)
  for k = 1, 4 do
    local yy = py(ymax * k / 4)
    for xx = 2, cw, 3 do cset(cv, xx, yy, G.grid) end
  end
  local sc = selectedCycle()
  local selKey
  if sc then
    local e = toEastern(sc.start)
    selKey = cy.all and (e.year * 12 + e.month) or e.day
  end
  local nb = max(1, #bars)
  local slotW = max(1, floor((cw - 1) / nb))
  local barW = slotW >= 3 and slotW - 1 or slotW
  for i, b in ipairs(bars) do
    local x0 = 2 + (i - 1) * slotW
    if b.n > 0 then
      local yt = py(b.v)
      local col = (selKey ~= nil and selKey == b.key) and 0xFFFFFF or G.nb
      for xx = x0, x0 + barW - 1 do
        cset(cv, xx, yt, lerp(col, 0xFFFFFF, 0.4))
        for yy = yt + 1, ph - 1 do cset(cv, xx, yy, lerp(col, G.panel, 0.05 + 0.6 * (yy - yt) / max(1, ph - 1 - yt))) end
      end
      local first = b.first
      region(regions, gx + x0 - 1, gy, barW, rows + 1, function() pickCycle(first) end)
    end
  end
  for xx = 1, cw do cset(cv, xx, ph, G.axis) end
  crender(cv, gx, gy)
  for k = 0, 4 do
    local lv = ymax * k / 4
    textW(P.x + 1, gy + floor((py(lv) - 1) / 2), LW8, shortL(lv), G.dim, G.panel, "right")
  end
  local labs = {}
  local every = max(1, ceil(5 / slotW))
  for i, b in ipairs(bars) do
    if (i - 1) % every == 0 then labs[#labs + 1] = { 2 + (i - 1) * slotW + floor(barW / 2), b.label } end
  end
  text(gx, gy + rows, UI.labelRow(cw, labs), G.dim, G.panel)
  UI.segs(P.x + 2, gy + rows + 2, P.w - 4, { { "▀ ", G.nb }, { "liters used   click a bar to jump to its first cycle", G.dim } })
end

local function drawCycleTotals()
  local y0 = HY + 23
  local h = SY - y0
  UI.panel(RXX, y0, RXW, h, "TOTALS - " .. periodText(), G.accent)
  local T = cy.tot
  local n = T.n
  local x1, x2, w = RXX + 2, RXX + 36, 33
  local function kv(x, y, label, value, col)
    textW(x, y, 14, label, G.dim, G.panel)
    textW(x + 14, y, w - 14, value, col or G.text, G.panel)
  end
  local y = y0 + 2
  kv(x1, y, "Cycles:", commas(n), G.accent)
  kv(x2, y, "Total NB:", commas(T.nb) .. " L", G.nb)
  kv(x1, y + 1, "Avg NB/cycle:", n > 0 and (commas(T.nb / n) .. " L") or "--")
  kv(x2, y + 1, "Avg duration:", n > 0 and fmtDurLong(T.dur / n) or "--")
  kv(x1, y + 2, "Longest:", n > 0 and fmtDurLong(T.longest) or "--")
  kv(x2, y + 2, "Shortest:", n > 0 and fmtDurLong(T.shortest) or "--")
  kv(x1, y + 3, "Avg idle gap:", T.gapN > 0 and fmtDurLong(T.gaps / T.gapN) or "--")
  local period
  if cy.all then
    period = n > 0 and (now() - cy.list[1].start) or 0
  else
    local ms = easternMidnight(cy.y, cy.m, 1)
    local from = n > 0 and max(ms, cy.list[1].start) or ms
    period = min(now(), ms + daysIn(cy.y, cy.m) * 86400) - from
  end
  kv(x2, y + 3, "Charging:", period > 0 and (string.format("%.1f", T.dur / period * 100) .. "% of the time") or "--", G.good)
  kv(x1, y + 5, "Total time:", n > 0 and fmtDurLong(T.dur) or "--")
  kv(x2, y + 5, "Busiest:", T.busiest and (T.busiest.label .. "  " .. shortL(T.busiest.v) .. " L") or "--")
  kv(x1, y + 7, "First:", n > 0 and fmtStamp(cy.list[1].start) or "--")
  kv(x2, y + 7, "Latest:", n > 0 and fmtStamp(cy.list[n].start) or "--")
  UI.segs(RXX + 2, y + 9, RXW - 4, { { "Cycles come from lscstats (port " .. CONFIG.STATS_PORT .. ") and are never deleted.", G.dim } })
end

local function drawCycles()
  toolbar({
    { "◄ Back", 10, back },
    "gap",
    { "◄ Month", 11, function() monthStep(-1) end },
    { "Month ►", 11, function() monthStep(1) end },
    { "This Month", 14, function() openCycles(); drawAll() end, not cy.all },
    { "All Time", 12, function() cy.all = true; cy.sel = nil; loadCycles(); drawAll() end, cy.all },
    { "Refresh", 11, function() loadCycles(); drawAll() end },
    "gap",
    { "Time Between Cycles", 23, function() gapsFromCycles() end },
  })
  fill(X0, HY, CW, 1, G.header)
  text(X0 + 1, HY, "≡ LSC CYCLES · " .. periodText(), G.accent, G.header)
  textW(X0 + CW - 40, HY, 39, "charging cycles from lscstats", G.dim, G.header, "right")
  fill(X0, HY + 1, CW, SY - HY - 1, G.bg)
  fill(X0, HY + 1, LXW, SY - HY - 1, G.panel)
  local cx = X0 + 1
  for _, col in ipairs(CCOLS) do
    textW(cx, HY + 1, col[2] + 1, col[1], G.dim, G.panel)
    cx = cx + col[2] + 1
  end
  for r = 1, CROWS do
    region(regions, X0, HY + 1 + r, LXW - 1, 1, function()
      local c = cy.list[#cy.list - cy.scroll - r + 1]
      if c then pickCycle(c) end
    end)
  end
  region(regions, X0 + LXW - 1, HY + 2, 1, 1, function() cy.scroll = cy.scroll - 1; drawCycleRows() end)
  region(regions, X0 + LXW - 1, HY + 1 + CROWS, 1, 1, function() cy.scroll = cy.scroll + 1; drawCycleRows() end)
  drawCycleRows()
  drawCycleChart()
  drawCycleTotals()
  status98({ statusMsg, #cy.list .. " cycles", periodText():lower(),
    "archive: " .. commas(ARC.info().cycles) .. " cycles in total" })
end

------------------------------------------------------------- TEXT VIEW
local tv = { title = "", lines = {}, scroll = 0, size = 0, truncated = false }
local TXY, TXH = HY + 1, SY - HY - 1

local function openText(path, title)
  kind = "text"
  tv.title, tv.lines, tv.scroll = title or path, {}, 0
  tv.size = filesystem.size(path) or 0
  local f = io.open(path, "rb")
  local data = f and f:read(49152) or "(could not open the file)"
  if f then f:close() end
  tv.truncated = tv.size > #data
  data = data:gsub("\r\n?", "\n"):gsub("\t", "  "):gsub("[%z\1-\8\11-\31\127]", ".")
  for line in (data .. "\n"):gmatch("(.-)\n") do
    tv.lines[#tv.lines + 1] = line
    if #tv.lines >= 3000 then tv.truncated = true; break end
  end
end

local function drawTextRows()
  local n = #tv.lines
  local maxScroll = max(0, n - TXH)
  tv.scroll = max(0, min(tv.scroll, maxScroll))
  for r = 1, TXH do
    local i = tv.scroll + r
    local y = TXY + r - 1
    local line = tv.lines[i]
    if line then
      textW(X0, y, 6, tostring(i) .. " ", K.sh, 0xF0F0F0, "right")
      textW(X0 + 6, y, CW - 7, " " .. line, K.black, K.white)
    else
      fill(X0, y, 6, 1, 0xF0F0F0)
      fill(X0 + 6, y, CW - 7, 1, K.white)
    end
  end
  UI.scrollbar(X0 + CW - 1, TXY, TXH, tv.scroll, maxScroll, true)
end

local function drawText()
  toolbar({
    { "◄ Back", 10, back },
    "gap",
    { "Top", 7, function() tv.scroll = 0; drawTextRows() end },
    { "Page ▲", 10, function() tv.scroll = tv.scroll - TXH; drawTextRows() end },
    { "Page ▼", 10, function() tv.scroll = tv.scroll + TXH; drawTextRows() end },
    { "Bottom", 10, function() tv.scroll = #tv.lines; drawTextRows() end },
  })
  fill(X0, HY, CW, 1, K.face)
  textW(X0 + 1, HY, CW - 2, "≡ " .. tv.title .. "   (" .. humanBytes(tv.size) .. ", read-only"
    .. (tv.truncated and ", first 48 KB shown" or "") .. ")", K.navy, K.face)
  region(regions, X0 + CW - 1, TXY, 1, 1, function() tv.scroll = tv.scroll - 1; drawTextRows() end)
  region(regions, X0 + CW - 1, TXY + TXH - 1, 1, 1, function() tv.scroll = tv.scroll + 1; drawTextRows() end)
  drawTextRows()
  status98({ statusMsg, #tv.lines .. " lines", "line " .. (tv.scroll + 1) })
end

-------------------------------------------------- TIME BETWEEN CYCLES
-- gtgraphs' "charge gaps" graph with the whole archive behind it: idle
-- time from the end of one charge to the start of the next (how long a
-- full charge lasts). Bars are colored against the average; a dashed line
-- marks the average, a solid line the trend; the hatched bar is now.
local GAPC = 0xFF8A3D
local gp = { mode = "last", count = 50, y = nil, m = nil, list = {}, sel = nil, scroll = 0, live = nil }
local GGY, GGROWS = HY + 2, 18                -- chart rows (36 pixels)
local GTH = GGY + GGROWS + 3                  -- table header row
local GTR = SY - GTH - 1                      -- table rows

local function gapPeriod()
  if gp.mode == "all" then return "ALL TIME" end
  if gp.mode == "last" then return "LAST " .. gp.count .. " GAPS" end
  return (UI.MONTHS[gp.m] or "?"):upper() .. " " .. gp.y
end

local function loadGaps()
  local cycles
  if gp.mode == "month" then
    local ny, nm = (gp.m == 12) and gp.y + 1 or gp.y, gp.m % 12 + 1
    cycles = ARC.readCycles(easternMidnight(gp.y, gp.m, 1), easternMidnight(ny, nm, 1))
  else
    cycles = ARC.readCycles(nil)
  end
  local all = ARC.gapsOf(cycles)
  if gp.mode == "last" then
    local cut = {}
    for i = max(1, #all - gp.count + 1), #all do cut[#cut + 1] = all[i] end
    all = cut
  end
  gp.list = all
  gp.scroll = 0
  -- idle right now? (only when the period reaches today)
  gp.live = nil
  local inNow = gp.mode ~= "month"
  if gp.mode == "month" then
    local e = toEastern(now())
    inNow = (e.year == gp.y and e.month == gp.m)
  end
  local L, S = ARC.live.lsc, ARC.stats
  local charging
  if L and ARC.fresh(L.at) then charging = (L.flags or 0) > 0
  elseif S.snap and ARC.fresh(S.at) then charging = S.snap.signalOn and true or false end
  local lastStop = (S.snap and S.snap.lastStop) or (cycles[#cycles] and cycles[#cycles].stop)
  if inNow and charging == false and lastStop then gp.live = max(0, now() - lastStop) end
  -- stats + least-squares trend (seconds gained/lost per cycle)
  local n, sum, mn, mx = #all, 0, math.huge, 0
  for _, g in ipairs(all) do sum = sum + g.gap; mn = min(mn, g.gap); mx = max(mx, g.gap) end
  gp.n, gp.avg, gp.mn, gp.mx = n, n > 0 and sum / n or nil, n > 0 and mn or nil, n > 0 and mx or nil
  gp.slope, gp.icept = nil, nil
  if n >= 3 then
    local sx, sy, sxx, sxy = 0, 0, 0, 0
    for i, g in ipairs(all) do sx, sy, sxx, sxy = sx + i, sy + g.gap, sxx + i * i, sxy + i * g.gap end
    local d = n * sxx - sx * sx
    if d ~= 0 then
      gp.slope = (n * sxy - sx * sy) / d
      gp.icept = (sy - gp.slope * sx) / n
    end
  end
  if gp.sel then
    local ok = false
    for _, g in ipairs(all) do if g.start == gp.sel then ok = true end end
    if not ok then gp.sel = nil end
  end
end

local function openGaps(mode, y, m)
  kind = "gaps"
  if mode then gp.mode = mode end
  if y then gp.y, gp.m = y, m end
  if gp.mode == "month" and not gp.y then
    local e = toEastern(now())
    gp.y, gp.m = e.year, e.month
  end
  gp.sel = nil
  loadGaps()
end

local function gapStep(d)
  if gp.mode ~= "month" then
    local e = toEastern(now())
    gp.y, gp.m = e.year, e.month
    gp.mode = "month"
    if d < 0 then d = 0 end
  end
  local k = gp.y * 12 + (gp.m - 1) + d
  gp.y, gp.m = floor(k / 12), k % 12 + 1
  loadGaps(); drawAll()
end

local function axisDur(s)
  s = max(0, floor(s + 0.5))
  if s < 60 then return s .. "s" end
  if s < 3600 then return string.format("%dm %02ds", floor(s / 60), s % 60) end
  if s < 86400 then return string.format("%dh %02dm", floor(s / 3600), floor(s % 3600 / 60)) end
  return string.format("%dd %02dh", floor(s / 86400), floor(s % 86400 / 3600))
end

local function ratioColor(r)
  if r >= 0.9 then return G.good elseif r >= 0.7 then return G.warn end
  return G.bad
end

local function trendInfo()
  if not (gp.slope and gp.avg and gp.avg > 0) then return "needs 3+ gaps", G.dim end
  local pct = gp.slope / gp.avg
  if pct < -0.03 then return "-" .. axisDur(math.abs(gp.slope)) .. "/cycle ▼ SHRINKING", G.bad end
  if pct > 0.03 then return "+" .. axisDur(gp.slope) .. "/cycle ▲ GROWING", G.good end
  return "STABLE", G.text
end

local function selectedGap()
  if not gp.sel then return nil end
  for i, g in ipairs(gp.list) do if g.start == gp.sel then return g, i end end
end

local function drawGapStats()
  local tt, tc = trendInfo()
  local g = selectedGap()
  if g then
    UI.segs(X0, HY + 1, CW, {
      { " SELECTED ", G.accent }, { "before cycle #" .. tostring(g.id or "?") .. "   ", G.text },
      { "IDLE ", G.dim }, { fmtDurLong(g.gap) .. "   ", GAPC },
      { "VS AVG ", G.dim }, { gp.avg and (floor(g.gap / gp.avg * 100 + 0.5) .. "%   ") or "--   ", ratioColor(gp.avg and g.gap / gp.avg or 1) },
      { "ENDED ", G.dim }, { UI.stamp(g.prevStop) .. "  ", G.text },
      { "NEXT ", G.dim }, { UI.stamp(g.start), G.text } }, gp.n .. " gaps ", G.panel)
  else
    UI.segs(X0, HY + 1, CW, {
      { " LATEST ", G.dim }, { gp.n > 0 and fmtDurLong(gp.list[gp.n].gap) or "--", GAPC },
      { "   AVG ", G.dim }, { gp.avg and fmtDurLong(gp.avg) or "--", G.text },
      { "   MIN ", G.dim }, { gp.mn and fmtDurLong(gp.mn) or "--", G.text },
      { "   MAX ", G.dim }, { gp.mx and fmtDurLong(gp.mx) or "--", G.text },
      { "   TREND ", G.dim }, { tt, tc },
      { gp.live and ("   IDLE NOW " .. fmtDurLong(gp.live)) or "", G.accent } },
      gp.n .. " gaps ", G.panel)
  end
end

local function drawGapChart()
  local list, n = gp.list, #gp.list
  local cw, ph = NCOL, GGROWS * 2
  fill(X0, GGY, CW, GGROWS + 3, G.panel)
  local ymax = UI.niceMax(max(gp.mx or 0, gp.live or 0, 60) * 1.1)
  local function py(v) return ph - 1 - floor(v / ymax * (ph - 3) + 0.5) end
  local cv = newCanvas(cw, ph, G.panel)
  for k = 1, 4 do
    local yy = py(ymax * k / 4)
    for xx = 3, cw, 3 do cset(cv, xx, yy, G.grid) end
  end
  -- bars: one per gap while they fit, else groups of gaps (bar = group average)
  local nb = n + (gp.live and 1 or 0)
  local slotW, per = 1, 1
  if nb > 0 then
    slotW = min(10, floor((cw - 2) / max(nb, 6)))
    if slotW < 1 then slotW, per = 1, ceil(nb / (cw - 2)) end
  end
  local barW = slotW >= 4 and slotW - 2 or (slotW >= 2 and slotW - 1 or 1)
  local function barX(i) return 3 + (i - 1) * slotW end
  gp.slotW, gp.per, gp.barX0 = slotW, per, 3
  local groups = ceil(n / per)
  local selG = nil
  local sg, si = selectedGap()
  if si then selG = ceil(si / per) end
  for gi = 1, groups do
    local a, b = (gi - 1) * per + 1, min(n, gi * per)
    local s, hi = 0, 0
    for i = a, b do s = s + list[i].gap; hi = max(hi, list[i].gap) end
    local v = s / (b - a + 1)
    local col = (gi == selG) and 0xFFFFFF or ratioColor(gp.avg and v / gp.avg or 1)
    local yt, yh = py(v), py(hi)
    local top = lerp(col, 0xFFFFFF, 0.4)
    for xx = barX(gi), barX(gi) + barW - 1 do
      if per > 1 then for yy = yh, yt - 1 do cset(cv, xx, yy, lerp(col, G.panel, 0.7)) end end
      cset(cv, xx, yt, top)
      for yy = yt + 1, ph - 1 do cset(cv, xx, yy, lerp(col, G.panel, 0.05 + 0.6 * (yy - yt) / max(1, ph - 1 - yt))) end
    end
  end
  if gp.live then
    local i = groups + 1
    local yt = py(gp.live)
    local hatch = lerp(G.accent, G.panel, 0.45)
    for xx = barX(i), barX(i) + barW - 1 do
      cset(cv, xx, yt, G.accent)
      for yy = yt + 1, ph - 1 do if (yy - yt) % 2 == 0 then cset(cv, xx, yy, hatch) end end
    end
  end
  if gp.avg then
    local yy = py(gp.avg)
    for xx = 2, cw do if xx % 4 < 2 then cset(cv, xx, yy, G.dim) end end
  end
  local tt, tc = trendInfo()
  if gp.slope and n >= 3 then
    local function cx(i) return barX(ceil(i / per)) + floor(barW / 2) end
    cline(cv, cx(1), py(max(0, gp.icept + gp.slope)), cx(n), py(max(0, gp.icept + gp.slope * n)), tc)
  end
  for yy = 1, ph do cset(cv, 1, yy, G.axis) end
  for xx = 1, cw do cset(cv, xx, ph, G.axis) end
  crender(cv, GX, GGY)
  for k = 0, 4 do
    local lv = ymax * k / 4
    textW(X0, GGY + floor((py(lv) - 1) / 2), LABW, axisDur(lv), G.dim, G.panel, "right")
  end
  if nb == 0 then
    textW(GX, GGY + 7, cw, "No gaps yet - it takes two back-to-back charging cycles.", G.dim, G.panel, "center")
  end
  -- labels under the bars: cycle numbers + idle times when there is room, else dates
  local ly = GGY + GGROWS
  local ids, durs = {}, {}
  if slotW >= 5 then
    local maxLab = slotW - 1
    for i, g in ipairs(list) do
      ids[#ids + 1] = { barX(i) + floor(barW / 2), ("#" .. tostring(g.id or "?")):sub(1, maxLab) }
      durs[#durs + 1] = { barX(i) + floor(barW / 2), UI.fmtShort(g.gap):sub(1, maxLab) }
    end
    if gp.live then
      ids[#ids + 1] = { barX(groups + 1) + floor(barW / 2), ("now"):sub(1, maxLab) }
      durs[#durs + 1] = { barX(groups + 1) + floor(barW / 2), UI.fmtShort(gp.live):sub(1, maxLab) }
    end
    textW(X0, ly, LABW, "cycle", G.dim, G.panel, "right")
    text(GX, ly, UI.labelRow(cw, ids), G.text, G.panel)
    textW(X0, ly + 1, LABW, "idle", G.dim, G.panel, "right")
    text(GX, ly + 1, UI.labelRow(cw, durs), GAPC, G.panel)
  elseif groups > 0 then
    for k = 0, 4 do
      local gi = max(1, min(groups, 1 + floor((groups - 1) * k / 4)))
      ids[#ids + 1] = { barX(gi), UI.dateOnly(list[(gi - 1) * per + 1].start, true) }
    end
    textW(X0, ly, LABW, "date", G.dim, G.panel, "right")
    text(GX, ly, UI.labelRow(cw, ids), G.dim, G.panel)
    textW(GX, ly + 1, cw, per > 1 and ("each bar = " .. per .. " gaps (average, lighter top = longest)") or
      (n .. " gaps, oldest on the left"), G.dim, G.panel)
  end
  UI.segs(X0 + 2, ly + 2, CW - 4, {
    { "■", G.good }, { " >=90% of avg  ", G.dim }, { "■", G.warn }, { " 70-90%  ", G.dim },
    { "■", G.bad }, { " <70%  ", G.dim }, { "▒", G.accent }, { " idle now  ", G.dim },
    { "/", tc }, { " trend  ", G.dim }, { "--", G.dim }, { " avg      click a bar or a row to select it", G.dim } })
end

local GCOLS = { { "BEFORE CYCLE", 13 }, { "CHARGE ENDED", 18 }, { "NEXT CHARGE STARTED", 20 },
                { "IDLE TIME", 15 }, { "VS AVG", 8 }, { "THAT CYCLE", 14 }, { "NB USED", 14 } }

local function drawGapTable()
  fill(X0, GTH, CW, 1, G.header)
  local cx = X0 + 1
  for i, col in ipairs(GCOLS) do
    textW(cx, GTH, col[2], col[1], G.dim, G.header, i >= 4 and "right" or nil)
    cx = cx + col[2] + 2
  end
  local list, n = gp.list, #gp.list
  local maxS = max(0, n - GTR)
  gp.scroll = max(0, min(gp.scroll, maxS))
  for r = 1, GTR do
    local g = list[n - gp.scroll - r + 1]
    local y = GTH + r
    if g then
      local sel = g.start == gp.sel
      local b = sel and G.button or ((r % 2 == 0) and 0x1B1B1B or G.panel)
      local ratio = gp.avg and g.gap / gp.avg or 1
      local c = g.cycle or {}
      local cells = { "#" .. tostring(g.id or "?"), UI.stampSec(g.prevStop), UI.stampSec(g.start),
                      fmtDurLong(g.gap), floor(ratio * 100 + 0.5) .. "%", c.dur and fmtDurLong(c.dur) or "--",
                      c.used and shortL(c.used) .. " L" or "--" }
      local colors = { G.accent, G.text, G.text, GAPC, ratioColor(ratio), G.dim, G.nb }
      cx = X0 + 1
      fill(X0, y, 1, 1, b)
      for i, col in ipairs(GCOLS) do
        textW(cx, y, col[2] + 2, cells[i] .. "  ", colors[i], b, i >= 4 and "right" or nil)
        cx = cx + col[2] + 2
      end
      fill(cx, y, X0 + CW - 1 - cx, 1, b)
    else
      fill(X0, y, CW - 1, 1, G.panel)
    end
  end
  UI.scrollbar(X0 + CW - 1, GTH + 1, GTR, gp.scroll, maxS)
end

local function pickGap(g)
  gp.sel = (g and gp.sel ~= g.start) and g.start or nil
  local _, i = selectedGap()
  if i then
    local row = #gp.list - i + 1
    if row <= gp.scroll or row > gp.scroll + GTR then gp.scroll = max(0, row - floor(GTR / 2)) end
  end
  drawGapStats(); drawGapChart(); drawGapTable()
end

local function drawGaps()
  toolbar({
    { "◄ Back", 10, back },
    "gap",
    { "Last 12", 11, function() gp.mode, gp.count = "last", 12; gp.sel = nil; loadGaps(); drawAll() end, gp.mode == "last" and gp.count == 12 },
    { "Last 50", 11, function() gp.mode, gp.count = "last", 50; gp.sel = nil; loadGaps(); drawAll() end, gp.mode == "last" and gp.count == 50 },
    { "◄ Month", 11, function() gapStep(-1) end },
    { "Month ►", 11, function() gapStep(1) end },
    { "All Time", 12, function() gp.mode = "all"; gp.sel = nil; loadGaps(); drawAll() end, gp.mode == "all" },
    { "Refresh", 11, function() loadGaps(); drawAll() end },
    "gap",
    { "Cycle Log", 13, function() openCycles(); drawAll() end },
  })
  fill(X0, HY, CW, 1, G.header)
  text(X0 + 1, HY, "≡ TIME BETWEEN CHARGING CYCLES · " .. gapPeriod(), GAPC, G.header)
  textW(X0 + CW - 46, HY, 45, "idle time a full charge lasts", G.dim, G.header, "right")
  drawGapStats()
  drawGapChart()
  region(regions, GX, GGY, NCOL, GGROWS, function(px)
    local gi = floor((px - GX + 1 - (gp.barX0 or 3)) / (gp.slotW or 1)) + 1
    local i = (gi - 1) * (gp.per or 1) + 1
    local g = gp.list[max(1, min(#gp.list, i))]
    if g and gi >= 1 and gi <= ceil(#gp.list / (gp.per or 1)) then pickGap(g) end
  end)
  drawGapTable()
  for r = 1, GTR do
    region(regions, X0, GTH + r, CW - 1, 1, function()
      local g = gp.list[#gp.list - gp.scroll - r + 1]
      if g then pickGap(g) end
    end)
  end
  region(regions, X0 + CW - 1, GTH + 1, 1, 1, function() gp.scroll = gp.scroll - 1; drawGapTable() end)
  region(regions, X0 + CW - 1, GTH + GTR, 1, 1, function() gp.scroll = gp.scroll + 1; drawGapTable() end)
  status98({ statusMsg, gp.n .. " gaps shown", gapPeriod():lower(),
    "logged in the cycle log (" .. ARC.CYCLE_FOLDER .. "), never deleted" })
end

gapsFromCycles = function()
  if cy.all then openGaps("all") else openGaps("month", cy.y, cy.m) end
  drawAll()
end

------------------------------------------------------- STORAGE REPORT
local rp = nil          -- last computed report

local function openReport()
  kind = "report"
  statusMsg = "Reading the archive..."
  rp = ARC.report()
  statusMsg = "Ready"
end

local function bar(x, y, w, frac, col)
  local n = max(0, min(w, floor(w * frac + 0.5)))
  text(x, y, string.rep("█", n), col, G.track)
  if w - n > 0 then text(x + n, y, string.rep("░", w - n), G.grid, G.track) end
end

local KEPT = { raw = nil, min = "until space is needed", q15 = "years (deleted last)", cyc = "forever" }

local function drawReport()
  toolbar({ { "◄ Back", 10, back }, "gap", { "Refresh", 11, function() openReport(); drawAll() end } })
  fill(X0, HY, CW, 1, G.header)
  text(X0 + 1, HY, "≡ STORAGE REPORT", G.accent, G.header)
  textW(X0 + CW - 40, HY, 39, "computed " .. UI.stampSec(rp.at), G.dim, G.header, "right")
  fill(X0, HY + 1, CW, SY - HY - 1, G.bg)
  -- drives
  local drives = ARC.drives()
  local dh = min(#drives, 6) + 3
  UI.panel(X0, HY + 1, CW, dh, "ARCHIVE DRIVES", G.accent, #drives .. " drive(s) ")
  for i, d in ipairs(drives) do
    if i > 6 then break end
    local y = HY + 2 + i
    local used = d.total - max(0, d.free)
    local frac = d.total > 0 and used / d.total or 0
    textW(X0 + 2, y, 6, d.letter .. ":", G.text, G.panel)
    bar(X0 + 8, y, 60, frac, frac > 0.9 and G.bad or (frac > 0.75 and G.warn or G.good))
    textW(X0 + 70, y, CW - 72, string.format("%s used of %s   (%s free, %d%% full)", humanBytes(used),
      humanBytes(d.total), humanBytes(max(0, d.free)), floor(frac * 100 + 0.5)), G.text, G.panel)
  end
  if #drives == 0 then textW(X0 + 2, HY + 3, CW - 4, "No archive drives found - add a hard drive to the server.", G.bad, G.panel) end
  -- what is stored
  local ty = HY + 1 + dh + 1
  local rows = rp.rows
  local th = #rows + 5
  UI.panel(X0, ty, CW, th, "WHAT IS STORED", G.nb, "one row per log; every graph of a source reads the same entries ")
  local cols = { { "LOG", 12 }, { "DETAIL", 20 }, { "GRAPHS", 7 }, { "FILES", 6 }, { "ENTRIES", 13 },
                 { "OLDEST", 11 }, { "NEWEST", 11 }, { "SIZE", 10 }, { "KEPT", 24 } }
  local cx = X0 + 2
  for i, c in ipairs(cols) do
    textW(cx, ty + 1, c[2], c[1], G.dim, G.panel, (i >= 3 and i <= 5 or i == 8) and "right" or nil)
    cx = cx + c[2] + 2
  end
  local last
  for r, row in ipairs(rows) do
    local y = ty + 1 + r
    local entries = (row.exact and "" or "~") .. commas(row.records) .. (row.ext == "cyc" and " cyc" or "")
    local kept = KEPT[row.ext] or (ARC.rawDays() .. " days (Settings)")
    local cells = { row.folder ~= last and row.folder or "", row.label, tostring(row.graphs), tostring(row.files),
                    entries, row.from or "--", row.to or "--", humanBytes(row.bytes), kept }
    last = row.folder
    cx = X0 + 2
    for i, c in ipairs(cols) do
      textW(cx, y, c[2], cells[i], i == 1 and G.accent or (i == 5 and G.nb or G.text), G.panel,
        (i >= 3 and i <= 5 or i == 8) and "right" or nil)
      cx = cx + c[2] + 2
    end
  end
  local gy = ty + 2 + #rows
  UI.segs(X0 + 2, gy, CW - 4, { { "Time between cycles", G.accent },
    { "   " .. commas(rp.gaps) .. " gaps, worked out from the " .. commas(rp.cycles) .. " archived cycles", G.text },
    { "   (each new cycle line also stores its gap)", G.dim } })
  UI.segs(X0 + 2, gy + 1, CW - 4, { { "~ = estimated from the file size (text files)", G.dim } })
  -- will it fill up?
  local fy = ty + th + 1
  local fh = SY - fy
  UI.panel(X0, fy, CW, fh, "WILL IT FILL UP?", G.good)
  local pd = rp.perDay
  local longTerm = pd.min + pd.q15
  local lines = {}
  local function L(segs) lines[#lines + 1] = segs end
  L({ { "New data per day:  ", G.dim }, { humanBytes(pd.raw + pd.min + pd.q15), G.text },
      { string.format("   (5-second %s, 1-minute %s, 15-minute %s)", humanBytes(pd.raw), humanBytes(pd.min), humanBytes(pd.q15)), G.dim } })
  L({ { "5-second files are kept " .. ARC.rawDays() .. " days, so they level off at about ", G.dim },
      { humanBytes(pd.raw * ARC.rawDays()), G.text }, { " and stop growing.", G.dim } })
  if longTerm > 0 then
    local days = rp.usable / longTerm
    local full = now() + days * 86400
    L({ { "Long-term growth (1-min + 15-min): ", G.dim }, { humanBytes(longTerm) .. "/day", G.text },
        { "   free for it: ", G.dim }, { humanBytes(rp.usable), G.text },
        { "   → full in about ", G.dim }, { floor(days + 0.5) .. " days", days < 14 and G.warn or G.good },
        { " (" .. UI.dateOnly(full, true) .. ")", G.dim } })
    if pd.q15 > 0 then
      L({ { "15-minute history alone would fit about ", G.dim },
          { string.format("%.1f years", rp.total / pd.q15 / 365), G.text }, { " on these drives.", G.dim } })
    end
  else
    L({ { "Not enough data yet to measure the daily growth - check back after a day of recording.", G.dim } })
  end
  L({ { "It can't overflow: ", G.good }, { "every drive always keeps " .. humanBytes(ARC.reserve()) .. " free, checked before every write.", G.text } })
  L({ { "When space runs short, the oldest 5-second files are deleted first, then 1-minute, then 15-minute files.", G.text } })
  L({ { "More room: add a hard drive or a RAID block - it is picked up automatically within 30 seconds.", G.dim } })
  for i, segs in ipairs(lines) do
    if i > fh - 2 then break end
    UI.segs(X0 + 2, fy + 1 + i, CW - 4, segs)
  end
  status98({ statusMsg, commas(rp.cycles) .. " cycles", humanBytes(rp.free) .. " free on archive drives" })
end

------------------------------------------------------------- COMMON
local function draw()
  if kind == "graph" then drawGraph()
  elseif kind == "cycles" then drawCycles()
  elseif kind == "gaps" then drawGaps()
  elseif kind == "report" then drawReport()
  elseif kind == "text" then drawText() end
end

local function title()
  if kind == "graph" then return gv.src.folder .. " - " .. gv.src.fields[gv.fi].long end
  if kind == "cycles" then return "LSC Cycles - " .. periodText():lower() end
  if kind == "text" then return tv.title end
  if kind == "gaps" then return "Time between cycles - " .. gapPeriod():lower() end
  if kind == "report" then return "Storage Report" end
  return ""
end

-- once per second while visible
local function tick()
  if kind == "graph" and gv.live then
    local s = span()
    local every = s <= 90000 and 30 or (s <= 8 * 86400 and 120 or 600)
    if computer.uptime() - gv.at >= every then
      recompute(); drawStats(); drawGraphArea(); drawTable()
    end
    graphStatus()
  end
end

local function scroll(x, y, dir)
  if kind == "graph" and y >= TR0 then gv.scroll = gv.scroll - dir; drawTable(); return true end
  if kind == "cycles" and x < X0 + LXW and y > HY + 1 then cy.scroll = cy.scroll - dir; drawCycleRows(); return true end
  if kind == "text" then tv.scroll = tv.scroll - dir * 3; drawTextRows(); return true end
  if kind == "gaps" and y > GTH then gp.scroll = gp.scroll - dir; drawGapTable(); return true end
end

local function key(code)
  if code == 14 then back(); return end                          -- backspace
  if kind == "graph" then
    if code == 203 then shift(-1) elseif code == 205 then shift(1)
    elseif code == 201 then gv.scroll = gv.scroll - TROWS; drawTable()
    elseif code == 209 then gv.scroll = gv.scroll + TROWS; drawTable() end
  elseif kind == "cycles" then
    if code == 203 then monthStep(-1) elseif code == 205 then monthStep(1)
    elseif code == 200 then cy.scroll = cy.scroll - 1; drawCycleRows()
    elseif code == 208 then cy.scroll = cy.scroll + 1; drawCycleRows() end
  elseif kind == "gaps" then
    if code == 203 then gapStep(-1) elseif code == 205 then gapStep(1)
    elseif code == 200 then gp.scroll = gp.scroll - 1; drawGapTable()
    elseif code == 208 then gp.scroll = gp.scroll + 1; drawGapTable() end
  elseif kind == "text" then
    local d = ({ [200] = -1, [208] = 1, [201] = -TXH, [209] = TXH, [199] = -1e9, [207] = 1e9 })[code]
    if d then tv.scroll = tv.scroll + d; drawTextRows() end
  end
end

return {
  openGraph = openGraph, openCycles = openCycles, openText = openText,
  openGaps = openGaps, openReport = openReport,
  draw = draw, title = title, tick = tick, scroll = scroll, key = key,
  isOpen = function() return kind ~= nil end,
  close = function() kind = nil end,
  onBack = function(fn) backFn = fn end,
}
end)()


---------------------------------------------------------- FILE EXPLORER
-- Windows-style browser for the archive.
--   This PC                  Archive (all drives merged) + every drive
--   This PC\Archive\...      the archive as one tree, whatever drive a file is on
--   This PC\D:\...           one drive exactly as it is on disk
-- Click a row to select it, click it again (or Enter / Open) to open it.
FX = (function()
local X0, CW = WX + 1, WW - 2
local TB, AY = WY + 3, WY + 6
local BY = WY + 7                       -- body top
local SY = WY + WH - 2                  -- status bar
local TRX, TRW, TRH = X0, 36, 22        -- folder tree
local RBY = BY + TRH                    -- recorder box
local LX, LW = X0 + TRW + 1, CW - TRW - 1
local LH = SY - BY
local LROWS = LH - 3
local COLS = { { "Name", 36, "name" }, { "Size", 11, "size" }, { "Type", 22, "type" },
               { "Modified", 18, "mtime" }, { "On", 9, "where" } }
local TYPE = { raw = "5-second samples", min = "1-minute averages", q15 = "15-minute averages",
               cyc = "Cycle log", lua = "Lua program", dat = "Data file", cfg = "Settings file",
               txt = "Text file", log = "Log file", md = "Text file" }
local TYPE_COLOR = { raw = 0x007A7A, min = 0x0050A0, q15 = 0x6A2D9A, cyc = 0xA06000, lua = K.green }

local path = {}                         -- {} = This PC
local hist = {}
local entries = {}
local sel, scroll = nil, 0
local sortKey, sortDesc = "name", false
local tree, treeScroll = {}, 0
local lastList = 0

local function copy(p) local o = {} for i, v in ipairs(p) do o[i] = v end return o end
local function child(name) local p = copy(path); p[#p + 1] = name; return p end
local function samePath(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function typeOf(name, isDir)
  if isDir then return ARC.SRC[name] and "Archive source" or (name == ARC.CYCLE_FOLDER and "Cycle logs" or "File Folder") end
  local e = name:match("%.(%w+)$")
  return e and (TYPE[e:lower()] or (e:upper() .. " File")) or "File"
end

local function driveByLetter(L)
  for _, d in ipairs(ARC.allDrives()) do if d.letter == L then return d end end
end

local function addressText(p)
  p = p or path
  local s = "This PC"
  for i, seg in ipairs(p) do s = s .. "\\" .. ((i == 1 and seg == "Archive") and "Archive (all drives)" or seg) end
  return s
end

-- source folder name of a path, or nil  (Archive\LSC Power\.. or D:\archive\LSC Power\..)
local function folderOf(p)
  p = p or path
  if p[1] == "Archive" then return p[2] end
  if p[2] == CONFIG.ARCHIVE_DIR then return p[3] end
end

-- the real folders behind a path: { { drive, dir } }
local function dirsOf(p)
  if p[1] == "Archive" then
    local rel = table.concat(p, "/", 2)
    local out = {}
    for _, d in ipairs(ARC.drives()) do
      local dir = d.base .. (rel ~= "" and ("/" .. rel) or "")
      if filesystem.isDirectory(dir) then out[#out + 1] = { d, dir } end
    end
    return out
  end
  local L = p[1] and p[1]:match("^(%a):$")
  local d = L and driveByLetter(L)
  if d then
    local dir = filesystem.concat(d.path, table.concat(p, "/", 2))
    if filesystem.isDirectory(dir) then return { { d, dir } } end
  end
  return {}
end

local function listing(p, dirsOnly)
  local out = {}
  if #p == 0 then
    local tot, used = 0, 0
    for _, d in ipairs(ARC.drives()) do ARC.freeOf(d); tot, used = tot + d.total, used + (d.used or 0) end
    out[1] = { name = "Archive", label = "Archive (all drives)", isDir = true, kind = "archive",
               size = tot, free = tot - used, ty = #ARC.drives() .. " archive drive(s)", where = "", mtime = 0, fulls = {} }
    for _, d in ipairs(ARC.allDrives()) do
      ARC.freeOf(d)
      local kindName = (d.label and d.label ~= "") and d.label
        or (d.boot and "Boot Disk") or (d.total < CONFIG.MIN_DRIVE_BYTES and "Floppy") or "Local Disk"
      out[#out + 1] = { name = d.letter .. ":", label = kindName .. " (" .. d.letter .. ":)", isDir = true,
        kind = "drive", drive = d, size = d.total, free = d.free, mtime = 0, fulls = {},
        ty = d.archive and "Archive drive" or ("Not used - " .. (d.why or "?")), where = d.address:sub(1, 5) }
    end
    return out
  end
  local byName = {}
  for _, pd in ipairs(dirsOf(p)) do
    local d, dir = pd[1], pd[2]
    for _, name in ipairs(ARC.listDir(dir)) do
      local full = dir .. "/" .. name
      local isDir = filesystem.isDirectory(full)
      if isDir or not dirsOnly then
        local e = byName[name]
        if not e then
          e = { name = name, isDir = isDir, size = 0, mtime = 0, where = "", fulls = {},
                kind = isDir and "dir" or "file", ty = typeOf(name, isDir) }
          byName[name] = e
          out[#out + 1] = e
        end
        if not isDir then e.size = e.size + (filesystem.size(full) or 0) end
        local lm = (filesystem.lastModified(full) or 0) / 1000
        if lm > e.mtime then e.mtime = lm end
        if not e.where:find(d.letter, 1, true) then e.where = e.where .. d.letter end
        e.fulls[#e.fulls + 1] = full
      end
    end
    breathe()
  end
  return out
end

local function sortEntries()
  if #path == 0 then return end
  table.sort(entries, function(a, b)
    if a.isDir ~= b.isDir then return a.isDir end
    local ka, kb
    if sortKey == "size" then ka, kb = a.size, b.size
    elseif sortKey == "mtime" then ka, kb = a.mtime, b.mtime
    elseif sortKey == "type" then ka, kb = a.ty, b.ty
    elseif sortKey == "where" then ka, kb = a.where, b.where
    else ka, kb = a.name:lower(), b.name:lower() end
    if ka == kb then return a.name < b.name end
    if sortDesc then return ka > kb end
    return ka < kb
  end)
end

local function buildTree()
  tree = { { label = "This PC", p = {}, depth = 0, kind = "pc" } }
  local function expand(p, depth)
    local kids = listing(p, true)
    if #p > 0 then table.sort(kids, function(a, b) return a.name < b.name end) end
    for _, e in ipairs(kids) do
      local cp = copy(p)
      cp[#cp + 1] = e.name
      tree[#tree + 1] = { label = e.label or e.name, p = cp, depth = depth, kind = e.kind }
      local onPath = #path >= #cp
      for i = 1, #cp do if cp[i] ~= path[i] then onPath = false; break end end
      if onPath and depth < 6 then expand(cp, depth + 1) end
    end
  end
  expand({}, 1)
  for i, n in ipairs(tree) do
    if samePath(n.p, path) then
      if i <= treeScroll or i > treeScroll + TRH - 2 then treeScroll = max(0, i - floor((TRH - 2) / 2)) end
    end
  end
end

local function load(keepName)
  entries = listing(path)
  sortEntries()
  sel, scroll = nil, 0
  if keepName then
    for i, e in ipairs(entries) do if e.name == keepName then sel = i end end
    if sel and sel > LROWS then scroll = sel - floor(LROWS / 2) end
  end
  buildTree()
  lastList = computer.uptime()
end

local function refresh()
  load(sel and entries[sel] and entries[sel].name)
end

local function go(p, noHist)
  if not noHist then
    hist[#hist + 1] = path
    if #hist > 50 then table.remove(hist, 1) end
  end
  local from = path
  path = p
  -- going up to a parent: keep the folder we came from selected
  local keep = nil
  if #p < #from then
    keep = from[#p + 1]
    for i = 1, #p do if p[i] ~= from[i] then keep = nil; break end end
  end
  load(keep)
  drawAll()
end

local function goUp() if #path > 0 then local p = copy(path); p[#p] = nil; go(p) end end
local function goBack() if #hist > 0 then go(table.remove(hist), true) end end

------------------------------------------------------------ ACTIONS
local function dayRange(base)
  local y, m, d = base:match("^(%d+)%-(%d+)%-?(%d*)$")
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if not y or not m then return nil end
  if d then
    local ny, nm, nd = nextDay(y, m, d)
    return easternMidnight(y, m, d), easternMidnight(ny, nm, nd)
  end
  local ny, nm = (m == 12) and y + 1 or y, m % 12 + 1
  return easternMidnight(y, m, 1), easternMidnight(ny, nm, 1)
end

local function openEntry(e)
  if not e then return end
  if e.isDir then go(child(e.name)); return end
  local base, ext = ARC.splitName(e.name)
  local folder = folderOf()
  local src = folder and ARC.SRC[folder]
  if src and base and (ext == "raw" or ext == "min" or ext == "q15") then
    local t0, t1 = dayRange(base)
    if t0 then VIEW.openGraph(src.key, t0, t1, ext == "raw" and "raw" or "auto") end
  elseif folder == ARC.CYCLE_FOLDER and ext == "cyc" and base then
    local y, m = base:match("^(%d+)%-(%d+)$")
    VIEW.openCycles(tonumber(y), tonumber(m))
  elseif e.fulls[1] then
    VIEW.openText(e.fulls[1], e.name)
  end
  drawAll()
end

local function graphHere()
  local e = sel and entries[sel]
  local folder = folderOf()
  if not folder and e and e.isDir and path[1] == "Archive" then folder = e.name end
  if folder == ARC.CYCLE_FOLDER then VIEW.openCycles()
  else VIEW.openGraph((ARC.SRC[folder or ""] or ARC.SOURCES[1]).key) end
  drawAll()
end

local function deletable(e)
  if not e or e.kind == "drive" or e.kind == "archive" then return false end
  if path[1] == "Archive" then return true end
  return path[2] == CONFIG.ARCHIVE_DIR
end

local drawStatus   -- forward

local function confirmDelete()
  local e = sel and entries[sel]
  if not e then statusMsg = "Select a file or folder first"; drawStatus(); return end
  if not deletable(e) then
    dialog("Delete", { "Only archive files and folders can be deleted from here.",
      "\"" .. e.name .. "\" is outside the archive." }, { { "OK" } })
    return
  end
  local what = e.isDir and ("the folder \"" .. e.name .. "\" and everything in it")
    or ("\"" .. e.name .. "\" (" .. humanBytes(e.size) .. ")")
  dialog("Confirm Delete", {
    "Permanently delete " .. what .. "?",
    #e.fulls > 1 and ("It is on drives " .. e.where .. " - every copy is deleted.") or "This can't be undone.",
  }, {
    { "Yes", function()
        ARC.flush()
        local n = 0
        for _, full in ipairs(e.fulls) do if filesystem.remove(full) then n = n + 1 end end
        ARC.forget()
        statusMsg = (n > 0) and ("Deleted " .. e.name) or ("Could not delete " .. e.name)
        load()
      end },
    { "No" },
  })
end

local function properties()
  local e = sel and entries[sel]
  if not e then
    dialog("Properties", { "Folder: " .. addressText(), #entries .. " item(s)" }, { { "OK" } })
    return
  end
  local L = {}
  if e.kind == "drive" then
    local d = e.drive
    ARC.freeOf(d)
    L = { "Name:        " .. e.label, "Address:     " .. d.address, "Mounted at:  " .. d.path,
      "Capacity:    " .. humanBytes(d.total) .. "  (" .. commas(d.total) .. " bytes)",
      "Used:        " .. humanBytes(d.used) .. "     Free: " .. humanBytes(d.free),
      "Archive:     " .. (d.archive and ("yes - " .. d.base) or ("not used (" .. (d.why or "?") .. ")")) }
  elseif e.kind == "archive" then
    L = { "The archive merged from every archive drive:" }
    for _, d in ipairs(ARC.drives()) do
      ARC.freeOf(d)
      L[#L + 1] = "  " .. d.letter .. ":  " .. humanBytes(d.used) .. " used of " .. humanBytes(d.total)
        .. "   (" .. humanBytes(d.free) .. " free)"
    end
    if #ARC.drives() == 0 then L[#L + 1] = "  (no archive drives found - add a hard drive)" end
    L[#L + 1] = ""
    L[#L + 1] = "New data goes to the first drive with room (C:, D:, E: ...)."
  elseif e.isDir then
    local kids = listing(child(e.name))
    local nd, nf, sz = 0, 0, 0
    for _, k in ipairs(kids) do if k.isDir then nd = nd + 1 else nf, sz = nf + 1, sz + k.size end end
    L = { "Name:        " .. e.name, "Type:        " .. e.ty, "Location:    " .. addressText(),
      "On drive(s): " .. e.where,
      "Contains:    " .. nd .. " folder(s), " .. nf .. " file(s)" .. (nf > 0 and (" (" .. humanBytes(sz) .. ")") or ""),
      "Modified:    " .. (e.mtime > 1e9 and fmtStamp(e.mtime) or "--") }
  else
    local info = ARC.fileInfo(e.fulls[1]) or {}
    L = { "Name:        " .. e.name, "Type:        " .. e.ty, "Location:    " .. addressText(),
      "Stored on:   drive " .. e.where .. (#e.fulls > 1 and "  (the parts are read as one file)" or ""),
      "Size:        " .. humanBytes(e.size) .. "  (" .. commas(e.size) .. " bytes)",
      "Modified:    " .. (e.mtime > 1e9 and fmtStamp(e.mtime) or "--") }
    if info.format then L[#L + 1] = "Format:      " .. info.format end
    if info.records then L[#L + 1] = "Records:     " .. commas(info.records) .. (#e.fulls > 1 and " (first part)" or "") end
    local base = ARC.splitName(e.name)
    local t0 = base and dayRange(base)
    if t0 and folderOf() then
      local ev = toEastern(t0 + 3600)
      L[#L + 1] = "Covers:      " .. (base:match("%-%d+%-%d+$") and (ev.wday .. " " .. string.format("%02d/%02d/%04d", ev.month, ev.day, ev.year))
        or ((UI.MONTHS[ev.month] or "?") .. " " .. ev.year))
    end
  end
  dialog("Properties - " .. (e.label or e.name), L, { { "OK" } })
end

local function diskCleanup()
  local u = ARC.usage()
  local free, total = 0, 0
  for _, d in ipairs(ARC.drives()) do ARC.freeOf(d); free, total = free + d.free, total + d.total end
  local function row(label, k) return string.format("  %-20s %6d file(s)   %s", label, u[k][1], humanBytes(u[k][2])) end
  dialog("Disk Cleanup", {
    #ARC.drives() .. " archive drive(s):  " .. humanBytes(free) .. " free of " .. humanBytes(total),
    "",
    row("5-second samples", "raw"), row("1-minute averages", "min"),
    row("15-minute averages", "q15"), row("Cycle logs", "cyc"),
    "",
    "5-second files older than " .. ARC.rawDays() .. " day(s) are removed automatically",
    "(change it in Settings). When space runs low the oldest .raw files go",
    "first, then .min, then .q15. Cycle logs are never removed automatically.",
  }, {
    { "Clean Up Now", function()
        local n, fr = ARC.cleanup(true)
        statusMsg = "Disk Cleanup removed " .. n .. " file(s), freed " .. humanBytes(fr)
        load()
      end },
    { "Close" },
  })
end

------------------------------------------------------------ DRAWING
local function rowIcon(e)
  if e.kind == "drive" then return "▤", e.drive.archive and K.navy or K.sh end
  if e.kind == "archive" then return "◆", 0x007A7A end
  if e.isDir then return "■", 0xC8A000 end
  local ext = e.name:match("%.(%w+)$")
  return "≡", TYPE_COLOR[ext or ""] or K.sh
end

local function cellsOf(e)
  if e.kind == "drive" or e.kind == "archive" then
    return { e.label, humanBytes(e.size), e.ty, humanBytes(e.free) .. " free", e.where }
  end
  return { e.name, e.isDir and "" or humanBytes(e.size), e.ty, e.mtime > 1e9 and UI.stamp(e.mtime) or "", e.where }
end

local function drawRows()
  local maxS = max(0, #entries - LROWS)
  scroll = max(0, min(scroll, maxS))
  for r = 1, LROWS do
    local i = scroll + r
    local e = entries[i]
    local y = BY + 1 + r
    if e then
      local on = (i == sel)
      local b, f = on and K.navy or K.white, on and K.white or K.black
      local cells = cellsOf(e)
      local ic, icol = rowIcon(e)
      local cx = LX + 1
      text(cx, y, " ", f, b)
      text(cx + 1, y, ic, on and K.white or icol, b)
      textW(cx + 2, y, COLS[1][2] - 1, " " .. cells[1], f, b)
      cx = cx + COLS[1][2] + 1
      for k = 2, #COLS do
        textW(cx, y, COLS[k][2] + 1, (k == 2) and (cells[k] .. " ") or (" " .. cells[k]), on and K.white or (k == 2 and K.black or 0x404040), b, k == 2 and "right" or nil)
        cx = cx + COLS[k][2] + 1
      end
      fill(cx, y, LX + LW - 2 - cx, 1, b)
    else
      fill(LX + 1, y, LW - 3, 1, K.white)
      if r == 1 and #entries == 0 then
        textW(LX + 1, y, LW - 3, (#path >= 1) and "This folder is empty." or "", K.sh, K.white, "center")
      end
    end
  end
  UI.scrollbar(LX + LW - 2, BY + 2, LROWS, scroll, maxS, true)
end

local function drawTree()
  bevel(TRX, BY, TRW, TRH, "sunken", K.face, K.white)
  local rows = TRH - 2
  local maxS = max(0, #tree - rows)
  treeScroll = max(0, min(treeScroll, maxS))
  for r = 1, rows do
    local n = tree[treeScroll + r]
    local y = BY + r
    fill(TRX + 1, y, TRW - 3, 1, K.white)
    if n then
      local on = samePath(n.p, path)
      local ind = string.rep(" ", n.depth * 2)
      local icon, icol = "■", 0xC8A000
      if n.kind == "pc" then icon, icol = "▣", K.navy
      elseif n.kind == "drive" then icon, icol = "▤", K.sh
      elseif n.kind == "archive" then icon, icol = "◆", 0x007A7A end
      text(TRX + 1 + #ind, y, icon, icol, K.white)
      textW(TRX + 3 + #ind, y, TRW - 5 - #ind, " " .. n.label .. " ", on and K.white or K.black, on and K.navy or K.white)
    end
  end
  UI.scrollbar(TRX + TRW - 2, BY + 1, rows, treeScroll, maxS, true)
end

local function drawRecorder()
  local x, w = TRX + 2, TRW - 4
  local y = RBY + 1
  local t = now()
  local function feed(yy, name, at, waitTxt)
    local ok = ARC.fresh(at)
    text(x, yy, ok and "●" or "○", ok and K.green or (at and K.red or K.sh), K.face)
    textW(x + 2, yy, 14, name, K.black, K.face)
    textW(x + 16, yy, w - 16, at and (UI.fmtShort(t - at) .. " ago") or waitTxt, ok and K.black or K.red, K.face, "right")
  end
  local L, F, S = ARC.live.lsc, ARC.live.farm, ARC.stats
  local inf = ARC.info()
  feed(y, "LSC Power", L and L.at, "waiting")
  local lv = L and L.vals
  textW(x, y + 1, w, lv and ("  out " .. UI.shortNum(lv[1]) .. "  in " .. UI.shortNum(lv[2]) .. "  "
    .. (lv[4] and string.format("%.1f%%", lv[4]) or "--")) or "  lscfuel, port " .. CONFIG.FUEL_PORT, K.sh, K.face)
  feed(y + 2, "Tree Farm", F and F.at, "waiting")
  local fv = F and F.vals
  textW(x, y + 3, w, fv and ("  oak " .. commas(fv[1] or 0) .. ((F.flags or 0) > 0 and "  running" or "  idle"))
    or "  treefarm2, port " .. CONFIG.FARM_PORT, K.sh, K.face)
  feed(y + 4, "LSC Cycles", S.at, "waiting")
  textW(x, y + 5, w, "  " .. commas(inf.cycles) .. " cycles archived", K.sh, K.face)
  text(x, y + 6, string.rep("─", w), K.sh, K.face)
  local today = (L and L.today or 0) + (F and F.today or 0)
  textW(x, y + 7, w, "Today: " .. commas(today) .. " samples", K.black, K.face)
  textW(x, y + 8, w, "Saved " .. humanBytes(inf.written) .. " · " .. inf.pending .. " waiting", K.black, K.face)
  local free = 0
  for _, d in ipairs(ARC.drives()) do free = free + (d.free or 0) end
  textW(x, y + 9, w, (ARC.binary() and "Packed binary" or "Text files") .. " · " .. #ARC.drives() .. " drive(s)",
    K.black, K.face)
  if inf.lastError then
    textW(x, y + 10, w, "! " .. inf.lastError, K.red, K.face)
    region(regions, x, y + 10, w, 1, function() ARC.clearError(); drawRecorder() end)
  else
    textW(x, y + 10, w, humanBytes(free) .. " free on archive drives", K.black, K.face)
  end
end

drawStatus = function()
  fill(X0, SY, CW, 1, K.face)
  local e = sel and entries[sel]
  local parts = {
    #entries .. " object(s)",
    e and (e.name .. (e.isDir and "" or ("  " .. humanBytes(e.size)))) or addressText(),
    statusMsg,
  }
  local cx = X0 + 1
  local widths = { 16, 50, CW - 70 }
  for i, p in ipairs(parts) do
    if i > 1 then text(cx - 1, SY, "│", K.sh, K.face) end
    textW(cx, SY, widths[i] - 1, p, K.black, K.face)
    cx = cx + widths[i]
  end
end

local function setSel(i)
  if #entries == 0 then sel = nil
  else
    sel = max(1, min(#entries, i))
    if sel <= scroll then scroll = sel - 1 elseif sel > scroll + LROWS then scroll = sel - LROWS end
  end
  drawRows(); drawStatus()
end

local function drawBrowse()
  -- toolbar
  fill(X0, TB, CW, 3, K.face)
  local x = X0 + 1
  local function tb(label, w, fn) button(regions, x, TB, w, label, fn); x = x + w + 1 end
  tb("◄ Back", 10, goBack)
  tb("▲ Up", 8, goUp)
  tb("Refresh", 11, function() refresh(); drawAll() end)
  x = x + 2
  tb("Open", 8, function() openEntry(sel and entries[sel]) end)
  tb("Graph", 9, graphHere)
  tb("Cycles", 10, function() VIEW.openCycles(); drawAll() end)
  tb("Gaps", 8, function() VIEW.openGaps(); drawAll() end)
  x = x + 2
  tb("Properties", 14, properties)
  tb("Delete", 10, confirmDelete)
  tb("Disk Cleanup", 16, diskCleanup)
  tb("Storage Report", 18, function() VIEW.openReport(); drawAll() end)
  -- address bar
  fill(X0, AY, CW, 1, K.face)
  text(X0 + 1, AY, "Address", K.black, K.face)
  textW(X0 + 9, AY, CW - 10, " " .. addressText(), K.black, K.white)
  -- tree + recorder
  drawTree()
  for r = 1, TRH - 2 do
    region(regions, TRX + 1, BY + r, TRW - 3, 1, function()
      local n = tree[treeScroll + r]
      if n and not samePath(n.p, path) then go(copy(n.p)) end
    end)
  end
  region(regions, TRX + TRW - 2, BY + 1, 1, 1, function() treeScroll = treeScroll - 1; drawTree() end)
  region(regions, TRX + TRW - 2, BY + TRH - 2, 1, 1, function() treeScroll = treeScroll + 1; drawTree() end)
  groupBox(TRX, RBY, TRW, SY - RBY, "Recorder")
  drawRecorder()
  -- file list
  bevel(LX, BY, LW, LH, "sunken", K.face, K.white)
  local cx = LX + 1
  for _, col in ipairs(COLS) do
    local lab = " " .. col[1] .. ((sortKey == col[3] and #path > 0) and (sortDesc and " ▼" or " ▲") or "")
    textW(cx, BY + 1, col[2], lab, K.black, K.face)
    text(cx + col[2], BY + 1, "│", K.sh, K.face)
    local key = col[3]
    region(regions, cx, BY + 1, col[2], 1, function()
      if sortKey == key then sortDesc = not sortDesc else sortKey, sortDesc = key, false end
      sortEntries(); drawAll()
    end)
    cx = cx + col[2] + 1
  end
  fill(cx, BY + 1, LX + LW - 1 - cx, 1, K.face)
  for r = 1, LROWS do
    region(regions, LX + 1, BY + 1 + r, LW - 3, 1, function()
      local i = scroll + r
      if not entries[i] then sel = nil; drawRows(); drawStatus()
      elseif sel == i then openEntry(entries[i])
      else setSel(i) end
    end)
  end
  region(regions, LX + LW - 2, BY + 2, 1, 1, function() scroll = scroll - 1; drawRows() end)
  region(regions, LX + LW - 2, BY + 1 + LROWS, 1, 1, function() scroll = scroll + 1; drawRows() end)
  drawRows()
  drawStatus()
end

------------------------------------------------------------ MENUS
local function fileMenu()
  popupMenu(WX + 2, WY + 3, {
    { "Open", function() openEntry(sel and entries[sel]) end },
    { "Graph", graphHere },
    { "Cycle Log", function() VIEW.openCycles() end },
    { "Time Between Cycles", function() VIEW.openGaps() end },
    { "Storage Report", function() VIEW.openReport() end },
    { "-" },
    { "Properties", properties },
    { "Delete...", confirmDelete },
    { "Disk Cleanup...", diskCleanup },
    { "-" },
    { "Close File Explorer", function() explorerOpen = false; activeApp = nil end },
  })
end

local function viewMenu()
  local function sortBy(k) return function() sortKey, sortDesc = k, false; sortEntries() end end
  popupMenu(WX + 8, WY + 3, {
    { "Refresh", refresh },
    { "Up One Level", function() VIEW.close(); goUp() end },
    { "Back", function() VIEW.close(); goBack() end },
    { "-" },
    { "Sort by Name", sortBy("name") },
    { "Sort by Size", sortBy("size") },
    { "Sort by Type", sortBy("type") },
    { "Sort by Modified", sortBy("mtime") },
    { "-" },
    { "This PC", function() VIEW.close(); go({}) end },
    { "Archive", function() VIEW.close(); go({ "Archive" }) end },
  })
end

local function helpMenu()
  popupMenu(WX + 14, WY + 3, {
    { "Using File Explorer...", function()
        dialog("Using File Explorer", {
          "Click a row to select it, click it again to open it (or press Enter).",
          "Archive (all drives) shows every drive's archive as one tree.",
          "",
          ".raw  5-second samples (kept " .. ARC.rawDays() .. " days)   .min  1-minute averages",
          ".q15  15-minute averages (one file per month)   .cyc  charging cycles",
          "",
          "In a graph: click a slice to select it, Zoom + / - around it,",
          "◄ ► to move through time, 1H...ALL for a live window.",
          "Keys: arrows, Page Up/Down, Enter, Backspace (back), Delete.",
        }, { { "OK" } })
      end },
    { "About...", about },
  })
end

------------------------------------------------------------ PUBLIC
local function draw()
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  local title = VIEW.isOpen() and VIEW.title() or (#path == 0 and "This PC" or addressText():match("[^\\]+$"))
  titleBar(WX + 1, WY + 1, WW - 2, "▣ File Explorer - " .. title, true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(regions, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(regions, bx + 7, WY + 1, 3, 1, function() explorerOpen = false; activeApp = nil; drawAll() end)
  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  text(WX + 2, WY + 2, " File ", K.black, K.face)
  text(WX + 8, WY + 2, " View ", K.black, K.face)
  text(WX + 14, WY + 2, " Help ", K.black, K.face)
  region(regions, WX + 2, WY + 2, 6, 1, fileMenu)
  region(regions, WX + 8, WY + 2, 6, 1, viewMenu)
  region(regions, WX + 14, WY + 2, 6, 1, helpMenu)
  if VIEW.isOpen() then VIEW.draw() else drawBrowse() end
end

local function tick()
  if VIEW.isOpen() then VIEW.tick(); return end
  drawRecorder()
  if computer.uptime() - lastList >= 30 then      -- new files appear by themselves
    local keep = sel and entries[sel] and entries[sel].name
    entries = listing(path)
    sortEntries()
    sel = nil
    for i, e in ipairs(entries) do if e.name == keep then sel = i end end
    lastList = computer.uptime()
    drawRows()
    local n0 = #tree
    buildTree()
    if #tree ~= n0 then drawTree() end
  end
  drawStatus()
end

local function scrollAt(x, y, dir)
  if VIEW.isOpen() then return VIEW.scroll(x, y, dir) end
  if x >= LX and y > BY and y < BY + LH then scroll = scroll - dir * 3; drawRows(); return true end
  if x < LX and y > BY and y < BY + TRH then treeScroll = treeScroll - dir * 2; drawTree(); return true end
end

local function key(ch, code)
  if VIEW.isOpen() then VIEW.key(code); return end
  local i = sel or 0
  if code == 200 then setSel(i - 1)
  elseif code == 208 then setSel(i + 1)
  elseif code == 201 then setSel(i - LROWS)
  elseif code == 209 then setSel(i + LROWS)
  elseif code == 199 then setSel(1)
  elseif code == 207 then setSel(#entries)
  elseif code == 28 or code == 156 then openEntry(sel and entries[sel])
  elseif code == 14 then goBack()
  elseif code == 211 then confirmDelete()
  elseif ch and ch > 32 and ch < 127 then          -- jump to the first name starting with that letter
    local c = string.char(ch):lower()
    for k = 1, #entries do
      local j = (i + k - 1) % #entries + 1
      if entries[j].name:sub(1, 1):lower() == c then setSel(j); break end
    end
  end
end

VIEW.onBack(function() refresh() end)

return {
  draw = draw, tick = tick, scroll = scrollAt, key = key,
  start = function() path = { "Archive" }; load() end,
  home = function() VIEW.close() end,
}
end)()


------------------------------------------------------------ MY COMPUTER
-- Storage, memory, power and component details for this computer.
-- Own function = own local-variable budget (Lua allows 200 locals per function).
local SYS = (function()
local tab = "storage"          -- "storage" | "memory" | "components"
local sysRegions = {}
local memHist, powHist = {}, {}   -- last 120 samples (one per second)
local compList, compSel, compScroll = {}, 1, 0
local devInfo = {}
local lastSlow = 0

local PX0, PY0, PW, PH = 16, 7, 140, 36    -- tab panel
local BAR_FG, BAR_BG = K.navy, K.white

local function human(n)
  if not n then return "--" end
  if n == math.huge or n ~= n then return "unlimited" end
  if n >= 1048576 then return string.format("%.2f MB", n / 1048576) end
  if n >= 1024 then return string.format("%.1f KB", n / 1024) end
  return string.format("%d B", floor(n))
end

local function bar(x, y, w, frac, col)
  frac = max(0, min(1, frac or 0))
  local n = floor(frac * w + 0.5)
  bg(K.sh); fg(K.white)
  fill(x, y, w, 1, BAR_BG)
  if n > 0 then fill(x, y, n, 1, col or BAR_FG) end
end

local function safe(fn, ...)
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
end

-- data -------------------------------------------------------------------
local function drives()
  local byAddr, list = {}, {}
  for proxy, path in filesystem.mounts() do
    local a = proxy.address
    local d = byAddr[a]
    if not d then
      d = { address = a, proxy = proxy, paths = {} }
      byAddr[a] = d
      list[#list + 1] = d
    end
    d.paths[#d.paths + 1] = path
  end
  for _, d in ipairs(list) do
    table.sort(d.paths)
    d.used = safe(d.proxy.spaceUsed) or 0
    d.total = safe(d.proxy.spaceTotal)
    d.label = safe(d.proxy.getLabel)
    d.ro = safe(d.proxy.isReadOnly)
    d.letter = ARC.letterOf(d.address)
    for _, x in ipairs(ARC.drives()) do if x.address == d.address then d.isArc = true end end
    local info = devInfo[d.address]
    d.kind = (d.paths[1] == "/tmp" or (d.label == "tmpfs")) and "RAM disk (tmpfs)"
      or (info and info.description) or "Disk"
  end
  table.sort(list, function(a, b) return a.paths[1] < b.paths[1] end)
  return list
end

local function homeFiles()
  local out = {}
  local ok, iter = pcall(filesystem.list, "/home")
  if not ok or not iter then return out end
  for name in iter do
    local path = "/home/" .. name
    if not filesystem.isDirectory(path) then
      out[#out + 1] = { name = name, size = filesystem.size(path) or 0,
                        time = (filesystem.lastModified(path) or 0) / 1000 }
    end
  end
  table.sort(out, function(a, b) return a.size > b.size end)
  return out
end

local function refreshComponents()
  devInfo = (computer.getDeviceInfo and safe(computer.getDeviceInfo)) or {}
  compList = {}
  for addr, ctype in component.list() do
    compList[#compList + 1] = { address = addr, type = ctype, info = devInfo[addr] or {} }
  end
  table.sort(compList, function(a, b)
    if a.type ~= b.type then return a.type < b.type end
    return a.address < b.address
  end)
  compSel = max(1, min(compSel, #compList))
end

-- extra live readings for well-known component types
local SIDES = { [0] = "bottom", "top", "north", "south", "west", "east" }
local function liveStats(c)
  local out = {}
  local p = safe(component.proxy, c.address)
  if not p then return out end
  local function add(k, v) if v ~= nil then out[#out + 1] = { k, tostring(v) } end end
  if c.type == "gpu" then
    local w, h = safe(p.getResolution); local mw, mh = safe(p.maxResolution)
    if w then add("Resolution", w .. " x " .. h) end
    if mw then add("Max resolution", mw .. " x " .. mh) end
    add("Color depth", (safe(p.getDepth) or "?") .. " bit (max " .. (safe(p.maxDepth) or "?") .. ")")
    local scr = safe(p.getScreen); add("Bound screen", scr and scr:sub(1, 8))
  elseif c.type == "screen" then
    add("Powered on", safe(p.isOn))
    local aw, ah = safe(p.getAspectRatio); if aw then add("Size (blocks)", aw .. " x " .. ah) end
    local kb = safe(p.getKeyboards); add("Keyboards", kb and #kb)
  elseif c.type == "modem" then
    add("Wireless", safe(p.isWireless))
    if safe(p.isWireless) then add("Signal strength", safe(p.getStrength)) end
    add("Max packet size", safe(p.maxPacketSize))
  elseif c.type == "internet" then
    add("HTTP enabled", safe(p.isHttpEnabled)); add("TCP enabled", safe(p.isTcpEnabled))
  elseif c.type == "filesystem" then
    add("Label", safe(p.getLabel) or "(none)")
    add("Used", human(safe(p.spaceUsed))); add("Capacity", human(safe(p.spaceTotal)))
    add("Read-only", safe(p.isReadOnly))
  elseif c.type == "eeprom" then
    add("Label", safe(p.getLabel)); add("Code size", human(safe(p.getSize)))
    add("Data size", human(safe(p.getDataSize)))
  elseif c.type == "redstone" then
    local outs = {}
    for sd = 0, 5 do outs[#outs + 1] = SIDES[sd] .. "=" .. tostring(safe(p.getOutput, sd) or "?") end
    add("Outputs", table.concat(outs, " "))
  elseif c.type == "computer" then
    add("Running", safe(p.isRunning))
  end
  local methods = safe(component.methods, c.address)
  if methods then
    local n = 0
    for _ in pairs(methods) do n = n + 1 end
    add("API methods", n)
  end
  return out
end

-- sampling (called once per second from the main loop) -------------------
local function sample()
  local total, free = computer.totalMemory(), computer.freeMemory()
  memHist[#memHist + 1] = (total - free) / total
  local e, me = computer.energy(), computer.maxEnergy()
  powHist[#powHist + 1] = (me > 0) and e / me or 0
  while #memHist > 120 do table.remove(memHist, 1) end
  while #powHist > 120 do table.remove(powHist, 1) end
end

local function history(x, y, w, rows, data, col)
  local cv = newCanvas(w, rows * 2, K.white)
  for k = 0, 3 do
    local yy = 1 + floor(k * (rows * 2 - 1) / 3)
    for xx = 1, w, 2 do cset(cv, xx, yy, K.grid) end
  end
  local n = #data
  local lx, ly
  for i = 1, n do
    local xx = w - (n - i)
    if xx >= 1 then
      local yy = rows * 2 - floor(data[i] * (rows * 2 - 1) + 0.5)
      if lx then cline(cv, lx, ly, xx, yy, col) else cset(cv, xx, yy, col) end
      lx, ly = xx, yy
    end
  end
  crender(cv, x, y)
end

-- tabs ---------------------------------------------------------------------
local TABS = { { "storage", "Storage" }, { "memory", "Memory & Power" }, { "components", "Components" } }

local function drawTabs()
  fill(WX + 1, 5, WW - 2, 2, K.face)
  local x = PX0
  for _, t in ipairs(TABS) do
    local w = unicode.len(t[2]) + 4
    local active = (tab == t[1])
    text(x, 5, "┌" .. string.rep("─", w - 2) .. "┐", K.hi, K.face)
    text(x, 6, "│", K.hi, K.face)
    textW(x + 1, 6, w - 2, t[2], K.black, K.face, "center")
    text(x + w - 1, 6, "│", K.sh, K.face)
    region(sysRegions, x, 5, w, 2, function() tab = t[1]; drawAll() end)
    t.x, t.w = x, w
    x = x + w
  end
end

local function drawPanelFrame()
  bevel(PX0, PY0, PW, PH, "raised", K.face, K.face)
  for _, t in ipairs(TABS) do      -- open the border under the active tab
    if tab == t[1] and t.x then text(t.x + 1, PY0, string.rep(" ", t.w - 2), K.black, K.face) end
  end
end

-- Storage tab
local function drawStorage(full)
  local x, y = PX0 + 2, PY0 + 1
  if full then groupBox(x, y, PW - 4, 19, "Drives") end
  local list = drives()
  for i, d in ipairs(list) do
    if i > 8 then
      textW(x + 2, y + 17, PW - 8, "+ " .. (#list - 8) .. " more drive(s) - see the Components tab", K.sh, K.face)
      break
    end
    local yy = y + 1 + (i - 1) * 2
    local name = (d.letter and (d.letter .. ":  ") or "") .. (d.label and d.label ~= "" and d.label or "Unlabeled")
      .. "  (" .. d.address:sub(1, 8) .. ")"
    textW(x + 2, yy, 48, "▣ " .. name, K.black, K.face)
    textW(x + 50, yy, 40, "Mounted at " .. table.concat(d.paths, ", "), K.sh, K.face)
    textW(x + 90, yy, PW - 96, d.kind .. (d.ro and "  [read-only]" or "") .. (d.isArc and "  [archive]" or ""),
      d.isArc and K.navy or K.sh, K.face)
    local frac = (d.total and d.total > 0 and d.total ~= math.huge) and d.used / d.total or 0
    bar(x + 4, yy + 1, 60, frac, frac > 0.9 and K.red or K.navy)
    textW(x + 66, yy + 1, PW - 72, human(d.used) .. " used of " .. human(d.total)
      .. ((d.total and d.total ~= math.huge) and string.format("   (%d%% full, %s free)", floor(frac * 100 + 0.5), human(d.total - d.used)) or ""),
      K.black, K.face)
  end

  local y2 = y + 20
  if full then groupBox(x, y2, PW - 4, PH - 22, "Program Files in /home") end
  local files = homeFiles()
  textW(x + 2, y2 + 1, 40, "Name", K.sh, K.face)
  textW(x + 44, y2 + 1, 14, "Size", K.sh, K.face, "right")
  textW(x + 62, y2 + 1, 30, "Last changed", K.sh, K.face)
  for i = 1, PH - 25 do
    local f = files[i]
    local yy = y2 + 1 + i
    if f then
      local what = f.name:match("%.lua$") and "program" or (f.name:match("%.dat$") and "data" or "")
      textW(x + 2, yy, 40, f.name, K.black, K.face)
      textW(x + 44, yy, 14, human(f.size), K.black, K.face, "right")
      textW(x + 62, yy, 30, f.time > 1e9 and fmtStamp(f.time) or "--", K.black, K.face)
      textW(x + 94, yy, PW - 100, what, K.sh, K.face)
    else
      textW(x + 2, yy, PW - 8, "", K.black, K.face)
    end
  end
end

-- Memory & Power tab
local function drawMemory(full)
  local x, y = PX0 + 2, PY0 + 1
  local total, free = computer.totalMemory(), computer.freeMemory()
  local e, me = computer.energy(), computer.maxEnergy()
  if full then
    groupBox(x, y, PW - 4, 13, "Memory (RAM)")
    groupBox(x, y + 14, PW - 4, 13, "Power")
    groupBox(x, y + 28, PW - 4, 6, "System")
  end
  bar(x + 2, y + 2, 60, (total - free) / total, (free / total < 0.1) and K.red or K.navy)
  textW(x + 64, y + 2, PW - 70, human(total - free) .. " used of " .. human(total)
    .. string.format("   (%d%%)   %s free", floor((total - free) / total * 100 + 0.5), human(free)), K.black, K.face)
  textW(x + 2, y + 3, PW - 8, "Last 2 minutes. A sawtooth is normal: Lua frees unused memory in batches, before it runs out.",
    K.sh, K.face)
  history(x + 2, y + 4, PW - 8, 8, memHist, K.navy)

  local pf = me > 0 and e / me or 0
  bar(x + 2, y + 16, 60, pf, pf < 0.2 and K.red or K.green)
  textW(x + 64, y + 16, PW - 70, string.format("%s / %s energy stored   (%d%%)", commas(e), commas(me), floor(pf * 100 + 0.5)),
    K.black, K.face)
  textW(x + 2, y + 17, PW - 8, "Stored energy over the last 2 minutes (a falling line means the power supply can't keep up):", K.sh, K.face)
  history(x + 2, y + 18, PW - 8, 8, powHist, K.green)

  local up = computer.uptime()
  textW(x + 2, y + 29, 66, "Uptime: " .. fmtDurLong(up) .. "    Architecture: " ..
    tostring((computer.getArchitecture and safe(computer.getArchitecture)) or "?"), K.black, K.face)
  textW(x + 70, y + 29, PW - 76, "OS: " .. tostring(_OSVERSION or "OpenOS"), K.black, K.face)
  textW(x + 2, y + 30, 66, "Computer address: " .. tostring(computer.address()), K.black, K.face)
  textW(x + 70, y + 30, PW - 76, "Components connected: " .. #compList, K.black, K.face)
  textW(x + 2, y + 31, PW - 8, "This program (Lymanos Archive) is using about " ..
    human(total - free) .. " of RAM including OpenOS.", K.sh, K.face)
end

-- Components tab
local CCOLS = { { "Type", 13 }, { "Address", 9 }, { "Description", 26 }, { "Product", 30 }, { "Vendor", 24 }, { "Capacity / Speed", 22 } }
local LROWS = 16
local function capText(info)
  local parts = {}
  if info.capacity then parts[#parts + 1] = "cap " .. info.capacity end
  if info.width then parts[#parts + 1] = "width " .. info.width end
  if info.clock then parts[#parts + 1] = "clock " .. info.clock end
  if info.size then parts[#parts + 1] = "size " .. info.size end
  return table.concat(parts, ", ")
end

local function drawCompRows()
  local x, y, w = PX0 + 2, PY0 + 1, PW - 4
  local maxScroll = max(0, #compList - LROWS)
  compScroll = max(0, min(compScroll, maxScroll))
  for r = 1, LROWS do
    local i = compScroll + r
    local c = compList[i]
    local yy = y + 1 + r
    local sel = (i == compSel)
    local b, f = sel and K.navy or K.white, sel and K.white or K.black
    if c then
      local cells = { c.type, c.address:sub(1, 8), c.info.description or "", c.info.product or "",
                      c.info.vendor or "", capText(c.info) }
      local cx = x + 1
      for k, col in ipairs(CCOLS) do
        textW(cx, yy, col[2] + 1, " " .. cells[k], f, b)
        cx = cx + col[2] + 1
      end
      fill(cx, yy, x + w - 2 - cx, 1, b)
    else
      fill(x + 1, yy, w - 3, 1, K.white)
    end
  end
  local sx = x + w - 2
  text(sx, y + 1, "▲", K.black, K.face)
  text(sx, y + LROWS + 1, "▼", K.black, K.face)
  vtext(sx, y + 2, string.rep("░", LROWS - 1), K.face, K.track)
  if maxScroll > 0 then
    text(sx, y + 2 + floor((LROWS - 2) * compScroll / maxScroll + 0.5), "█", K.face, K.track)
  end
end

local function drawCompDetail()
  local x, y = PX0 + 2, PY0 + 21
  groupBox(x, y, PW - 4, PH - 22, "Details")
  local c = compList[compSel]
  if not c then return end
  local rows = {
    { "Type", c.type }, { "Address", c.address },
  }
  for k, v in pairs(c.info) do rows[#rows + 1] = { k:sub(1, 1):upper() .. k:sub(2), tostring(v) } end
  for _, kv in ipairs(liveStats(c)) do rows[#rows + 1] = kv end
  local perCol = PH - 24
  for i, kv in ipairs(rows) do
    if i > perCol * 2 then break end
    local col = (i <= perCol) and 0 or 1
    local yy = y + i - col * perCol
    textW(x + 2 + col * 68, yy, 18, kv[1] .. ":", K.sh, K.face)
    textW(x + 20 + col * 68, yy, 48, kv[2], K.black, K.face)
  end
end

local function drawComponents(full)
  local x, y, w = PX0 + 2, PY0 + 1, PW - 4
  if full then
    bevel(x, y, w, LROWS + 3, "sunken", K.face, K.white)
    local cx = x + 1
    for _, col in ipairs(CCOLS) do
      textW(cx, y + 1, col[2], " " .. col[1], K.black, K.face)
      text(cx + col[2], y + 1, "│", K.sh, K.face)
      cx = cx + col[2] + 1
    end
    fill(cx, y + 1, x + w - 2 - cx, 1, K.face)
    for r = 1, LROWS do
      region(sysRegions, x + 1, y + 1 + r, w - 3, 1, function()
        if compList[compScroll + r] then compSel = compScroll + r; drawCompRows(); drawCompDetail() end
      end)
    end
    region(sysRegions, x + w - 2, y + 1, 1, 1, function() compScroll = compScroll - 1; drawCompRows() end)
    region(sysRegions, x + w - 2, y + LROWS + 1, 1, 1, function() compScroll = compScroll + 1; drawCompRows() end)
  end
  drawCompRows()
  drawCompDetail()
end

local function drawStatus()
  local yy = WY + WH - 2
  fill(WX + 1, yy, WW - 2, 1, K.face)
  local total, free = computer.totalMemory(), computer.freeMemory()
  textW(WX + 2, yy, 46, "Memory: " .. human(total - free) .. " / " .. human(total), K.black, K.face)
  text(WX + 49, yy, "│", K.sh, K.face)
  textW(WX + 50, yy, 40, string.format("Energy: %d%%", floor(computer.energy() / max(1, computer.maxEnergy()) * 100 + 0.5)), K.black, K.face)
  text(WX + 91, yy, "│", K.sh, K.face)
  textW(WX + 92, yy, 50, #compList .. " components   Uptime " .. fmtDur(computer.uptime()), K.black, K.face)
end

local function drawBody(full)
  if tab == "storage" then drawStorage(full)
  elseif tab == "memory" then drawMemory(full)
  else drawComponents(full) end
end

local function drawWindow()
  sysRegions = {}
  refreshComponents()
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ My Computer - System Properties", true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(sysRegions, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(sysRegions, bx + 7, WY + 1, 3, 1, function() closeSysApp() end)
  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  text(WX + 2, WY + 2, " Refresh ", K.black, K.face)
  region(sysRegions, WX + 2, WY + 2, 9, 1, function() drawAll() end)
  drawTabs()
  drawPanelFrame()
  drawBody(true)
  drawStatus()
  lastSlow = computer.uptime()
end

-- once per second while visible: live values only (overwrite, no flicker)
local function tick(visible)
  pcall(sample)
  if not visible then return end
  if tab == "memory" then drawMemory(false) end
  if computer.uptime() - lastSlow >= 5 then
    lastSlow = computer.uptime()
    if tab == "storage" then drawStorage(false)
    elseif tab == "components" then refreshComponents(); drawCompRows() end
  end
  drawStatus()
end

local function scroll(x, y, dir)
  if tab == "components" and y >= PY0 + 2 and y <= PY0 + 1 + LROWS then
    compScroll = compScroll - dir
    drawCompRows()
    return true
  end
end

return {
  drawWindow = drawWindow, tick = tick, scroll = scroll,
  regions = function() return sysRegions end,
  resetRegions = function() sysRegions = {} end,
}
end)()
local sysOpen = false
openSysApp = function() sysOpen = true; activeApp = "sys" end
closeSysApp = function() sysOpen = false; activeApp = nil; drawAll() end
sysAppOpen = function() return sysOpen end

------------------------------------------------------------ LOCK SCREEN
-- Start > Lock, or automatically after SETTINGS.lockMins idle minutes.
-- Uses the overlay so every app keeps running underneath without drawing.
LOCK = (function()
-- 6x12 bold font, ASCII 32-126, 12 rows of 2 hex digits per glyph (from X11 koi6x13b;
-- "M" and "m" redrawn so they read as letters instead of solid blocks)
local F1 =
  "000000000000000000000000000c0c0c0c0c0c0c000c000000363636000000000000000000001e1e3f1e3f1e1e0000000000" ..
  "0c1e3c1e0f1e0c000000001b3f1e060c181e3f360000000000183c3c183f361f0000000c0c0c0000000000000000060c0c18" ..
  "181818180c0c0600180c0c06060606060c0c1800000000331e3f1e33000000000000000c0c3f0c0c00000000000000000000" ..
  "00000e0c180000000000003f00000000000000000000000000000c1e0c0000030306060c181830300000000c1e3333333333" ..
  "1e0c0000000c1c3c0c0c0c0c0c3f0000001e333303060c18303f0000003f03060c1e0303331e00000006060e1e16363f0606" ..
  "0000003f30303e3b0303331e0000000e1830303e3b33331e0000003f0306060c0c1818180000001e3333331e3333331e0000" ..
  "001e3333371f0303061c000000000c1e0c00000c1e0c00000000000c1e0c00000e0c18000003060c1830180c060300000000" ..
  "00003f00003f000000000030180c0603060c18300000001e333303060c0c000c0000001e3333373f3f3e301f0000000c1e33" ..
  "33333f3333330000003e1b1b1b1e1b1b1b3e0000001e333030303030331e0000003e1b1b1b1b1b1b1b3e0000003f3030303e" ..
  "3030303f0000003f3030303e303030300000001e333030303733331e000000333333333f333333330000001e0c0c0c0c0c0c" ..
  "0c1e0000000f030303030303331e0000003333363c383c36333300000030303030303030303f00000021333b353131313100" ..
  "000000333b3b3f3f373733330000001e333333333333331e0000003e3333333e303030300000001e3333333333333f1e0300" ..
  "003e3333333e3c3633330000001e3330301e0303331e0000003f0c0c0c0c0c0c0c0c00000033333333333333331e00000033" ..
  "3333331e1e1e0c0c000000333333333f3f3f3f3300000033331e1e0c1e1e333300000033331e1e0c0c0c0c0c0000003f0306" ..
  "060c1818303f00001e1818181818181818181e0000303018180c0606030300001e0606060606060606061e00000c1e330000" ..
  "000000000000000000000000000000003f00180c00000000000000000000000000001e031f33371b000000303030363b3333" ..
  "3b360000000000001e333030331e0000000303031b373333371b0000000000001e333f30301e0000000e1b18183e18181818" ..
  "0000000000001f36361c301e331e00303030363b333333330000000c0c001c0c0c0c0c1e0000000606000e0606060636361c" ..
  "00303030363c383c36330000001c0c0c0c0c0c0c0c1e0000000000003c3635353535000000000000363b3333333300000000" ..
  "00001e333333331e000000000000363b333b36303030000000001b3733371b03030300000000363b30303030000000000000" ..
  "1e331c06331e0000000018183e1818181b0e00000000000033333333371b0000000000003333331e1e0c0000000000003333" ..
  "3f3f3f12000000000000331e0c0c1e33000000000000333333371b03331e000000003f060c18303f00000e1818180c380c18" ..
  "18180e00000c0c0c0c0c0c0c0c0c0000380c0c0c180e180c0c0c3800001a3e240000000000000000"
-- 12x20 bold digits "0123456789:", 20 rows of 3 hex digits per glyph (X11 koi12x24b)
local F2 =
  "0f01f839c30c70e606e07e07e07e07e07e07e07e0760670e30c39c1f80f00700f01f07f00700700700700700700700700700" ..
  "700700700700700703fe0f039c70e607c0700700700e00e01c0380300600c0180303603607ffffff3f073cc1c00e00e00e00" ..
  "c0181f03fc01e00f00700700700700e01c078fc001c01c03c03c07c07c0dc0dc19c19c31c31c61c61cfff01c01c01c01c07f" ..
  "7ff7fe6006006006006007f879c70e60700700700700700700e00e03c7e003c0e0180380700700e00e00ef8f8ee07e07e07e" ..
  "07e07e0770e70e39c0f0ffffffe03c06c0c00c0180180300300700700600e00e00e00e00e00e00e00f039c30c70e70e70e70" ..
  "e38c3d81f01f833e60ee07e07e07e0760670e1f80f039c70e70ee07e07e07e07e0760771f1f700700700e00e01c0180703c0" ..
  "0000000000000000000000f00f00f00000000000000000000000f00f00f0"
local F1W, F1H, F2W, F2H = 6, 12, 12, 20
local F2CH = "0123456789:"
local STYLES = {      -- name, top color, bottom color, accent
  { "Midnight", 0x070B1E, 0x3B1E66, 0xA9B8FF },
  { "Aurora",   0x03161A, 0x0E5A55, 0x7CF5D0 },
  { "Sunset",   0x1E0B33, 0x9A4A3A, 0xFFC98A },
  { "Slate",    0x14171B, 0x46505E, 0xD0D8E2 },
  { "Ember",    0x120606, 0x5A1E0A, 0xFFB07A },
}
local locked, lastKey, lastDay = false, nil, nil
local lastActivity = computer.uptime()

local function style() return STYLES[SETTINGS.lockStyle] or STYLES[1] end
local function grad(py) local s = style(); return lerp(s[2], s[3], max(0, min(1, (py - 1) / 99))) end
local function rowBg(r) return grad(r * 2) end

-- draws text in one of the bitmap fonts; x0 = screen column, row0 = screen row
local function bigText(font, fw, fh, hexw, chars, s, x0, row0, color, gap)
  gap = gap or 0
  local n = #s
  local w = n * (fw + gap) - gap
  if w <= 0 then return end
  local cv = newCanvas(w, fh, 0)
  local g = cv.g
  for py = 1, fh do
    local c = grad(row0 * 2 - 2 + py)
    for x = 1, w do g[(py - 1) * w + x] = c end
  end
  for i = 1, n do
    local ch = s:sub(i, i)
    local idx = chars and chars:find(ch, 1, true) or (ch:byte() - 31)
    if idx and idx >= 1 and idx <= #font / (fh * hexw) then
      local base = (idx - 1) * fh * hexw
      for py = 1, fh do
        local bits = tonumber(font:sub(base + (py - 1) * hexw + 1, base + py * hexw), 16) or 0
        for px = 1, fw do
          if floor(bits / 2 ^ (fw - px)) % 2 == 1 then g[(py - 1) * w + (i - 1) * (fw + gap) + px] = color end
        end
      end
    end
  end
  crender(cv, x0, row0)
end
local function small(s, x, row, color) bigText(F1, F1W, F1H, 2, nil, s, x, row, color, 1) end
local function centerSmall(s, row, color) small(s, floor((W - #s * (F1W + 1) + 1) / 2) + 1, row, color) end

local MONTHS = { "January", "February", "March", "April", "May", "June", "July",
                 "August", "September", "October", "November", "December" }
local DAYS = { Sun = "Sunday", Mon = "Monday", Tue = "Tuesday", Wed = "Wednesday",
               Thu = "Thursday", Fri = "Friday", Sat = "Saturday" }

local function greeting(e)
  local g = (e.hour >= 5 and e.hour < 12) and "Good morning"
    or (e.hour >= 12 and e.hour < 17) and "Good afternoon" or "Good evening"
  local name = tostring(PLAYER_NAME):gsub("[^\32-\126]", "")
  local room = 22 - #g - 3
  if #name > room then name = name:sub(1, max(1, room)) end
  return g .. ", " .. name .. "."
end

local function drawTime(e)
  local ts, ap
  if SETTINGS.clock24 then ts = string.format("%02d:%02d", e.hour, e.min)
  else local h; h, ap = h12(e); ts = string.format("%d:%02d", h, e.min) end
  local tw = #ts * F2W
  local total = tw + (ap and (3 + 2 * F1W + 1) or 0)
  local x0 = floor((W - total) / 2) + 1
  -- clear the clock band first (width changes, e.g. 9:59 -> 10:00)
  for r = 6, 17 do bg(rowBg(r)); fg(grad(r * 2 - 1)); gpu.fill(1, r, W, 1, "▀") end
  bigText(F2, F2W, F2H, 3, F2CH, ts, x0, 7, 0xFFFFFF)
  if ap then small(ap, x0 + tw + 3, 7, style()[4]) end
end

local function statusLine(t)
  local parts = {}
  local L, F = ARC.live.lsc, ARC.live.farm
  if L and L.at then parts[#parts + 1] = "LSC " .. (ARC.fresh(L.at) and ((L.flags or 0) > 0 and "charging" or "idle") or "offline") end
  if F and F.at then parts[#parts + 1] = "Farm " .. (ARC.fresh(F.at) and ((F.flags or 0) > 0 and "running" or "idle") or "offline") end
  parts[#parts + 1] = "recording " .. ((ARC.anyFresh()) and "on" or "waiting")
  local free = computer.freeMemory()
  parts[#parts + 1] = string.format("RAM %dK free", floor(free / 1024))
  local s = table.concat(parts, "   ·   ")
  textW(W - 71, 49, 70, s, style()[4], rowBg(49), "right")
end

local function unlock()
  locked = false
  lockedFlag = false
  lastActivity = computer.uptime()
  overlay = nil
  nextDialogOrRedraw()
end

local function draw()
  if not (overlay and overlay.lock) then
    if overlay and overlay.reshow then table.insert(dialogQueue, 1, overlay.reshow) end
    overlay = { regions = {}, modal = true, lock = true }
  end
  overlay.regions = {}
  local t = now()
  local e = toEastern(t)
  lastKey, lastDay = e.hour * 60 + e.min, e.day
  local acc = style()[4]
  for r = 1, H do bg(rowBg(r)); fg(grad(r * 2 - 1)); gpu.fill(1, r, W, 1, "▀") end
  text(3, 2, "◆ " .. tostring(SETTINGS.systemName or "Lymanos Archive"), acc, rowBg(2))
  text(W - 12, 2, "■ LOCKED", acc, rowBg(2))
  drawTime(e)
  local date = (DAYS[e.wday] or e.wday) .. ", " .. MONTHS[e.month] .. " " .. e.day
  if #date > 22 then date = (DAYS[e.wday] or e.wday) .. ", " .. MONTHS[e.month]:sub(1, 3) .. " " .. e.day end
  centerSmall(date, 19, acc)
  -- round "account" picture with your initial
  local cw, ch = 14, 14
  local cv = newCanvas(cw, ch, 0)
  local ax, ar = floor((W - cw) / 2) + 1, 27
  for py = 1, ch do
    for px = 1, cw do
      local dx, dy = px - 7.5, py - 7.5
      cv.g[(py - 1) * cw + px] = (dx * dx + dy * dy <= 42) and lerp(acc, 0x000000, 0.35) or grad(ar * 2 - 2 + py)
    end
  end
  crender(cv, ax, ar)
  local initial = tostring(PLAYER_NAME):sub(1, 1):upper()
  -- the letter sits on the circle color, so draw it over a canvas of that color
  local lc = newCanvas(F1W, F1H, lerp(acc, 0x000000, 0.35))
  local idx = (initial:byte() or 63) - 31
  if idx >= 1 and idx <= 95 then
    for py = 1, F1H do
      local bits = tonumber(F1:sub((idx - 1) * 24 + (py - 1) * 2 + 1, (idx - 1) * 24 + py * 2), 16) or 0
      for px = 1, F1W do if floor(bits / 2 ^ (F1W - px)) % 2 == 1 then lc.g[(py - 1) * F1W + px] = 0xFFFFFF end end
    end
  end
  crender(lc, ax + 4, ar + 1)
  centerSmall(greeting(e), 35, 0xFFFFFF)
  -- Unlock button
  local bw = 24
  local bx = floor((W - bw) / 2) + 1
  for r = 43, 45 do fill(bx, r, bw, 1, lerp(rowBg(r), 0xFFFFFF, r == 44 and 0.22 or 0.12)) end
  textW(bx, 44, bw, "Unlock  ▸", 0xFFFFFF, lerp(rowBg(44), 0xFFFFFF, 0.22), "center")
  region(overlay.regions, bx, 43, bw, 3, unlock)
  text(3, 49, "Press Enter or click Unlock", lerp(acc, rowBg(49), 0.35), rowBg(49))
  statusLine(t)
end

local function lock()
  if locked then return end
  locked = true
  lockedFlag = true
  draw()
end

-- once per second while locked
local function tick(t)
  local e = toEastern(t)
  local key = e.hour * 60 + e.min
  if key ~= lastKey then
    if e.day ~= lastDay or floor(key / 60) ~= floor((lastKey or 0) / 60) then draw()
    else lastKey = key; drawTime(e) end
  end
  statusLine(t)
end

-- a small preview of a style (Settings)
local function preview(x, y, w, h, i)
  local s = STYLES[i] or STYLES[1]
  for r = 0, h - 1 do
    bg(lerp(s[2], s[3], (r * 2 + 1) / (h * 2 - 1))); fg(lerp(s[2], s[3], (r * 2) / (h * 2 - 1)))
    gpu.fill(x, y + r, w, 1, "▀")
  end
  textW(x, y + floor(h / 2), w, "12:00", 0xFFFFFF, lerp(s[2], s[3], 0.5), "center")
end

return {
  lock = lock, unlock = unlock, draw = draw, tick = tick, preview = preview,
  isLocked = function() return locked end,
  key = function(code) if code == 28 or code == 156 or code == 57 then unlock() end end,
  poke = function() lastActivity = computer.uptime() end,
  idle = function() return computer.uptime() - lastActivity end,
  styleCount = #STYLES, styleName = function(i) return (STYLES[i] or STYLES[1])[1] end,
}
end)()

---------------------------------------------------------------- SETTINGS
SET = (function()
local fields = { user = "", system = "" }
local focus, input = nil, ""
local LOCK_MINS = { 0, 5, 10, 15, 30, 60, 120 }
local RAW_DAYS = { 1, 2, 3, 5, 7, 14, 30 }
local RESERVE = { 64, 128, 256, 512, 1024, 2048 }
local saved = nil       -- "Saved" flash text
local FX = 36           -- field / control column

local function idxOf(list, v)
  for i, x in ipairs(list) do if x == v then return i end end
  return 1
end
local function step(list, v, d) return list[(idxOf(list, v) - 1 + d) % #list + 1] end

local function changed(msg) saveSettings(); saved = msg or "Saved"; drawAll() end

local function setUser(n)
  n = n:gsub("^%s+", ""):gsub("%s+$", "")
  SETTINGS.userName = (n ~= "") and n or nil
  PLAYER_NAME = SETTINGS.userName or ("Player-" .. wlan.address:sub(1, 4))
  changed("Name saved")
end

local function field(id, x, y, w, value)
  if focus == id then textW(x, y, w, " " .. input .. "_", K.black, 0xFFFFC0)
  else textW(x, y, w, " " .. value, K.navy, K.white) end
  region(regions, x, y, w, 1, function()
    focus, input = id, ""
    drawAll()
  end)
end

local function cycler(x, y, w, value, onStep)
  text(x, y, " ◄ ", K.black, 0xD4D0C8)
  textW(x + 3, y, w, value, K.navy, K.white, "center")
  text(x + 3 + w, y, " ► ", K.black, 0xD4D0C8)
  region(regions, x, y, 3, 1, function() onStep(-1) end)
  region(regions, x + 3 + w, y, 3, 1, function() onStep(1) end)
end

local function label(x, y, s) textW(x, y, FX - 18, s, K.black, K.face) end
local function note(x, y, w, s) textW(x, y, w, s, K.sh, K.face) end

local function drawFields()
  local L = 18
  field("user", L + FX - 18, 7, 28, PLAYER_NAME)
  field("system", L + FX - 18, 9, 28, SETTINGS.systemName or "Lymanos Archive")
end

local function drawWindow()
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ Settings - " .. tostring(SETTINGS.systemName or "Lymanos Archive"), true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(regions, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(regions, bx + 7, WY + 1, 3, 1, function() closeSettings() end)
  local L, R = 18, 88
  local LWd, RWd = 66, 66

  -- your name & system
  groupBox(L - 2, 5, LWd + 2, 9, "Name")
  label(L, 7, "Your name:")
  label(L, 9, "System name:")
  drawFields()
  note(L, 11, LWd - 2, "Your name is shown on the lock screen.")
  note(L, 12, LWd - 2, "Click a box, type, press Enter.")

  -- desktop & clock
  groupBox(L - 2, 15, LWd + 2, 8, "Desktop & Clock")
  label(L, 17, "Desktop color:")
  local dc = DESK_COLORS[SETTINGS.desk] or DESK_COLORS[1]
  cycler(L + FX - 18, 17, 14, dc[1], function(d)
    SETTINGS.desk = (SETTINGS.desk - 1 + d) % #DESK_COLORS + 1
    K.desk = DESK_COLORS[SETTINGS.desk][2]
    changed()
  end)
  fill(L + FX + 2, 17, 6, 1, dc[2])
  label(L, 19, "Clock:")
  cycler(L + FX - 18, 19, 14, SETTINGS.clock24 and "24-hour" or "12-hour", function()
    SETTINGS.clock24 = not SETTINGS.clock24; changed()
  end)
  note(L, 21, LWd - 2, "Used on the taskbar, lock screen and File Explorer.")

  -- about
  groupBox(L - 2, 24, LWd + 2, 19, "About This Computer")
  local total, free = computer.totalMemory(), computer.freeMemory()
  local rows = {
    { "System:", tostring(SETTINGS.systemName or "Lymanos Archive") .. "  (Lymanos Archive 1.0)" },
    { "User:", tostring(PLAYER_NAME) },
    { "Memory:", string.format("%d K used of %d K", floor((total - free) / 1024), floor(total / 1024)) },
    { "Network card:", wlan.address:sub(1, 8) .. (wlan.isWireless() and " (wireless)" or " (wired)") },
    { "Settings file:", CONFIG.SETTINGS_FILE },
    { "Ports:", "lscstats " .. CONFIG.STATS_PORT .. "  lscfuel " .. CONFIG.FUEL_PORT .. "  treefarm2 " .. CONFIG.FARM_PORT },
    { "Architecture:", tostring((computer.getArchitecture and computer.getArchitecture()) or "?") },
  }
  for i, r in ipairs(rows) do
    label(L, 25 + i, r[1])
    textW(L + FX - 18, 25 + i, LWd - FX + 16, r[2], K.black, K.face)
  end
  note(L, 33, LWd - 2, "Settings save automatically. CONFIG at the top of")
  note(L, 34, LWd - 2, "lymarc.lua holds the defaults and advanced options.")
  button(regions, L, 38, 24, "Reset to defaults", function()
    dialog("Reset Settings", { "Put every setting back to its default?",
      "(Your name goes back to the CONFIG default too.)" }, {
      { "Yes", function()
          SETTINGS.userName, SETTINGS.systemName, SETTINGS.lockMins, SETTINGS.lockStyle = nil, "Lymanos Archive", 30, 1
          SETTINGS.clock24, SETTINGS.desk, SETTINGS.rawDays, SETTINGS.reserveKB = false, 1, nil, nil
          K.desk = DESK_COLORS[1][2]
          PLAYER_NAME = "Player-" .. wlan.address:sub(1, 4)
          saveSettings(); saved = "Settings reset"
        end },
      { "No" } })
  end)

  -- lock screen
  groupBox(R - 2, 5, RWd + 2, 17, "Lock Screen")
  label(R, 7, "Lock after:")
  local m = SETTINGS.lockMins or 0
  cycler(R + FX - 18, 7, 22, m == 0 and "Never" or (m .. " min idle"), function(d)
    SETTINGS.lockMins = step(LOCK_MINS, m, d); LOCK.poke(); changed()
  end)
  label(R, 9, "Style:")
  cycler(R + FX - 18, 9, 22, LOCK.styleName(SETTINGS.lockStyle), function(d)
    SETTINGS.lockStyle = (SETTINGS.lockStyle - 1 + d) % LOCK.styleCount + 1; changed()
  end)
  LOCK.preview(R + FX - 15, 11, 22, 5, SETTINGS.lockStyle)
  note(R, 17, RWd - 2, "Programs keep running while the screen is locked.")
  button(regions, R, 18, 20, "Lock Now", function() LOCK.lock() end)

  -- archive
  groupBox(R - 2, 23, RWd + 2, 20, "Archive")
  local rd = ARC.rawDays()
  label(R, 25, "Keep 5-second:")
  cycler(R + FX - 18, 25, 22, rd .. (rd == 1 and " day" or " days"), function(d)
    SETTINGS.rawDays = step(RAW_DAYS, rd, d); changed()
  end)
  note(R, 26, RWd - 2, "Full-detail .raw files older than this are deleted.")
  local kb = SETTINGS.reserveKB or CONFIG.RESERVE_KB
  label(R, 28, "Keep free:")
  cycler(R + FX - 18, 28, 22, (kb >= 1024 and (floor(kb / 1024) .. " MB") or (kb .. " KB")) .. " / drive", function(d)
    SETTINGS.reserveKB = step(RESERVE, kb, d); changed()
  end)
  note(R, 29, RWd - 2, "Room left empty on every archive drive.")
  label(R, 31, "Storage format:")
  textW(R + FX - 18, 31, RWd - FX + 16, ARC.binary() and "Packed binary (Lua 5.3)" or "Text (Lua 5.2)", K.navy, K.face)
  if ARC.binary() then
    note(R, 32, RWd - 2, "About half the size of text files.")
  else
    note(R, 32, RWd - 2, "Shift-right-click the CPU to Lua 5.3 and restart for")
    note(R, 33, RWd - 2, "packed files (half the size). Old files stay readable.")
  end
  local free, letters = 0, ""
  for _, d in ipairs(ARC.drives()) do ARC.freeOf(d); free = free + d.free; letters = letters .. d.letter .. ": " end
  label(R, 35, "Archive drives:")
  textW(R + FX - 18, 35, RWd - FX + 16, #ARC.drives() == 0 and "none found!" or letters, K.black, K.face)
  label(R, 36, "Free space:")
  textW(R + FX - 18, 36, RWd - FX + 16, humanBytes(free), K.black, K.face)
  button(regions, R, 38, 24, "Save Samples Now", function()
    ARC.flush(); changed("All samples written to disk")
  end)

  -- status bar
  local yy = WY + WH - 2
  fill(WX + 1, yy, WW - 2, 1, K.face)
  textW(WX + 2, yy, WW - 4, saved or "Changes are saved automatically.", saved and K.navy or K.black, K.face)
  saved = nil
end

local function key(ch, code)
  if code == 28 or code == 156 then
    local v = input
    local id = focus
    focus, input = nil, ""
    if id == "user" then setUser(v)
    elseif id == "system" then
      v = v:gsub("^%s+", ""):gsub("%s+$", "")
      SETTINGS.systemName = (v ~= "") and v or "Lymanos"
      changed("System name saved")
    end
  elseif code == 1 then focus, input = nil, ""; drawFields()
  elseif code == 14 then input = input:sub(1, -2); drawFields()
  elseif ch and ch >= 32 and ch < 127 then
    local c = string.char(ch)
    if c:match("[%w %-_%.']") and #input < 16 then input = input .. c; drawFields() end
  end
end

return {
  drawWindow = drawWindow, key = key, drawFields = drawFields,
  focus = function(v) if v == false then focus, input = nil, "" end return focus ~= nil end,
}
end)()

local settingsOpenFlag = false
openSettings = function() settingsOpenFlag = true; activeApp = "settings" end
closeSettings = function() settingsOpenFlag = false; SET.focus(false); activeApp = nil; drawAll() end
settingsOpen = function() return settingsOpenFlag end

drawAll = function(keepOverlay)
  if LOCK.isLocked() then LOCK.draw(); return end
  regions = {}
  SYS.resetRegions()
  if not keepOverlay then overlay = nil end
  drawDesktop()
  if activeApp == "explorer" and explorerOpen then
    FX.draw()
  elseif activeApp == "sys" then
    SYS.drawWindow()
  elseif activeApp == "settings" then
    SET.drawWindow()
  end
  drawTaskbar()
end

openExplorer = function() explorerOpen = true; activeApp = "explorer" end

------------------------------------------------------------- MAIN LOOP
local oldW, oldH = gpu.getResolution()

local function main()
  local mw, mh = gpu.maxResolution()
  if mw < W or mh < H then error("Lymanos Archive needs a tier 3 GPU and screen (160x50).", 0) end
  gpu.setResolution(W, H)
  fill(1, 1, W, H, K.desk)
  textW(1, 24, W, "Starting " .. tostring(SETTINGS.systemName or "Lymanos Archive") .. " - reading the archive...",
    K.white, K.desk, "center")
  ARC.start()
  FX.start()
  drawAll()
  requestUpdate()

  local lastTick = 0
  while running do
    local ev = { event.pull(0.5) }
    breathed()
    local name = ev[1]
    if name == "touch" or name == "drag" or name == "scroll" or name == "key_down" then LOCK.poke() end
    if name == "interrupted" then
      running = false
    elseif name == "key_down" and LOCK.isLocked() then
      LOCK.key(ev[4])
    elseif name == "touch" then
      local x, y = ev[3], ev[4]
      if overlay then
        if not hit(overlay.regions, x, y) and not overlay.modal then closeOverlay() end
      elseif hit(taskRegions, x, y) then
        -- taskbar
      elseif activeApp == "settings" then
        local wasFocus = SET.focus()
        SET.focus(false)
        hit(regions, x, y)
        if wasFocus and not SET.focus() and activeApp == "settings" and not overlay then SET.drawFields() end
      elseif activeApp == "sys" then
        if not hit(SYS.regions(), x, y) then hit(regions, x, y) end
      else
        hit(regions, x, y)
      end
    elseif name == "scroll" and not overlay and not LOCK.isLocked() then
      if activeApp == "sys" then SYS.scroll(ev[3], ev[4], ev[5])
      elseif activeApp == "explorer" and explorerOpen then FX.scroll(ev[3], ev[4], ev[5]) end
    elseif name == "modem_message" then
      local port, tag = ev[4], ev[6]
      if port == CONFIG.FUEL_PORT and tag == "LSCFUEL" then
        ARC.onFuel(ev[8])
      elseif port == CONFIG.FARM_PORT and tag == "TREEFARM" then
        ARC.onFarm(ev[8])
      elseif port == CONFIG.STATS_PORT and tag == "LSCSTATS" then
        if ARC.onStats(ev[3], ev[5], ev[8]) then statusMsg = "New charging cycle archived" end
      end
    elseif name == "key_down" and activeApp == "settings" and SET.focus() and not overlay then
      SET.key(ev[3], ev[4])
    elseif name == "key_down" and activeApp == "explorer" and explorerOpen and not overlay then
      FX.key(ev[3], ev[4])
    elseif (name == "component_added" or name == "component_removed") and ev[3] == "filesystem" then
      ARC.scan()
      statusMsg = (name == "component_added") and "New drive found" or "A drive was removed"
    end

    ARC.tick()

    local up = computer.uptime()
    if running and up - lastTick >= 1 then
      lastTick = up
      local t = now()
      if LOCK.isLocked() then
        LOCK.tick(t)
      elseif not overlay then
        if activeApp == "explorer" and explorerOpen then FX.tick() end
        drawTray()
      end
      SYS.tick(activeApp == "sys" and not overlay and not LOCK.isLocked())
      -- lock after the idle time set in Settings (0 = never)
      local mins = SETTINGS.lockMins or 0
      if mins > 0 and not LOCK.isLocked() and LOCK.idle() >= mins * 60 then LOCK.lock() end
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
local fok, ferr = pcall(ARC.finalFlush)        -- write what is still in RAM
gpu.setResolution(oldW, oldH)
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
term.clear()
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write(tostring(err) .. "\n")
end
if not fok then io.stderr:write("Could not save the last samples: " .. tostring(ferr) .. "\n") end
