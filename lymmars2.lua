--[[
  lymmars.lua / lymearth.lua  -  Lymanos Link
  (Lymanos for a Mars base server, and the Earth computer that talks to it)

  ONE program, two roles. The two files are identical except for the ROLE
  line below - fix something once, copy it to both:
    lymearth.lua   ROLE = "earth"   the computer at home
    lymmars.lua    ROLE = "mars"    the server at the Mars base

  The two talk over a Linked Card (OpenComputers "tunnel" card), which works
  across dimensions. Wireless cards can't reach Mars.

    Earth -> Mars  every wireless packet from the Earth programs listed in
                   CONFIG.RELAY (lscstats, lscfuel, treefarm2) is passed on,
                   so the Logs app on Mars shows the same data as at home.
                   Earth pushes program updates (Start > Update Mars Base)
                   and can restart or reboot the Mars server.
    Mars -> Earth  a status report every 15 s (version, RAM, power, uptime),
                   crash / update reports from lymboot, and the packets of any
                   Mars programs on CONFIG.MARS_PORTS (kept on Earth in
                   /home/lymanos_link.dat for the coming Mars Base app).

  Apps: Logs, GT Graphs (gtgraphs.lua as a full-screen app), My Computer,
        Settings, and Mars Link / Earth Link.
        (Bank, Chess, Brokerage and Casino are not in this build.)

  Mars runs under lymboot.lua (the bootloader). It starts lymmars.lua,
  installs updates sent from Earth (old version kept as lymmars.bak), goes
  back to the old version if a new one crashes in its first 2 minutes, and
  keeps listening for a fix if the program stops - no trip to Mars needed.

  Needs: tier 3 GPU + tier 3 screen (160x50), and one card of a linked pair
  in each computer. Earth also needs a wireless card (to hear lscstats etc.).
  Mars only needs a wireless card if Mars programs should send data home.
  Exit: Start > Shut Down, File > Exit Lymanos, or Ctrl+C.
]]

local ROLE = "mars"               -- "earth" = home computer, "mars" = Mars base server
local LYM_VERSION = "2.4-link1"   -- Earth reads this from the file it sends; shown on both ends

---------------------------------------------------------------- CONFIG
local CONFIG = {
  PORT = 4040,                 -- must match WIRELESS_PORT in lscstats.lua
  SENDER = nil,                -- nil = accept any lscstats computer, or put its card address
  ARCHIVE_MAX = 100,           -- cycles kept in the local archive
  GRAPH_CYCLES = 8,            -- cycles shown in the chart
  STALE_SECONDS = 75,          -- no packet for this long = "Not Responding"
  COPY_FILE = "/home/lscstats_copy.dat",
  ARCHIVE_FILE = "/home/lymanos_archive.dat",
  PLAYER_NAME = nil,           -- default name; normally set in the Settings app

  -- Live feeds for the Logs graphs (wireless broadcasts from other programs)
  FUEL_PORT = 4041,            -- lscfuel.lua (LSC EU in/out, charge %)
  FARM_PORT = 4042,            -- treefarm2.lua (Oak Wood count, farm running / last ON)
  FEED_STALE = 30,             -- seconds without a packet = that feed is offline
  FEED_STEP = 60,              -- graph point every N seconds (averaged); 240 points kept = 4 hours

  -- Earth <-> Mars link (Linked Card)
  -- Earth passes these wireless packets on to Mars:  [port] = { TAG = true }
  -- (add your other Earth programs here later)
  RELAY = {
    [4040] = { LSCSTATS = true },
    [4041] = { LSCFUEL = true },
    [4042] = { TREEFARM = true },
  },
  MARS_PORTS = {},             -- Mars: wireless ports whose packets go home, e.g. { 4050, 4051 }
  MARS_REBROADCAST = true,     -- Mars: repeat Earth's packets on Mars wireless (for gtmars.lua displays)
  MARS_FEED_PORT = 4060,       -- Mars: lymmars status ("LYMMARS") + requests ("LYMMARS_REQ") for gtmars
  MARS_BEAT = 10,              -- Mars: seconds between "LYMMARS" status broadcasts
  LINK_STATUS_EVERY = 15,      -- seconds between status reports (both ends)
  LINK_STALE = 45,             -- no word from the other end for this long = link down
  LINK_FILE = "/home/lymanos_link.dat",    -- other end's status, Mars data (Earth), link events
  MARS_FILE = "/home/lymmars.lua",         -- Earth: the Mars program that "Update Mars Base" sends
  BOOT_FILE = "/home/lymboot.lua",         -- Earth: the bootloader that "Bootloader" sends
  UPDATE_TIMEOUT = 4,          -- seconds to wait for Mars to confirm each piece of an update
  UPDATE_TRIES = 6,            -- tries per piece before the update is given up

  SETTINGS_FILE = "/home/lymanos_settings.dat",   -- written by the Settings app
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

-- SCREEN BUFFER: every app draws into a copy of the screen kept in memory, and
-- gpu.flush() (once per main-loop pass) sends only the cells that changed to
-- the real GPU. The screen never shows a half-drawn frame - no flicker - and
-- redrawing a whole window only costs the cells that actually changed.
-- (~0.5 MB: two copies of the 160x50 screen.)
local rgpu = component.gpu
local gpu
do
  local SW, SH = rgpu.getResolution()
  local P = 16777216                          -- colors packed as fg * P + bg
  local wc, wk, hc, hk = {}, {}, {}, {}       -- wanted / on screen: char, colors
  local lo, hi = {}, {}                       -- per row: columns touched since the last flush
  local cf, cb = 0xFFFFFF, 0x000000           -- colors the program has set
  local rf, rb                                -- colors the real GPU has
  local CH = "[\0-\127\194-\244][\128-\191]*" -- one UTF-8 character
  local function touch(y, a, b)
    if not lo[y] or a < lo[y] then lo[y] = a end
    if not hi[y] or b > hi[y] then hi[y] = b end
  end
  gpu = setmetatable({}, { __index = rgpu })
  function gpu.setForeground(c) local o = cf; cf = c; return o end
  function gpu.setBackground(c) local o = cb; cb = c; return o end
  function gpu.getForeground() return cf end
  function gpu.getBackground() return cb end
  function gpu.set(x, y, s, vertical)
    local k, i = cf * P + cb, 0
    if vertical then
      for ch in s:gmatch(CH) do
        local yy = y + i
        if yy >= 1 and yy <= SH and x >= 1 and x <= SW then
          local idx = (yy - 1) * SW + x
          wc[idx], wk[idx] = ch, k
          touch(yy, x, x)
        end
        i = i + 1
      end
    elseif y >= 1 and y <= SH then
      local base, first = (y - 1) * SW, nil
      for ch in s:gmatch(CH) do
        local xx = x + i
        if xx >= 1 and xx <= SW then wc[base + xx], wk[base + xx] = ch, k; first = first or xx end
        i = i + 1
      end
      if first then touch(y, first, min(SW, x + i - 1)) end
    end
    return true
  end
  function gpu.fill(x, y, w, h, ch)
    local x1, x2, y1, y2 = max(1, x), min(SW, x + w - 1), max(1, y), min(SH, y + h - 1)
    if x1 > x2 or y1 > y2 then return true end
    local k = cf * P + cb
    ch = (ch or " "):match(CH) or " "
    for yy = y1, y2 do
      local base = (yy - 1) * SW
      for xx = x1, x2 do wc[base + xx], wk[base + xx] = ch, k end
      touch(yy, x1, x2)
    end
    return true
  end
  -- move a block of the screen (scrolling): the real GPU moves it in one call,
  -- and both copies of the screen move with it, so only new rows cost anything
  function gpu.copy(x, y, w, h, tx, ty)
    gpu.flush()                                -- the screen shows exactly what's wanted
    local ok = rgpu.copy(x, y, w, h, tx, ty)
    local x1, x2, y1, y2 = max(1, x), min(SW, x + w - 1), max(1, y), min(SH, y + h - 1)
    if x1 > x2 or y1 > y2 then return ok end
    local ys, ye, sy = y1, y2, 1
    if ty > 0 then ys, ye, sy = y2, y1, -1 end
    local xs, xe, sx = x1, x2, 1
    if tx > 0 then xs, xe, sx = x2, x1, -1 end
    for yy = ys, ye, sy do
      local dy = yy + ty
      if dy >= 1 and dy <= SH then
        local sb, db = (yy - 1) * SW, (dy - 1) * SW
        for xx = xs, xe, sx do
          local dx = xx + tx
          if dx >= 1 and dx <= SW then
            local a, b = sb + xx, db + dx
            wc[b], wk[b], hc[b], hk[b] = wc[a], wk[a], hc[a], hk[a]
          end
        end
      end
    end
    return ok
  end
  function gpu.setResolution(w, h)
    local ok = rgpu.setResolution(w, h)
    SW, SH = w, h
    wc, wk, hc, hk, lo, hi, rf, rb = {}, {}, {}, {}, {}, {}, nil, nil
    return ok
  end
  -- send what changed: runs of cells with the same colors become one gpu.set
  -- changed runs are collected first, then sent grouped by color: the GPU's
  -- setBackground / setForeground calls cost more than set, so each color
  -- pair is set once per flush instead of once per run
  local rx, ry, rs, rbg, rfg, ord = {}, {}, {}, {}, {}, {}
  local function byColor(a, b)
    if rbg[a] ~= rbg[b] then return rbg[a] < rbg[b] end
    return rfg[a] < rfg[b]
  end
  function gpu.flush()
    local n = 0
    for y = 1, SH do
      local a = lo[y]
      if a then
        local b = hi[y]
        lo[y], hi[y] = nil, nil
        local base, x = (y - 1) * SW, a
        while x <= b do
          local i = base + x
          local c, k = wc[i], wk[i]
          local hk0 = hk[i]
          if c ~= nil and (c ~= hc[i] or (k ~= hk0 and not (c == " " and hk0 and k % P == hk0 % P))) then
            local bgc = k % P
            local fgc = c ~= " " and (k - bgc) / P or nil
            local parts = { c }
            hc[i], hk[i] = c, k
            local x2 = x + 1
            while x2 <= b do
              local j = base + x2
              local cj, kj = wc[j], wk[j]
              if cj == nil or kj % P ~= bgc then break end
              if cj ~= " " then
                local fj = (kj - bgc) / P
                if fgc and fj ~= fgc then break end
                fgc = fj
              end
              parts[#parts + 1] = cj
              hc[j], hk[j] = cj, kj
              x2 = x2 + 1
            end
            n = n + 1
            rx[n], ry[n], rs[n], rbg[n], rfg[n] = x, y, table.concat(parts), bgc, fgc or -1
            ord[n] = n
            x = x2
          else
            x = x + 1
          end
        end
      end
    end
    if n == 0 then return end
    for i = n + 1, #ord do ord[i] = nil end
    if n > 1 then table.sort(ord, byColor) end
    for k = 1, n do
      local i = ord[k]
      local bgc, fgc = rbg[i], rfg[i]
      if bgc ~= rb then rgpu.setBackground(bgc); rb = bgc end
      if fgc >= 0 and fgc ~= rf then rgpu.setForeground(fgc); rf = fgc end
      rgpu.set(rx[i], ry[i], rs[i])
      rs[i] = nil
    end
  end
end

-- one-time rename of the old lscview files (lscview_x.dat -> lymanos_x.dat)
pcall(function()
  local old = {}
  for name in filesystem.list("/home/") do
    if name:match("^lscview_.+%.dat$") then old[#old + 1] = name end
  end
  for _, name in ipairs(old) do
    local new = "/home/" .. name:gsub("^lscview_", "lymanos_")
    if not filesystem.exists(new) then filesystem.rename("/home/" .. name, new) end
  end
end)

---------------------------------------------------------------- SETTINGS
-- Values changed in the Settings app. They override CONFIG and are saved
-- as a small text table. nil = use the CONFIG default.
local SETTINGS = {
  userName = nil,       -- your name (lock screen greeting)
  systemName = "Lymanos",
  lockMins = 30,        -- auto-lock after this many idle minutes (0 = never)
  lockStyle = 1,        -- lock screen color theme
  clock24 = false,      -- 24-hour clock on the taskbar and lock screen
  desk = 1,             -- desktop color
  logsQ = { "nb", "gaps" },   -- graphs in the Logs app's two panels
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
}

------------------------------------------------------------------ NETWORK
-- Wireless card: Earth hears lscstats / lscfuel / treefarm2 with it.
-- Mars only needs one if Mars programs should send their data home.
local wlan
for addr in component.list("modem") do
  local m = component.proxy(addr)
  if m.isWireless() then wlan = m; break end
end
if not wlan then
  -- a wired network card still works if both computers share a cable network
  local a = component.list("modem")()
  if a then wlan = component.proxy(a) end
end
local hasRadio = wlan ~= nil
if not wlan then
  if ROLE == "earth" then
    io.stderr:write("No network card found. The Earth computer needs a Wireless Network Card (tier 2).\n")
    return { reason = "exit" }
  end
  local function nop() return false end
  wlan = { address = computer.address(), isWireless = nop, open = nop, close = nop, broadcast = nop, send = nop }
end
-- Linked Card: the only thing that reaches the other planet (no linked card = no link)
local TUN = component.list("tunnel")()
TUN = TUN and component.proxy(TUN) or nil

if ROLE == "earth" then
  wlan.open(CONFIG.PORT)
  wlan.open(CONFIG.FUEL_PORT)
  wlan.open(CONFIG.FARM_PORT)
  for p in pairs(CONFIG.RELAY) do wlan.open(p) end
else
  for _, p in ipairs(CONFIG.MARS_PORTS) do wlan.open(p) end
  wlan.open(CONFIG.MARS_FEED_PORT)           -- gtmars displays ask for data here
end
local PLAYER_NAME = SETTINGS.userName or CONFIG.PLAYER_NAME or ("Player-" .. wlan.address:sub(1, 4))
local LINK                        -- the Earth <-> Mars link (below)
local exitReason = nil            -- told to lymboot when the program ends ("update", "restart")

local function requestUpdate()
  if ROLE == "mars" then
    if LINK then LINK.request() end      -- Earth asks lscstats and resends its latest data
  else
    pcall(wlan.broadcast, CONFIG.PORT, "LSCSTATS_REQ")
  end
end

------------------------------------------------------- REAL-WORLD TIME
local TIME_PATHS = { "/tmp/.lymanos_clock", "/home/.lymanos_clock" }
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

----------------------------------------------------------------- STORAGE
local snap = nil          -- latest snapshot from lscstats
local archive = {}        -- all cycles we have seen, oldest first
local lastPacket = nil    -- our time of last packet
local lastFrom, lastDist = nil, nil

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

local function saveArchive()
  writeFile(CONFIG.ARCHIVE_FILE, serialization.serialize({
    cycles = archive, lastPacket = lastPacket, lastFrom = lastFrom }))
end

local function mergeCycles(cycles)
  local byStart = {}
  for _, c in ipairs(archive) do byStart[tostring(c.start)] = c end
  local changed = false
  for _, c in ipairs(cycles or {}) do
    if not byStart[tostring(c.start)] then
      archive[#archive + 1] = c
      byStart[tostring(c.start)] = c
      changed = true
    end
  end
  table.sort(archive, function(a, b) return a.start < b.start end)
  while #archive > CONFIG.ARCHIVE_MAX do table.remove(archive, 1) end
  return changed
end

local function loadSaved()
  local raw = readFile(CONFIG.ARCHIVE_FILE)
  if raw then
    local ok, t = pcall(serialization.unserialize, raw)
    if ok and type(t) == "table" then
      archive = t.cycles or {}
      lastPacket, lastFrom = t.lastPacket, t.lastFrom
    end
  end
  raw = readFile(CONFIG.COPY_FILE)
  if raw then
    local ok, t = pcall(serialization.unserialize, raw)
    if ok and type(t) == "table" then
      snap = t
      senderClockOK = t.clockOK ~= false
      mergeCycles(t.cycles)
    end
  end
end

-- returns true if the cycle list changed
local function receive(from, dist, payload)
  local ok, t = pcall(serialization.unserialize, payload)
  if not ok or type(t) ~= "table" then return false end
  writeFile(CONFIG.COPY_FILE, payload)        -- exact copy of the log data
  snap = t
  senderClockOK = t.clockOK ~= false
  lastPacket, lastFrom, lastDist = now(), from, dist
  local changed = mergeCycles(t.cycles)
  if changed then saveArchive() end      -- not on every packet: saving builds a big string
  return changed
end

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

------------------------------------------------------------------ STATE
local running = true
local activeApp = "viewer"    -- window in front: "viewer" | "sys" | "settings" | nil (desktop)
local scroll = 0              -- list scroll offset (rows)
local selected = nil          -- selected cycle start time (key)
local statusMsg = "Ready"
local lockedFlag = false      -- lock screen up (set by LOCK)

-- Window geometry
local WX, WY, WW, WH = 14, 2, 144, 44

local function responding(t)
  return lastPacket and (t - lastPacket) <= CONFIG.STALE_SECONDS
end

--------------------------------------------------------------- DESKTOP
local function drawIcon(x, y, kind, label)
  if kind == "pc" then
    fill(x + 1, y, 6, 2, K.face)
    fill(x + 2, y, 4, 1, K.navy)
    fill(x + 2, y + 1, 4, 1, K.navy)
    fill(x + 2, y + 2, 4, 1, K.face)
  elseif kind == "doc" then
    fill(x + 2, y, 4, 3, K.white)
    text(x + 2, y, "▀▀▀", K.sh, K.white)
    text(x + 2, y + 1, "≡≡≡", K.navy, K.white)
    text(x + 5, y, "◣", K.sh, K.white)
  elseif kind == "bin" then
    text(x + 2, y, "▄▄▄▄", K.sh, K.desk)
    fill(x + 2, y + 1, 4, 2, K.face)
    text(x + 2, y + 1, "║║║║", K.sh, K.face)
  end
  textW(x - 2, y + 3, 12, label, K.white, K.desk, "center")
end

local drawAll                                            -- forward
local openSysApp, closeSysApp, sysAppOpen                -- forward (My Computer)
local openSettings, closeSettings, settingsOpen          -- forward (Settings)
local LOCK, SET, GT                                      -- lock screen, Settings, GT Graphs (below)
local openGraphs, graphsOpen = nil, false                -- GT Graphs app

-- link icon: Earth's desktop shows Mars, Mars's desktop shows Earth
local function drawPlanet(x, y)
  local cv = newCanvas(8, 6, K.desk)
  for py = 1, 6 do
    for px = 1, 8 do
      local dx, dy = (px - 4.5) / 4, (py - 3.5) / 3
      if dx * dx + dy * dy <= 1 then
        local c
        if ROLE == "earth" then        -- Mars: rust red, darker patches
          c = ((px + py) % 5 == 0 or (px == 3 and py == 2)) and 0x8A2E14 or 0xC1440E
        else                           -- Earth: blue sea, green land
          c = ((px <= 4 and py >= 3) or (px == 6 and py == 2)) and 0x2E8B3A or 0x1E5AA8
        end
        cset(cv, px, py, c)
      end
    end
  end
  crender(cv, x, y)
end

local function drawDesktop()
  fill(1, 1, W, 46, K.desk)
  drawIcon(3, 2, "pc", "My Computer")
  drawIcon(3, 8, "doc", "Logs")
  region(regions, 1, 2, 12, 5, function() openSysApp(); drawAll() end)
  region(regions, 1, 8, 12, 5, function() activeApp = "viewer"; drawAll() end)
  drawPlanet(4, 14)
  textW(1, 17, 12, ROLE == "earth" and "Mars Link" or "Earth Link", K.white, K.desk, "center")
  region(regions, 1, 14, 12, 4, function() LINK.dialog() end)
  -- Settings icon: a little control panel with sliders
  fill(4, 20, 8, 3, K.face)
  text(4, 20, "─●──────", K.navy, K.face)
  text(4, 21, "────●───", K.navy, K.face)
  text(4, 22, "──────●─", K.navy, K.face)
  textW(1, 23, 12, "Settings", K.white, K.desk, "center")
  region(regions, 1, 20, 12, 4, function() openSettings(); drawAll() end)
  -- GT Graphs icon: a little dark graph panel
  fill(4, 26, 8, 3, 0x161616)
  text(4, 26, "    ▗▞▀", 0x00C8FF, 0x161616)
  text(4, 27, "▁▗▄▞   ", 0xC8964B, 0x161616)
  text(4, 28, "▔▔▔▔▔▔▔▔", 0x6E6E6E, 0x161616)
  textW(1, 29, 12, "GT Graphs", K.white, K.desk, "center")
  region(regions, 1, 26, 12, 4, function() openGraphs(); drawAll() end)
  drawIcon(3, 43, "bin", "Recycle Bin")
end

----------------------------------------------------------------- TASKBAR

-- tray: lscstats signal, the Earth/Mars link, the clock
local function drawTray(t)
  if activeApp == "graphs" then return end      -- full-screen GT Graphs has its own taskbar
  bevel(132, 48, 28, 3, "sunken", K.face, K.face)
  local ok = responding(t)
  text(134, 49, "((•))", ok and K.green or K.sh, K.face)
  local up, busy = LINK.state()
  text(140, 49, ROLE == "earth" and "⇄MARS " or "⇄EARTH", busy and K.navy or (up and K.green or K.red), K.face)
  textW(148, 49, 11, fmtTray(t), K.black, K.face, "right")
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

local function drawTaskbar(t)
  taskRegions = {}
  fill(1, 47, W, 4, K.face)
  text(1, 47, string.rep("▔", W), K.hi, K.face)
  button(taskRegions, 1, 48, 9, "◆ Start", function() openStartMenu() end, overlay and overlay.start)
  local list = { { " ▣ Logs", "viewer" } }
  if graphsOpen then list[#list + 1] = { " ▦ GT Graphs", "graphs" } end
  if sysAppOpen and sysAppOpen() then list[#list + 1] = { " ▣ My Computer", "sys" } end
  if settingsOpen and settingsOpen() then list[#list + 1] = { " ▣ Settings", "settings" } end
  local bw = min(25, floor(118 / #list) - 1)      -- buttons shrink when many apps are open
  for i, it in ipairs(list) do taskButton(11 + (i - 1) * (bw + 1), bw, it[1], it[2]) end
  drawTray(t)
  region(taskRegions, 139, 48, 8, 3, function() LINK.dialog() end)   -- click the link light
end

local about, confirmClear   -- defined with the dialogs below

-------------------------------------------------------------- LOGS APP
-- Dark "monitor" look (same style as gtgraphs) inside the 98 window.
-- Left: Overview / Lists tabs. Right: two graph panels, each with a dropdown.
local LG = (function()
local G = {
  bg = 0x0B0B0B, panel = 0x161616, panel2 = 0x242424, header = 0x0E2A38,
  text = 0xE6E6E6, dim = 0x8C8C8C, dark = 0x000000, accent = 0x00C8FF,
  good = 0x3FE06A, warn = 0xFFB000, bad = 0xFF4D4D, grid = 0x333333,
  axis = 0x6E6E6E, button = 0x2E4A5A, track = 0x2A2A2A,
}
local X0, CW = WX + 1, WW - 2                         -- content x / width
local TY, CY, CB, SY = WY + 3, WY + 4, WY + WH - 3, WY + WH - 2   -- tabs, top, bottom, status
local LW = 62                                         -- left pane width
local RX, RW = X0 + LW + 1, CW - LW - 1               -- right pane
local QH = floor((CB - CY + 1) / 2)                   -- graph panel height
local NB_COLOR = 0xE8C547
local tab = "overview"
local lastQuads = 0

-- graphs for the right-hand panels. "feed" graphs get their numbers from
-- LG.push(key, value) - nothing sends those yet (future updates).
local GRAPHS = {
  { key = "nb",    label = "Nitrobenzene per cycle", color = NB_COLOR },
  { key = "gaps",  label = "Time between charges",   color = 0xFF8A3D },
  { key = "dur",   label = "Charge duration",        color = 0x5AD1A0 },
  { key = "euout", label = "LSC EU out",             color = 0x00C8FF, feed = "lscfuel", unit = " EU/t" },
  { key = "euin",  label = "LSC EU in",              color = 0xB07CFF, feed = "lscfuel", unit = " EU/t" },
  { key = "oak",   label = "Oak Wood in AE2",        color = 0xC8964B, feed = "treefarm2" },
}
local LISTS = { { key = "cycles", label = "LSC charging cycles" } }   -- more log lists later

local series = {}        -- feed data, created only when a reading arrives
local SERIES_MAX = 240

local function graphOf(key)
  for _, g in ipairs(GRAPHS) do if g.key == key then return g end end
  return GRAPHS[1]
end

local function niceMax(v)
  if v <= 0 then return 1 end
  local e = 10 ^ floor(math.log(v, 10))
  for _, m in ipairs({ 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 }) do
    if v <= m * e then return m * e end
  end
  return 10 * e
end

local function shortNum(n)
  local a = math.abs(n)
  if a >= 1e12 then return string.format("%.2fT", n / 1e12)
  elseif a >= 1e9 then return string.format("%.2fG", n / 1e9)
  elseif a >= 1e6 then return string.format("%.2fM", n / 1e6)
  elseif a >= 1e3 then return string.format("%.1fK", n / 1e3) end
  return string.format("%d", floor(n + 0.5))
end

local function fmtShort(s)        -- at most 5 characters
  s = max(0, floor(s + 0.5))
  if s < 60 then return s .. "s" end
  if s < 3600 then return floor(s / 60) .. "m" end
  if s < 86400 then return string.format("%dh%02d", floor(s / 3600), floor(s % 3600 / 60)) end
  return string.format("%dd%02d", floor(s / 86400), floor(s % 86400 / 3600))
end

local function axisDur(s)
  s = max(0, floor(s + 0.5))
  if s < 60 then return s .. "s" end
  if s < 3600 then return string.format("%dm%02ds", floor(s / 60), s % 60) end
  if s < 86400 then return string.format("%dh%02dm", floor(s / 3600), floor(s % 3600 / 60)) end
  return string.format("%dd%02dh", floor(s / 86400), floor(s % 86400 / 3600))
end

local function stamp(t)           -- "11/06 11:56 PM"
  if not t then return "--" end
  if not senderClockOK then return "up " .. fmtDur(t) end
  local e = toEastern(t)
  if SETTINGS.clock24 then return string.format("%02d/%02d %02d:%02d", e.month, e.day, e.hour, e.min) end
  local h, ap = h12(e)
  return string.format("%02d/%02d %2d:%02d %s", e.month, e.day, h, e.min, ap)
end

-- colored pieces left, dim text right-aligned, the rest padded (no flicker)
local function segs(x, y, w, list, right, b)
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
  if rw > 0 then text(x + w - rw, y, right, G.dim, b) end
end

-- one row of text with labels centered on given columns
local function labelRow(width, items)
  local chars = {}
  for i = 1, width do chars[i] = " " end
  for _, it in ipairs(items) do
    local lab = it[2]
    local len = unicode.len(lab)
    local lx = max(1, min(it[1] - floor(len / 2), width - len + 1))
    for i = 1, len do chars[lx + i - 1] = unicode.sub(lab, i, i) end
  end
  return table.concat(chars)
end

local function panel(x, y, w, h, title, color, right)
  fill(x, y, w, h, G.panel)
  fill(x, y, w, 1, color)
  text(x, y, " " .. title .. " ", G.dark, color)
  if right then textW(x + w - unicode.len(right) - 1, y, unicode.len(right), right, G.dark, color) end
end

local function kvd(x, y, w, label, value, col)
  textW(x, y, 15, label, G.dim, G.panel)
  textW(x + 15, y, w - 15, value, col or G.text, G.panel)
end

local function selectedCycle()
  if not selected then return nil end
  for _, c in ipairs(archive) do if c.start == selected then return c end end
end

local function pick(c)
  selected = (c and selected ~= c.start) and c.start or nil
  drawAll()
end

-- idle gaps between back-to-back cycles: { cycle, seconds }
local function gapsList()
  local g = {}
  for i = 2, #archive do
    local a, b = archive[i - 1], archive[i]
    local consecutive = not (a.id and b.id) or b.id == a.id + 1
    if consecutive and a.stop and b.start > a.stop then g[#g + 1] = { b, b.start - a.stop } end
  end
  return g
end

local function lastStop()
  return (snap and snap.lastStop) or (archive[#archive] and archive[#archive].stop)
end

------------------------------------------------------------ OVERVIEW
local LIVE_Y, TOT_Y, REC_Y = CY, CY + 6, CY + 21

local function drawLiveRows(t)
  local x, w = X0 + 2, LW - 4
  local y = LIVE_Y + 1
  local ok = responding(t)
  local conn = not lastPacket and { "○ WAITING FOR LSCSTATS", G.dim }
    or (ok and { "● ONLINE", G.good } or { "● NOT RESPONDING", G.bad })
  segs(x, y, w, { conn, { lastPacket and ("   packet " .. fmtDurLong(t - lastPacket) .. " ago") or "", G.dim } },
    lastFrom and (tostring(lastFrom):sub(1, 8) .. (lastDist and ("  " .. floor(lastDist + 0.5) .. " blocks")
      or (ROLE == "mars" and "  via Earth" or ""))) or "")
  local chg = snap and snap.signalOn
  segs(x, y + 1, w, { { "FUEL ", G.dim }, { snap and (chg and "CHARGING" or "IDLE") or "--", chg and G.good or G.text },
    { "    BURN RATE ", G.dim }, { snap and (commas(snap.rate or 0) .. " L/s") or "--", G.text } })
  local cur = chg and snap.current or nil
  if cur then
    local el = t - cur.start
    segs(x, y + 2, w, { { "CYCLE ", G.dim }, { "#" .. tostring(cur.id), G.accent }, { "   ELAPSED ", G.dim },
      { fmtDur(el), G.text }, { "   NB SO FAR ", G.dim }, { commas(el * (snap.rate or 0)) .. " L", NB_COLOR } })
  else
    local ls = lastStop()
    segs(x, y + 2, w, { { "NO CYCLE RUNNING", G.dim },
      { ls and ("   idle for " .. fmtDurLong(t - ls)) or "", G.text } })
  end
end

local function drawTotals()
  local x, w = X0, LW
  panel(x, TOT_Y, w, 14, "ARCHIVE TOTALS", G.accent, #archive .. " / " .. CONFIG.ARCHIVE_MAX .. " cycles")
  local n = #archive
  local tot, totDur, longest, shortest = 0, 0, 0, math.huge
  for _, c in ipairs(archive) do
    tot, totDur = tot + (c.used or 0), totDur + (c.dur or 0)
    longest, shortest = max(longest, c.dur or 0), min(shortest, c.dur or 0)
  end
  local gaps, gsum = gapsList(), 0
  for _, g in ipairs(gaps) do gsum = gsum + g[2] end
  local c1, c2 = x + 2, x + 31
  local y = TOT_Y + 2
  kvd(c1, y, 28, "Total NB:", commas(tot) .. " L", NB_COLOR)
  kvd(c2, y, 29, "Avg NB/cycle:", n > 0 and (commas(tot / n) .. " L") or "--")
  kvd(c1, y + 1, 28, "Avg duration:", n > 0 and fmtDurLong(totDur / n) or "--")
  kvd(c2, y + 1, 29, "Avg idle gap:", #gaps > 0 and fmtDurLong(gsum / #gaps) or "--")
  kvd(c1, y + 2, 28, "Longest:", n > 0 and fmtDurLong(longest) or "--")
  kvd(c2, y + 2, 29, "Shortest:", n > 0 and fmtDurLong(shortest) or "--")
  kvd(c1, y + 3, 28, "Total time:", n > 0 and fmtDurLong(totDur) or "--")
  kvd(c2, y + 3, 29, "Cycles:", tostring(n))
  kvd(c1, y + 4, 58, "First cycle:", n > 0 and stamp(archive[1].start) or "--")
  kvd(c1, y + 5, 58, "Latest cycle:", n > 0 and stamp(archive[n].start) or "--")
  kvd(c1, y + 6, 58, "Files:", CONFIG.COPY_FILE:match("[^/]+$") .. ", " .. CONFIG.ARCHIVE_FILE:match("[^/]+$"))
  text(x + 2, y + 8, string.rep("─", w - 4), G.grid, G.panel)
  local c = selectedCycle()
  if c then
    segs(x + 2, y + 9, w - 4, { { "SELECTED ", G.dim }, { "#" .. tostring(c.id), G.accent },
      { "   " .. fmtDurLong(c.dur or 0), G.text }, { "   " .. commas(c.used or 0) .. " L", NB_COLOR } })
    segs(x + 2, y + 10, w - 4, { { stamp(c.start) .. "  ->  " .. stamp(c.stop), G.dim } })
  else
    segs(x + 2, y + 9, w - 4, { { "Click a cycle in a list or graph to see it here.", G.dim } })
    segs(x + 2, y + 10, w - 4, {})
  end
end

local function drawRecent()
  local x, w = X0, LW
  local h = CB - REC_Y + 1
  panel(x, REC_Y, w, h, "RECENT CYCLES", NB_COLOR, "newest first")
  local rows = h - 2
  local n = #archive
  local mx = 1
  for i = max(1, n - rows + 1), n do mx = max(mx, archive[i].used or 0) end
  local barW = 18
  for r = 1, rows do
    local c = archive[n - r + 1]
    local y = REC_Y + r + 1
    if c then
      local sel = c.start == selected
      local b = sel and G.button or G.panel
      local len = floor((c.used or 0) / mx * barW + 0.5)
      segs(x + 1, y, w - 2, {
        { sel and "►" or " ", G.accent }, { string.format("%-5s", "#" .. tostring(c.id)), G.accent },
        { string.format("%-16s", stamp(c.start)), G.text }, { string.format("%-9s", fmtDur(c.dur or 0)), G.dim },
        { string.rep("█", len), NB_COLOR }, { string.rep("░", barW - len) .. " ", G.track },
        { shortL(c.used or 0) .. " L", NB_COLOR } }, nil, b)
      region(regions, x + 1, y, w - 2, 1, function() pick(c) end)
    elseif r == 1 then
      segs(x + 2, y, w - 4, { { "No cycles yet. Press REQUEST UPDATE.", G.dim } })
    end
  end
end

--------------------------------------------------------------- LISTS
local LCOLS = { { "#", 5 }, { "Started", 15 }, { "Stopped", 15 }, { "Duration", 8 }, { "NB used L", 11 } }
local LROWS = CB - CY - 6
local listScroll = 0

local function drawListRows()
  local x, w = X0 + 1, LW - 3
  local n = #archive
  local maxScroll = max(0, n - LROWS)
  listScroll = max(0, min(listScroll, maxScroll))
  for r = 1, LROWS do
    local c = archive[n - listScroll - r + 1]
    local y = CY + 2 + r
    if c then
      local sel = c.start == selected
      local b = sel and G.button or ((r % 2 == 0) and 0x1B1B1B or G.panel)
      local cells = { (sel and "►" or " ") .. "#" .. tostring(c.id), stamp(c.start), stamp(c.stop),
                      fmtDur(c.dur or 0), commas(c.used or 0) }
      local cx = x
      for i, col in ipairs(LCOLS) do
        textW(cx, y, col[2], cells[i], i == 5 and NB_COLOR or (i == 1 and G.accent or G.text), b, i >= 4 and "right" or nil)
        cx = cx + col[2]
        text(cx, y, " ", nil, b)
        cx = cx + 1
      end
      fill(cx, y, x + w - cx, 1, b)
    else
      fill(x, y, w, 1, G.panel)
      if r == 1 and n == 0 then textW(x, y, w, "No cycles received yet. Press REQUEST UPDATE.", G.dim, G.panel, "center") end
    end
  end
  -- scrollbar
  local sx = X0 + LW - 2
  text(sx, CY + 3, "▲", G.text, G.button)
  text(sx, CY + 2 + LROWS, "▼", G.text, G.button)
  vtext(sx, CY + 4, string.rep("░", LROWS - 2), G.axis, G.track)
  if maxScroll > 0 then
    text(sx, CY + 4 + floor((LROWS - 3) * listScroll / maxScroll + 0.5), "█", G.accent, G.track)
  end
  -- selected cycle details
  local c = selectedCycle()
  local dy = CB - 2
  if c then
    segs(X0 + 2, dy, LW - 4, { { "SELECTED ", G.dim }, { "#" .. tostring(c.id), G.accent },
      { "   " .. fmtDurLong(c.dur or 0) .. "   rate " .. commas(c.rate or 0) .. " L/s", G.text } })
    segs(X0 + 2, dy + 1, LW - 4, { { "Used " .. commas(c.used or 0) .. " L   " .. fmtStamp(c.start), NB_COLOR } })
  else
    segs(X0 + 2, dy, LW - 4, { { "Click a row to select a cycle.", G.dim } })
    segs(X0 + 2, dy + 1, LW - 4, { { #archive .. " cycles stored (newest first). Scroll with the wheel.", G.dim } })
  end
end

local function listDropdown()
  overlay = { regions = {} }
  drawAll(true)
  local x, y, w = X0 + 2, CY + 1, 40
  fill(x, y, w, #LISTS + 2, G.panel2)
  for j, l in ipairs(LISTS) do
    local on = l.key == "cycles"
    textW(x + 1, y + j, w - 2, (on and " ● " or " ○ ") .. l.label, on and G.dark or G.text, on and NB_COLOR or G.panel2)
    region(overlay.regions, x, y + j, w, 1, function() overlay = nil; drawAll() end)
  end
end

local function drawLists()
  panel(X0, CY, LW, CB - CY + 1, "LOG LISTS  ▼ LSC CHARGING CYCLES", NB_COLOR, #archive .. " entries")
  region(regions, X0, CY, 36, 1, listDropdown)
  local cx = X0 + 1
  for _, col in ipairs(LCOLS) do
    textW(cx, CY + 2, col[2] + 1, col[1], G.dim, G.panel)
    cx = cx + col[2] + 1
  end
  text(X0 + 1, CY + 2 + LROWS + 1, string.rep("─", LW - 2), G.grid, G.panel)
  for r = 1, LROWS do
    region(regions, X0 + 1, CY + 2 + r, LW - 3, 1, function()
      local c = archive[#archive - listScroll - r + 1]
      if c then pick(c) end
    end)
  end
  region(regions, X0 + LW - 2, CY + 3, 1, 1, function() listScroll = listScroll - 1; drawListRows() end)
  region(regions, X0 + LW - 2, CY + 2 + LROWS, 1, 1, function() listScroll = listScroll + 1; drawListRows() end)
  drawListRows()
end

-------------------------------------------------------------- GRAPHS
local function quadRect(i) return { x = RX, y = CY + (i - 1) * QH, w = RW, h = QH } end

-- bar chart: items = { { v, label, sub, cycle } }, live = optional growing bar
local function drawBars(P, g, items, axisFmt, stats, right, live, empty)
  segs(P.x + 2, P.y + 1, P.w - 4, stats, right)
  local LABW = 8
  local gx, gy = P.x + LABW + 2, P.y + 2
  local cw, rows = P.w - LABW - 4, 12
  local ph = rows * 2
  local mx, sum = 0, 0
  for _, it in ipairs(items) do mx, sum = max(mx, it[1]), sum + it[1] end
  local avg = #items > 0 and sum / #items or nil
  local ymax = niceMax(max(mx, live or 0, 1) * 1.1)
  local function py(v) return ph - 1 - floor(v / ymax * (ph - 3) + 0.5) end
  local cv = newCanvas(cw, ph, G.panel)
  for k = 1, 4 do
    local yy = py(ymax * k / 4)
    for xx = 3, cw, 3 do cset(cv, xx, yy, G.grid) end
  end
  local nb = #items + (live and 1 or 0)
  local slotW = min(10, floor((cw - 2) / max(nb, 6)))
  local barW = slotW >= 4 and slotW - 2 or max(1, slotW - 1)
  local function barX(i) return 3 + (i - 1) * slotW end
  for i, it in ipairs(items) do
    local sel = it[4] and it[4].start == selected
    local col = sel and 0xFFFFFF or g.color
    local yt = py(it[1])
    for xx = barX(i), barX(i) + barW - 1 do
      cset(cv, xx, yt, lerp(col, 0xFFFFFF, 0.4))
      for yy = yt + 1, ph - 1 do
        cset(cv, xx, yy, lerp(col, G.panel, 0.05 + 0.6 * (yy - yt) / max(1, ph - 1 - yt)))
      end
    end
    if it[4] then
      local c = it[4]
      region(regions, gx + barX(i) - 1, gy, barW, rows + 2, function() pick(c) end)
    end
  end
  if live then
    local yt, hatch = py(live), lerp(G.accent, G.panel, 0.45)
    for xx = barX(nb), barX(nb) + barW - 1 do
      cset(cv, xx, yt, G.accent)
      for yy = yt + 1, ph - 1 do if (yy - yt) % 2 == 0 then cset(cv, xx, yy, hatch) end end
    end
  end
  if avg then
    local yy = py(avg)
    for xx = 2, cw do if xx % 4 < 2 then cset(cv, xx, yy, G.dim) end end
  end
  for yy = 1, ph do cset(cv, 1, yy, G.axis) end
  for xx = 1, cw do cset(cv, xx, ph, G.axis) end
  crender(cv, gx, gy)
  for k = 0, 4 do
    local lv = ymax * k / 4
    textW(P.x + 1, gy + floor((py(lv) - 1) / 2), LABW, axisFmt(lv), G.dim, G.panel, "right")
  end
  if nb == 0 then textW(gx + 2, gy + 5, cw - 4, empty, G.dim, G.panel, "center") end
  local ids, subs = {}, {}
  local maxLab = max(1, slotW - (slotW >= 5 and 1 or 0))
  for i, it in ipairs(items) do
    local cxm = barX(i) + floor(barW / 2)
    ids[#ids + 1] = { cxm, unicode.sub(it[2], 1, maxLab) }
    subs[#subs + 1] = { cxm, unicode.sub(it[3], 1, maxLab) }
  end
  if live then
    local cxm = barX(nb) + floor(barW / 2)
    ids[#ids + 1] = { cxm, unicode.sub("now", 1, maxLab) }
    subs[#subs + 1] = { cxm, unicode.sub(fmtShort(live), 1, maxLab) }
  end
  text(gx, gy + rows, labelRow(cw, ids), G.text, G.panel)
  text(gx, gy + rows + 1, labelRow(cw, subs), g.color, G.panel)
  segs(P.x + 2, gy + rows + 2, P.w - 4, { { "▀ ", g.color }, { "per cycle   ", G.dim }, { "-- ", G.dim },
    { "average   ", G.dim }, { "click a bar to select it", G.dim } })
end

local function lastN(list, n)
  local out = {}
  for i = max(1, #list - n + 1), #list do out[#out + 1] = list[i] end
  return out
end

local function drawCycleGraph(P, g, t)
  local nbars = CONFIG.GRAPH_CYCLES or 8
  if g.key == "gaps" then
    local items, gs = {}, lastN(gapsList(), nbars)
    local sum, mn = 0, math.huge
    for _, x in ipairs(gs) do
      items[#items + 1] = { x[2], "#" .. tostring(x[1].id), fmtShort(x[2]), x[1] }
      sum, mn = sum + x[2], min(mn, x[2])
    end
    local live
    local ls = lastStop()
    if snap and snap.signalOn == false and ls and responding(t) then live = max(0, t - ls) end
    drawBars(P, g, items, axisDur, {
      { "LATEST ", G.dim }, { #gs > 0 and fmtDurLong(gs[#gs][2]) or "--", g.color },
      { "   AVG ", G.dim }, { #gs > 0 and fmtDurLong(sum / #gs) or "--", G.text },
      { "   MIN ", G.dim }, { #gs > 0 and fmtDurLong(mn) or "--", G.text } },
      #gs .. " gaps", live, "Needs two back-to-back charging cycles...")
  else
    local list = lastN(archive, nbars)
    local items, sum = {}, 0
    for _, c in ipairs(list) do
      local v = g.key == "nb" and (c.used or 0) or (c.dur or 0)
      items[#items + 1] = { v, "#" .. tostring(c.id), g.key == "nb" and shortL(v) or fmtShort(v), c }
      sum = sum + v
    end
    local f = g.key == "nb" and function(v) return shortL(v) .. " L" end or fmtDurLong
    drawBars(P, g, items, g.key == "nb" and shortL or axisDur, {
      { "LATEST ", G.dim }, { #list > 0 and f(items[#items][1]) or "--", g.color },
      { "   AVG ", G.dim }, { #list > 0 and f(sum / #list) or "--", G.text } },
      "last " .. #list .. " cycles", nil, "Waiting for charging cycles from lscstats...")
  end
end

-- live feeds ---------------------------------------------------------
local feed = { fuel = nil, fuelAt = nil, farm = nil, farmAt = nil, lastOn = nil, onSince = nil }
local latest, bucket = {}, {}

local function fresh(at) return at ~= nil and now() - at <= (CONFIG.FEED_STALE or 30) end

local function pushPoint(key, v, t)
  local s = series[key]
  if not s then s = { t = {}, v = {} }; series[key] = s end
  if #s.v >= SERIES_MAX then table.remove(s.t, 1); table.remove(s.v, 1) end
  s.t[#s.t + 1], s.v[#s.v + 1] = t, v
end

-- every reading is averaged into one graph point per FEED_STEP seconds
local function record(key, v, t)
  if type(v) ~= "number" then return end
  latest[key] = v
  local b = bucket[key]
  local stepS = CONFIG.FEED_STEP or 60
  if not b then
    bucket[key] = { start = t, sum = 0, n = 0 }
    pushPoint(key, v, t)                         -- first point right away
    return
  end
  b.sum, b.n = b.sum + v, b.n + 1
  if t - b.start >= stepS then
    pushPoint(key, b.sum / b.n, t)
    b.start, b.sum, b.n = t, 0, 0
  end
end

local function unpackPayload(payload)
  local ok, s = pcall(serialization.unserialize, payload)
  if ok and type(s) == "table" then return s end
end

-- lscfuel.lua packet (port 4041, "LSCFUEL")
local function onFuel(payload)
  local s = unpackPayload(payload)
  if not s then return end
  local t = now()
  feed.fuel, feed.fuelAt = s, t
  if s.online ~= false then
    record("euout", s.avgOut, t)
    record("euin", s.avgIn, t)
  end
end

-- treefarm2.lua packet (port 4042, "TREEFARM")
local function onFarm(payload)
  local s = unpackPayload(payload)
  if not s then return end
  local t = now()
  feed.farm, feed.farmAt = s, t
  record("oak", s.oak, t)
  if s.active then
    if not feed.onSince then feed.onSince = s.runningFor and (t - s.runningFor) or t end
    feed.lastOn = t
  else
    feed.onSince = nil
    if s.lastActiveAgo then
      local seen = t - s.lastActiveAgo
      if not feed.lastOn or seen > feed.lastOn then feed.lastOn = seen end
    end
  end
end

-- one line under a feed graph: where the data comes from + its state
local function feedInfo(g, t)
  if g.feed == "lscfuel" then
    local f = feed.fuel
    if not f then return { { "Waiting for lscfuel " .. (ROLE == "mars" and "(relayed by Earth)"
      or ("on port " .. CONFIG.FUEL_PORT .. " (needs its wireless card)")), G.warn } } end
    if not fresh(feed.fuelAt) then return { { "lscfuel silent for " .. fmtDurLong(t - feed.fuelAt) .. " - is it running?", G.bad } } end
    if f.online == false then return { { "lscfuel says the LSC is not responding", G.bad } } end
    local out = {}
    if f.percent then out[#out + 1] = { string.format("Stored %.1f%%", f.percent), G.text } end
    if f.avgIn and f.avgOut then
      local net = f.avgIn - f.avgOut
      out[#out + 1] = { "   Net " .. (net >= 0 and "+" or "-") .. shortNum(math.abs(net)) .. " EU/t", net >= 0 and G.good or G.warn }
    end
    if f.outputOn then out[#out + 1] = { "   CHARGING", G.good } end
    if f.nitro then out[#out + 1] = { "   NB in AE2 " .. shortL(f.nitro) .. " L", NB_COLOR } end
    return out
  else
    local f = feed.farm
    if not f then return { { "Waiting for treefarm2 " .. (ROLE == "mars" and "(relayed by Earth)"
      or ("on port " .. CONFIG.FARM_PORT .. " (needs its wireless card)")), G.warn } } end
    if not fresh(feed.farmAt) then
      return { { "treefarm2 silent for " .. fmtDurLong(t - feed.farmAt), G.bad },
               { feed.lastOn and ("   farm last ON " .. stamp(feed.lastOn)) or "", G.dim } }
    end
    if f.found == false then return { { "treefarm2 can't find the Industrial Tree Farm", G.bad } } end
    if f.active then
      return { { "● FARM RUNNING", G.good }, { feed.onSince and ("   since " .. stamp(feed.onSince)) or "", G.text } }
    end
    if feed.lastOn then
      return { { "Farm last ON ", G.dim }, { stamp(feed.lastOn), g.color }, { "   (" .. fmtDurLong(t - feed.lastOn) .. " ago)", G.dim } }
    end
    return { { f.allowed == false and "Farm disabled - not seen running yet" or "Farm idle - not seen running yet", G.dim } }
  end
end

-- line graph for data feeds
local function drawFeed(P, g)
  local s = series[g.key]
  local n = s and #s.v or 0
  local LABW = 8
  local gx, gy = P.x + LABW + 2, P.y + 2
  local cw, rows = P.w - LABW - 4, 13
  local ph = rows * 2
  local t = now()
  local mx, mn = 0, math.huge
  for i = 1, n do mx, mn = max(mx, s.v[i]), min(mn, s.v[i]) end
  local live = fresh(g.feed == "lscfuel" and feed.fuelAt or feed.farmAt)
  local cur = latest[g.key]
  local fmt = g.key == "oak" and commas or shortNum
  segs(P.x + 2, P.y + 1, P.w - 4, n > 0 and {
    { "NOW ", G.dim }, { (live and cur) and (fmt(cur) .. (g.unit or "")) or "--", g.color },
    { "   MIN ", G.dim }, { shortNum(mn), G.text }, { "   MAX ", G.dim }, { shortNum(mx), G.text } }
    or { { "NO DATA YET", G.dim } }, n .. " pts @ " .. floor((CONFIG.FEED_STEP or 60) / 60 + 0.5) .. "m")
  -- Oak Wood: treefarm2's ON/OFF thresholds as dashed lines
  local marks = {}
  if g.key == "oak" and feed.farm then
    if feed.farm.low then marks[#marks + 1] = { feed.farm.low, G.warn } end
    if feed.farm.high then marks[#marks + 1] = { feed.farm.high, G.good } end
  end
  local top = mx
  for _, m in ipairs(marks) do top = max(top, m[1]) end
  local ymax = n > 0 and niceMax(max(top, 1) * 1.08) or 100
  local function py(v) return ph - 1 - floor(v / ymax * (ph - 3) + 0.5) end
  local cv = newCanvas(cw, ph, G.panel)
  for k = 1, 4 do
    local yy = py(ymax * k / 4)
    for xx = 3, cw, 3 do cset(cv, xx, yy, G.grid) end
  end
  -- shaded area under the line, column by column (interpolated between points)
  local area = lerp(g.color, G.panel, 0.7)
  if n > 1 then
    for c = 2, cw - 1 do
      local f = (c - 2) / max(1, cw - 3) * (n - 1) + 1
      local i = min(n - 1, floor(f))
      local v = s.v[i] + (s.v[i + 1] - s.v[i]) * (f - i)
      for y2 = py(v) + 1, ph - 1 do cset(cv, c, y2, area) end
    end
  end
  if n > 0 then
    for _, m in ipairs(marks) do
      local yy = py(m[1])
      for xx = 2, cw do if xx % 4 < 2 then cset(cv, xx, yy, m[2]) end end
    end
  end
  local prevX, prevY
  for i = 1, n do
    local xx = (n == 1) and cw or (2 + floor((i - 1) * (cw - 3) / (n - 1) + 0.5))
    local yy = py(s.v[i])
    if n == 1 then for y2 = yy + 1, ph - 1 do cset(cv, xx, y2, area) end end
    if prevX then cline(cv, prevX, prevY, xx, yy, lerp(g.color, 0xFFFFFF, 0.3)) end
    prevX, prevY = xx, yy
  end
  for yy = 1, ph do cset(cv, 1, yy, G.axis) end
  for xx = 1, cw do cset(cv, xx, ph, G.axis) end
  crender(cv, gx, gy)
  for k = 0, 4 do
    local lv = ymax * k / 4
    textW(P.x + 1, gy + floor((py(lv) - 1) / 2), LABW, shortNum(lv), G.dim, G.panel, "right")
  end
  if n == 0 then
    textW(gx + 2, gy + 5, cw - 4, "Waiting for " .. g.feed .. " readings...", G.dim, G.panel, "center")
    textW(gx + 2, gy + 6, cw - 4, "(port " .. (g.feed == "lscfuel" and CONFIG.FUEL_PORT or CONFIG.FARM_PORT)
      .. " - the graph starts with the first packet)", G.grid, G.panel, "center")
  end
  local first, last = s and s.t[1], s and s.t[n]
  text(gx, gy + rows, labelRow(cw, { { 1, first and stamp(first) or "" }, { cw, last and "now" or "" } }), G.dim, G.panel)
  segs(P.x + 2, gy + rows + 2, P.w - 4, feedInfo(g, t))
end

local function quadDropdown(i)
  overlay = { regions = {} }
  drawAll(true)
  local P = quadRect(i)
  local x, y, w = P.x + 5, P.y + 1, 42
  fill(x, y, w, #GRAPHS + 2, G.panel2)
  for j, g in ipairs(GRAPHS) do
    local on = SETTINGS.logsQ[i] == g.key
    local b = on and g.color or G.panel2
    textW(x + 1, y + j, w - 2, (on and " ● " or " ○ ") .. g.label, on and G.dark or G.text, b)
    if g.feed then text(x + w - 16, y + j, "(from " .. g.feed .. ")", on and G.dark or G.dim, b) end
    region(overlay.regions, x, y + j, w, 1, function()
      SETTINGS.logsQ[i] = g.key
      saveSettings()
      overlay = nil
      drawAll()
    end)
  end
end

local function drawQuad(i, t)
  local P = quadRect(i)
  local g = graphOf(SETTINGS.logsQ[i])
  fill(P.x, P.y, P.w, P.h, G.panel)
  fill(P.x, P.y, P.w, 1, g.color)
  text(P.x, P.y, " Q" .. i .. " ", G.text, lerp(g.color, 0x000000, 0.55))
  text(P.x + 5, P.y, " ▼ " .. g.label:upper() .. " ", G.dark, g.color)
  textW(P.x + P.w - 12, P.y, 11, "change ▾ ", G.dark, g.color, "right")
  region(regions, P.x, P.y, P.w, 1, function() quadDropdown(i) end)
  local ok, err
  if g.feed then ok, err = pcall(drawFeed, P, g) else ok, err = pcall(drawCycleGraph, P, g, t) end
  if not ok then textW(P.x + 2, P.y + P.h - 2, P.w - 4, "draw error: " .. tostring(err), G.bad, G.panel) end
end

------------------------------------------------------------- WINDOW
local function drawTitle(t)
  local title = ROLE == "mars" and "Logs - LSC charging cycles (from Earth)" or "Logs - LSC charging cycles"
  if lastPacket and not responding(t) then title = title .. " (Not Responding)" end
  titleBar(WX + 1, WY + 1, WW - 2, "▣ " .. title, true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
end

local function drawStatus(t)
  local parts = {
    { statusMsg, G.text },
    { "  │  " .. #archive .. " cycles", G.dim },
    { ROLE == "mars" and "  │  relayed by Earth (linked card)"
      or ("  │  port " .. CONFIG.PORT .. (wlan.isWireless() and " wireless" or " wired")), G.dim },
  }
  segs(X0, SY, CW, parts, (lastPacket and ("updated " .. fmtTime(lastPacket)) or "no data yet") .. " ", G.header)
end

local function tabButton(x, label, on, fn)
  local w = unicode.len(label)
  text(x, TY, label, on and G.dark or G.text, on and G.accent or G.button)
  region(regions, x, TY, w, 1, fn)
  return x + w + 1
end

local function setTab(v) tab = v; drawAll() end

local function draw(t)
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  drawTitle(t)
  region(regions, WX + WW - 12, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(regions, WX + WW - 5, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  text(WX + 2, WY + 2, " File ", K.black, K.face)
  text(WX + 8, WY + 2, " View ", K.black, K.face)
  text(WX + 14, WY + 2, " Help ", K.black, K.face)
  -- dark body
  fill(X0, TY, CW, 1, G.header)
  text(X0 + 1, TY, "≡ LOGS", G.accent, G.header)
  local x = X0 + 9
  x = tabButton(x, " OVERVIEW ", tab == "overview", function() setTab("overview") end)
  x = tabButton(x, " LISTS ", tab == "lists", function() setTab("lists") end)
  local bx = X0 + CW - 50
  bx = tabButton(bx, " REQUEST UPDATE ", false, function()
    requestUpdate(); statusMsg = "Update requested..."; drawStatus(now())
  end)
  bx = tabButton(bx, " CLEAR ARCHIVE ", false, function() confirmClear() end)
  tabButton(bx, " ABOUT ", false, function() about() end)
  fill(X0, CY, CW, CB - CY + 1, G.bg)
  if tab == "overview" then
    panel(X0, LIVE_Y, LW, 5, "LIVE STATUS", G.good)
    drawLiveRows(t)
    drawTotals()
    drawRecent()
  else
    drawLists()
  end
  drawQuad(1, t)
  drawQuad(2, t)
  lastQuads = computer.uptime()
  drawStatus(t)
end

-- once per second while visible (overwrite only, no flicker)
local wasResp
local function tick(t)
  local r = responding(t) and true or false
  if r ~= wasResp then drawTitle(t); wasResp = r end
  if tab == "overview" then drawLiveRows(t) end
  drawStatus(t)
  if computer.uptime() - lastQuads >= 10 then      -- "now" bars keep growing
    lastQuads = computer.uptime()
    for i = 1, 2 do
      local g = graphOf(SETTINGS.logsQ[i])
      if g.key == "gaps" or g.feed then drawQuad(i, t) end
    end
  end
end

local function scrollAt(x, y, dir)
  if tab == "lists" and x >= X0 and x < X0 + LW and y > CY + 2 and y <= CY + 2 + LROWS then
    listScroll = listScroll - dir
    drawListRows()
    return true
  end
end

return {
  draw = draw, tick = tick, scroll = scrollAt, setTab = setTab,
  scrollTop = function() listScroll = 0 end,
  onFuel = onFuel, onFarm = onFarm,
  -- for the lock screen status line
  feedState = function() return feed, fresh(feed.fuelAt), fresh(feed.farmAt) end,
}
end)()

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
  local h = #lines + 8
  local x, y = floor((W - w) / 2), floor((46 - h) / 2)
  overlay = { regions = {}, modal = true, reshow = function() dialog(title, lines, buttons) end }
  drawAll(true)
  bevel(x, y, w, h, "raised", K.desk, K.face)
  titleBar(x + 1, y + 1, w - 2, title, true)
  text(x + w - 4, y + 1, " X ", K.black, K.face)
  region(overlay.regions, x + w - 4, y + 1, 3, 1, closeOverlay)
  text(x + 3, y + 3, "(i)", K.white, K.navy)
  for i, l in ipairs(lines) do text(x + 8, y + 2 + i, l, K.black, K.face) end
  local bw = 12
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

about = function()
  dialog("About Logs", {
    tostring(SETTINGS.systemName or "Lymanos") .. "  -  Logs (Lymanos Link " .. LYM_VERSION .. ", " .. ROLE .. ")",
    ROLE == "mars" and "Shows the charging-cycle log from lscstats on Earth,"
      or "Receives the charging-cycle log from lscstats",
    ROLE == "mars" and "relayed by the Earth computer over the linked card."
      or ("over wireless (port " .. CONFIG.PORT .. ") and keeps an archive."),
    "",
    "Archive: " .. #archive .. " cycles",
  }, { { "OK" } })
end

confirmClear = function()
  dialog("Clear Archive", {
    "Delete all " .. #archive .. " archived cycles on this computer?",
    "(The lscstats computer keeps its own log.)",
  }, {
    { "Yes", function()
        archive = {}; selected = nil; saveArchive()
        statusMsg = "Archive cleared"
      end },
    { "No" },
  })
end

local function confirmExit()
  dialog("Shut Down", ROLE == "mars" and { "Close Lymanos on the Mars base?",
      "lymboot keeps listening, so Earth can still update or restart it." }
    or { "Are you sure you want to close Lymanos?" },
    { { "Yes", function() running = false end }, { "No" } })
end


local function fileMenu()
  popupMenu(WX + 2, WY + 3, {
    { "Request Update", function() requestUpdate(); statusMsg = "Update requested..." end },
    { "Clear Archive...", confirmClear },
    { "-" },
    { "Exit Lymanos", confirmExit },
  })
end

local function viewMenu()
  popupMenu(WX + 8, WY + 3, {
    { "Overview", function() LG.setTab("overview") end },
    { "Lists", function() LG.setTab("lists") end },
    { "-" },
    { "Scroll to Newest", function() LG.scrollTop() end },
    { "Clear Selection", function() selected = nil end },
  })
end

local function helpMenu()
  popupMenu(WX + 14, WY + 3, { { "About Logs...", about } })
end

openStartMenu = function()
  local items = {
    { "Logs", function() activeApp = "viewer" end },
    { "GT Graphs", function() openGraphs() end },
    { "My Computer", function() openSysApp() end },
    { "Settings", function() openSettings() end },
    { ROLE == "earth" and "Mars Link..." or "Earth Link...", function() LINK.dialog() end },
  }
  if ROLE == "earth" then items[#items + 1] = { "Update Mars Base...", function() LINK.confirmUpdate("program") end } end
  for _, it in ipairs({
    { "-" },
    { "Lock", function() LOCK.lock() end },
    { "Request Update", function() requestUpdate(); statusMsg = "Update requested..." end },
    { "Clear Archive...", confirmClear },
    { "About...", about },
    { "-" },
    { "Shut Down...", confirmExit },
  }) do items[#items + 1] = it end
  popupMenu(1, 47, items, { banner = true, above = true, start = true })
end


------------------------------------------------------- EARTH <-> MARS LINK
-- Everything between the planets goes through the Linked Card. The first
-- value of every message says what it is:
--   "LYMLINK" "HELLO"                       I just started (Earth answers with its latest data)
--   "LYMLINK" "STATUS" serialized-table     who I am and how I'm doing (every 15 s)
--   "LYMLINK" "REQ"                         Mars: please ask lscstats for a fresh log
--   "LYMLINK" "RELAY" port tag from a b     one wireless packet passed on
--   "LYMLINK" "RBIG" id i n port tag from a piece      ... a big one, in pieces
--   "LYMUPD"  ...                           updates; on Mars lymboot answers these:
--       Earth: BEGIN id target size sum n / PART id i data / END id / ABORT id
--              PING / RESTART / REBOOT
--       Mars:  ACK id i / DONE id ok msg / PONG mode bootVer progVer / BOOT event detail
LINK = (function()
local L = {}
local OTHER = ROLE == "earth" and "Mars" or "Earth"
local BOOT = rawget(_G, "LYMBOOT")      -- set by lymboot.lua when it started us (Mars)
local peer = nil                -- the other end's last STATUS
local heard = nil               -- uptime when the other end was last heard
local events = {}               -- link log, newest last: { t, s, bad }
local data = {}                 -- Earth: latest Mars packet per "port/tag" (for the Mars Base app)
local cache = {}                -- Earth: latest relayed packet per "port/tag" (resent when Mars says hello)
local big, bigId = {}, 0        -- big packets being put back together
local lastStatus, lastSave, dirty = -1e9, 0, false
local wasUp, lost = false, false
local started = computer.uptime()
local healthy = false
local feedFn = nil              -- Mars: where relayed Earth packets go (set by the main loop)
local U = nil                   -- Earth: the update being sent
local lastResult = nil          -- Earth: how the last update went

local function maxPacket()
  if not TUN then return 8192 end
  local ok, n = pcall(TUN.maxPacketSize)
  return (ok and type(n) == "number") and n or 8192
end
local PIECE = max(1024, maxPacket() - 512)     -- bytes of data per message (room left for the rest)

local function send(...)
  if not TUN then return false end
  local ok, r = pcall(TUN.send, ...)
  return ok and r ~= false
end

local function kb(n) return n and string.format("%.1f KB", n / 1024) or "--" end

local function when(t)
  if not t or t < 1e9 then return "--" end
  local e = toEastern(t)
  if SETTINGS.clock24 then return string.format("%02d/%02d %02d:%02d", e.month, e.day, e.hour, e.min) end
  local h, ap = h12(e)
  return string.format("%02d/%02d %d:%02d %s", e.month, e.day, h, e.min, ap)
end

-- a long text (a crash traceback) as at most n lines of w characters
local function wrap(s, w, n)
  local out = {}
  for line in (tostring(s) .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\t", "  ")
    while #out < n do
      if unicode.len(line) <= w then out[#out + 1] = line; break end
      out[#out + 1] = unicode.sub(line, 1, w)
      line = unicode.sub(line, w + 1)
    end
    if #out >= n then break end
  end
  return out
end
local function firstLine(s) return (tostring(s or ""):match("^[^\n]*") or ""):sub(1, 90) end

local function log(s, bad)
  events[#events + 1] = { t = now(), s = s, bad = bad or nil }
  while #events > 40 do table.remove(events, 1) end
  dirty = true
end

-- same checksum as lymboot (Adler-32 done with plain arithmetic: works on Lua 5.2 and 5.3)
local function checksum(s)
  local a, b = 1, 0
  for i = 1, #s, 256 do
    local bytes = { s:byte(i, min(#s, i + 255)) }
    for j = 1, #bytes do
      a = (a + bytes[j]) % 65521
      b = (b + a) % 65521
    end
  end
  return b * 65536 + a
end

local function versionOf(src)
  return src and (src:match('LYM_VERSION%s*=%s*"([^"]+)"') or src:match('BOOT_VERSION%s*=%s*"([^"]+)"'))
end
local function fileHead(path)          -- enough of a file to find its version line
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read(8192)
  f:close()
  return s
end

---------------------------------------------------------------- status
local function sendStatus()
  lastStatus = computer.uptime()
  local total, free = computer.totalMemory(), computer.freeMemory()
  send("LYMLINK", "STATUS", serialization.serialize({
    role = ROLE, mode = "running", ver = LYM_VERSION, boot = BOOT and BOOT.version or nil,
    name = SETTINGS.systemName, up = floor(computer.uptime()), mem = total - free, memT = total,
    en = floor(computer.energy()), enM = floor(computer.maxEnergy()),
    cycles = #archive, lsc = lastPacket ~= nil and responding(now()) or false,
    radio = hasRadio, at = now(),
  }))
end

function L.state()
  return TUN ~= nil and heard ~= nil and computer.uptime() - heard <= CONFIG.LINK_STALE, U ~= nil
end

function L.channel()
  if not TUN then return "--" end
  local ok, c = pcall(TUN.getChannel)
  return ok and tostring(c):sub(1, 8) or "?"
end

function L.summary()
  if not TUN then return "no linked card in this computer" end
  if not heard then return "no word from " .. OTHER .. " yet" end
  local ago = computer.uptime() - heard
  if ago > CONFIG.LINK_STALE then return "no word from " .. OTHER .. " for " .. fmtDurLong(ago) end
  if peer and peer.mode == "standby" then return OTHER .. " is up, but Lymanos is stopped (lymboot standby)" end
  return OTHER .. " online  -  v" .. tostring(peer and peer.ver or "?")
    .. ((peer and peer.up) and ("  up " .. fmtDurLong(peer.up)) or "")
end

---------------------------------------------------------------- relaying
-- Earth relays CONFIG.RELAY; Mars relays its CONFIG.MARS_PORTS home
local function wanted(port, tag)
  if ROLE == "earth" then
    local t = CONFIG.RELAY[port]
    return t ~= nil and t[tag] == true
  end
  if port == CONFIG.MARS_FEED_PORT or tag == "LSCSTATS" or tag == "LSCFUEL" or tag == "TREEFARM" then return false end
  for _, p in ipairs(CONFIG.MARS_PORTS) do if p == port then return true end end
  return false
end

local function forward(port, tag, from, a, b)
  if type(b) == "string" and #b > PIECE then
    bigId = bigId % 1000000 + 1
    local n = ceil(#b / PIECE)
    for i = 1, n do
      send("LYMLINK", "RBIG", bigId, i, n, port, tag, from, a, b:sub((i - 1) * PIECE + 1, i * PIECE))
    end
  else
    send("LYMLINK", "RELAY", port, tag, from, a, b)
  end
end

function L.relay(port, tag, from, a, b)
  if not TUN or not wanted(port, tag) then return end
  if ROLE == "earth" then cache[port .. "/" .. tostring(tag)] = { port, tag, from, a, b } end
  forward(port, tag, from, a, b)
end

local function replay()                  -- Earth: Mars (re)started - send what it missed
  for _, p in pairs(cache) do forward(p[1], p[2], p[3], p[4], p[5]) end
end

local function gotRelay(port, tag, from, a, b)
  if ROLE == "mars" then
    -- repeat it on Mars wireless, unchanged, for gtmars displays
    if CONFIG.MARS_REBROADCAST and hasRadio then pcall(wlan.broadcast, port, tag, a, b) end
    if feedFn then feedFn(from, nil, port, tag, a, b) end
  else
    data[port .. "/" .. tostring(tag)] = { port = port, tag = tag, from = from, a = a, b = b, at = now() }
    dirty = true
  end
end

function L.setFeed(fn) feedFn = fn end

-- Mars: tell gtmars displays whether the Earth link is up
local lastBeat = -1e9
local function beat()
  lastBeat = computer.uptime()
  if not hasRadio then return end
  pcall(wlan.broadcast, CONFIG.MARS_FEED_PORT, "LYMMARS", serialization.serialize({
    earth = (L.state()), ago = heard and floor(computer.uptime() - heard) or nil, ver = LYM_VERSION }))
end

-- Mars: a wireless packet on MARS_FEED_PORT (a gtmars display asking for data)
function L.onMarsRadio(port, tag)
  if ROLE ~= "mars" or port ~= CONFIG.MARS_FEED_PORT then return false end
  if tag == "LYMMARS_REQ" then L.request(); beat() end
  return true
end

function L.request()
  if not TUN then statusMsg = "No linked card - can't reach Earth"; return end
  send("LYMLINK", "REQ")
end

---------------------------------------------------------------- updates (Earth sends)
local progress            -- forward

local function finish(ok, msg)
  local what = U and U.what or "Update"
  U = nil
  lastResult = { t = now(), ok = ok, s = what .. ": " .. firstLine(msg) }
  log(what .. (ok and " done: " or " FAILED: ") .. firstLine(msg), not ok)
  if overlay and overlay.linkProgress then overlay = nil end
  showOrQueue(function()
    dialog(ok and (what .. " done") or (what .. " failed"), wrap(msg, 80, 8), { { "OK" } })
  end)
end

local function sendPiece()
  U.sentAt = computer.uptime()
  if U.i == 0 then
    send("LYMUPD", "BEGIN", U.id, U.target, #U.src, U.sum, U.n)
  elseif U.i <= U.n then
    send("LYMUPD", "PART", U.id, U.i, U.src:sub((U.i - 1) * PIECE + 1, U.i * PIECE))
  else
    send("LYMUPD", "END", U.id)
  end
end

progress = function()
  if not U or U.hidden or lockedFlag then return end
  if overlay and not overlay.linkProgress and not overlay.busy then return end   -- another menu or dialog is open
  local done = min(U.i, U.n)
  local pct = floor(done / max(1, U.n) * 100 + 0.5)
  local w = 40
  local nb = floor(pct / 100 * w + 0.5)
  dialog(U.what .. " - sending to Mars", {
    U.path .. "   " .. (U.ver and ("v" .. U.ver) or "no version line") .. ", " .. kb(#U.src),
    "",
    string.rep("█", nb) .. string.rep("░", w - nb) .. "  " .. pct .. "%",
    U.i > U.n and "All sent. Mars is checking and installing it..."
      or ("piece " .. done .. " of " .. U.n .. (U.tries > 0 and ("   (no answer - retry " .. U.tries .. ")") or "")),
  }, { { "Hide", function() if U then U.hidden = true end end }, { "Cancel", function() L.abort() end } })
  if overlay then overlay.linkProgress = true end
end

function L.abort()
  if not U then return end
  send("LYMUPD", "ABORT", U.id)
  finish(false, "Cancelled. Mars keeps the version it has.")
end

local function readWhole(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function L.startUpdate(target)
  if U or ROLE ~= "earth" then return end
  local title = target == "boot" and "Send Bootloader" or "Update Mars Base"
  if not TUN then
    dialog(title, { "This computer has no Linked Card.", "Put one card of a linked pair here and the other on Mars." }, { { "OK" } })
    return
  end
  local path = target == "boot" and CONFIG.BOOT_FILE or CONFIG.MARS_FILE
  local src = readWhole(path)
  if not src then
    dialog(title, { "Can't read " .. path .. ".", "Copy the file onto this computer first (or change MARS_FILE / BOOT_FILE in CONFIG)." }, { { "OK" } })
    return
  end
  if target == "program" and not src:find('\nlocal ROLE%s*=%s*"mars"') then
    dialog(title, { path .. " isn't the Mars program:", 'its ROLE line must say  local ROLE = "mars"' }, { { "OK" } })
    return
  end
  if target == "boot" and not src:find("LYMBOOT", 1, true) then
    dialog(title, { path .. " doesn't look like lymboot.lua." }, { { "OK" } })
    return
  end
  local fn, err = load(src, "=" .. (path:match("[^/]+$") or path))
  if not fn then
    local lines = { "Not sent - the file has a syntax error:", "" }
    for _, l in ipairs(wrap(err, 80, 4)) do lines[#lines + 1] = l end
    dialog(title, lines, { { "OK" } })
    return
  end
  fn = nil
  U = { id = math.random(1, 999999999), target = target, path = path, src = src, ver = versionOf(src),
        sum = checksum(src), n = ceil(#src / PIECE), i = 0, tries = 0,
        what = target == "boot" and "Bootloader update" or "Mars update" }
  log("Sending " .. (path:match("[^/]+$") or path) .. (U.ver and (" v" .. U.ver) or "") .. " (" .. kb(#src) .. ", " .. U.n .. " pieces)")
  sendPiece()
  progress()
end

function L.confirmUpdate(target)
  if ROLE ~= "earth" then return end
  if U then U.hidden = false; overlay = nil; progress(); return end
  local path = target == "boot" and CONFIG.BOOT_FILE or CONFIG.MARS_FILE
  local head = fileHead(path)
  local size = filesystem.exists(path) and filesystem.size(path) or nil
  local lines
  if not head then
    lines = { "Can't find " .. path .. " on this computer.", "Copy the file here first." }
    dialog(target == "boot" and "Send Bootloader" or "Update Mars Base", lines, { { "OK" } })
    return
  end
  local up = L.state()
  if target == "boot" then
    lines = { "Send " .. path .. "  (v" .. tostring(versionOf(head) or "?") .. ", " .. kb(size) .. ") to the Mars base?",
      "Mars runs lymboot " .. tostring(peer and peer.boot or "?") .. " now.",
      "lymboot saves it and switches to it at the next reboot (Mars Link > Reboot)." }
  else
    lines = { "Send " .. path .. "  (v" .. tostring(versionOf(head) or "?") .. ", " .. kb(size) .. ") to the Mars base?",
      "Mars runs v" .. tostring(peer and peer.ver or "?") .. " now.",
      "",
      "Mars checks it, keeps its current version as a backup and restarts.",
      "If the new version crashes in its first 2 minutes, Mars goes back to the old one." }
  end
  if not up then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Mars hasn't been heard from lately - the update may not get through."
  end
  dialog(target == "boot" and "Send Bootloader" or "Update Mars Base", lines,
    { { "Send", function() L.startUpdate(target) end }, { "Cancel" } })
end

local function confirmReboot()
  dialog("Restart Mars", {
    "Restart = start Lymanos on Mars again (quick, the server stays on).",
    "Reboot  = restart the whole Mars server computer; lymboot starts",
    "          Lymanos when it comes back (also loads a new lymboot).",
  }, {
    { "Restart", function() send("LYMUPD", "RESTART"); log("Asked Mars to restart Lymanos") end },
    { "Reboot", function() send("LYMUPD", "REBOOT"); log("Asked the Mars server to reboot") end },
    { "Cancel" },
  })
end

local function bootEvent(ev, det)
  ev, det = tostring(ev or "?"), tostring(det or "")
  if ev == "START" then log("Mars program started (v" .. det .. ")")
  elseif ev == "HEALTHY" then log("Mars v" .. det .. " ran 2 minutes without trouble - backup no longer needed")
  elseif ev == "POWERON" then log("Mars server booted (lymboot " .. det .. ")")
  elseif ev == "REBOOT" then log("Mars server is rebooting")
  elseif ev == "STANDBY" then log("Mars program stopped - lymboot waiting: " .. firstLine(det), true)
  elseif ev == "CRASH" or ev == "ROLLBACK" then
    local head = ev == "CRASH" and "The Mars program crashed." or "The new Mars program crashed - Mars went back to the old version."
    log((ev == "CRASH" and "Mars CRASHED: " or "Mars ROLLED BACK: ") .. firstLine(det), true)
    showOrQueue(function()
      local lines = { head, "" }
      for _, l in ipairs(wrap(det, 90, 10)) do lines[#lines + 1] = l end
      dialog("Mars Base", lines, { { "OK" } })
    end)
  else log("Mars: " .. ev .. " " .. firstLine(det)) end
end

---------------------------------------------------------------- incoming
function L.onTunnel(from, tag, kind, a, b, c, d, e, f, g, h)
  heard = computer.uptime()
  if tag == "LYMUPD" then
    if ROLE == "mars" then
      if BOOT then return BOOT.handle(kind, a, b, c, d, e) end
      if kind == "BEGIN" or kind == "END" then
        send("LYMUPD", "DONE", a, false, "Mars Lymanos isn't running under lymboot, so it can't install updates. Start it with lymboot.")
      elseif kind == "PING" then send("LYMUPD", "PONG", "no lymboot", nil, LYM_VERSION) end
      return nil
    end
    if kind == "ACK" then
      if U and a == U.id and b == U.i then
        U.i, U.tries = U.i + 1, 0
        sendPiece()
        progress()
      end
    elseif kind == "DONE" then
      if U and a == U.id then finish(b == true, tostring(c or "")) end
    elseif kind == "PONG" then
      log("Mars answered: " .. tostring(a) .. ", lymboot " .. tostring(b) .. ", program v" .. tostring(d or c))
    elseif kind == "BOOT" then
      bootEvent(a, b)
    end
    return nil
  end
  if tag ~= "LYMLINK" then return nil end
  if kind == "HELLO" then
    sendStatus()
    if ROLE == "earth" then replay() end
  elseif kind == "STATUS" then
    local ok, t = pcall(serialization.unserialize, a)
    if ok and type(t) == "table" then
      if not peer or peer.ver ~= t.ver then log(OTHER .. " is online (v" .. tostring(t.ver) .. ")") end
      peer = t
      peer.got = now()
      dirty = true
    end
  elseif kind == "REQ" then
    if ROLE == "earth" then pcall(wlan.broadcast, CONFIG.PORT, "LSCSTATS_REQ"); replay() end
  elseif kind == "RELAY" then
    gotRelay(a, b, c, d, e)
  elseif kind == "RBIG" then           -- a=id b=i c=n d=port e=tag f=from g=a h=piece
    local k = big[a]
    if not k then k = { n = c, got = 0, parts = {}, at = computer.uptime() }; big[a] = k end
    if type(b) == "number" and not k.parts[b] then k.parts[b] = h; k.got = k.got + 1 end
    if k.got >= k.n then
      big[a] = nil
      gotRelay(d, e, f, g, table.concat(k.parts))
    end
  end
  return nil
end

---------------------------------------------------------------- loop hooks
function L.start()
  if ROLE == "mars" and not TUN then log("No linked card - this server can't reach Earth", true) end
  send("LYMLINK", "HELLO")
  sendStatus()
end

function L.fast() return U ~= nil end

-- every pass of the main loop: re-send an update piece Mars didn't confirm
function L.pump()
  if U and computer.uptime() - U.sentAt >= CONFIG.UPDATE_TIMEOUT then
    U.tries = U.tries + 1
    if U.tries > CONFIG.UPDATE_TRIES then
      send("LYMUPD", "ABORT", U.id)
      finish(false, "Mars stopped answering at piece " .. min(U.i, U.n) .. " of " .. U.n
        .. ". Is the Mars server on and running lymboot?")
    else
      sendPiece()
      progress()
    end
  end
end

-- once a second
function L.tick()
  local up = computer.uptime()
  if up - lastStatus >= CONFIG.LINK_STATUS_EVERY then sendStatus() end
  if ROLE == "mars" and up - lastBeat >= CONFIG.MARS_BEAT then beat() end
  local isUp = L.state()
  if isUp and lost then log(OTHER .. " link is back"); lost = false
  elseif not isUp and wasUp then log("No word from " .. OTHER .. " for " .. CONFIG.LINK_STALE .. " s - link down", true); lost = true end
  if isUp ~= wasUp and not overlay and not LOCK.isLocked() then drawTray(now()) end
  wasUp = isUp
  for id, k in pairs(big) do if up - k.at > 30 then big[id] = nil end end
  -- Mars: tell lymboot this version works (a crash after this is not rolled back)
  if BOOT and not healthy and up - started >= 120 then healthy = true; pcall(BOOT.healthy) end
  if dirty and up - lastSave >= 60 then L.save() end
end

function L.save()
  lastSave, dirty = computer.uptime(), false
  writeFile(CONFIG.LINK_FILE, serialization.serialize({ peer = peer, events = events, data = data, result = lastResult }))
end

function L.load()
  local raw = readFile(CONFIG.LINK_FILE)
  if not raw then return end
  local ok, t = pcall(serialization.unserialize, raw)
  if ok and type(t) == "table" then
    peer, events, data, lastResult = t.peer, t.events or {}, t.data or {}, t.result
  end
end

-- the Mars Base app (coming later) reads Mars's data from here
function L.marsData() return data end
function L.peer() return peer end

---------------------------------------------------------------- the link dialog
function L.dialog()
  if U and U.hidden then U.hidden = false; overlay = nil; progress(); return end
  local lines = {
    "Linked card:  " .. (TUN and ("channel " .. L.channel()) or "NOT FOUND - put one card of a linked pair in each computer"),
    OTHER .. ":  " .. L.summary(),
  }
  if peer then
    if ROLE == "earth" then
      lines[#lines + 1] = "Mars program v" .. tostring(peer.ver) .. "   lymboot " .. tostring(peer.boot or "NOT RUNNING - no remote updates")
    else
      lines[#lines + 1] = "Earth program v" .. tostring(peer.ver)
        .. "   lscstats " .. (peer.lsc and "online" or "not heard") .. " on Earth"
    end
    if peer.memT then
      lines[#lines + 1] = string.format("%s RAM %s / %s   power %d%%   last report %s", OTHER, kb(peer.mem), kb(peer.memT),
        floor((peer.en or 0) / max(1, peer.enM or 1) * 100 + 0.5), when(peer.got))
    end
  end
  lines[#lines + 1] = ""
  if ROLE == "earth" then
    local head = fileHead(CONFIG.MARS_FILE)
    lines[#lines + 1] = "Sends to Mars:  " .. CONFIG.MARS_FILE .. (head and ("  (v" .. tostring(versionOf(head) or "?") .. ")") or "  (NOT FOUND)")
    lines[#lines + 1] = "Last update:  " .. (lastResult and (when(lastResult.t) .. "  " .. lastResult.s) or "none yet")
    local nd = 0
    for _ in pairs(data) do nd = nd + 1 end
    lines[#lines + 1] = "Mars data feeds kept: " .. nd .. "  (for the Mars Base app)"
  else
    lines[#lines + 1] = "This server:  Lymanos Link v" .. LYM_VERSION
      .. (BOOT and ("  under lymboot " .. tostring(BOOT.version)) or "  - NOT under lymboot (no remote updates!)")
    lines[#lines + 1] = "Updates are pushed from Earth:  Start > Update Mars Base."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Recent:"
  if #events == 0 then lines[#lines + 1] = "  (nothing yet)" end
  for i = max(1, #events - 4), #events do
    local ev = events[i]
    lines[#lines + 1] = "  " .. when(ev.t) .. "  " .. (ev.bad and "! " or "") .. ev.s:sub(1, 84)
  end
  local buttons
  if ROLE == "earth" then
    buttons = {
      { "Update", function() L.confirmUpdate("program") end },
      { "Bootloader", function() L.confirmUpdate("boot") end },
      { "Restart", confirmReboot },
      { "Ping", function() send("LYMUPD", "PING"); send("LYMLINK", "HELLO") end },
      { "Close" },
    }
  else
    buttons = {
      { "Resync", function() send("LYMLINK", "HELLO"); log("Asked Earth to resend its data") end },
      { "Close" },
    }
  end
  dialog(ROLE == "earth" and "Mars Link" or "Earth Link", lines, buttons)
end

return L
end)()


------------------------------------------------------------ GT GRAPHS
-- gtgraphs.lua as a Lymanos app: the same four graphs, full screen, with
-- the gtgraphs taskbar (plus a LYMANOS button back to the desktop). Every
-- series keeps recording while the app is closed, exactly like gtgraphs.
--   Earth: LSC data from lscfuel, cycles from lscstats, farm from treefarm2
--          (wireless), Oak Wood from an ME Interface here if there is one.
--   Mars:  the same packets, relayed by Earth over the linked card; Oak Wood
--          comes from treefarm2's count.
-- Saved to /home/lymanos_graphs.dat + _meta.dat (same format as gtgraphs:
-- copy gtgraphs.dat / gtgraphs_meta.dat over them to keep old history).
GT = (function()
local LYM = CONFIG
local CONFIG = {
  ME_ADDRESS   = nil,            -- Earth: ME Interface address (nil = auto-detect, optional)
  LOG_FILTER = { name = "minecraft:log", damage = 0 },   -- Oak Wood only
  FARM_ON_MODE = "active",       -- "active" = running a recipe, "allowed" = enabled
  FARM_PORT = LYM.FARM_PORT,
  FARM_STALE = 30,
  OAK_MARKERS = { { 100000, 0xFFB000 }, { 1000000, 0x3FE06A } },
  POLL_INTERVAL = 5,
  WINDOWS = {
    { label = "1H",  interval = 5,   points = 720 },
    { label = "6H",  interval = 30,  points = 720 },
    { label = "24H", interval = 120, points = 720 },
    { label = "7D",  interval = 840, points = 720 },
  },
  LSC_PORT = LYM.FUEL_PORT,
  LSC_STALE = 30,
  CYCLE_SOURCE = "lscstats",     -- or "lscfuel" (build cycles from lscfuel's fuel signal)
  WIRELESS_PORT = LYM.PORT,
  LINK_STALE = 120,
  CYCLE_ARCHIVE = 60,
  GAP_BARS = 12,
  LAYOUT = {
    q1 = { src = "euout",  win = 2 },
    q2 = { src = "cycles", win = 2 },
    q3 = { src = "empty",  win = 2 },
    q4 = { src = "oak",    win = 2 },
  },
  SAVE_INTERVAL = 300,
  DATA_FILE = "/home/lymanos_graphs.dat",
  META_FILE = "/home/lymanos_graphs_meta.dat",
}
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local huge = math.huge
local tointeger = math.tointeger or function(v) return v and floor(v) end
local NOCARD = ROLE == "mars" and "No linked card - this server can't get Earth's data" or "No wireless card"
local WHERE_LSC = ROLE == "mars" and "(relayed by Earth)" or ("on port " .. LYM.FUEL_PORT .. " (needs its wireless card)")
local WHERE_FARM = ROLE == "mars" and "(relayed by Earth)" or ("on port " .. LYM.FARM_PORT .. " (needs its wireless card)")
local onExit = nil               -- the LYMANOS button
local addButton                  -- (taskbar, below)

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
  if ROLE == "mars" then return nil end     -- Mars: Oak Wood comes from treefarm2 (relayed by Earth)
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
  hidden = {},        -- gaps removed by the user, by gapKey(start of the cycle after it)
}
local function gapKey(start) return string.format("%.0f", start) end
local det = { charging = nil, nextId = 1 }   -- "lscfuel" cycle mode
local cycleMode = (CONFIG.CYCLE_SOURCE == "lscfuel") and "lscfuel" or "lscstats"
local wlan = nil                 -- true when this computer can get the feeds (Earth: radio, Mars: linked card)
local lastReq = -huge

local function initLink()        -- (Lymanos owns the cards and opens the ports)
  wlan = (ROLE == "mars" and TUN ~= nil) or (ROLE == "earth" and hasRadio) or nil
end

local function requestLink()
  requestUpdate()                -- Earth: asks lscstats; Mars: asks Earth over the link
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
    if consecutive and a.stop and b.start > a.stop and not cyc.hidden[gapKey(b.start)] then
      g[#g + 1] = { id = b.id, gap = b.start - a.stop, start = b.start }
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
        T.buf[i] = tointeger(tonumber(v)) or -1
      end
      T.last = tointeger(tonumber(last))
    end
  end
  f:close()
end

local function saveMeta()
  local f = io.open(CONFIG.META_FILE, "w")
  if not f then return end
  local hidden = {}      -- only gaps whose cycle is still kept
  for _, c in ipairs(cyc.list) do
    local k = gapKey(c.start)
    if cyc.hidden[k] then hidden[k] = true end
  end
  f:write(serialization.serialize({
    layout = layout, selected = selected,
    farmLastOn = farm.lastOn,
    cycles = cyc.list, current = cyc.current, lastStop = cyc.lastStop,
    detCharging = det.charging, detNextId = det.nextId, hidden = hidden,
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
        layout[k].win = tointeger(v.win) or layout[k].win
      end
    end
  end
  if layout[m.selected or ""] then selected = m.selected end
  farm.lastOn = m.farmLastOn
  cyc.list = type(m.cycles) == "table" and m.cycles or {}
  cyc.hidden = type(m.hidden) == "table" and m.hidden or {}
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
local function niceMax(v)
  if v <= 0 then return 1 end
  local e = 10 ^ floor(math.log(v, 10))
  for _, m in ipairs({ 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 }) do
    if v <= m * e then return m * e end
  end
  return 10 * e
end

-------------------------------------------------------- REMOVING POINTS
-- Tap a point on a time graph to select it, REMOVE deletes it (bad
-- readings / outliers). It is removed from the window it was picked in,
-- together with the shorter-window points inside the same time span. The
-- longer windows that had it averaged in are re-averaged without it (from
-- the shorter window's points when it still has them), so the rest of the
-- data stays exactly as it was. Every change is logged for UNDO.
local function inRing(T, slot) return T.last ~= nil and slot <= T.last and slot > T.last - T.n end
local function inAcc(T, slot) return T.acc.slot == slot and T.acc.cnt > 0 end

-- number of readings (polls) that went into one slot
local function readingsIn(T, slot)
  if inAcc(T, slot) then return T.acc.cnt end
  return max(1, floor(T.iv / CONFIG.POLL_INTERVAL + 0.5))
end

local function logRing(log, T, slot, val)
  local i = slot % T.n + 1
  log.ring[#log.ring + 1] = { T = T, slot = slot, old = T.buf[i] }
  T.buf[i] = val
end

local function logAcc(log, T, sum, cnt)
  local a = T.acc
  log.acc[#log.acc + 1] = { T = T, slot = a.slot, sum = a.sum, cnt = a.cnt, flag = a.flag }
  if cnt <= 0 then a.sum, a.cnt, a.flag = 0, 0, false else a.sum, a.cnt = sum, cnt end
end

local function clearSlot(log, T, slot)
  if inRing(T, slot) and T.buf[slot % T.n + 1] >= 0 then logRing(log, T, slot, -1) end
  if inAcc(T, slot) then logAcc(log, T, 0, 0) end
end

-- slot `slot` of window wi went from vo (nr readings) to vn (nil = removed):
-- re-average the slot of the next longer window that holds it, and so on up
local function reaverage(log, s, wi, slot, vo, vn, nr)
  local Tf, Tc = s.tiers[wi], s.tiers[wi + 1]
  if not Tc then return end
  local sc = floor(slot * Tf.iv / Tc.iv)
  local A, flag = tierGet(Tc, sc)
  if not A then return end
  local N = readingsIn(Tc, sc)
  local newA
  if inAcc(Tc, sc) then                      -- still being averaged right now
    local a = Tc.acc
    local m = min(a.cnt, nr)
    if vn then logAcc(log, Tc, a.sum + (vn - vo) * m, a.cnt)
    else logAcc(log, Tc, a.sum - vo * m, a.cnt - m) end
    if a.cnt > 0 then newA = a.sum / a.cnt end
  else
    local f0 = floor(sc * Tc.iv / Tf.iv)
    local f1 = floor(((sc + 1) * Tc.iv - 1) / Tf.iv)
    local newest = max(Tf.last or -huge, Tf.acc.slot or -huge)
    if Tf.last and f0 > Tf.last - Tf.n and f1 <= newest then
      -- the shorter window still has this whole span: average it again exactly
      local sm, ct, fl = 0, 0, false
      for f = f0, f1 do
        local v, ff = tierGet(Tf, f)
        if v then
          sm, ct = sm + v, ct + 1
          if ff then fl = true end
        end
      end
      if ct > 0 then newA, flag = sm / ct, fl end
    elseif vn then
      newA = A + (vn - vo) * nr / N          -- only the average is left: correct it
    elseif N > nr then
      newA = (A * N - vo * nr) / (N - nr)
    end
  end
  if inRing(Tc, sc) then logRing(log, Tc, sc, newA and encode(newA, flag) or -1) end
  reaverage(log, s, wi + 1, sc, A, newA, N)
end

-- removes one point; returns its value and the undo log
local function deletePoint(s, wi, slot)
  local T = s.tiers[wi]
  local v = tierGet(T, slot)
  if not v then return nil end
  local log = { ring = {}, acc = {} }
  local nr = readingsIn(T, slot)
  local t0, t1 = slot * T.iv, (slot + 1) * T.iv
  clearSlot(log, T, slot)
  for j = 1, wi - 1 do                       -- shorter windows: the same time span
    local Tf = s.tiers[j]
    for fs = floor(t0 / Tf.iv), floor((t1 - 1) / Tf.iv) do clearSlot(log, Tf, fs) end
  end
  reaverage(log, s, wi, slot, v, nil, nr)
  return v, log
end

local function undoDelete(log)
  for i = #log.ring, 1, -1 do
    local r = log.ring[i]
    if inRing(r.T, r.slot) then r.T.buf[r.slot % r.T.n + 1] = r.old end
  end
  for i = #log.acc, 1, -1 do
    local r = log.acc[i]
    local a = r.T.acc
    if a.slot == r.slot then
      a.sum, a.cnt, a.flag = r.sum, r.cnt, r.flag
    elseif r.cnt > 0 and inRing(r.T, r.slot) then   -- it has been stored since
      r.T.buf[r.slot % r.T.n + 1] = encode(r.sum / r.cnt, r.flag)
    end
  end
end

-- what is selected / was just removed, and where the graphs are on screen
local pick = nil        -- { qk, kind = "point" | "gap", ... }
local lastDel = nil     -- { qk, at, text, undo }  (UNDO is offered for 30 s)
local geo = {}          -- qk -> plot geometry from the last draw (for taps)
local qbuttons = {}     -- qk -> buttons drawn inside that panel
local drawQuad, redrawGraphs   -- defined below (QUADRANTS)

local function qbutton(qk, x, y, w, label, f, b, fn)
  local l = qbuttons[qk]
  l[#l + 1] = { x = x, y = y, w = w, fn = fn }
  textW(x, y, w, label, f, b, "center")
end

-- screen column c of a series graph covers slots s0..s1
local function colSlots(g, c)
  local s0 = g.startSlot + floor((c - 1) * g.n / g.cw)
  return s0, max(s0, g.startSlot + floor(c * g.n / g.cw) - 1)
end

local function colOf(g, slot)
  if slot < g.startSlot or slot >= g.startSlot + g.n then return nil end
  local c = max(1, min(g.cw, floor((slot - g.startSlot) * g.cw / g.n) + 1))
  while c > 1 and colSlots(g, c) > slot do c = c - 1 end
  while c < g.cw and colSlots(g, c + 1) <= slot do c = c + 1 end
  return c
end

-- bottom line of a panel while something is selected or was just removed.
-- describe() -> segments; onRemove() removes it. Returns true if drawn.
local function editBar(qk, P, describe, onRemove)
  local y = P.y + 21
  local bx = P.x + P.w - 2 - 17
  text(bx + 8, y, " ", nil, C.panel)          -- the space between the two buttons
  if pick and pick.qk == qk then
    writeSegs(P.x + 2, y, bx - P.x - 2, describe())
    qbutton(qk, bx, y, 8, "REMOVE", C.dark, C.bad, onRemove)
    qbutton(qk, bx + 9, y, 8, "CANCEL", C.text, C.button, function() pick = nil; drawQuad(qk, false) end)
    return true
  end
  if lastDel and lastDel.qk == qk then
    if computer.uptime() - lastDel.at > 30 then
      lastDel = nil
    else
      writeSegs(P.x + 2, y, bx - P.x - 2, { { lastDel.text, C.warn } })
      qbutton(qk, bx, y, 8, "UNDO", C.dark, C.warn, function()
        local d = lastDel
        lastDel = nil
        if d and d.undo then d.undo() end
        redrawGraphs()
      end)
      qbutton(qk, bx + 9, y, 8, "OK", C.text, C.button, function() lastDel = nil; drawQuad(qk, false) end)
      return true
    end
  end
  return false
end

local function clearEdits(qk)
  if pick and pick.qk == qk then pick = nil end
  if lastDel and lastDel.qk == qk then lastDel = nil end
end

-- a tap inside a graph: select the point (or bar) nearest to it
local function pickAt(qk, x, y)
  local g = geo[qk]
  if not g or x < g.gx or x >= g.gx + g.cw or y < g.gy or y >= g.gy + g.rows then return false end
  local old = pick
  pick = nil
  local cx = x - g.gx + 1
  if g.kind == "series" then
    local pyc = (y - g.gy) * 2 + 1.5          -- the tapped cell = 2 pixel rows
    local best, bestD
    for c = max(1, cx - 1), min(g.cw, cx + 1) do
      local s0, s1 = colSlots(g, c)
      for sl = s0, s1 do
        local v = tierGet(g.T, sl)
        if v then
          local d = abs(g.py(v) - pyc) + abs(c - cx) * 4
          if not bestD or d < bestD then best, bestD = sl, d end
        end
      end
    end
    if best then pick = { qk = qk, kind = "point", series = g.series, wi = g.wi, slot = best } end
  elseif g.kind == "gaps" then
    local i = floor((cx - 3) / g.slotW) + 1
    local gp = g.shown[i]
    if gp and cx >= 3 then pick = { qk = qk, kind = "gap", key = gapKey(gp.start) } end
  end
  if old and old.qk ~= qk then drawQuad(old.qk, false) end
  return true
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
  local g = { kind = "series", gx = gx, gy = gy, cw = cw, rows = rows, n = n,
              startSlot = startSlot, T = T, wi = wi, series = src.series }

  -- summarize the ring buffer into one min/max/avg per screen column
  local cmin, cmax, cavg, cflag = {}, {}, {}, {}
  local vmin, vmax, vsum, vcnt, latest, lastCol = huge, -huge, 0, 0, nil, nil
  for c = 1, cw do
    local s0, s1 = colSlots(g, c)
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
  g.py = py
  geo[qk] = g

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
  -- selected point: red ring, its column lightly marked
  local pk = (pick and pick.qk == qk) and pick or nil
  if pk and (pk.kind ~= "point" or pk.series ~= src.series or pk.wi ~= wi) then pick, pk = nil, nil end
  local pv, pc
  if pk then
    pv = tierGet(T, pk.slot)
    pc = pv and colOf(g, pk.slot)
    if not pc then pick, pk = nil, nil end
  end
  if pk then
    local ya = py(pv)
    local hl = lerp(C.bad, C.panel, 0.7)
    for yy = 1, ph - 1 do
      if cv.g[(yy - 1) * cw + pc] == C.panel and yy % 2 == 0 then cset(cv, pc, yy, hl) end
    end
    for dx = -1, 1 do for dy = -1, 1 do cset(cv, pc + dx, ya + dy, C.bad) end end
    cset(cv, pc, ya, 0xFFFFFF)
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

  -- info line (or the selected point with REMOVE / CANCEL)
  local drawn = editBar(qk, P, function()
    return { { "SELECTED ", C.dim }, { fmtStamp(pk.slot * T.iv), C.text },
             { "  " .. fmt(pv) .. (src.unit or ""), C.bad }, { "  (" .. fmtStep(T.iv) .. " point)", C.dim } }
  end, function()
    local p = pick
    pick = nil
    local v, log = deletePoint(src.series, wi, p.slot)
    if v then
      lastDel = { qk = qk, at = computer.uptime(),
        text = "Removed " .. fmt(v) .. (src.unit or "") .. " at " .. fmtStamp(p.slot * T.iv),
        undo = function() undoDelete(log); pcall(saveSeries) end }
      pcall(saveSeries)
    end
    redrawGraphs()
  end)
  if not drawn then
    local s, col = src.info(t)
    textW(P.x + 2, P.y + 21, P.w - 4, s or "", col or C.text, C.panel)
  end
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

  -- tap a bar to select it (REMOVE hides that gap)
  geo[qk] = { kind = "gaps", gx = gx, gy = gy, cw = cw, rows = rows + 2, slotW = slotW, shown = shown }
  local pk, selI = (pick and pick.qk == qk) and pick or nil, nil
  if pk and pk.kind == "gap" then
    for i, g in ipairs(shown) do if gapKey(g.start) == pk.key then selI = i end end
  end
  if pk and not selI then pick, pk = nil, nil end

  for i, g in ipairs(shown) do
    local col = (i == selI) and 0xFFFFFF or barColor(g.gap / avg)
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
    right = ROLE == "mars" and "no linked card!" or "no wireless card!"
  elseif cycleMode == "lscstats" then
    if cyc.lastPacket then right = "lscstats link, " .. fmtShort(t - cyc.lastPacket) .. " ago"
    else right = "waiting for lscstats..." end
  else
    right = lscFresh(t) and "from lscfuel fuel signal" or "waiting for lscfuel..."
  end
  local drawn = editBar(qk, P, function()
    local g = shown[selI]
    return { { "SELECTED ", C.dim }, { "gap before cycle #" .. tostring(g.id or "?"), C.text },
             { "   " .. fmtDurLong(g.gap), C.bad },
             { "   (" .. fmtAxisTime(g.start - g.gap) .. " - " .. fmtAxisTime(g.start) .. ")", C.dim } }
  end, function()
    local g = shown[selI]
    pick = nil
    if g then
      local key = gapKey(g.start)
      cyc.hidden[key] = true
      lastDel = { qk = qk, at = computer.uptime(),
        text = "Removed the " .. fmtDurLong(g.gap) .. " gap before cycle #" .. tostring(g.id or "?"),
        undo = function() cyc.hidden[key] = nil; saveMeta() end }
      saveMeta()
    end
    redrawGraphs()
  end)
  if not drawn then writeSegs(P.x + 2, P.y + 21, P.w - 4, { { left, lcol } }, right) end
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
  if not wlan then return NOCARD end
  if not lscData then return "Waiting for lscfuel " .. WHERE_LSC .. "..." end
  if not lscFresh(now()) then return "No data from lscfuel for " .. fmtDurLong(now() - lscAt) end
end

local function lscInfo(t)
  if not wlan then return NOCARD, C.bad end
  if not lscData then return "Waiting for lscfuel " .. WHERE_LSC, C.warn end
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
  if not wlan then return NOCARD, C.bad end
  if not farmData then return "Waiting for treefarm2 " .. WHERE_FARM, C.warn end
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
      if not dev.me and not farmData then
        return ROLE == "mars" and "No Oak Wood count from treefarm2 yet (relayed by Earth)"
          or "No ME Interface here and no data from treefarm2 yet"
      end
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

drawQuad = function(qk, full)
  local q = layout[qk]
  local src = SOURCES[q.src] or SOURCES.empty
  local P = rectOf(qk)
  qbuttons[qk], geo[qk] = {}, nil
  if full then
    fill(P.x, P.y, P.w, P.h, C.panel)
    drawStrip(qk, P, src, q)
  end
  local ok, err = pcall(src.draw, qk, P, q, src, full)
  if not ok then textW(P.x + 2, P.y + P.h - 2, P.w - 4, "draw error: " .. tostring(err), C.bad, C.panel) end
end

redrawGraphs = function()
  for _, qk in ipairs(QORDER) do drawQuad(qk, false) end
end

---------------------------------------------------------------- TASKBAR
local buttons = {}

addButton = function(x, y, w, label, f, b, fn)
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
  if ROLE == "mars" then dot("EARTH", (LINK.state())) else dot("ME", dev.me ~= nil) end
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
  clearEdits(selected)
  layout[selected].src = key
  drawQuad(selected, true)
  drawTaskbar()
  saveMeta()
end

local function setWindow(wi)
  clearEdits(selected)
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
  addButton(W - 12, 49, 12, " ◄ LYMANOS ", C.dark, C.accent, function() if onExit then onExit() end end)

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

local function drawScreen()
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
  for _, b in ipairs(qbuttons[qk] or {}) do          -- REMOVE / CANCEL / UNDO / OK
    if y == b.y and x >= b.x and x < b.x + b.w then b.fn(); return end
  end
  if qk ~= selected then selectQuad(qk) end
  if pickAt(qk, x, y) then drawQuad(qk, false) end    -- tapped a graph: select a point
end

---------------------------------------------------------------- app hooks
local nextPoll, lastSave = 0, 0

return {
  init = function()
    initLink()
    loadSeries()
    loadMeta()
    poll()
    nextPoll = computer.uptime() + CONFIG.POLL_INTERVAL
    lastSave = computer.uptime()
  end,
  draw = function() drawScreen() end,
  touch = onTouch,
  -- packets (Earth: wireless; Mars: relayed by Earth)
  onLscstats = function(payload) if cycleMode == "lscstats" then receivePacket(payload) end end,
  onFuel = receiveFuel,
  onFarm = receiveFarm,
  -- once a second: record every 5 s (always), redraw while on screen
  tick = function(visible)
    local up = computer.uptime()
    if up >= nextPoll then
      nextPoll = up + CONFIG.POLL_INTERVAL
      poll()
      if visible then
        for _, qk in ipairs(QORDER) do drawQuad(qk, false) end
        drawTaskStatus()
      end
    end
    if visible then drawTaskClock(now()) end
    if up - lastSave >= CONFIG.SAVE_INTERVAL then lastSave = up; pcall(saveAll) end
  end,
  save = saveAll,
  setExit = function(fn) onExit = fn end,
}
end)()

graphsOpen = false
openGraphs = function() graphsOpen = true; activeApp = "graphs" end
GT.setExit(function() activeApp = nil; drawAll() end)     -- the LYMANOS button

------------------------------------------------------------ MY COMPUTER
-- Storage, memory, power and component details for this computer.
-- Own function = own local-variable budget (see Brokerage).
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
local TABS = { { "storage", "Storage" }, { "report", "Storage Report" }, { "memory", "Memory & Power" }, { "components", "Components" } }

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
    if i > 5 then
      textW(x + 2, y + 17, PW - 8, "+ " .. (#list - 5) .. " more drive(s) - see the Components tab", K.sh, K.face)
      break
    end
    local yy = y + 1 + (i - 1) * 3
    local name = (d.label and d.label ~= "" and d.label or "Unlabeled") .. "  (" .. d.address:sub(1, 8) .. ")"
    textW(x + 2, yy, 48, "▣ " .. name, K.black, K.face)
    textW(x + 50, yy, 40, "Mounted at " .. table.concat(d.paths, ", "), K.sh, K.face)
    textW(x + 90, yy, PW - 96, d.kind .. (d.ro and "  [read-only]" or ""), K.sh, K.face)
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

-- Storage Report tab: what Lymanos keeps on disk, how fast it grows, when the
-- drive would be full. Same layout as the archive server's Storage Report.
local SREP = { rp = nil, hist = nil, at = 0 }
local GROW_FILE = "/home/lymanos_storage.dat"   -- one line per day: day number, bytes in /home
-- every data file Lymanos writes, and how much of it is kept
local KINDS = {
  { "LSC Logs", "charging cycles", "^lymanos_archive%.dat$", CONFIG.ARCHIVE_MAX .. " cycles" },
  { "", "last lscstats packet", "^lscstats_copy%.dat$", "latest only" },
  { "GT Graphs", "graph history + layout", "^lymanos_graphs.*%.dat$", "720 points x 4 windows per graph" },
  { "Link", ROLE == "earth" and "Mars status, Mars data, events" or "Earth status, link events",
    "^lymanos_link%.dat$", "latest packet per feed + 40 events" },
  { "Boot", "lymboot state + old versions", "^lym[a-z]*%.[bdn][ae][dktw]$", "1 backup + 1 failed copy" },
  { "System", "settings + clock", "^lymanos_settings%.dat$", "fixed size" },
  { "", "this report's growth log", "^lymanos_storage%.dat$", "60 days" },
  { "Programs", "Lua programs", "%.lua$", "until you delete them" },
}
local function homeBytes()
  local tot = 0
  local ok, iter = pcall(filesystem.list, "/home")
  if ok and iter then
    for name in iter do
      local p = "/home/" .. name
      if not filesystem.isDirectory(p) then tot = tot + (filesystem.size(p) or 0) end
    end
  end
  return tot
end
local function readGrow()
  if SREP.hist then return SREP.hist end
  SREP.hist = {}
  local f = io.open(GROW_FILE, "r")
  if f then
    for line in f:lines() do
      local d, b = line:match("^(%d+)%s+(%d+)")
      if d then SREP.hist[#SREP.hist + 1] = { tonumber(d), tonumber(b) } end
    end
    f:close()
  end
  return SREP.hist
end
-- every 10 minutes: today's size of /home (one line per day, the last 60 days)
function SREP.grow()
  local up = computer.uptime()
  if up - SREP.at < 600 and SREP.at > 0 then return end
  SREP.at = up
  local t = now()
  if t < 1e9 then return end
  local e = toEastern(t)
  local day = daysFromCivil(e.year, e.month, e.day)
  local h = readGrow()
  local b = homeBytes()
  if h[#h] and h[#h][1] == day then h[#h][2] = b else h[#h + 1] = { day, b } end
  while #h > 60 do table.remove(h, 1) end
  local f = io.open(GROW_FILE, "w")
  if f then
    for _, r in ipairs(h) do f:write(r[1], " ", r[2], "\n") end
    f:close()
  end
end
local function countLines(path, size)
  if size > 400000 then return nil end          -- too big to read for a count
  local f = io.open(path, "r")
  if not f then return nil end
  local n = 0
  while true do
    local chunk = f:read(8192)
    if not chunk then break end
    local _, c = chunk:gsub("\n", "")
    n = n + c
  end
  f:close()
  return n
end
-- everything the report shows
function SREP.compute()
  SREP.grow()
  local rows = {}
  local files = {}
  local ok, iter = pcall(filesystem.list, "/home")
  if ok and iter then
    for name in iter do
      local p = "/home/" .. name
      if not filesystem.isDirectory(p) then
        files[#files + 1] = { name = name, size = filesystem.size(p) or 0, time = (filesystem.lastModified(p) or 0) / 1000, path = p }
      end
    end
  end
  local used = {}
  local total, biggest = 0, nil
  for _, k in ipairs(KINDS) do
    local r = { folder = k[1], label = k[2], kept = k[4], files = 0, bytes = 0, lines = 0, exact = true }
    for i, f in ipairs(files) do
      if not used[i] and f.name:match(k[3]) then
        used[i] = true
        r.files, r.bytes = r.files + 1, r.bytes + f.size
        local n = countLines(f.path, f.size)
        if n then r.lines = r.lines + n else r.exact = false end
        if f.time > 1e9 and (not r.newest or f.time > r.newest) then r.newest = f.time end
        if f.time > 1e9 and (not r.oldest or f.time < r.oldest) then r.oldest = f.time end
      end
    end
    rows[#rows + 1] = r
  end
  local other = { folder = "Other", label = "anything else in /home", kept = "--", files = 0, bytes = 0, lines = 0, exact = true }
  for i, f in ipairs(files) do
    total = total + f.size
    if not biggest or f.size > biggest.size then biggest = f end
    if not used[i] then
      other.files, other.bytes = other.files + 1, other.bytes + f.size
      if f.time > 1e9 and (not other.newest or f.time > other.newest) then other.newest = f.time end
      if f.time > 1e9 and (not other.oldest or f.time < other.oldest) then other.oldest = f.time end
      other.exact = false
    end
  end
  if other.files > 0 then rows[#rows + 1] = other end
  -- growth per day from the daily log
  local h = readGrow()
  local perDay, span
  if #h >= 2 then
    local a, b = h[1], h[#h]
    span = b[1] - a[1]
    if span >= 1 then perDay = (b[2] - a[2]) / span end
  end
  -- the drive /home lives on
  local hp = filesystem.get and select(1, pcall(filesystem.get, "/home")) and filesystem.get("/home")
  local hfree, htotal
  if hp then
    local okT, tt = pcall(hp.spaceTotal)
    local okU, uu = pcall(hp.spaceUsed)
    if okT and okU and tt and tt ~= math.huge then htotal, hfree = tt, tt - uu end
  end
  SREP.rp = { at = now(), rows = rows, total = total, biggest = biggest, perDay = perDay, span = span,
              days = #h, hfree = hfree, htotal = htotal }
end

-- dark report panels (same look as the archive's File Explorer)
local RG = { bg = 0x0B0B0B, panel = 0x161616, dark = 0x000000, text = 0xE6E6E6, dim = 0x8C8C8C, accent = 0x00C8FF,
             good = 0x3FE06A, warn = 0xFFB000, bad = 0xFF4D4D, grid = 0x333333, track = 0x2A2A2A, nb = 0xB07CFF }
local function rpanel(x, y, w, h, title, color, right)
  fill(x, y, w, h, RG.panel)
  fill(x, y, w, 1, color)
  text(x, y, " " .. title .. " ", RG.dark, color)
  if right then textW(x + w - unicode.len(right) - 1, y, unicode.len(right), right, RG.dark, color) end
end
local function rsegs(x, y, w, list)
  textW(x, y, w, "", RG.text, RG.panel)
  local cx = x
  for _, s in ipairs(list) do
    local room = x + w - cx
    if room <= 0 then break end
    local str = s[1]
    if unicode.len(str) > room then str = unicode.sub(str, 1, room) end
    text(cx, y, str, s[2], RG.panel)
    cx = cx + unicode.len(str)
  end
end
local function rbar(x, y, w, frac, col)
  local n = max(0, min(w, floor(w * frac + 0.5)))
  text(x, y, string.rep("█", n), col, RG.track)
  if w - n > 0 then text(x + n, y, string.rep("░", w - n), RG.grid, RG.track) end
end
local function dateOnly(t)
  local e = toEastern(t)
  return string.format("%02d/%02d/%04d", e.month, e.day, e.year)
end

function SREP.draw(full)
  if full or not SREP.rp then SREP.compute() end
  local rp = SREP.rp
  local X, W = PX0 + 1, PW - 2
  local Y, YB = PY0 + 1, PY0 + PH - 2
  fill(X, Y, W, YB - Y + 1, RG.bg)
  fill(X, Y, W, 1, 0x0E2A38)
  text(X + 1, Y, "≡ STORAGE REPORT", RG.accent, 0x0E2A38)
  textW(X + W - 41, Y, 40, "computed " .. fmtStamp(rp.at) .. "   ", RG.dim, 0x0E2A38, "right")
  -- drives
  local list = drives()
  local nd = min(#list, 5)
  local dh = nd + 3
  rpanel(X, Y + 1, W, dh, "DRIVES", RG.accent, #list .. " drive(s) ")
  for i, d in ipairs(list) do
    if i > 5 then break end
    local y = Y + 2 + i
    local total = d.total and d.total ~= math.huge and d.total or nil
    local frac = total and total > 0 and d.used / total or 0
    textW(X + 2, y, 14, table.concat(d.paths, " "), RG.text, RG.panel)
    rbar(X + 17, y, 50, frac, frac > 0.9 and RG.bad or (frac > 0.75 and RG.warn or RG.good))
    textW(X + 69, y, W - 71, total and string.format("%s used of %s   (%s free, %d%% full)%s", human(d.used), human(total),
      human(total - d.used), floor(frac * 100 + 0.5), d.kind == "RAM disk (tmpfs)" and "  RAM disk" or "") or (human(d.used) .. " used"),
      RG.text, RG.panel)
  end
  -- what is stored
  local ty = Y + 1 + dh + 1
  local rows = rp.rows
  local th = #rows + 4
  rpanel(X, ty, W, th, "WHAT IS STORED", RG.nb, "everything Lymanos keeps in /home ")
  local cols = { { "DATA", 10 }, { "DETAIL", 30 }, { "FILES", 5 }, { "LINES", 8 }, { "OLDEST", 10 }, { "NEWEST", 10 }, { "SIZE", 10 }, { "KEPT", 37 } }
  local function rowCells(y, cells, colr)
    local cx = X + 2
    for i, c in ipairs(cols) do
      textW(cx, y, c[2], cells[i], colr and colr(i) or RG.dim, RG.panel, (i >= 3 and i <= 4 or i == 7) and "right" or nil)
      cx = cx + c[2] + 1
    end
  end
  local head = {}
  for i, c in ipairs(cols) do head[i] = c[1] end
  rowCells(ty + 1, head)
  for r, row in ipairs(rows) do
    rowCells(ty + 1 + r, { row.folder, row.label, tostring(row.files), row.files > 0 and ((row.exact and "" or "~") .. commas(row.lines)) or "--",
      row.oldest and dateOnly(row.oldest) or "--", row.newest and dateOnly(row.newest) or "--",
      row.files > 0 and human(row.bytes) or "--", row.kept },
      function(i) return i == 1 and RG.accent or (i == 4 and RG.nb or (row.files > 0 and RG.text or RG.dim)) end)
  end
  rsegs(X + 2, ty + 2 + #rows, W - 4, { { "OLDEST / NEWEST = when the oldest and newest of those files were last written.   ", RG.dim },
    { "~ = some files not counted", RG.dim } })
  -- will it fill up?
  local fy = ty + th + 1
  local fh = YB - fy + 1
  rpanel(X, fy, W, fh, "WILL IT FILL UP?", RG.good)
  local L = {}
  L[#L + 1] = { { "Lymanos data in /home:  ", RG.dim }, { human(rp.total), RG.text },
    { rp.biggest and ("   (biggest file: " .. rp.biggest.name .. ", " .. human(rp.biggest.size) .. ")") or "", RG.dim } }
  if rp.perDay then
    L[#L + 1] = { { "Growth per day:  ", RG.dim }, { (rp.perDay >= 0 and "+" or "") .. human(math.abs(rp.perDay)) .. (rp.perDay < 0 and " smaller" or ""), RG.text },
      { "   measured over the last " .. rp.span .. " day(s)", RG.dim } }
  else
    L[#L + 1] = { { "Not enough data yet to measure the daily growth - Lymanos logs the size once a day; check back tomorrow.", RG.dim } }
  end
  if rp.hfree then
    local seg = { { "Free on the drive with /home:  ", RG.dim }, { human(rp.hfree), rp.hfree < 102400 and RG.bad or RG.text },
                  { "  of " .. human(rp.htotal), RG.dim } }
    if rp.perDay and rp.perDay > 1 then
      local days = rp.hfree / rp.perDay
      seg[#seg + 1] = { "   → full in about ", RG.dim }
      seg[#seg + 1] = { commas(floor(days + 0.5)) .. " days", days < 30 and RG.warn or RG.good }
      seg[#seg + 1] = { " (" .. dateOnly(now() + days * 86400) .. ")", RG.dim }
    elseif rp.perDay then
      seg[#seg + 1] = { "   → not growing: it won't fill up", RG.good }
    end
    L[#L + 1] = seg
  end
  L[#L + 1] = { { "Every Lymanos data file has a fixed limit (KEPT), so they level off and stop growing once full.", RG.text } }
  L[#L + 1] = { { "Only programs you add make /home bigger.", RG.dim } }
  L[#L + 1] = { { "Keep at least 100 KB free: if the drive fills up, saves fail and the newest changes are lost.", RG.dim } }
  for i, segs in ipairs(L) do
    if i > fh - 1 then break end
    rsegs(X + 2, fy + i, W - 4, segs)
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
  textW(x + 2, y + 31, PW - 8, "This program (Lymanos) is using about " ..
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
  elseif tab == "report" then SREP.draw(full)
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
  pcall(SREP.grow)
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
-- 6x12 bold font, ASCII 32-126, 12 rows of 2 hex digits per glyph (from X11 koi6x13b)
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
  local ok = responding(t)
  if lastPacket then
    parts[#parts + 1] = "LSC " .. (ok and ((snap and snap.signalOn) and "charging" or "idle") or "offline")
  end
  local fd, _, farmOk = LG.feedState()
  if farmOk and fd.farm then parts[#parts + 1] = "Farm " .. (fd.farm.active and "running" or "idle") end
  parts[#parts + 1] = (ROLE == "earth" and "Mars link " or "Earth link ") .. (LINK.state() and "OK" or "down")
  local free = computer.freeMemory()
  parts[#parts + 1] = string.format("RAM %dK free", floor(free / 1024))
  local s = table.concat(parts, "   ·   ")
  textW(W - 61, 49, 60, s, style()[4], rowBg(49), "right")
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
  text(3, 2, "◆ " .. tostring(SETTINGS.systemName or "Lymanos"), acc, rowBg(2))
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
local GRAPH_KEYS = { "nb", "gaps", "dur", "euout", "euin", "oak" }
local GRAPH_NAMES = { nb = "Nitrobenzene per cycle", gaps = "Time between charges", dur = "Charge duration",
  euout = "LSC EU out", euin = "LSC EU in", oak = "Oak Wood in AE2" }
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
  PLAYER_NAME = SETTINGS.userName or CONFIG.PLAYER_NAME or ("Player-" .. wlan.address:sub(1, 4))
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
  field("system", L + FX - 18, 9, 28, SETTINGS.systemName or "Lymanos")
end

local function drawWindow()
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ Settings - " .. tostring(SETTINGS.systemName or "Lymanos"), true)
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
  note(L, 21, LWd - 2, "Used on the taskbar, lock screen and Logs.")

  -- about
  groupBox(L - 2, 24, LWd + 2, 19, "About This Computer")
  local total, free = computer.totalMemory(), computer.freeMemory()
  local rows = {
    { "System:", tostring(SETTINGS.systemName or "Lymanos") .. "  (Lymanos Link " .. LYM_VERSION .. ")" },
    { "Role:", ROLE == "earth" and "Earth (home computer)" or ("Mars base  - " ..
      (rawget(_G, "LYMBOOT") and ("lymboot " .. tostring(rawget(_G, "LYMBOOT").version)) or "NOT under lymboot!")) },
    { "User:", tostring(PLAYER_NAME) },
    { "Memory:", string.format("%d K used of %d K", floor((total - free) / 1024), floor(total / 1024)) },
    { "Network card:", hasRadio and (wlan.address:sub(1, 8) .. (wlan.isWireless() and " (wireless)" or " (wired)")) or "none" },
    { "Linked card:", TUN and (TUN.address:sub(1, 8) .. "   channel " .. LINK.channel()) or "NOT FOUND" },
    { "Settings file:", CONFIG.SETTINGS_FILE },
  }
  for i, r in ipairs(rows) do
    label(L, 25 + i, r[1])
    textW(L + FX - 18, 25 + i, LWd - FX + 16, r[2], K.black, K.face)
  end
  note(L, 33, LWd - 2, "Settings save automatically. CONFIG at the top of")
  note(L, 34, LWd - 2, "lymanos.lua holds the defaults and advanced options.")
  button(regions, L, 38, 24, "Reset to defaults", function()
    dialog("Reset Settings", { "Put every setting back to its default?",
      "(Your name goes back to the CONFIG default too.)" }, {
      { "Yes", function()
          SETTINGS.userName, SETTINGS.systemName, SETTINGS.lockMins, SETTINGS.lockStyle = nil, "Lymanos", 30, 1
          SETTINGS.clock24, SETTINGS.desk = false, 1
          SETTINGS.logsQ = { "nb", "gaps" }
          K.desk = DESK_COLORS[1][2]
          PLAYER_NAME = CONFIG.PLAYER_NAME or ("Player-" .. wlan.address:sub(1, 4))
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

  -- link
  groupBox(R - 2, 23, RWd + 2, 9, ROLE == "earth" and "Mars Link" or "Earth Link")
  label(R, 25, "Link:")
  textW(R + FX - 18, 25, RWd - FX + 16, LINK.summary(), LINK.state() and K.green or K.red, K.face)
  if ROLE == "earth" then
    note(R, 26, RWd - 2, "Mars program sent from: " .. CONFIG.MARS_FILE)
    button(regions, R, 27, 18, "Mars Link...", function() LINK.dialog() end)
    button(regions, R + 20, 27, 24, "Update Mars Base...", function() LINK.confirmUpdate("program") end)
  else
    note(R, 26, RWd - 2, "Updates come from Earth (Start > Update Mars Base).")
    button(regions, R, 27, 18, "Earth Link...", function() LINK.dialog() end)
  end
  note(R, 30, RWd - 2, "Click the link light on the taskbar for details.")

  -- logs
  groupBox(R - 2, 33, RWd + 2, 10, "Logs")
  for i = 1, 2 do
    label(R, 33 + i * 2, "Graph panel " .. i .. ":")
    cycler(R + FX - 18, 33 + i * 2, 22, GRAPH_NAMES[SETTINGS.logsQ[i]] or "?", function(d)
      SETTINGS.logsQ[i] = step(GRAPH_KEYS, SETTINGS.logsQ[i], d); changed()
    end)
  end
  note(R, 39, RWd - 2, "Same as the dropdowns on the Logs graph panels.")

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
  local t = now()
  regions = {}
  SYS.resetRegions()
  if not keepOverlay then overlay = nil end
  drawDesktop()
  if activeApp == "graphs" then             -- full screen, gtgraphs' own taskbar
    taskRegions = {}
    GT.draw()
    return
  end
  if activeApp == "viewer" then
    LG.draw(t)
    region(regions, WX + 2, WY + 2, 6, 1, fileMenu)
    region(regions, WX + 8, WY + 2, 6, 1, viewMenu)
    region(regions, WX + 14, WY + 2, 6, 1, helpMenu)
  elseif activeApp == "sys" then
    SYS.drawWindow()
  elseif activeApp == "settings" then
    SET.drawWindow()
  end
  drawTaskbar(t)
end

------------------------------------------------------------- MAIN LOOP
local oldW, oldH = gpu.getResolution()

-- a packet from an Earth program: heard on Earth's own wireless card, or on
-- Mars relayed by Earth (from = the sending computer on Earth, dist = nil)
local function onFeed(from, dist, port, tag, a, b)
  if port == CONFIG.PORT and tag == "LSCSTATS" then
    if CONFIG.SENDER and tostring(from):sub(1, #CONFIG.SENDER) ~= CONFIG.SENDER then return end
    pcall(GT.onLscstats, b)
    local changed = receive(from, dist, b)
    statusMsg = changed and "New cycle data received" or "Update received"
    if not overlay then
      if activeApp == "viewer" then
        if changed then drawAll() else LG.tick(now()) end
      else drawTray(now()) end
    end
  elseif port == CONFIG.FUEL_PORT and tag == "LSCFUEL" then
    LG.onFuel(b)
    pcall(GT.onFuel, b)
  elseif port == CONFIG.FARM_PORT and tag == "TREEFARM" then
    LG.onFarm(b)
    pcall(GT.onFarm, b)
  end
end

local function main()
  local mw, mh = gpu.maxResolution()
  if mw < W or mh < H then error("Lymanos needs a tier 3 GPU and screen (160x50).", 0) end
  gpu.setResolution(W, H)
  loadSaved()
  LINK.load()
  GT.init()
  LINK.setFeed(onFeed)
  drawAll()
  if ROLE == "earth" then requestUpdate() end   -- (Mars: LINK.start's hello makes Earth resend)
  LINK.start()

  local lastTick = 0
  while running do
    gpu.flush()                        -- show this pass's drawing in one go
    local ev = { event.pull(LINK.fast() and 0.05 or 0.5) }
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
      elseif activeApp == "graphs" then
        local okg, ge = pcall(GT.touch, x, y)
        if not okg then statusMsg = "GT Graphs error: " .. tostring(ge) end
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
    elseif name == "scroll" and not overlay and activeApp == "sys" then
      SYS.scroll(ev[3], ev[4], ev[5])
    elseif name == "scroll" and not overlay and activeApp == "viewer" then
      LG.scroll(ev[3], ev[4], ev[5])
    elseif name == "modem_message" and TUN and ev[2] == TUN.address then
      -- from the other planet (linked card: port 0, distance 0)
      local ok, act = pcall(LINK.onTunnel, ev[3], ev[6], ev[7], ev[8], ev[9], ev[10], ev[11], ev[12], ev[13], ev[14], ev[15])
      if not ok then statusMsg = "Link error: " .. tostring(act)
      elseif act == "update" or act == "restart" then exitReason = act; running = false end
    elseif name == "modem_message" then
      -- wireless: Earth uses the Earth programs' packets and passes them to Mars;
      -- Mars passes its own programs' packets (CONFIG.MARS_PORTS) home
      if ROLE == "earth" then onFeed(ev[3], ev[5], ev[4], ev[6], ev[7], ev[8]) end
      if not LINK.onMarsRadio(ev[4], ev[6]) then LINK.relay(ev[4], ev[6], ev[3], ev[7], ev[8]) end
    elseif name == "key_down" and activeApp == "settings" and SET.focus() and not overlay then
      SET.key(ev[3], ev[4])
    end

    LINK.pump()

    local up = computer.uptime()
    if running and up - lastTick >= 1 then
      lastTick = up
      local t = now()
      if LOCK.isLocked() then
        LOCK.tick(t)
      elseif not overlay then
        if activeApp == "viewer" then LG.tick(t) end
        drawTray(t)
      end
      SYS.tick(activeApp == "sys" and not overlay)
      local okg, ge = pcall(GT.tick, activeApp == "graphs" and not overlay and not LOCK.isLocked())
      if not okg then statusMsg = "GT Graphs error: " .. tostring(ge) end
      local okl, le = pcall(LINK.tick)
      if not okl then statusMsg = "Link error: " .. tostring(le) end
      -- lock after the idle time set in Settings (0 = never)
      local mins = SETTINGS.lockMins or 0
      if mins > 0 and not LOCK.isLocked() and LOCK.idle() >= mins * 60 then LOCK.lock() end
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
pcall(LINK.save)                   -- link events + the other end's status (+ Mars data on Earth)
pcall(GT.save)                     -- graph history + layout
gpu.setResolution(oldW, oldH)
rgpu.setBackground(0x000000)
rgpu.setForeground(0xFFFFFF)
term.clear()
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write(tostring(err) .. "\n")
  return { reason = "crash", err = tostring(err) }
end
if exitReason and not rawget(_G, "LYMBOOT") then
  print("Lymanos was updated - start it again to run the new version.")
end
return { reason = exitReason or "exit" }
