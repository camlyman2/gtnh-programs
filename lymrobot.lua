--[[
  lymrobot.lua  -  Lymanos Robot (a stripped-down Lymanos for the robot controller)

  Apps:
    Robot Control  drive a robot over a Linked Card: manual buttons, a live
                   map of everything it touches and scans, click-to-go
                   pathfinding, vein mining, going home to unload and charge,
                   and over-the-air updates of the robot's program
    My Computer    storage, memory, power and hardware details
    Settings       your name, system name, lock screen, desktop color and the
                   Robot Control options. Saved to /home/lymanos_settings.dat

  Lock screen: Start > Lock, or automatically after a period without
  activity (Settings). Everything keeps running while locked - the robot
  keeps working too.

  Files on this computer:
    /home/lymrobot.lua          this program
    /home/robot.lua             the robot's program (sent to the robot by its boot.lua)
    /home/rc_map.dat            the map
    /home/rc_state.dat          home position, energy-per-move, mined tally, view
    /home/lymanos_settings.dat  settings

  Needs: tier 3 GPU + tier 3 screen (160x50), a Linked Card paired with the
  robot's card. Mouse + keyboard. Exit: Start > Shut Down, File > Exit, or Ctrl+C.
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  PLAYER_NAME = nil,               -- default name; normally set in the Settings app
  SETTINGS_FILE = "/home/lymanos_settings.dat",   -- written by the Settings app

  -- Robot Control
  ROBOT_PROGRAM = "/home/robot.lua",   -- master copy of the robot's program
  MAP_FILE = "/home/rc_map.dat",
  STATE_FILE = "/home/rc_state.dat",
  LINK_ADDR = nil,                 -- nil = first Linked Card, or the start of its address
  LINK_STALE = 30,                 -- seconds without a word from the robot = offline
  WAKE = "RC_WAKE",                -- must match WAKE in boot.lua
  MAP_MAX = 30000,                 -- blocks kept on the map (far plain blocks are forgotten first)
  SEGMENT = 32,                    -- long trips are planned in pieces of this many blocks
  PLAN_BUDGET = 400,               -- route search: blocks checked per main-loop pass
  PLAN_MAX = 12000,                -- give up a route search after this many blocks
  BATCH = 6,                       -- steps sent to the robot at a time
  GEO_NOISE = 2,                   -- geolyzerNoise from the server's OpenComputers config
  -- never dig blocks whose name contains one of these (same list as robot.lua)
  AVOID = { "opencomputers", "chest", "charger", "enderstorage", "appliedenergistics",
            "gt.blockmachines", "bedrock", "computer", "ironchest", "storagedrawers" },
  ORE = { "ore" },                 -- a block is ore when its name contains one of these
  NOT_ORE = { "core", "store", "orechid" },
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
---------------------------------------------------------------- SETTINGS
-- Values changed in the Settings app. They override CONFIG and are saved
-- as a small text table. nil = use the CONFIG default.
local SETTINGS = {
  userName = nil,       -- your name
  systemName = "Lymanos",
  lockMins = 30,        -- auto-lock after this many idle minutes (0 = never)
  lockStyle = 1,        -- lock screen color theme
  clock24 = false,      -- 24-hour clock on the taskbar and lock screen
  desk = 1,             -- desktop color
  rc = nil,             -- Robot Control options (defaults below)
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
-- Robot Control options (Settings app). Missing ones get their defaults.
local RC_DEFAULTS = {
  scanR = 4,          -- scan radius (blocks each way)
  scanEvery = 12,     -- vein mining: scan again after this many moves (0 = only when out of targets)
  veinR = 16,         -- vein mining: mine ores within this many blocks of the picked block
  reserve = 15,       -- % of the battery kept on top of the trip home
  chargeTo = 95,      -- % to charge to at home before going back to the vein
  rock = 1.5,         -- hardness of the plain rock where it mines (stone 1.5, netherrack 0.4, end stone 3.0)
  liquids = false,    -- route through liquids
  homeDone = true,    -- go home when the vein is finished
  unload = "down",    -- where the home chest is, seen from the robot at home
  digThrough = true,  -- manual moves dig what's in the way
}
if type(SETTINGS.rc) ~= "table" then SETTINGS.rc = {} end
for k, v in pairs(RC_DEFAULTS) do if SETTINGS.rc[k] == nil then SETTINGS.rc[k] = v end end

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
----------------------------------------------------------------- NETWORK
-- The robot is reached through the Linked Card (Robot Control). A network
-- card is optional here; it's only shown in Settings / My Computer.
local wlan
for addr in component.list("modem") do
  local m = component.proxy(addr)
  if m.isWireless() then wlan = m; break end
end
if not wlan then
  local a = component.list("modem")()
  if a then wlan = component.proxy(a) end
end
local PLAYER_NAME = SETTINGS.userName or CONFIG.PLAYER_NAME or ("Player-" .. computer.address():sub(1, 4))

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
----------------------------------------------------------------- FILES
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
local activeApp = "robot"     -- window in front: "robot" | "sys" | "settings" | nil (desktop)
local statusMsg = "Ready"
local lockedFlag = false      -- lock screen up (set by LOCK)

-- Window geometry
local WX, WY, WW, WH = 14, 2, 144, 44

--------------------------------------------------------------- DESKTOP
local function drawIcon(x, y, kind, label)
  if kind == "pc" then
    fill(x + 1, y, 6, 2, K.face)
    fill(x + 2, y, 4, 1, K.navy)
    fill(x + 2, y + 1, 4, 1, K.navy)
    fill(x + 2, y + 2, 4, 1, K.face)
  elseif kind == "bin" then
    text(x + 2, y, "▄▄▄▄", K.sh, K.desk)
    fill(x + 2, y + 1, 4, 2, K.face)
    text(x + 2, y + 1, "║║║║", K.sh, K.face)
  end
  textW(x - 2, y + 3, 12, label, K.white, K.desk, "center")
end

local drawAll                                           -- forward
local openSysApp, closeSysApp, sysAppOpen               -- forward (My Computer)
local openSettings, closeSettings, settingsOpen         -- forward (Settings)
local LOCK, SET, RC                                     -- lock screen, Settings, Robot Control (below)

local function drawDesktop()
  fill(1, 1, W, 46, K.desk)
  drawIcon(3, 2, "pc", "My Computer")
  region(regions, 1, 2, 12, 5, function() openSysApp(); drawAll() end)
  -- Robot Control icon: a little robot head
  text(5, 8, "▗▄▄▄▄▖", 0x8C8C8C, K.desk)
  text(5, 9, "▐●  ●▌", 0x00C8FF, 0x5A5A5A)
  text(5, 10, "▝▀▀▀▀▘", 0x5A5A5A, K.desk)
  textW(1, 11, 12, "Robot", K.white, K.desk, "center")
  region(regions, 1, 8, 12, 4, function() RC.open(); drawAll() end)
  -- Settings icon: a little control panel with sliders
  fill(4, 14, 8, 3, K.face)
  text(4, 14, "─●──────", K.navy, K.face)
  text(4, 15, "────●───", K.navy, K.face)
  text(4, 16, "──────●─", K.navy, K.face)
  textW(1, 17, 12, "Settings", K.white, K.desk, "center")
  region(regions, 1, 14, 12, 4, function() openSettings(); drawAll() end)
  drawIcon(3, 43, "bin", "Recycle Bin")
end

----------------------------------------------------------------- TASKBAR
local function drawTray(t)
  bevel(144, 48, 16, 3, "sunken", K.face, K.face)
  text(146, 49, "((•))", RC.linkOK() and K.green or K.sh, K.face)
  textW(151, 49, 8, fmtTray(t), K.black, K.face, "right")
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
  local list = {}
  if RC.isOpen() then list[#list + 1] = { RC.alert() and " ◘ Robot - CHECK LOG!" or " ◘ Robot Control", "robot" } end
  if sysAppOpen and sysAppOpen() then list[#list + 1] = { " ▣ My Computer", "sys" } end
  if settingsOpen and settingsOpen() then list[#list + 1] = { " ▣ Settings", "settings" } end
  if #list > 0 then
    local bw = min(25, floor(132 / #list) - 1)
    for i, it in ipairs(list) do taskButton(11 + (i - 1) * (bw + 1), bw, it[1], it[2]) end
  end
  drawTray(t)
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

local function about()
  dialog("About " .. tostring(SETTINGS.systemName or "Lymanos"), {
    tostring(SETTINGS.systemName or "Lymanos") .. "  -  Lymanos Robot 1.0",
    "A stripped-down Lymanos for driving a robot over a Linked Card:",
    "Robot Control, My Computer and Settings.",
  }, { { "OK" } })
end

local function confirmExit()
  dialog("Shut Down", { "Are you sure you want to close Lymanos?",
    "(The robot finishes the step it's on, then waits.)" },
    { { "Yes", function() running = false end }, { "No" } })
end

openStartMenu = function()
  popupMenu(1, 47, {
    { "Robot Control", function() RC.open() end },
    { "My Computer", function() openSysApp() end },
    { "Settings", function() openSettings() end },
    { "-" },
    { "Lock", function() LOCK.lock() end },
    { "About...", about },
    { "-" },
    { "Shut Down...", confirmExit },
  }, { banner = true, above = true, start = true })
end

------------------------------------------------------------ MY COMPUTER
-- Storage, memory, power and component details for this computer.
-- Own function = own local-variable budget.
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
  elseif c.type == "tunnel" then
    add("Linked Card", "talks only to its twin card (the robot)")
    add("Channel", safe(p.getChannel))
    add("Max packet size", safe(p.maxPacketSize))
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
  { "Robot", "map of everything seen", "^rc_map%.dat$", commas(CONFIG.MAP_MAX) .. " blocks (far plain blocks forgotten first)" },
  { "", "home, energy per move, mined tally", "^rc_state%.dat$", "fixed size" },
  { "", "robot program (sent to the robot)", "^robot%.lua$", "your master copy" },
  { "System", "settings + clock", "^lymanos_settings%.dat$", "fixed size" },
  { "", "this report's growth log", "^lymanos_storage%.dat$", "60 days" },
  { "Programs", "Lua programs (lymrobot.lua, ...)", "%.lua$", "until you delete them" },
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
  L[#L + 1] = { { "Only new players' accounts and programs you add make /home bigger.", RG.dim } }
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
------------------------------------------------------------ ROBOT CONTROL
-- Talks to one robot over the Linked Card. Manual buttons, a live map built
-- from everything the robot touches and scans, click-to-go pathfinding (A*),
-- vein mining, going home to unload and charge, and over-the-air updates of
-- the robot program (/home/robot.lua on this computer).
-- Own function = own local-variable budget (see Brokerage).
RC = (function()
local G = {
  bg = 0x0B0B0B, panel = 0x161616, panel2 = 0x242424, header = 0x0E2A38,
  text = 0xE6E6E6, dim = 0x8C8C8C, dark = 0x000000, accent = 0x00C8FF,
  good = 0x3FE06A, warn = 0xFFB000, bad = 0xFF4D4D, grid = 0x333333,
  button = 0x2E4A5A, track = 0x2A2A2A, pink = 0xFF4DFF, path = 0xFFE04D,
}
local RS = SETTINGS.rc
local abs, sqrt = math.abs, math.sqrt

-- block types on the map (number kept in each map cell: type + hardness + distance)
local T = { AIR = 1, TRAIL = 2, MINED = 3, STONE = 4, SOFT = 5, CAND = 6, ORE = 7,
            LIQUID = 8, BEDROCK = 9, OTHER = 10, BLOCKED = 11 }
local TNAME = { [0] = "Unknown", "Air", "Robot trail", "Mined ore", "Stone", "Soft block (dirt/gravel)",
  "Maybe ore (scan)", "Ore", "Liquid", "Bedrock", "Protected block", "Blocked (couldn't pass)" }
local FACE = { [0] = "North", "East", "South", "West" }
local ARROW = { [0] = "▲", "►", "▼", "◄" }

-- layout (inside the standard Lymanos window)
local MX0, MW, MY0, MROWS = WX + 1, 96, WY + 5, 35     -- map: x 15..110, rows 7..41
local RX0, RW = WX + 98, 45                            -- right column: x 112..156
local SY = WY + WH - 2                                 -- status row

local rcRegions = {}
local isOpen, alertFlag = false, false

---------------------------------------------------------------- link
local tunnel
local function findLink()
  tunnel = nil
  for addr in component.list("tunnel") do
    if not CONFIG.LINK_ADDR or addr:sub(1, #CONFIG.LINK_ADDR) == CONFIG.LINK_ADDR then
      tunnel = component.proxy(addr)
      break
    end
  end
end
findLink()
local function tsend(kind, ...)
  if not tunnel then return false end
  return pcall(tunnel.send, "RC", kind, ...)
end
local function unser(s)
  if type(s) == "table" then return s end
  if type(s) ~= "string" or s == "" then return nil end
  local ok, t = pcall(serialization.unserialize, s)
  if ok then return t end
end
local function checksum(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end
local function lowerHas(name, list)
  name = tostring(name or ""):lower()
  for _, p in ipairs(list) do if name:find(p, 1, true) then return true end end
  return false
end
local function isOreName(n) return lowerHas(n, CONFIG.ORE) and not lowerHas(n, CONFIG.NOT_ORE) end

---------------------------------------------------------------- robot state
local R = { st = nil, heard = nil, progSum = nil, progAt = -100, err = nil }
local home = nil              -- { x, y, z, f }
local perStep = 25            -- energy per move (learned)
local drops = {}              -- item label -> count (mined this session)
local logs = {}
local manual = {}             -- command id -> label (manual buttons)
local cmdSeq = 0
local trip, job = nil, nil
local PATH = {}               -- map keys of the route still to go
local prompt = nil            -- { label, input, onEnter }

local function linkOK() return R.heard ~= nil and computer.uptime() - R.heard <= CONFIG.LINK_STALE end

local refresh   -- forward
local function log(s, col)
  table.insert(logs, 1, { fmtTray(now()), tostring(s), col or G.text })
  while #logs > 60 do table.remove(logs) end
end
local function alert() if activeApp ~= "robot" then alertFlag = true end end

---------------------------------------------------------------- map
-- One number per block: type + 16 * hardness code + 16384 * scan distance
-- (distance 0 = the robot touched it, so it's certain). Keys pack x/y/z
-- into one number. Ordinary stone seen only by scans isn't stored at all:
-- unknown blocks are treated as stone, which keeps the map small.
local OFF, SPAN, YS, YOFF = 1048576, 2097152, 512, 64
local MAP = { M = {}, ore = {}, cand = {}, n = 0, dirty = false, okeys = {}, oidx = {}, savedAt = 0 }
local function key(x, y, z) return ((x + OFF) * SPAN + (z + OFF)) * YS + (y + YOFF) end
local function unkey(k)
  local y = k % YS
  local r = (k - y) / YS
  local z = r % SPAN
  local x = (r - z) / SPAN
  return floor(x - OFF + 0.5), floor(y - YOFF + 0.5), floor(z - OFF + 0.5)
end
local function typeAt(k) local v = MAP.M[k]; return v and v % 16 or 0 end
local function distAt(k) local v = MAP.M[k]; return v and floor(v / 16384) or nil end
local function hardAt(k)
  local v = MAP.M[k]
  if not v then return nil end
  return (floor(v / 16) % 1024 - 100) / 10
end
local function setCell(k, t, d, h)
  local q = h and max(0, min(1023, floor(h * 10 + 0.5) + 100)) or 0
  if MAP.M[k] == nil then MAP.n = MAP.n + 1 end
  MAP.M[k] = t + 16 * q + 16384 * max(0, min(99, d or 0))
  if t ~= T.ORE then MAP.ore[k] = nil end
  if t == T.CAND then MAP.cand[k] = true else MAP.cand[k] = nil end
  MAP.dirty = true
end
local function delCell(k)
  if MAP.M[k] ~= nil then
    MAP.M[k], MAP.ore[k], MAP.cand[k] = nil, nil, nil
    MAP.n = MAP.n - 1
    MAP.dirty = true
  end
end
local function oreIndex(name, meta)
  local s = tostring(name) .. "#" .. tostring(meta or 0)
  local i = MAP.oidx[s]
  if not i then
    MAP.okeys[#MAP.okeys + 1] = s
    i = #MAP.okeys
    MAP.oidx[s] = i
  end
  return i
end

-- what the robot detected / analyzed next to it: { x, y, z, desc, name, meta, hardness }
local function senseCell(e)
  if type(e) ~= "table" or not e[1] then return end
  local k = key(e[1], e[2], e[3])
  local desc, name, meta, h = e[4], e[5], e[6], e[7]
  local old = typeAt(k)
  if desc == "air" or desc == "passable" or desc == "replaceable" then
    if old == T.ORE or old == T.CAND then setCell(k, T.MINED, 0)
    elseif old ~= T.TRAIL and old ~= T.MINED then setCell(k, T.AIR, 0) end
  elseif desc == "liquid" then
    setCell(k, T.LIQUID, 0)
  elseif desc == "solid" then
    local n = tostring(name or ""):lower()
    if n:find("bedrock", 1, true) or (h and h < 0) then setCell(k, T.BEDROCK, 0, h)
    elseif n ~= "" and lowerHas(n, CONFIG.AVOID) then setCell(k, T.OTHER, 0, h)
    elseif n ~= "" and isOreName(n) then setCell(k, T.ORE, 0, h); MAP.ore[k] = oreIndex(name, meta)
    elseif h and h < 1 then setCell(k, T.SOFT, 0, h)
    else setCell(k, T.STONE, 0, h) end
  end
end

local minedTotal = 0
local function markVisited(x, y, z)
  local k = key(x, y, z)
  local t = typeAt(k)
  if t == T.ORE or t == T.CAND then setCell(k, T.MINED, 0); minedTotal = minedTotal + 1
  elseif t ~= T.MINED and t ~= T.TRAIL then setCell(k, T.TRAIL, 0) end
end

-- one reading from a geolyzer scan. The geolyzer adds noise of up to
-- distance * GEO_NOISE / 33, so a reading only counts as "maybe ore" when it
-- can't be plain base rock at that distance. New readings are averaged with
-- old ones (closer counts more). Blocks the robot touched are certain, unless
-- a close scan clearly says they changed (dug out, filled in, flooded).
local function applyScan(k, h, d)
  local v = MAP.M[k]
  if v then
    local od = floor(v / 16384)
    if od == 0 then
      local ot = v % 16
      local open = ot == T.AIR or ot == T.TRAIL or ot == T.MINED
      if d > 3 then return end
      if (open and h >= 1.0) or (not open and ot ~= T.LIQUID and ot ~= T.BEDROCK and ot ~= T.OTHER and h < 0.3) then
        delCell(k)
        v = nil
      else
        return
      end
    end
  end
  if v then
    local od = floor(v / 16384)
    local oh = (floor(v / 16) % 1024 - 100) / 10
    local wo, wn = 1 / od, 1 / d
    h = (oh * wo + h * wn) / (wo + wn)
    d = min(od, d)
  end
  local m = d * CONFIG.GEO_NOISE / 33          -- largest possible noise at this distance
  local rock = RS.rock or 1.5
  local t
  if h >= 30 then t = T.LIQUID
  elseif h < -(m + 0.05) then t = T.BEDROCK
  elseif h < min(0.3, rock / 2) and h > -m then t = T.AIR
  elseif h > rock + m + 0.05 then t = T.CAND end
  if t then setCell(k, t, d, h) elseif v then delCell(k) end
end

local function onScan(cx, cy, cz, r, dy, data)
  cx, cy, cz, r, dy = tonumber(cx), tonumber(cy), tonumber(cz), tonumber(r), tonumber(dy)
  if not (cx and cy and cz and r and dy) or type(data) ~= "string" then return end
  local y = cy + dy
  local j = 0
  for row in data:gmatch("[^;]+") do
    local z, i = cz - r + j, 0
    for val in row:gmatch("[^,]+") do
      local x = cx - r + i
      local d = floor(sqrt((x - cx) ^ 2 + (y - cy) ^ 2 + (z - cz) ^ 2) + 0.5)
      if d >= 1 then applyScan(key(x, y, z), tonumber(val) or 0, d) end
      i = i + 1
    end
    j = j + 1
  end
end

-- keep the map under CONFIG.MAP_MAX blocks: forget plain blocks far away
local function prune()
  if MAP.n <= CONFIG.MAP_MAX then return end
  local s = R.st or { x = 0, y = 64, z = 0 }
  local gone = {}
  for k, v in pairs(MAP.M) do
    local t = v % 16
    if t == T.AIR or t == T.STONE or t == T.SOFT or t == T.BLOCKED then
      local x, y, z = unkey(k)
      if abs(x - s.x) + abs(y - s.y) + abs(z - s.z) > 40 then gone[#gone + 1] = k end
    end
  end
  for _, k in ipairs(gone) do delCell(k) end
  log("Map trimmed: forgot " .. #gone .. " far-away blocks", G.dim)
end

local function saveMap()
  local f = io.open(CONFIG.MAP_FILE, "w")
  if not f then return end
  f:write("RCMAP1\n")
  local buf, n = {}, 0
  for k, v in pairs(MAP.M) do
    n = n + 1
    buf[n] = string.format("%.0f %.0f %d", k, v, MAP.ore[k] or 0)
    if n >= 400 then f:write(table.concat(buf, "\n", 1, n), "\n"); n = 0 end
  end
  if n > 0 then f:write(table.concat(buf, "\n", 1, n), "\n") end
  f:close()
  MAP.dirty, MAP.savedAt = false, computer.uptime()
end

local V = { cx = 0, cz = 0, y = 64, follow = true, zoom = 2, sel = nil, x0 = 0, z0 = 0, cols = 48, centered = false }

local function saveState()
  writeFile(CONFIG.STATE_FILE, serialization.serialize({
    home = home, perStep = perStep, okeys = MAP.okeys, drops = drops, mined = minedTotal,
    view = { cx = V.cx, cz = V.cz, y = V.y, follow = V.follow, zoom = V.zoom }, last = R.st }))
end

local function load()
  local t = unser(readFile(CONFIG.STATE_FILE))
  if type(t) == "table" then
    home, perStep = t.home, tonumber(t.perStep) or 25
    MAP.okeys = type(t.okeys) == "table" and t.okeys or {}
    for i, s in ipairs(MAP.okeys) do MAP.oidx[s] = i end
    drops = type(t.drops) == "table" and t.drops or {}
    minedTotal = tonumber(t.mined) or 0
    if type(t.view) == "table" then
      V.cx, V.cz, V.y = t.view.cx or 0, t.view.cz or 0, t.view.y or 64
      V.follow, V.zoom = t.view.follow ~= false, t.view.zoom == 1 and 1 or 2
      V.centered = true
    end
    if type(t.last) == "table" then R.st = t.last end
  end
  local f = io.open(CONFIG.MAP_FILE, "r")
  if f then
    local first = f:read("*l")
    if first == "RCMAP1" then
      for line in f:lines() do
        local a, b, c = line:match("^(%-?%d+) (%d+) (%d+)")
        if a then
          local k, v, o = tonumber(a), tonumber(b), tonumber(c)
          if MAP.M[k] == nil then MAP.n = MAP.n + 1 end
          MAP.M[k] = v
          if v % 16 == T.ORE and o > 0 then MAP.ore[k] = o end
          if v % 16 == T.CAND then MAP.cand[k] = true end
        end
      end
    end
    f:close()
  end
  MAP.dirty = false
  log("Map loaded: " .. commas(MAP.n) .. " blocks", G.dim)
  if not tunnel then log("No Linked Card found in this computer!", G.bad) end
end

---------------------------------------------------------------- pathfinding (A*)
-- Moves: 4 sides + up + down. Air costs 1, a block to dig ~2.2, unknown ~2.5
-- (probably stone). Liquids, bedrock and protected blocks are walls.
-- Runs a few hundred blocks per main-loop pass so the screen never freezes.
local NX = { [0] = 0, 1, 0, -1, 0, 0 }
local NY = { [0] = 0, 0, 0, 0, 1, -1 }
local NZ = { [0] = -1, 0, 1, 0, 0, 0 }
local COST = { [0] = 2.5, 1, 1, 1, 2.2, 2.2, 2.2, 2.2 }   -- by type; nil = can't pass
local TURN = 0.4

local function stepCost(k)
  local t = typeAt(k)
  local c = COST[t]
  if c then return c end
  if t == T.LIQUID and RS.liquids then return 6 end
  return nil
end

local function heapPush(P, k, f)
  local n = P.hn + 1
  P.hn = n
  local hk, hf = P.hk, P.hf
  while n > 1 do
    local p = floor(n / 2)
    if hf[p] <= f then break end
    hk[n], hf[n] = hk[p], hf[p]
    n = p
  end
  hk[n], hf[n] = k, f
end
local function heapPop(P)
  local hk, hf, n = P.hk, P.hf, P.hn
  local top = hk[1]
  local lk, lf = hk[n], hf[n]
  hk[n], hf[n] = nil, nil
  n = n - 1
  P.hn = n
  if n > 0 then
    local i = 1
    while true do
      local c = i * 2
      if c > n then break end
      if c < n and hf[c + 1] < hf[c] then c = c + 1 end
      if hf[c] >= lf then break end
      hk[i], hf[i] = hk[c], hf[c]
      i = c
    end
    hk[i], hf[i] = lk, lf
  end
  return top
end

local function newPlanner(sk, gk, f0)
  local sx, sy, sz = unkey(sk)
  local gx, gy, gz = unkey(gk)
  local M = 12
  local P = {
    s = sk, g = gk, gx = gx, gy = gy, gz = gz,
    bx1 = min(sx, gx) - M, bx2 = max(sx, gx) + M,
    by1 = max(-60, min(sy, gy) - M), by2 = min(400, max(sy, gy) + M),
    bz1 = min(sz, gz) - M, bz2 = max(sz, gz) + M,
    G = { [sk] = 0 }, came = {}, dir = { [sk] = f0 or 0 }, closed = {},
    hk = {}, hf = {}, hn = 0, n = 0, done = false,
  }
  heapPush(P, sk, 0)
  return P
end

local function plannerStep(P, budget)
  for _ = 1, budget do
    if P.hn == 0 then P.done, P.err = true, "no route found"; return end
    local k = heapPop(P)
    if not P.closed[k] then
      if k == P.g then
        local path, c = {}, k
        while c ~= P.s do table.insert(path, 1, c); c = P.came[c] end
        P.path, P.done = path, true
        return
      end
      P.closed[k] = true
      P.n = P.n + 1
      if P.n > CONFIG.PLAN_MAX then P.done, P.err = true, "route too complicated (try a closer target)"; return end
      local x, y, z = unkey(k)
      local g0, d0 = P.G[k], P.dir[k]
      for d = 0, 5 do
        local nx, ny, nz = x + NX[d], y + NY[d], z + NZ[d]
        if nx >= P.bx1 and nx <= P.bx2 and ny >= P.by1 and ny <= P.by2 and nz >= P.bz1 and nz <= P.bz2 then
          local nk = key(nx, ny, nz)
          if not P.closed[nk] then
            local c = stepCost(nk)
            if c then
              if d <= 3 and d ~= d0 then c = c + TURN end
              local g2 = g0 + c
              if g2 < (P.G[nk] or math.huge) then
                P.G[nk], P.came[nk], P.dir[nk] = g2, k, (d <= 3) and d or d0
                heapPush(P, nk, g2 + 1.05 * (abs(nx - P.gx) + abs(ny - P.gy) + abs(nz - P.gz)))
              end
            end
          end
        end
      end
    end
  end
end

-- route -> robot steps ("face" to turn, "tf"/"tu"/"td" = dig if needed + move)
local function stepsFromPath(path, x, y, z, f, match)
  local steps, keys = {}, {}
  for _, k in ipairs(path) do
    local nx, ny, nz = unkey(k)
    if ny > y then steps[#steps + 1] = { "tu" }
    elseif ny < y then steps[#steps + 1] = { "td" }
    else
      local d = (nx > x and 1) or (nx < x and 3) or (nz > z and 2) or 0
      if d ~= f then steps[#steps + 1] = { "face", d }; f = d end
      steps[#steps + 1] = { "tf" }
    end
    keys[#steps] = k
    x, y, z = nx, ny, nz
  end
  if match and #steps > 0 then steps[#steps].m = match end
  return steps, keys
end

---------------------------------------------------------------- trips
local finishTrip, planTrip   -- forward

local function sendSteps()
  local t = trip
  local n = min(#t.steps - t.next + 1, CONFIG.BATCH)
  if n <= 0 then return end
  local list = {}
  for i = 1, n do list[i] = t.steps[t.next + i - 1] end
  cmdSeq = cmdSeq + 1
  t.id, t.bstart, t.bn, t.sentAt = cmdSeq, t.next, n, computer.uptime()
  tsend("CMD", cmdSeq, serialization.serialize(list))
end

local function arrived()
  local cb = trip and trip.onDone
  trip, PATH = nil, {}
  if cb then cb(true) end
end

finishTrip = function(ok, why)
  local cb = trip and trip.onDone
  trip, PATH = nil, {}
  if not ok and not tostring(why):find("^nomatch") then log("✗ " .. tostring(why), G.warn) end
  if cb then cb(ok, why) end
end

planTrip = function()
  local t, s = trip, R.st
  if not s then return finishTrip(false, "no robot position yet") end
  local sk = key(s.x, s.y, s.z)
  local gx, gy, gz = unkey(t.goal)
  local dist = abs(gx - s.x) + abs(gy - s.y) + abs(gz - s.z)
  local seg = t.goal
  if dist > CONFIG.SEGMENT then        -- long trips go in pieces, re-planned as the map grows
    local fr = CONFIG.SEGMENT / dist
    local ix, iy, iz = s.x + floor((gx - s.x) * fr + 0.5), s.y + floor((gy - s.y) * fr + 0.5), s.z + floor((gz - s.z) * fr + 0.5)
    seg = key(ix, iy, iz)
    for up = 1, 4 do
      if stepCost(seg) then break end
      seg = key(ix, iy + up, iz)
    end
  end
  t.seg = seg
  t.planner = newPlanner(sk, seg, s.f)
  t.phase = "plan"
  PATH = {}
end

local function startTrip(goal, match, onDone)
  trip = { goal = goal, match = match, onDone = onDone, replans = 0, total = 0 }
  planTrip()
end

local function runSteps(list, onDone)
  trip = { steps = list, keys = {}, next = 1, onDone = onDone, phase = "run", replans = 0 }
  sendSteps()
end

local function tripFail(gi, why)
  local k = trip.keys and trip.keys[gi]
  why = tostring(why or "failed")
  if why:find("^nomatch") then return finishTrip(false, why) end
  if why:find("energy") or not trip.goal then return finishTrip(false, why) end
  if why:find("^protected") then
    if k then setCell(k, T.OTHER, 0) end
  elseif k then
    setCell(k, T.BLOCKED, 0)
  end
  if k and k == trip.goal then return finishTrip(false, "target can't be reached: " .. why) end
  trip.replans = trip.replans + 1
  if trip.replans > 6 then return finishTrip(false, "gave up after 6 re-plans: " .. why) end
  log("Blocked (" .. why .. ") - finding another way", G.warn)
  planTrip()
end

---------------------------------------------------------------- jobs
local function stopAll(quiet)
  tsend("STOP")
  trip, job, PATH = nil, nil, {}
  if not quiet then log("Stopped") end
end

local function needHome()
  local s = R.st
  if not s or not home then return nil end
  local d = abs(s.x - home.x) + abs(s.y - home.y) + abs(s.z - home.z)
  if (s.e or 0) < d * perStep * 1.5 + (s.me or 0) * (RS.reserve or 15) / 100 then return "low energy" end
  if s.invn and s.invn > 0 and (s.inv or 0) >= s.invn - 1 then return "inventory full" end
  if s.dur and s.dur < 0.03 then return "tool almost broken" end
  return nil
end

local veinNext   -- forward

local function goHome(resumeJob, why)
  if not home then
    stopAll(true)
    log("Can't go home: no home set (Set Home Here)", G.bad); alert()
    return
  end
  if trip then tsend("STOP"); trip, PATH = nil, {} end
  job = { kind = "home", resume = resumeJob, why = why }
  log("Going home" .. (why and (" - " .. why) or ""), why and G.warn or G.text)
  startTrip(key(home.x, home.y, home.z), nil, function(ok, err)
    if not ok then job = nil; log("Couldn't get home: " .. tostring(err), G.bad); alert(); return end
    runSteps({ { "face", home.f or 0 }, { "unload", RS.unload or "down" } }, function(ok2, err2)
      if not ok2 then log("Unload: " .. tostring(err2), G.warn) else log("Home - unloaded", G.good) end
      if job and job.resume then
        job.phase, job.chargeStart, job.chargeE, job.warned = "charge", computer.uptime(), R.st and R.st.e, false
        log("Charging to " .. RS.chargeTo .. "% before going back")
      else
        job = nil
        if why and why ~= "requested" then alert() end
      end
    end)
  end)
end

local function inVein(k)
  local x, y, z = unkey(k)
  return abs(x - job.cx) <= job.r and abs(y - job.cy) <= job.r and abs(z - job.cz) <= job.r
end

local function pickTarget()
  local s = R.st
  local best, bd = nil, math.huge
  local function try(k, bonus)
    if not job.tried[k] and inVein(k) then
      local x, y, z = unkey(k)
      local d = abs(x - s.x) + abs(y - s.y) + abs(z - s.z) - bonus
      if d < bd then best, bd = k, d end
    end
  end
  for k in pairs(MAP.ore) do try(k, 2) end
  for k in pairs(MAP.cand) do try(k, 0) end
  return best
end

local function targetsLeft()
  if not job or job.kind ~= "vein" then return 0 end
  local n = 0
  for k in pairs(MAP.ore) do if not job.tried[k] and inVein(k) then n = n + 1 end end
  for k in pairs(MAP.cand) do if not job.tried[k] and inVein(k) then n = n + 1 end end
  return n
end

veinNext = function()
  if not job or job.kind ~= "vein" then return end
  local s = R.st
  if not s then return end
  local why = needHome()
  if why then return goHome(why ~= "tool almost broken" and job or nil, why) end
  local here = key(s.x, s.y, s.z)
  local tk = pickTarget()
  if (RS.scanEvery > 0 and job.since >= RS.scanEvery and not job.scanned[here]) or (not tk and not job.scanned[here]) then
    job.since, job.scanned[here] = 0, true
    local r = RS.scanR
    return runSteps({ { "scan", r, -r, r } }, function(ok, err)
      if not ok then log("Scan failed: " .. tostring(err), G.warn) end
      veinNext()
    end)
  end
  if not tk then
    log("Vein finished: " .. job.mined .. " ore block(s) mined", G.good); alert()
    job = nil
    if RS.homeDone then goHome(nil, "vein finished") end
    return
  end
  startTrip(tk, "ore", function(ok, err)
    if not job or job.kind ~= "vein" then return end
    if ok then job.mined = job.mined + 1
    else
      job.tried[tk] = true
      if not tostring(err):find("^nomatch") then log("Skipped a target: " .. tostring(err), G.warn) end
    end
    veinNext()
  end)
end

local function startVein(k)
  local x, y, z = unkey(k)
  job = { kind = "vein", cx = x, cy = y, cz = z, r = RS.veinR, tried = {}, scanned = {}, since = 0, mined = 0 }
  log(string.format("Mining every ore within %d blocks of %d %d %d", RS.veinR, x, y, z), G.accent)
  veinNext()
end

---------------------------------------------------------------- messages
local function applyState(sv)
  local st = unser(sv)
  if type(st) ~= "table" or not st.x then return end
  R.st = st
  if st.set then markVisited(st.x, st.y, st.z) end
  if not V.centered then V.cx, V.cz, V.y, V.centered = st.x, st.z, st.y, true end
  if V.follow then
    V.y = st.y
    if abs(st.x - V.cx) > V.cols / 2 - 4 or abs(st.z - V.cz) > MROWS / 2 - 3 then V.cx, V.cz = st.x, st.z end
  end
end

local function serveCode(robotSum)
  local code = readFile(CONFIG.ROBOT_PROGRAM)
  if not code then
    tsend("NOCODE")
    log("Robot asked for its program but " .. CONFIG.ROBOT_PROGRAM .. " is missing", G.bad); alert()
    return
  end
  local sum = checksum(code)
  R.progSum, R.progAt = sum, computer.uptime()
  if sum == robotSum then tsend("UPTODATE"); log("Robot started - program up to date", G.good); return end
  local size = 8192
  if tunnel.maxPacketSize then size = select(2, pcall(tunnel.maxPacketSize)) or 8192 end
  local CH = max(1024, (tonumber(size) or 8192) - 256)
  local n = ceil(#code / CH)
  for i = 1, n do tsend("CODE", i, n, sum, code:sub((i - 1) * CH + 1, i * CH)) end
  log("Sent robot program: " .. commas(#code) .. " bytes in " .. n .. " part(s)", G.accent)
end

local MOVES = { tf = true, tu = true, td = true, f = true, b = true, u = true, d = true }

local function onRes(id, i, n, ok, why, payload)
  local p = unser(payload) or {}
  local prevE = R.st and R.st.e
  applyState(p.st)
  for _, e in ipairs(p.se or {}) do senseCell(e) end
  if type(p.x) == "table" and type(p.x.drops) == "table" then
    for _, d in ipairs(p.x.drops) do drops[tostring(d[1])] = (drops[tostring(d[1])] or 0) + (tonumber(d[2]) or 0) end
  end
  if why == "" then why = nil end
  if manual[id] then
    if not ok then log("✗ " .. manual[id] .. ": " .. tostring(why), G.warn) end
    if i == n or not ok then manual[id] = nil end
    return
  end
  if not (trip and trip.id == id and trip.phase == "run") then return end
  trip.sentAt = computer.uptime()
  local gi = trip.bstart + i - 1
  local step = trip.steps[gi]
  if not ok then return tripFail(gi, why) end
  trip.next = gi + 1
  if trip.keys[gi] then PATH[trip.keys[gi]] = nil end
  if step and MOVES[step[1]] then
    if job and job.kind == "vein" then job.since = job.since + 1 end
    local e = R.st and R.st.e
    if prevE and e and e < prevE and prevE - e < 1000 then perStep = perStep * 0.9 + (prevE - e) * 0.1 end
    -- safety checks while out working
    if job and (job.kind == "vein" or job.kind == "goto") then
      local need = needHome()
      if need and (job.kind == "vein" or need == "low energy") then
        return goHome(job.kind == "vein" and need ~= "tool almost broken" and job or nil, need)
      end
    end
  end
  if i == n then
    if trip.next > #trip.steps then
      if trip.goal and trip.seg ~= trip.goal then planTrip() else arrived() end
    else
      sendSteps()
    end
  end
end

local function onMessage(ev)
  if not tunnel or ev[2] ~= tunnel.address then return end
  R.heard = computer.uptime()
  local kind = ev[7]
  if kind == "HELLO" then
    serveCode(tonumber(ev[8]) or 0)
  elseif kind == "READY" then
    applyState(ev[8])
    log("Robot program running (v" .. tostring(R.st and R.st.ver or "?") .. ")", G.good)
    if R.st and not R.st.set then log("Robot position not set yet - use Set Pos...", G.warn) end
  elseif kind == "BEAT" or kind == "PONG" then
    applyState(ev[8])
  elseif kind == "RES" then
    onRes(ev[8], ev[9], ev[10], ev[11], ev[12], ev[13])
  elseif kind == "SCAN" then
    onScan(ev[8], ev[9], ev[10], ev[11], ev[12], ev[13])
  elseif kind == "STOPPED" then
    applyState(ev[9])
  elseif kind == "ERR" then
    R.err = tostring(ev[8])
    log("Robot error: " .. R.err:match("^[^\n]*"), G.bad); alert()
    local lines = {}
    for l in R.err:gmatch("[^\n]+") do
      if #lines < 8 then lines[#lines + 1] = unicode.sub(l:gsub("\t", "  "), 1, 100) end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Fix /home/robot.lua on this computer, then press Update Robot."
    showOrQueue(function() dialog("Robot Error", lines, { { "OK" } }) end)
  elseif kind == "BOOTMSG" then
    log("Robot: " .. tostring(ev[8]), G.dim)
  elseif kind == "BYE" then
    log("Robot program " .. (ev[8] == "update" and "restarting for an update" or tostring(ev[8])), G.dim)
  end
  if refresh then refresh() end
end

---------------------------------------------------------------- commands (buttons)
local function sendManual(label, list)
  if not tunnel then log("No Linked Card in this computer", G.bad); return end
  if trip or job then stopAll(true); log("Trip stopped - manual control", G.warn) end
  cmdSeq = cmdSeq + 1
  manual[cmdSeq] = label
  tsend("CMD", cmdSeq, serialization.serialize(list))
end

local function needPos()
  if not R.st then
    dialog("Robot Control", { "No word from the robot yet.", "Check it's switched on (Wake) and has its Linked Card." }, { { "OK" } })
    return true
  end
  if not R.st.set then
    dialog("Robot Control", { "Tell the robot where it is first:", "press Set Pos... and type its X Y Z and facing." }, { { "OK" } })
    return true
  end
  return false
end

local function goHere()
  if not V.sel then dialog("Go Here", { "Click a block on the map first." }, { { "OK" } }); return end
  if needPos() then return end
  local t = typeAt(V.sel)
  if t == T.BEDROCK or t == T.OTHER or (t == T.LIQUID and not RS.liquids) then
    dialog("Go Here", { "The robot can't go into that block (" .. TNAME[t] .. ").", "Pick a block next to it instead." }, { { "OK" } })
    return
  end
  if trip or job then stopAll(true) end
  local x, y, z = unkey(V.sel)
  job = { kind = "goto" }
  V.follow = true
  log(string.format("Going to %d %d %d", x, y, z), G.accent)
  startTrip(V.sel, nil, function(ok)
    if ok then log("Arrived", G.good) end
    if job and job.kind == "goto" then job = nil end
  end)
end

local function mineVein()
  if not V.sel then
    dialog("Mine Vein", { "Click an ore (◆) or a maybe-ore (??) on the map first.",
      "The robot mines every ore within " .. RS.veinR .. " blocks of it (Settings)." }, { { "OK" } })
    return
  end
  if needPos() then return end
  if trip or job then stopAll(true) end
  V.follow = true
  startVein(V.sel)
end

local function parseFacing(s)
  s = tostring(s or ""):upper():sub(1, 1)
  return ({ N = 0, E = 1, S = 2, W = 3, ["0"] = 0, ["1"] = 1, ["2"] = 2, ["3"] = 3 })[s]
end

local function askSetPos()
  local s = R.st
  prompt = { label = "Robot position - X Y Z facing (N/E/S/W):",
    input = s and string.format("%d %d %d %s", s.x, s.y, s.z, ("NESW"):sub(s.f + 1, s.f + 1)) or "",
    onEnter = function(v)
      local x, y, z, f = v:match("^%s*(%-?%d+)[%s,]+(%-?%d+)[%s,]+(%-?%d+)[%s,]*(%w*)")
      local fc = parseFacing(f)
      if not x or not fc then log("Set Pos: type it like  120 64 -300 N", G.warn); return end
      sendManual("Set Pos", { { "setpos", tonumber(x), tonumber(y), tonumber(z), fc } })
      if not home then home = { x = tonumber(x), y = tonumber(y), z = tonumber(z), f = fc }; saveState(); log("Home set to the same spot", G.good) end
      V.cx, V.cz, V.y = tonumber(x), tonumber(z), tonumber(y)
      log("Position set: " .. x .. " " .. y .. " " .. z .. " facing " .. FACE[fc], G.good)
    end }
end

local function askGoto()
  prompt = { label = "Go to - X Y Z:", input = "",
    onEnter = function(v)
      local x, y, z = v:match("^%s*(%-?%d+)[%s,]+(%-?%d+)[%s,]+(%-?%d+)")
      if not x then log("Go to: type it like  140 30 -280", G.warn); return end
      V.sel = key(tonumber(x), tonumber(y), tonumber(z))
      V.cx, V.cz, V.y, V.follow = tonumber(x), tonumber(z), tonumber(y), false
      goHere()
    end }
end

local function setHomeHere()
  local s = R.st
  if not s or not s.set then needPos(); return end
  home = { x = s.x, y = s.y, z = s.z, f = s.f }
  saveState()
  log(string.format("Home set: %d %d %d facing %s", s.x, s.y, s.z, FACE[s.f]), G.good)
end

local function clearMap()
  dialog("Clear Map", { "Forget everything on the map (" .. commas(MAP.n) .. " blocks)?",
    "Home, settings and the robot's position are kept." }, {
    { "Yes", function()
        MAP.M, MAP.ore, MAP.cand, MAP.n = {}, {}, {}, 0
        PATH = {}
        saveMap()
        log("Map cleared")
      end },
    { "No" } })
end

local function wake()
  if tunnel then pcall(tunnel.send, CONFIG.WAKE); log("Wake signal sent") end
end

local function moveBtn(dig, plain, label)
  return function() sendManual(label, { { RS.digThrough and dig or plain } }) end
end

---------------------------------------------------------------- drawing
local function panel(x, y, w, h, title, color, right)
  fill(x, y, w, h, G.panel)
  fill(x, y, w, 1, color)
  text(x, y, " " .. title .. " ", G.dark, color)
  if right then textW(x + w - unicode.len(right) - 1, y, unicode.len(right), right, G.dark, color) end
end
local function btn(x, y, w, label, fn, on, col)
  local b = col or (on and G.accent or G.button)
  textW(x, y, w, label, (on or col) and G.dark or G.text, b, "center")
  region(rcRegions, x, y, w, 1, fn)
end
local function rbar(x, y, w, frac, col)
  frac = max(0, min(1, frac or 0))
  local n = floor(w * frac + 0.5)
  text(x, y, string.rep("█", n), col, G.track)
  if w - n > 0 then text(x + n, y, string.rep("░", w - n), G.grid, G.track) end
end
local function kv(y, k, v, col)
  textW(RX0 + 1, y, 8, k, G.dim, G.panel)
  textW(RX0 + 9, y, RW - 10, v, col or G.text, G.panel)
end

local STY = {
  [0]         = { "  ", G.dim, 0x101010 },
  [T.AIR]     = { "  ", G.dim, 0x2C2C2C },
  [T.TRAIL]   = { "··", 0x8A8AC8, 0x262640 },
  [T.MINED]   = { "··", 0xFFB000, 0x3A3020 },
  [T.STONE]   = { "  ", 0, 0x5A5A5A },
  [T.SOFT]    = { "  ", 0, 0x6B5236 },
  [T.CAND]    = { "??", 0xFFFFFF, 0x6A3FB0 },
  [T.ORE]     = { "◆◆", 0x2A1A00, 0xFFB000 },
  [T.LIQUID]  = { "≈≈", 0xA8C8FF, 0x1E50C8 },
  [T.BEDROCK] = { "▓▓", 0x555555, 0x000000 },
  [T.OTHER]   = { "▒▒", 0xFF9090, 0x7A1010 },
  [T.BLOCKED] = { "××", 0xFF4D4D, 0x3A1010 },
}

local function layerOres(y)
  local n = 0
  for k in pairs(MAP.ore) do local _, ky = unkey(k); if ky == y then n = n + 1 end end
  for k in pairs(MAP.cand) do local _, ky = unkey(k); if ky == y then n = n + 1 end end
  return n
end

local function drawMap()
  local z2 = V.zoom
  local cols = floor(MW / z2)
  V.cols = cols
  local x0, z0 = V.cx - floor(cols / 2), V.cz - floor(MROWS / 2)
  V.x0, V.z0 = x0, z0
  local s = R.st
  local hy = home and home.y
  for j = 0, MROWS - 1 do
    local z = z0 + j
    local sx = MX0
    for i = 0, cols - 1 do
      local x = x0 + i
      local k = key(x, V.y, z)
      local t = typeAt(k)
      local sty = STY[t] or STY[0]
      local g, f, b = sty[1], sty[2], sty[3]
      if t == 0 or t == T.AIR or t == T.STONE or t == T.SOFT then
        local ku, kd = key(x, V.y + 1, z), key(x, V.y - 1, z)
        if MAP.ore[ku] or MAP.cand[ku] or MAP.ore[kd] or MAP.cand[kd] then g, f = "◇ ", 0xB08A30 end
      end
      if PATH[k] then g, f = "• ", G.path end
      if home and home.x == x and home.z == z and hy == V.y then g, f = "⌂ ", G.good end
      if V.sel == k then g, f = "[]", G.pink end
      if s and s.x == x and s.z == z then
        if s.y == V.y then g, f, b = (ARROW[s.f] or "?") .. " ", G.dark, G.accent
        else g, f = (s.y > V.y and "↑ " or "↓ "), G.accent end
      end
      if z2 == 1 then g = unicode.sub(g, 1, 1) end
      text(sx, MY0 + j, g, f, b)
      sx = sx + z2
    end
  end
end

local function drawMapHeader()
  local y = MY0 - 1
  fill(MX0, y, MW, 1, G.header)
  text(MX0, y, " ▣ MAP ", G.dark, G.accent)
  textW(MX0 + 7, y, 10, " Y = " .. V.y, G.text, G.header)
  btn(MX0 + 18, y, 4, " ▲ ", function() V.y = V.y + 1; V.follow = false; refresh() end)
  btn(MX0 + 23, y, 4, " ▼ ", function() V.y = V.y - 1; V.follow = false; refresh() end)
  btn(MX0 + 28, y, 9, "Robot", function()
    if R.st then V.cx, V.cz, V.y = R.st.x, R.st.z, R.st.y end
    refresh()
  end)
  btn(MX0 + 38, y, 10, "Follow", function() V.follow = not V.follow; refresh() end, V.follow)
  btn(MX0 + 49, y, 10, V.zoom == 2 and "Zoom: 2x" or "Zoom: 1x", function() V.zoom = V.zoom == 2 and 1 or 2; refresh() end)
  local here, up, dn = layerOres(V.y), layerOres(V.y + 1), layerOres(V.y - 1)
  textW(MX0 + 60, y, MW - 61, string.format("ores: %d here  %d above  %d below ", here, up, dn), G.dim, G.header, "right")
end

local function drawLegend()
  local y = MY0 + MROWS
  fill(MX0, y, MW, 2, G.bg)
  local items = {
    { "▲ ", G.dark, G.accent, "robot" }, { "⌂ ", G.good, 0x2C2C2C, "home" }, { "[]", G.pink, 0x2C2C2C, "selected" },
    { "• ", G.path, 0x2C2C2C, "route" }, { "◆◆", 0x2A1A00, 0xFFB000, "ore" }, { "??", 0xFFFFFF, 0x6A3FB0, "maybe ore" },
    { "◇ ", 0xB08A30, 0x101010, "ore 1 up/down" }, { "··", 0x8A8AC8, 0x262640, "trail" }, { "··", 0xFFB000, 0x3A3020, "mined" },
    { "  ", 0, 0x5A5A5A, "stone" }, { "  ", 0, 0x2C2C2C, "air" }, { "≈≈", 0xA8C8FF, 0x1E50C8, "liquid" },
    { "▓▓", 0x555555, 0x000000, "bedrock" }, { "▒▒", 0xFF9090, 0x7A1010, "protected" }, { "××", 0xFF4D4D, 0x3A1010, "blocked" },
  }
  local x, row = MX0 + 1, 0
  for _, it in ipairs(items) do
    local w = 3 + unicode.len(it[4]) + 2
    if x + w > MX0 + MW then x, row = MX0 + 1, row + 1 end
    text(x, y + row, it[1], it[2], it[3])
    text(x + 3, y + row, it[4], G.dim, G.bg)
    x = x + w
  end
end

local function activity()
  if trip and trip.planner then return "Planning a route (" .. trip.planner.n .. " blocks checked)", G.accent end
  if job then
    if job.kind == "vein" then return "Mining vein: " .. job.mined .. " mined, " .. targetsLeft() .. " to check", G.accent end
    if job.kind == "home" then
      if job.phase == "charge" then
        local s = R.st
        return "Charging at home" .. ((s and s.me > 0) and string.format(" (%d%%)", floor(s.e / s.me * 100)) or ""), G.good
      end
      return "Going home" .. (job.why and (" - " .. job.why) or ""), G.warn
    end
    if job.kind == "goto" then return "Going to the target", G.accent end
  end
  if trip then return "Running steps", G.accent end
  return "Idle", G.dim
end

local function drawStatusPanel()
  local s = R.st
  local on = linkOK()
  panel(RX0, MY0 - 1, RW, 10, "ROBOT", on and G.good or G.bad, on and "ONLINE " or "OFFLINE ")
  local y = MY0
  if not tunnel then kv(y, "Link", "NO LINKED CARD in this computer", G.bad)
  else kv(y, "Link", tunnel.address:sub(1, 8) .. "  ·  " .. (R.heard and ("heard " .. fmtDurLong(computer.uptime() - R.heard) .. " ago") or "never heard"), on and G.text or G.warn) end
  if s then
    kv(y + 1, "Pos", string.format("X %d  Y %d  Z %d  %s", s.x, s.y, s.z, ("NESW"):sub(s.f + 1, s.f + 1))
      .. (s.set and "" or "  NOT SET"), s.set and G.text or G.bad)
  else kv(y + 1, "Pos", "--", G.dim) end
  if home then
    local d = s and (abs(s.x - home.x) + abs(s.y - home.y) + abs(s.z - home.z)) or 0
    kv(y + 2, "Home", string.format("X %d  Y %d  Z %d  (%d away)", home.x, home.y, home.z, d))
  else kv(y + 2, "Home", "not set - Set Home Here", G.warn) end
  textW(RX0 + 1, y + 3, 8, "Energy", G.dim, G.panel)
  if s and s.me and s.me > 0 then
    local fr = s.e / s.me
    rbar(RX0 + 9, y + 3, 22, fr, fr < 0.2 and G.bad or (fr < 0.5 and G.warn or G.good))
    textW(RX0 + 32, y + 3, 12, string.format(" %d%%", floor(fr * 100 + 0.5)), G.text, G.panel)
  else textW(RX0 + 9, y + 3, RW - 10, "--", G.dim, G.panel) end
  textW(RX0 + 1, y + 4, 8, "Tool", G.dim, G.panel)
  if s and s.dur then
    rbar(RX0 + 9, y + 4, 22, s.dur, s.dur < 0.1 and G.bad or G.accent)
    textW(RX0 + 32, y + 4, 12, string.format(" %d%%", floor(s.dur * 100 + 0.5)), G.text, G.panel)
  else textW(RX0 + 9, y + 4, RW - 10, "no reading (empty, or GT tool)", G.dim, G.panel) end
  textW(RX0 + 1, y + 5, 8, "Cargo", G.dim, G.panel)
  if s and s.invn and s.invn > 0 then
    rbar(RX0 + 9, y + 5, 22, s.inv / s.invn, s.inv >= s.invn - 1 and G.bad or G.accent)
    textW(RX0 + 32, y + 5, 12, " " .. s.inv .. "/" .. s.invn, G.text, G.panel)
  else textW(RX0 + 9, y + 5, RW - 10, "--", G.dim, G.panel) end
  local prog, pc = "--", G.dim
  if s and s.ver then
    if R.progSum and s.sum and s.sum ~= 0 then
      if s.sum == R.progSum then prog, pc = "v" .. s.ver .. "  ·  up to date", G.good
      else prog, pc = "v" .. s.ver .. "  ·  OUTDATED - Update Robot", G.warn end
    else prog = "v" .. s.ver end
  end
  kv(y + 6, "Program", prog, pc)
  local a, ac = activity()
  kv(y + 7, "Doing", a, ac)
  kv(y + 8, "Cost", string.format("~%d energy per move  ·  map %s", floor(perStep + 0.5), commas(MAP.n)), G.dim)
end

local function drawManual()
  local y = MY0 + 9
  panel(RX0, y, RW, 11, "MANUAL", G.accent, RS.digThrough and "moves dig " or "moves only ")
  local x1, x2, x3, x4 = RX0 + 1, RX0 + 12, RX0 + 23, RX0 + 34
  btn(x1, y + 2, 10, "◄ Left", function() sendManual("Turn left", { { "l" } }) end)
  btn(x2, y + 2, 10, "▲ Fwd", moveBtn("tf", "f", "Forward"))
  btn(x3, y + 2, 10, "Right ►", function() sendManual("Turn right", { { "r" } }) end)
  btn(x4, y + 2, 10, "Up ▲", moveBtn("tu", "u", "Up"))
  btn(x1, y + 4, 10, "Around", function() sendManual("Turn around", { { "a" } }) end)
  btn(x2, y + 4, 10, "▼ Back", function() sendManual("Back", { { "b" } }) end)
  btn(x3, y + 4, 10, "Dig thru", function() RS.digThrough = not RS.digThrough; saveSettings(); refresh() end, RS.digThrough)
  btn(x4, y + 4, 10, "Down ▼", moveBtn("td", "d", "Down"))
  btn(x1, y + 6, 10, "Dig ▲", function() sendManual("Dig up", { { "digu" } }) end)
  btn(x2, y + 6, 10, "Dig front", function() sendManual("Dig front", { { "dig" } }) end)
  btn(x3, y + 6, 10, "Dig ▼", function() sendManual("Dig down", { { "digd" } }) end)
  btn(x4, y + 6, 10, "Scan", function()
    local r = RS.scanR
    sendManual("Scan", { { "scan", r, -r, r } })
    log("Scanning " .. (2 * r + 1) .. "³ blocks around the robot...")
  end)
  btn(x1, y + 8, 10, "Set Pos…", askSetPos)
  btn(x2, y + 8, 10, "Set Home", setHomeHere)
  btn(x3, y + 8, 10, "Unload", function() sendManual("Unload", { { "unload", RS.unload } }) end)
  btn(x4, y + 8, 10, "Ping", function() tsend("PING") end)
  textW(RX0 + 1, y + 10, RW - 2, "Arrows pan · PgUp/PgDn layer · Space STOP", G.dim, G.panel)
end

local function selInfo()
  local k = V.sel
  if not k then return "nothing selected - click the map", G.dim, "" end
  local x, y, z = unkey(k)
  local t = typeAt(k)
  local a = string.format("X %d  Y %d  Z %d", x, y, z)
  local b = TNAME[t] or "?"
  if t == T.ORE and MAP.ore[k] then b = "Ore: " .. tostring(MAP.okeys[MAP.ore[k]] or "?") end
  local h, d = hardAt(k), distAt(k)
  if h and t ~= T.AIR and t ~= T.TRAIL and t ~= T.MINED then
    b = b .. string.format("  ·  hardness %.1f%s", h, (d and d > 0) and (" (scan, " .. d .. " away)") or "")
  end
  local s = R.st
  local far = s and (abs(x - s.x) + abs(y - s.y) + abs(z - s.z)) or nil
  return a .. (far and ("   ·   " .. far .. " blocks from robot") or ""), G.text, b
end

local function drawTrip()
  local y = MY0 + 21
  panel(RX0, y, RW, 10, "TARGET & TRIPS", G.pink)
  local a, ac, b = selInfo()
  textW(RX0 + 1, y + 1, RW - 2, a, ac, G.panel)
  textW(RX0 + 1, y + 2, RW - 2, b, G.dim, G.panel)
  local x1, x2, x3, x4 = RX0 + 1, RX0 + 12, RX0 + 23, RX0 + 34
  btn(x1, y + 4, 10, "Go Here", goHere)
  btn(x2, y + 4, 10, "Mine Vein", mineVein)
  btn(x3, y + 4, 10, "Go Home", function() if not needPos() then goHome(nil, "requested") end end)
  btn(x4, y + 4, 10, "STOP", function() stopAll() ; refresh() end, false, G.bad)
  btn(x1, y + 6, 10, "Go to XYZ…", askGoto)
  btn(x2, y + 6, 10, "Clear Sel", function() V.sel = nil; refresh() end)
  btn(x3, y + 6, 10, "Clear Map…", clearMap)
  btn(x4, y + 6, 10, "Wake", wake)
  if trip and trip.steps and trip.goal then
    local total, done = #trip.steps, trip.next - 1
    rbar(RX0 + 1, y + 8, 30, total > 0 and done / total or 0, G.accent)
    textW(RX0 + 32, y + 8, 12, " " .. done .. "/" .. total .. " steps", G.text, G.panel)
  elseif trip and trip.planner then
    textW(RX0 + 1, y + 8, RW - 2, "Planning... " .. commas(trip.planner.n) .. " blocks checked", G.accent, G.panel)
  else
    textW(RX0 + 1, y + 8, RW - 2, "", G.text, G.panel)
  end
  local parts, list = {}, {}
  for lbl, c in pairs(drops) do list[#list + 1] = { lbl, c } end
  table.sort(list, function(p, q) return p[2] > q[2] end)
  for i = 1, min(3, #list) do parts[#parts + 1] = list[i][1] .. " ×" .. commas(list[i][2]) end
  textW(RX0 + 1, y + 9, RW - 2, #parts > 0 and ("Mined: " .. table.concat(parts, ", ")) or "Mined: nothing yet", G.dim, G.panel)
end

local function drawLog()
  local y = MY0 + 32
  panel(RX0, y, RW, 6, "LOG", G.button)
  for i = 1, 5 do
    local l = logs[i]
    if l then
      textW(RX0 + 1, y + i, 9, l[1], G.dim, G.panel)
      textW(RX0 + 10, y + i, RW - 11, l[2], l[3], G.panel)
    else
      textW(RX0 + 1, y + i, RW - 2, "", G.text, G.panel)
    end
  end
end

local function drawStatusBar()
  if prompt then
    fill(WX + 1, SY, WW - 2, 1, 0xFFFFC0)
    text(WX + 2, SY, prompt.label .. " ", K.black, 0xFFFFC0)
    local x = WX + 3 + unicode.len(prompt.label)
    textW(x, SY, WX + WW - 2 - x - 30, prompt.input .. "_", K.navy, 0xFFFFC0)
    textW(WX + WW - 32, SY, 30, "Enter = OK   Esc = cancel ", K.sh, 0xFFFFC0, "right")
    return
  end
  fill(WX + 1, SY, WW - 2, 1, G.header)
  local a, ac = activity()
  text(WX + 2, SY, a, ac, G.header)
  textW(WX + WW - 62, SY, 60, (tunnel and ("Linked Card " .. tunnel.address:sub(1, 8)) or "no Linked Card") ..
    "  ·  map " .. commas(MAP.n) .. " blocks ", G.dim, G.header, "right")
end

local function drawBody()
  rcRegions = {}
  fill(WX + 1, WY + 3, WW - 2, SY - WY - 3, G.bg)
  -- header strip
  fill(WX + 1, WY + 3, WW - 2, 1, G.header)
  text(WX + 2, WY + 3, "≡ ROBOT CONTROL", G.accent, G.header)
  btn(WX + WW - 64, WY + 3, 12, "Ping", function() tsend("PING") end)
  btn(WX + WW - 51, WY + 3, 15, "Update Robot", function()
    if tsend("UPDATE") then log("Update requested - the robot restarts with the new program", G.accent) end
  end)
  btn(WX + WW - 35, WY + 3, 10, "Wake", wake)
  btn(WX + WW - 24, WY + 3, 21, "STOP EVERYTHING", function() stopAll(); refresh() end, false, G.bad)
  drawMapHeader()
  drawMap()
  region(rcRegions, MX0, MY0, MW, MROWS, function(x, y)
    local i = floor((x - MX0) / V.zoom)
    local j = y - MY0
    V.sel = key(V.x0 + i, V.y, V.z0 + j)
    refresh()
  end)
  drawLegend()
  drawStatusPanel()
  drawManual()
  drawTrip()
  drawLog()
  drawStatusBar()
end

local function drawWindow()
  alertFlag = false
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ Robot Control", true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  text(WX + 2, WY + 2, " File ", K.black, K.face)
  text(WX + 8, WY + 2, " Robot ", K.black, K.face)
  text(WX + 15, WY + 2, " Help ", K.black, K.face)
  drawBody()
  region(rcRegions, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(rcRegions, bx + 7, WY + 1, 3, 1, function() isOpen = false; activeApp = nil; drawAll() end)
  region(rcRegions, WX + 2, WY + 2, 6, 1, function()
    popupMenu(WX + 2, WY + 3, {
      { "Save Map Now", function() saveMap(); saveState(); log("Map saved") end },
      { "Clear Map...", clearMap },
      { "-" },
      { "Close Robot Control", function() isOpen = false; activeApp = nil end },
    })
  end)
  region(rcRegions, WX + 8, WY + 2, 7, 1, function()
    popupMenu(WX + 8, WY + 3, {
      { "Ping", function() tsend("PING") end },
      { "Update Robot Program", function() tsend("UPDATE"); log("Update requested", G.accent) end },
      { "Wake Robot", wake },
      { "Restart Robot", function() tsend("REBOOT"); log("Restart requested") end },
      { "-" },
      { "Set Position...", askSetPos },
      { "Set Home Here", setHomeHere },
      { "Go Home", function() if not needPos() then goHome(nil, "requested") end end },
      { "Chunkloader On", function() sendManual("Chunkloader on", { { "chunk", true } }) end },
      { "Chunkloader Off", function() sendManual("Chunkloader off", { { "chunk", false } }) end },
      { "-" },
      { "Stop Everything", function() stopAll() end },
    })
  end)
  region(rcRegions, WX + 15, WY + 2, 6, 1, function()
    dialog("About Robot Control", {
      tostring(SETTINGS.systemName or "Lymanos") .. "  -  Robot Control",
      "Drives one robot over a Linked Card. Click the map to pick a block,",
      "then Go Here or Mine Vein. The robot reports after every step.",
      "",
      "Robot program: " .. CONFIG.ROBOT_PROGRAM .. " (sent to the robot by boot.lua)",
      "Map: " .. commas(MAP.n) .. " blocks   ·   energy per move: ~" .. floor(perStep + 0.5),
      "Ores are only certain once the robot touches them (◆). Scans show",
      "blocks harder than the base rock as ?? - GT granite/basalt too.",
    }, { { "OK" } })
  end)
end

-- redraw the inside of the window (after a robot message, a button...).
-- At most 5 times a second; anything in between is drawn by pump().
local lastDraw, drawDirty = 0, false
refresh = function()
  if activeApp ~= "robot" or overlay or lockedFlag then return end
  local up = computer.uptime()
  if up - lastDraw < 0.2 then drawDirty = true; return end
  drawDirty, lastDraw = false, up
  drawBody()
end

---------------------------------------------------------------- input
local function key(ch, code)
  if prompt then
    if code == 28 or code == 156 then
      local p = prompt
      prompt = nil
      p.onEnter(p.input)
    elseif code == 1 then prompt = nil
    elseif code == 14 then prompt.input = unicode.sub(prompt.input, 1, -2)
    elseif ch and ch >= 32 and ch < 127 then
      local c = string.char(ch)
      if c:match("[%w %-,%.]") and #prompt.input < 40 then prompt.input = prompt.input .. c end
    end
    refresh()
    return
  end
  local step = V.zoom == 2 and 8 or 16
  if code == 200 then V.cz = V.cz - 6; V.follow = false
  elseif code == 208 then V.cz = V.cz + 6; V.follow = false
  elseif code == 203 then V.cx = V.cx - step; V.follow = false
  elseif code == 205 then V.cx = V.cx + step; V.follow = false
  elseif code == 201 then V.y = V.y + 1; V.follow = false
  elseif code == 209 then V.y = V.y - 1; V.follow = false
  elseif code == 199 then if R.st then V.cx, V.cz, V.y = R.st.x, R.st.z, R.st.y end
  elseif code == 57 then stopAll()
  else return end
  refresh()
end

local function scroll(x, y, dir)
  if x >= MX0 and x < MX0 + MW and y >= MY0 and y < MY0 + MROWS then
    V.y = V.y + (dir > 0 and 1 or -1)
    V.follow = false
    refresh()
    return true
  end
end

---------------------------------------------------------------- engine room
local function pump()
  if drawDirty and computer.uptime() - lastDraw >= 0.2 then refresh() end
  local t = trip
  if not (t and t.planner) then return end
  local P = t.planner
  plannerStep(P, CONFIG.PLAN_BUDGET)
  if not P.done then return end
  t.planner = nil
  if P.err then finishTrip(false, P.err); refresh(); return end
  local s = R.st
  t.steps, t.keys = stepsFromPath(P.path, s.x, s.y, s.z, s.f, (t.seg == t.goal) and t.match or nil)
  t.next, t.phase = 1, "run"
  PATH = {}
  for _, k in ipairs(P.path) do PATH[k] = true end
  if #t.steps == 0 then
    if t.seg ~= t.goal then planTrip() else arrived() end
  else
    sendSteps()
  end
  refresh()
end

local lastSlow = 0
local function tick(visible)
  local up = computer.uptime()
  -- robot stopped answering in the middle of a trip
  if trip and trip.phase == "run" and trip.sentAt and up - trip.sentAt > 45 then
    finishTrip(false, "the robot stopped answering")
    job = nil
    alert()
  end
  -- charging at home before going back to the vein
  if job and job.kind == "home" and job.phase == "charge" then
    local s = R.st
    if s and s.me and s.me > 0 and s.e / s.me >= RS.chargeTo / 100 then
      local back = job.resume
      job = back
      log("Charged - back to the vein", G.good)
      veinNext()
    elseif s and up - job.chargeStart > 90 and not job.warned and (s.e or 0) <= (job.chargeE or 0) + 100 then
      job.warned = true
      log("Not charging - is the charger's lever on?", G.warn); alert()
    end
  end
  if up - lastSlow >= 15 then
    lastSlow = up
    if up - R.progAt > 60 then
      local code = readFile(CONFIG.ROBOT_PROGRAM)
      R.progSum, R.progAt = code and checksum(code) or nil, up
    end
    if MAP.n > CONFIG.MAP_MAX then prune() end
    if MAP.dirty and up - MAP.savedAt > 180 and not (trip and trip.planner) then saveMap(); saveState() end
    if R.heard and not linkOK() then
      if not R.lostLogged and job then log("Lost contact with the robot", G.bad); alert() end
      R.lostLogged = true
    else
      R.lostLogged = false
    end
  end
  if visible and not prompt then
    drawStatusPanel()
    drawStatusBar()
  end
end

return {
  drawWindow = drawWindow, key = key, scroll = scroll, pump = pump, tick = tick, load = load,
  onMessage = onMessage, linkOK = linkOK,
  open = function() isOpen = true; activeApp = "robot" end,
  isOpen = function() return isOpen end,
  alert = function() return alertFlag end,
  busy = function() return (trip ~= nil and trip.planner ~= nil) or drawDirty end,
  regions = function() return rcRegions end,
  refresh = function() refresh() end,
  resetRegions = function() rcRegions = {} end,
  focus = function() return prompt ~= nil end,
  save = function() saveMap(); saveState() end,
  statusText = function()
    local a = activity()
    local s = R.st
    local e = (s and s.me and s.me > 0) and string.format("  %d%%", floor(s.e / s.me * 100)) or ""
    return "Robot: " .. (linkOK() and a or "offline") .. e
  end,
}
end)()


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
  parts[#parts + 1] = RC.statusText()
  if RC.alert() then parts[#parts + 1] = "Robot: check the log!" end
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
local OPT = {
  scanR = { 3, 4, 5, 6 }, scanEvery = { 0, 8, 12, 16, 24 }, veinR = { 8, 12, 16, 24, 32 },
  reserve = { 10, 15, 20, 30 }, chargeTo = { 80, 90, 95, 100 }, rock = { 0.4, 0.8, 1.5, 2.0, 3.0 },
  unload = { "down", "front", "up" },
}
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
  PLAYER_NAME = SETTINGS.userName or CONFIG.PLAYER_NAME or ("Player-" .. computer.address():sub(1, 4))
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
  note(L, 11, LWd - 2, "Shown on the lock screen.")
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
  note(L, 21, LWd - 2, "Used on the taskbar, lock screen and Robot log.")

  -- about
  groupBox(L - 2, 24, LWd + 2, 19, "About This Computer")
  local total, free = computer.totalMemory(), computer.freeMemory()
  local rows = {
    { "System:", tostring(SETTINGS.systemName or "Lymanos") .. "  (Lymanos Robot 1.0)" },
    { "User:", tostring(PLAYER_NAME) },
    { "Memory:", string.format("%d K used of %d K", floor((total - free) / 1024), floor(total / 1024)) },
    { "Linked Card:", (component.list("tunnel")() or "none - Robot Control can't reach the robot"):sub(1, 40) },
    { "Network card:", wlan and (wlan.address:sub(1, 8) .. (wlan.isWireless() and " (wireless)" or " (wired)")) or "none (not needed)" },
    { "Settings file:", CONFIG.SETTINGS_FILE },
    { "Robot program:", CONFIG.ROBOT_PROGRAM },
    { "Map file:", CONFIG.MAP_FILE },
  }
  for i, r in ipairs(rows) do
    label(L, 25 + i, r[1])
    textW(L + FX - 18, 25 + i, LWd - FX + 16, r[2], K.black, K.face)
  end
  note(L, 33, LWd - 2, "Settings save automatically. CONFIG at the top of")
  note(L, 34, LWd - 2, "lymrobot.lua holds the defaults and advanced options.")
  button(regions, L, 38, 24, "Reset to defaults", function()
    dialog("Reset Settings", { "Put every setting back to its default?",
      "(Your name goes back to the CONFIG default too.)" }, {
      { "Yes", function()
          SETTINGS.userName, SETTINGS.systemName, SETTINGS.lockMins, SETTINGS.lockStyle = nil, "Lymanos", 30, 1
          SETTINGS.clock24, SETTINGS.desk = false, 1
          for k, v in pairs(RC_DEFAULTS) do SETTINGS.rc[k] = v end
          K.desk = DESK_COLORS[1][2]
          PLAYER_NAME = CONFIG.PLAYER_NAME or ("Player-" .. computer.address():sub(1, 4))
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

  -- robot control
  local rs = SETTINGS.rc
  groupBox(R - 2, 23, RWd + 2, 20, "Robot Control")
  local function opt(y, lbl, k, show)
    label(R, y, lbl)
    cycler(R + FX - 18, y, 22, show(rs[k]), function(d)
      if OPT[k] then rs[k] = step(OPT[k], rs[k], d) else rs[k] = not rs[k] end
      changed()
    end)
  end
  opt(24, "Scan radius:", "scanR", function(v) return v .. " blocks (" .. (2 * v + 1) .. "³)" end)
  opt(25, "Vein: rescan:", "scanEvery", function(v) return v == 0 and "only when needed" or ("every " .. v .. " moves") end)
  opt(26, "Vein size:", "veinR", function(v) return v .. " blocks each way" end)
  opt(27, "Energy reserve:", "reserve", function(v) return v .. "% + trip home" end)
  opt(28, "Charge to:", "chargeTo", function(v) return v .. "% at home" end)
  local ROCK = { [0.4] = "netherrack", [1.5] = "stone", [3.0] = "end stone" }
  opt(29, "Base rock:", "rock", function(v) return string.format("%.1f", v) .. (ROCK[v] and (" " .. ROCK[v]) or "") end)
  opt(30, "Liquids:", "liquids", function(v) return v and "may go through" or "go around" end)
  opt(31, "Vein done:", "homeDone", function(v) return v and "go home" or "stay there" end)
  opt(32, "Home chest:", "unload", function(v) return "robot drops " .. v end)
  opt(33, "Manual moves:", "digThrough", function(v) return v and "dig through" or "move only" end)
  note(R, 35, RWd - 2, "Scans only measure hardness: anything harder than the")
  note(R, 36, RWd - 2, "base rock shows as ?? (GT ores, but also GT granite).")
  note(R, 37, RWd - 2, "The robot checks each one up close before mining it.")
  note(R, 39, RWd - 2, "Energy reserve: the robot heads home when its energy gets")
  note(R, 40, RWd - 2, "down to the cost of the trip home plus this much.")

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
  RC.resetRegions()
  if not keepOverlay then overlay = nil end
  drawDesktop()
  if activeApp == "robot" then
    RC.drawWindow()
  elseif activeApp == "sys" then
    SYS.drawWindow()
  elseif activeApp == "settings" then
    SET.drawWindow()
  end
  drawTaskbar(t)
end

------------------------------------------------------------- MAIN LOOP
local oldW, oldH = gpu.getResolution()

local function main()
  local mw, mh = gpu.maxResolution()
  if mw < W or mh < H then error("Lymanos needs a tier 3 GPU and screen (160x50).", 0) end
  gpu.setResolution(W, H)
  RC.load()
  RC.open()
  drawAll()

  local lastTick = 0
  while running do
    gpu.flush()                        -- show this pass's drawing in one go
    local ev = { event.pull(RC.busy() and 0.05 or 0.5) }
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
      elseif activeApp == "robot" then
        if not hit(RC.regions(), x, y) then hit(regions, x, y) end
        RC.refresh()
      else
        hit(regions, x, y)
      end
    elseif name == "scroll" and not overlay and activeApp == "sys" then
      SYS.scroll(ev[3], ev[4], ev[5])
    elseif name == "scroll" and not overlay and activeApp == "robot" then
      RC.scroll(ev[3], ev[4], ev[5])
    elseif name == "modem_message" and ev[6] == "RC" then
      local ok, e = pcall(RC.onMessage, ev)
      if not ok then statusMsg = "Robot Control error: " .. tostring(e) end
    elseif name == "key_down" and activeApp == "robot" and not overlay then
      RC.key(ev[3], ev[4])
    elseif name == "key_down" and activeApp == "settings" and SET.focus() and not overlay then
      SET.key(ev[3], ev[4])
    end

    local okp, pe = pcall(RC.pump)
    if not okp then statusMsg = "Route error: " .. tostring(pe) end

    local up = computer.uptime()
    if running and up - lastTick >= 1 then
      lastTick = up
      local t = now()
      if LOCK.isLocked() then
        LOCK.tick(t)
      elseif not overlay then
        drawTray(t)
      end
      SYS.tick(activeApp == "sys" and not overlay)
      local okr, re = pcall(RC.tick, activeApp == "robot" and not overlay and not LOCK.isLocked())
      if not okr then statusMsg = "Robot Control error: " .. tostring(re) end
      -- lock after the idle time set in Settings (0 = never)
      local mins = SETTINGS.lockMins or 0
      if mins > 0 and not LOCK.isLocked() and LOCK.idle() >= mins * 60 then LOCK.lock() end
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
pcall(RC.save)                     -- map + home + stats
gpu.setResolution(oldW, oldH)
rgpu.setBackground(0x000000)
rgpu.setForeground(0xFFFFFF)
term.clear()
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write(tostring(err) .. "\n")
end
