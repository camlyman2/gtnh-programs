--[[
  lymanosgov.lua  -  Lymanos Government (stripped-down Lymanos for the Government server)

  Apps:
    Government    Income tab: every player's yearly salary (and the default
                  salary for players without their own), and Bonuses - typed
                  cash amounts paid into a player's Lymanos Bank savings.
    My Computer   storage, memory, power and hardware details
    Settings      your name, system name, lock screen, desktop color.
                  Saved to /home/lymanosgov_settings.dat

  How it talks to the players' Lymanos (lymanos.lua):
    * Players show up by themselves: every Lymanos announces its owner on
      BANK_PORT (4045) and checks in on GOV_PORT (4047) every 30 seconds.
    * Lymanos -> here:  "GOV", "SYNC", name
      here -> Lymanos:  "GOV", "INFO", serialized { n = name, sal = salary per
                        year, b = { unpaid bonuses { id, amt, m = memo } }, gov }
      Lymanos -> here:  "GOV", "BONUSOK", id, name   (after the money is saved)
      On start this server broadcasts "GOV", "HELLO" so everyone checks in at once.
    * A bonus stays "waiting" until that player's Lymanos answers BONUSOK. It is
      sent again on every check-in until then, and Lymanos pays each bonus id only
      once, so a bonus is never lost or paid twice.
    * A changed salary is sent at once; Lymanos keeps the last salary it heard, so
      paydays keep working while this server is off.

  Files written on this computer:
    /home/lymanosgov_data.dat       salaries, default salary, bonuses
    /home/lymanosgov_settings.dat   Settings app
    /home/lymanosgov_storage.dat    My Computer > Storage Report growth log

  Needs: tier 3 GPU + tier 3 screen (160x50) and a Wireless Network Card
  (tier 2 recommended: 400 blocks). Mouse + keyboard.
  Exit: Start > Shut Down or Ctrl+C.
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  GOV_PORT = 4047,             -- must match GOV_PORT in lymanos.lua
  BANK_PORT = 4045,            -- every Lymanos announces its owner here (who is on the network)
  GOV_NAME = "Lymanos Government",   -- shown to players when a bonus arrives
  DEFAULT_SALARY = 100000,     -- dollars per year until you change it in the app
  PAYDAY_HOUR = 21,            -- only shown here: must match PAYDAY_HOUR / MINUTE in lymanos.lua
  PAYDAY_MINUTE = 0,
  ONLINE_SECONDS = 60,         -- heard from a player this recently = online
  BONUS_MAX = 1e9,             -- largest single bonus
  BONUS_KEEP = 200,            -- paid / cancelled bonuses kept in the list (waiting ones are always kept)
  PLAYER_NAME = nil,           -- default name; normally set in the Settings app
  DATA_FILE = "/home/lymanosgov_data.dat",
  SETTINGS_FILE = "/home/lymanosgov_settings.dat",
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

---------------------------------------------------------------- SETTINGS
-- Values changed in the Settings app. They override CONFIG and are saved
-- as a small text table. nil = use the CONFIG default.
local SETTINGS = {
  userName = nil,       -- your name (shown on the lock screen)
  systemName = "Lymanos Gov",
  lockMins = 30,        -- auto-lock after this many idle minutes (0 = never)
  lockStyle = 1,        -- lock screen color theme
  clock24 = false,      -- 24-hour clock on the taskbar and lock screen
  desk = 2,             -- desktop color
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
wlan.open(CONFIG.GOV_PORT)
wlan.open(CONFIG.BANK_PORT)
local PLAYER_NAME = SETTINGS.userName or CONFIG.PLAYER_NAME or "Government"

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
local activeApp = "gov"       -- window in front: "gov" | "sys" | "settings" | nil (desktop)
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

local drawAll                                            -- forward
local openSysApp, closeSysApp, sysAppOpen                -- forward (My Computer)
local openSettings, closeSettings, settingsOpen          -- forward (Settings)
local LOCK, SET, GOVT                                    -- lock screen, Settings, Government (below)

local function drawDesktop()
  fill(1, 1, W, 46, K.desk)
  drawIcon(3, 2, "pc", "My Computer")
  region(regions, 1, 2, 12, 5, function() openSysApp(); drawAll() end)
  -- Government icon: a little capitol building
  text(4, 8, "  ▗██▖  ", 0xC9A227, K.desk)
  text(4, 9, "▗▄▄▄▄▄▄▖", 0xE8E8E8, K.desk)
  text(4, 10, "▐▌▐▌▐▌▐▌", 0x8A8A8A, 0xE8E8E8)
  text(4, 11, "▀▀▀▀▀▀▀▀", 0x8A8A8A, K.desk)
  textW(1, 12, 12, "Government", K.white, K.desk, "center")
  region(regions, 1, 8, 12, 5, function() GOVT.open(); drawAll() end)
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
  local on = GOVT and GOVT.stats().online > 0
  text(146, 49, "((•))", on and K.green or K.sh, K.face)
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
  if GOVT.isOpen() then list[#list + 1] = { " ★ Government", "gov" } end
  if sysAppOpen and sysAppOpen() then list[#list + 1] = { " ▣ My Computer", "sys" } end
  if settingsOpen and settingsOpen() then list[#list + 1] = { " ▣ Settings", "settings" } end
  local bw = min(25, floor(132 / max(1, #list)) - 1)
  for i, it in ipairs(list) do taskButton(11 + (i - 1) * (bw + 1), bw, it[1], it[2]) end
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
  local st = GOVT.stats()
  dialog("About " .. tostring(SETTINGS.systemName or "Lymanos Gov"), {
    tostring(CONFIG.GOV_NAME) .. "  -  lymanosgov (Lymanos Gov 1.0)",
    "Sets every player's salary and pays bonuses into their Lymanos Bank.",
    "Ports: " .. CONFIG.GOV_PORT .. " (government)   " .. CONFIG.BANK_PORT .. " (players announce themselves)",
    "",
    st.players .. " player(s), " .. st.online .. " online now, " .. st.waiting .. " bonus(es) waiting",
  }, { { "OK" } })
end

local function confirmExit()
  dialog("Shut Down", { "Are you sure you want to close Lymanos Gov?",
    "Players keep their last salary; waiting bonuses are sent after the restart." },
    { { "Yes", function() running = false end }, { "No" } })
end

openStartMenu = function()
  popupMenu(1, 47, {
    { "Government", function() GOVT.open() end },
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
local GROW_FILE = "/home/lymanosgov_storage.dat"   -- one line per day: day number, bytes in /home
-- every data file Lymanos writes, and how much of it is kept
local KINDS = {
  { "Government", "salaries + bonuses", "^lymanosgov_data%.dat", "every player + " .. CONFIG.BONUS_KEEP .. " finished bonuses" },
  { "System", "settings", "^lymanosgov_settings%.dat$", "fixed size" },
  { "", "this report's growth log", "^lymanosgov_storage%.dat$", "60 days" },
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


------------------------------------------------------------- GOVERNMENT
-- Income tab: the payroll (every player's yearly salary + the default salary),
-- the selected player, and bonuses (issue + the list of issued bonuses).
-- Everything is saved in DATA_FILE at once when it changes.
GOVT = (function()
local C = {
  navy = 0x1B365D, navy2 = 0x2B5797, gold = 0xC9A227, gold2 = 0xF2D675, pale = 0xE4EAF3, page = 0xF1F3F7,
  white = 0xFFFFFF, ink = 0x18212D, dim = 0x6C7686, line = 0xD8DEE8, red = 0xC2362B, green = 0x1E8C4E,
  mint = 0x2FB36B, sel = 0xDCE6F5, field = 0xFFFBD6, amber = 0xB7791F,
}
local X0, X1 = WX + 1, WX + WW - 2
local CW = X1 - X0 + 1
local HY, TOP, BOT, SY = WY + 3, WY + 4, WY + WH - 3, WY + WH - 2
local LX, LW = X0 + 1, 78                 -- left column (payroll, selected player)
local RX = LX + LW + 1                    -- right column (bonuses)
local RW = X1 - RX
local PY, PROWS = TOP + 4, 16             -- first payroll row, rows shown
local BY, BROWS = TOP + 20, 17            -- first bonus row, rows shown
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local EVERYONE = "*"

-- saved data: default salary, players { [name] = { sal = nil (default) | n, seen, s, p } }, bonuses (newest first)
local D = { def = CONFIG.DEFAULT_SALARY or 100000, users = {}, bonuses = {}, seq = 0 }
-- what is on screen
local V = { open = true, reg = {}, sel = nil, to = nil, amt = "", memo = "", focus = nil, input = "",
            pScroll = 0, bScroll = 0, msg = nil, msgCol = nil, redraw = false, lastDraw = 0,
            seenDirty = false, lastSave = 0, loadErr = nil }
local drawWindow   -- forward

---------------------------------------------------------------- helpers
local function cents(v) return floor(v * 100 + 0.5) / 100 end
local function money(n)
  if not n then return "--" end
  local neg = n < 0
  n = math.abs(n)
  local whole = floor(n)
  local c = floor((n - whole) * 100 + 0.5)
  if c >= 100 then whole, c = whole + 1, c - 100 end
  return (neg and "-$" or "$") .. commas(whole) .. string.format(".%02d", c)
end
local function short(n)
  if not n then return "--" end
  local a = math.abs(n)
  local s
  if a >= 1e9 then s = string.format("%.2fB", a / 1e9)
  elseif a >= 1e6 then s = string.format("%.2fM", a / 1e6)
  elseif a >= 1e4 then s = string.format("%.1fK", a / 1e3)
  else return money(n) end
  return (n < 0 and "-$" or "$") .. s
end
local function visible() return activeApp == "gov" and not overlay and not LOCK.isLocked() end
local function realTime(t) return t and t > 1e9 end
local function dayStamp(t)
  if not realTime(t) then return "--" end
  local e = toEastern(t)
  return MONTHS[e.month] .. string.format(" %02d", e.day)
end
local function clockText(h, m)
  if SETTINGS.clock24 then return string.format("%02d:%02d", h, m) end
  local hh = h % 12
  return string.format("%d:%02d %s", hh == 0 and 12 or hh, m, h < 12 and "AM" or "PM")
end
local function payTime() return clockText(CONFIG.PAYDAY_HOUR or 21, CONFIG.PAYDAY_MINUTE or 0) .. " ET" end
-- "250000", "$250,000", "250k", "1.5m", "2b" -> dollars (nil if it isn't a number)
local function parseMoney(s)
  s = tostring(s or ""):lower():gsub("[%$,%s_]", "")
  local mult = ({ k = 1e3, m = 1e6, b = 1e9, g = 1e9 })[s:sub(-1)]
  if mult then s = s:sub(1, -2) else mult = 1 end
  local v = tonumber(s)
  if not v or v ~= v or v < 0 or v == math.huge then return nil end
  return cents(v * mult)
end
local function trim(s) return (tostring(s or ""):gsub("[%c]", ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function say(m, col) V.msg, V.msgCol = m, col end

---------------------------------------------------------------- save / load
-- written to a .tmp file first, then swapped in: a crash mid-save never loses the data
local function saveData()
  local users = {}
  for name, u in pairs(D.users) do users[name] = { sal = u.sal, seen = u.seen, s = u.s, p = u.p } end
  local ok, raw = pcall(serialization.serialize, { v = 1, def = D.def, seq = D.seq, users = users, bonuses = D.bonuses })
  if not ok then say("Could not save: " .. tostring(raw), C.red); return end
  local tmp = CONFIG.DATA_FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then say("Could not save " .. CONFIG.DATA_FILE .. " - is the disk full?", C.red); return end
  local wok = f:write(raw)
  f:close()
  if not wok or (filesystem.size(tmp) or 0) < #raw then
    say("Could not save " .. CONFIG.DATA_FILE .. " - is the disk full?", C.red)
    return
  end
  if filesystem.exists(CONFIG.DATA_FILE) then filesystem.remove(CONFIG.DATA_FILE) end
  filesystem.rename(tmp, CONFIG.DATA_FILE)
  V.seenDirty, V.lastSave = false, computer.uptime()
end

local function loadData()
  local path = CONFIG.DATA_FILE
  if not filesystem.exists(path) and filesystem.exists(path .. ".tmp") then path = path .. ".tmp" end
  local raw = readFile(path)
  if not raw then return end
  local ok, t = pcall(serialization.unserialize, raw)
  if not ok or type(t) ~= "table" then
    writeFile(CONFIG.DATA_FILE .. ".bad", raw)        -- kept for you to look at; starting empty
    V.loadErr = "The data file could not be read - a copy was kept as " .. CONFIG.DATA_FILE .. ".bad"
    return
  end
  D.def = tonumber(t.def) or D.def
  D.seq = tonumber(t.seq) or 0
  if type(t.users) == "table" then
    for name, u in pairs(t.users) do
      if type(name) == "string" and type(u) == "table" then
        D.users[name] = { sal = tonumber(u.sal), seen = tonumber(u.seen), s = tonumber(u.s), p = tonumber(u.p) }
      end
    end
  end
  if type(t.bonuses) == "table" then
    for _, b in ipairs(t.bonuses) do
      if type(b) == "table" and type(b.id) == "string" and type(b.p) == "string" and tonumber(b.amt) then
        b.amt = tonumber(b.amt)
        if b.st ~= "paid" and b.st ~= "void" then b.st = "pend" end
        D.bonuses[#D.bonuses + 1] = b
      end
    end
  end
end

---------------------------------------------------------------- players
local function salaryOf(u) return (u and u.sal) or D.def end
local function isOnline(u) return u and u.up ~= nil and computer.uptime() - u.up <= (CONFIG.ONLINE_SECONDS or 60) end
local function names()
  local list = {}
  for name in pairs(D.users) do list[#list + 1] = name end
  table.sort(list, function(a, b)
    local la, lb = a:lower(), b:lower()
    if la ~= lb then return la < lb end
    return a < b
  end)
  return list
end
-- a player was heard from (SYNC or a Bank announcement)
local function heard(name, from)
  local u = D.users[name]
  local new = u == nil
  if new then u = {}; D.users[name] = u end
  local wasOnline = isOnline(u)
  u.up, u.addr, u.seen = computer.uptime(), from, now()
  V.seenDirty = true
  if new then
    saveData()
    say(name .. " joined the network - salary " .. money(salaryOf(u)) .. " a year (default).", C.green)
  end
  if new or not wasOnline then V.redraw = true end
  return u
end

---------------------------------------------------------------- bonuses
local function waitingFor(name)                  -- oldest first
  local out = {}
  for i = #D.bonuses, 1, -1 do
    local b = D.bonuses[i]
    if b.st == "pend" and b.p == name then out[#out + 1] = b end
  end
  return out
end
local function trimBonuses()
  local done = 0
  for _, b in ipairs(D.bonuses) do if b.st ~= "pend" then done = done + 1 end end
  local i = #D.bonuses
  while done > (CONFIG.BONUS_KEEP or 200) and i >= 1 do
    if D.bonuses[i].st ~= "pend" then table.remove(D.bonuses, i); done = done - 1 end
    i = i - 1
  end
end
local function stats()
  local s = { players = 0, online = 0, payroll = 0, waiting = 0, waitSum = 0, paidSum = 0 }
  for _, u in pairs(D.users) do
    s.players = s.players + 1
    if isOnline(u) then s.online = s.online + 1 end
    s.payroll = s.payroll + salaryOf(u)
  end
  for _, b in ipairs(D.bonuses) do
    if b.st == "pend" then s.waiting, s.waitSum = s.waiting + 1, s.waitSum + b.amt
    elseif b.st == "paid" then s.paidSum = s.paidSum + b.amt end
  end
  return s
end

---------------------------------------------------------------- network
-- what a player's Lymanos is told: its salary and the bonuses it hasn't confirmed
local function infoFor(name)
  local b = {}
  for _, x in ipairs(waitingFor(name)) do
    if #b >= 15 then break end                   -- keeps the packet small; the rest come next time
    b[#b + 1] = { id = x.id, amt = x.amt, m = x.m }
  end
  return serialization.serialize({ n = name, sal = salaryOf(D.users[name]), b = b, gov = CONFIG.GOV_NAME })
end
local function push(name) pcall(wlan.broadcast, CONFIG.GOV_PORT, "GOV", "INFO", infoFor(name)) end

local function onGov(from, kind, a, b)
  if kind == "SYNC" then
    if type(a) ~= "string" or a == "" then return end
    local name = a:sub(1, 32)
    heard(name, from)
    pcall(wlan.send, from, CONFIG.GOV_PORT, "GOV", "INFO", infoFor(name))
  elseif kind == "BONUSOK" then
    if type(a) ~= "string" then return end
    for _, x in ipairs(D.bonuses) do
      if x.id == a then
        if x.st ~= "paid" and (type(b) ~= "string" or b == x.p) then
          if x.st == "void" then x.late = true end   -- it reached them before the cancel did
          x.st, x.paid = "paid", floor(now())
          saveData()
          say(x.p .. " received the bonus of " .. money(x.amt) .. ".", C.green)
          V.redraw = true
        end
        return
      end
    end
  end
end

-- every Lymanos announces its owner's balances on BANK_PORT: that's the roster
local function onBank(from, kind, a)
  if kind ~= "STAT" then return end
  local ok, t = pcall(serialization.unserialize, a)
  if not ok or type(t) ~= "table" or type(t.n) ~= "string" or t.n == "" then return end
  local u = heard(t.n:sub(1, 32), from)
  u.s, u.p = tonumber(t.s), tonumber(t.p)
end

---------------------------------------------------------------- actions
local function redraw() if visible() then drawWindow() end end

local function setSalary(name, v)                -- v = nil: back to the default
  local u = D.users[name]
  if not u then return end
  if v and v > 1e10 then say("That salary is too big.", C.red); return end
  u.sal = v
  saveData()
  push(name)
  say(name .. "'s salary is now " .. money(salaryOf(u)) .. " a year" .. (v == nil and " (the default)" or "") ..
    " - " .. money(cents(salaryOf(u) / 365)) .. " a day.", C.green)
end

local function setDefault(v)
  if v > 1e10 then say("That salary is too big.", C.red); return end
  D.def = v
  saveData()
  local n = 0
  for name, u in pairs(D.users) do if u.sal == nil then push(name); n = n + 1 end end
  say("Default salary is now " .. money(v) .. " a year (" .. n .. " player" .. (n == 1 and "" or "s") .. " on the default).", C.green)
end

local function addPlayer(name)
  name = trim(name)
  if name == "" then return end
  if D.users[name] then V.sel = name; say(name .. " is already on the list.", C.dim); return end
  D.users[name] = {}
  V.sel, V.to = name, V.to or name
  saveData()
  say("Added " .. name .. ". The name must match their Lymanos name exactly (Settings > Your name).", C.green)
end

local function removePlayer(name)
  local w = #waitingFor(name)
  dialog("Remove Player", {
    "Remove " .. name .. " from the payroll list?",
    "Their own salary is forgotten: if their Lymanos checks in again they come back",
    "on the default salary (" .. money(D.def) .. " a year).",
    w > 0 and (w .. " waiting bonus(es) for them stay waiting.") or "",
  }, { { "Remove", function()
        D.users[name] = nil
        if V.sel == name then V.sel = nil end
        if V.to == name then V.to = nil end
        saveData()
        say(name .. " was removed from the list.", C.dim)
      end }, { "Cancel" } })
end

local function issue(to, amt, memo)
  local list = to == EVERYONE and names() or { to }
  local t = floor(now())
  for _, name in ipairs(list) do
    if not D.users[name] then D.users[name] = {} end
    D.seq = D.seq + 1
    -- the id includes the time: ids never repeat, even if the data file is lost
    table.insert(D.bonuses, 1, { id = wlan.address:sub(1, 4) .. "-" .. t .. "-" .. D.seq, p = name,
                                 amt = amt, m = memo, at = t, st = "pend" })
  end
  trimBonuses()
  saveData()
  for _, name in ipairs(list) do push(name) end
  V.amt, V.memo, V.bScroll = "", "", 0
  local who = to == EVERYONE and (#list .. " players") or to
  say("Bonus of " .. money(amt) .. " sent to " .. who .. ". It is paid when their Lymanos is in range.", C.green)
end

local function askIssue()
  local amt = parseMoney(V.amt)
  local list = V.to == EVERYONE and names() or { V.to }
  if not V.to or (V.to ~= EVERYONE and not D.users[V.to]) then say("Choose who gets the bonus (Pay to).", C.red); return redraw() end
  if #list == 0 then say("There are no players yet.", C.red); return redraw() end
  if not amt or amt <= 0 then say("Type the amount, e.g. 50000, 250k or 1.5m.", C.red); return redraw() end
  if amt > (CONFIG.BONUS_MAX or 1e9) then say("A single bonus can be at most " .. money(CONFIG.BONUS_MAX or 1e9) .. ".", C.red); return redraw() end
  local memo = trim(V.memo)
  if memo == "" then memo = "Government bonus" end
  local lines
  if V.to == EVERYONE then
    lines = { "Pay a bonus of " .. money(amt) .. " to each of the " .. #list .. " players?",
              "Total: " .. money(amt * #list) .. "      Memo: " .. memo }
  else
    lines = { "Pay a bonus of " .. money(amt) .. " to " .. V.to .. "?", "Memo: " .. memo }
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "It goes into their Lymanos Bank savings as soon as their"
  lines[#lines + 1] = "computer is in range (until then it waits here)."
  local to = V.to
  dialog("Issue Bonus", lines, { { "Pay", function() issue(to, amt, memo) end }, { "Cancel" } })
end

local function bonusDetails(b)
  local st = b.st == "pend" and "Waiting for their Lymanos to confirm"
    or (b.st == "paid" and ("Paid " .. fmtStamp(b.paid) .. (b.late and "  (it arrived before the cancel)" or ""))
    or "Cancelled")
  local lines = { "To:       " .. b.p, "Amount:   " .. money(b.amt), "Memo:     " .. tostring(b.m or ""),
                  "Issued:   " .. fmtStamp(b.at), "Status:   " .. st, "Id:       " .. b.id }
  if b.st == "pend" then
    dialog("Bonus", lines, { { "Cancel bonus", function()
        if b.st == "pend" then
          b.st = "void"
          saveData()
          push(b.p)
          say("Bonus of " .. money(b.amt) .. " to " .. b.p .. " cancelled.", C.dim)
        end
      end }, { "Close" } })
  else
    dialog("Bonus", lines, { { "OK" } })
  end
end

---------------------------------------------------------------- drawing kit
local function card(x, y, w, h, title, right)
  fill(x, y, w, h, C.white)
  text(x + 2, y, title, C.navy, C.white)
  if right then
    local rw = min(unicode.len(right), w - unicode.len(title) - 6)
    textW(x + w - 2 - rw, y, rw, right, C.dim, C.white, "right")
  end
  text(x + 2, y + 1, string.rep("─", w - 4), C.line, C.white)
end
-- one row painted left to right: { {width, text, color, align}, ... }
local function cells(x, y, list, b)
  for _, c in ipairs(list) do
    textW(x, y, c[1], c[2] or "", c[3] or C.ink, b or C.white, c[4])
    x = x + c[1]
  end
end
local function btn(x, y, s, fn, col)
  text(x, y, s, C.white, col or C.navy2)
  region(V.reg, x, y, unicode.len(s), 1, fn)
  return x + unicode.len(s) + 1
end
local function field(id, x, y, w, value, hint)
  if V.focus == id then
    local s = V.input
    if unicode.len(s) > w - 2 then s = unicode.sub(s, -(w - 2)) end
    textW(x, y, w, " " .. s .. "_", C.ink, C.field)
  elseif value and value ~= "" then
    textW(x, y, w, " " .. value, C.ink, C.pale)
  else
    textW(x, y, w, " " .. (hint or ""), C.dim, C.pale)
  end
  region(V.reg, x, y, w, 1, function()
    V.focus = id
    V.input = (id == "amt" and V.amt) or (id == "memo" and V.memo) or ""
    drawWindow()
  end)
end
local function lastSeen(u)
  if isOnline(u) then return "online now", C.green end
  if not u.seen then return "never seen", C.dim end
  if not realTime(u.seen) then return "seen (no clock)", C.dim end
  local ago = now() - u.seen
  if ago < 3600 then return floor(ago / 60) .. " min ago", C.dim end
  if ago < 86400 then return floor(ago / 3600) .. " h ago", C.dim end
  return dayStamp(u.seen), C.dim
end

---------------------------------------------------------------- the page
local function header(st)
  fill(X0, HY, CW, 1, C.navy)
  text(X0 + 1, HY, " ★ ", C.navy, C.gold)
  textW(X0 + 5, HY, 28, tostring(CONFIG.GOV_NAME):upper(), C.white, C.navy)
  text(X0 + 34, HY, "  Income  ", C.navy, C.white)
  textW(X1 - 60, HY, 60, "Payroll " .. short(st.payroll) .. " / year  ·  " .. short(cents(st.payroll / 365)) .. " new money / day  ",
    C.pale, C.navy, "right")
end

local function drawPayroll(st, list)
  local x, y, w = LX, TOP + 1, LW
  card(x, y, w, 24, "PAYROLL", st.players .. " player" .. (st.players == 1 and "" or "s") .. " · " .. st.online .. " online")
  cells(x + 1, y + 2, { { 3 }, { 17, "PLAYER", C.dim }, { 14, "SALARY / YEAR", C.dim, "right" }, { 1 },
    { 11, "PER DAY", C.dim, "right" }, { 1 }, { 13, "NET WORTH", C.dim, "right" }, { 2 }, { 13, "LAST SEEN", C.dim }, { 1 } })
  V.pScroll = max(0, min(V.pScroll, #list - PROWS))
  for r = 1, PROWS do
    local yy = PY + r - 1
    local name = list[r + V.pScroll]
    if name then
      local u = D.users[name]
      local sel = name == V.sel
      local b = sel and C.sel or C.white
      local seen, seenCol = lastSeen(u)
      local worth = (u.s or u.p) and short((u.s or 0) + (u.p or 0)) or "--"
      cells(x + 1, yy, { { 1 }, { 2, "●", isOnline(u) and C.mint or C.line }, { 17, name, sel and C.navy or C.ink },
        { 14, money(salaryOf(u)), u.sal and C.ink or C.dim, "right" }, { 1 }, { 11, money(cents(salaryOf(u) / 365)), C.dim, "right" },
        { 1 }, { 13, worth, C.ink, "right" }, { 2 }, { 13, seen, seenCol }, { 1 } }, b)
      region(V.reg, x + 1, yy, w - 2, 1, function()
        V.sel, V.focus = (V.sel == name) and nil or name, nil
        if V.sel then V.to = name end
        drawWindow()
      end)
    else
      textW(x + 1, yy, w - 2, (r == 2 and #list == 0) and
        "   No players yet. They appear when their Lymanos is in range, or add one below." or "", C.dim, C.white)
    end
  end
  local fy = PY + PROWS
  textW(x + 2, fy, w - 4, #list > PROWS and string.format("%d-%d of %d  ·  scroll for more  ·  grey salary = default",
    V.pScroll + 1, min(#list, V.pScroll + PROWS), #list) or "Grey salary = the player is on the default salary.", C.dim, C.white)
  text(x + 2, fy + 1, string.rep("─", w - 4), C.line, C.white)
  textW(x + 2, fy + 2, 16, "Default salary:", C.ink, C.white)
  field("def", x + 18, fy + 2, 15, nil, money(D.def))
  btn(x + 34, fy + 2, " Set ", function()
    local p = V.prev                             -- what was typed before this click
    local v = p and p.id == "def" and parseMoney(p.input)
    if v then setDefault(v)
    else V.focus, V.input = "def", ""; say("Type the new default salary per year, then press Enter.", C.dim) end
    drawWindow()
  end)
  textW(x + 41, fy + 2, 12, "Add player:", C.ink, C.white)
  field("add", x + 53, fy + 2, 15, nil, "name")
  btn(x + 69, fy + 2, " Add ", function()
    local p = V.prev
    if p and p.id == "add" and trim(p.input) ~= "" then addPlayer(p.input)
    else V.focus, V.input = "add", ""; say("Type the player's Lymanos name, then press Enter.", C.dim) end
    drawWindow()
  end)
  textW(x + 2, fy + 3, w - 4, "Each player's Lymanos pays salary / 365 every day at " .. payTime() .. ".", C.dim, C.white)
end

local function drawSelected()
  local x, y, w = LX, TOP + 26, LW
  local h = BOT - y + 1
  local name = V.sel
  local u = name and D.users[name]
  card(x, y, w, h, "SELECTED PLAYER")
  if not u then
    textW(x + 2, y + 3, w - 4, "Click a player in the payroll list to change their salary", C.dim, C.white)
    textW(x + 2, y + 4, w - 4, "or to pay them a bonus.", C.dim, C.white)
    return
  end
  local seen, seenCol = lastSeen(u)
  cells(x + 2, y + 2, { { 2, "●", isOnline(u) and C.mint or C.line }, { 24, name, C.navy }, { w - 30, seen, seenCol, "right" } })
  textW(x + 2, y + 3, w - 4, (u.s or u.p) and ("Savings " .. money(u.s or 0) .. "  ·  invested " .. money(u.p or 0) ..
    "  (from their Bank)") or "No balances heard yet (their Lymanos hasn't announced itself).", C.dim, C.white)
  textW(x + 2, y + 5, 17, "Salary per year:", C.ink, C.white)
  field("sal", x + 19, y + 5, 18, nil, money(salaryOf(u)))
  local bx = btn(x + 38, y + 5, " Set salary ", function()
    local p = V.prev
    local v = p and p.id == "sal" and parseMoney(p.input)
    if v then setSalary(name, v)
    else V.focus, V.input = "sal", ""; say("Type " .. name .. "'s salary per year (e.g. 120000 or 120k), then press Enter.", C.dim) end
    drawWindow()
  end)
  if u.sal then
    btn(bx, y + 5, " Use default ", function() V.focus = nil; setSalary(name, nil); drawWindow() end, C.dim)
  end
  textW(x + 2, y + 6, w - 4, "Now " .. money(salaryOf(u)) .. " a year" .. (u.sal and "" or " (the default)") .. " = " ..
    money(cents(salaryOf(u) / 365)) .. " a day at " .. payTime(), C.dim, C.white)
  local wl, sum = waitingFor(name), 0
  for _, b in ipairs(wl) do sum = sum + b.amt end
  textW(x + 2, y + 8, w - 4, #wl > 0 and (#wl .. " bonus" .. (#wl == 1 and "" or "es") .. " waiting for " .. name ..
    "'s Lymanos (" .. money(sum) .. ")") or "No bonuses waiting.", #wl > 0 and C.amber or C.dim, C.white)
  local bx2 = btn(x + 2, y + 10, " Pay " .. name .. " a bonus ", function()
    V.to, V.focus, V.input = name, "amt", V.amt
    drawWindow()
  end, C.gold)
  btn(bx2, y + 10, " Remove from list ", function() removePlayer(name) end, C.red)
end

local function drawIssue(st, list)
  local x, y, w = RX, TOP + 1, RW
  card(x, y, w, 15, "ISSUE A BONUS", "paid into their Bank savings")
  -- pay to: a player or everyone
  textW(x + 2, y + 2, 10, "Pay to:", C.ink, C.white)
  local opts = {}
  for _, n in ipairs(list) do opts[#opts + 1] = n end
  if #list > 1 then opts[#opts + 1] = EVERYONE end
  if V.to and V.to ~= EVERYONE and not D.users[V.to] then V.to = nil end
  if V.to == EVERYONE and #list <= 1 then V.to = nil end
  if not V.to and #opts > 0 then V.to = V.sel or opts[1] end
  local cur = 1
  for i, o in ipairs(opts) do if o == V.to then cur = i end end
  local label = V.to == EVERYONE and ("Everyone (" .. #list .. " players)") or (V.to or "no players yet")
  text(x + 12, y + 2, " ◄ ", C.white, C.navy2)
  textW(x + 15, y + 2, 30, label, C.ink, C.pale, "center")
  text(x + 45, y + 2, " ► ", C.white, C.navy2)
  local function stepTo(d)
    if #opts == 0 then return end
    V.to = opts[(cur - 1 + d) % #opts + 1]
    V.focus = nil
    drawWindow()
  end
  region(V.reg, x + 12, y + 2, 3, 1, function() stepTo(-1) end)
  region(V.reg, x + 45, y + 2, 3, 1, function() stepTo(1) end)
  region(V.reg, x + 15, y + 2, 30, 1, function() stepTo(1) end)
  -- amount and memo
  textW(x + 2, y + 4, 10, "Amount:", C.ink, C.white)
  field("amt", x + 12, y + 4, 20, V.amt, "e.g. 250k or 1.5m")
  local typed = V.focus == "amt" and V.input or V.amt
  local amt = parseMoney(typed)
  local n = V.to == EVERYONE and #list or 1
  textW(x + 33, y + 4, w - 35, (typed ~= "" and amt) and ("= " .. money(amt) .. (n > 1 and (" x " .. n .. " = " .. short(amt * n)) or ""))
    or (typed ~= "" and "not a number" or ""), (typed ~= "" and not amt) and C.red or C.green, C.white)
  textW(x + 2, y + 6, 10, "Memo:", C.ink, C.white)
  field("memo", x + 12, y + 6, w - 14, V.memo, "Government bonus  (shown to the player)")
  -- the button
  local bw = 22
  fill(x + 12, y + 8, bw, 3, C.gold)
  textW(x + 12, y + 9, bw, "PAY BONUS", C.navy, C.gold, "center")
  region(V.reg, x + 12, y + 8, bw, 3, function()
    if V.focus == "amt" then V.amt = V.input elseif V.focus == "memo" then V.memo = V.input end
    V.focus, V.input = nil, ""
    askIssue()
  end)
  textW(x + 36, y + 9, w - 38, "(you confirm first)", C.dim, C.white)
  textW(x + 2, y + 12, w - 4, "Enter: Amount -> Memo -> pay.   Tab switches fields.", C.dim, C.white)
  textW(x + 2, y + 13, w - 4, "A bonus is sent again until the player's Lymanos confirms it.", C.dim, C.white)
end

local STATUS = { pend = { "○ waiting", C.amber }, paid = { "✓ paid", C.green }, void = { "✕ cancelled", C.dim } }
local function drawBonuses(st)
  local x, y, w = RX, TOP + 17, RW
  card(x, y, w, BOT - y + 1, "BONUSES", st.waiting .. " waiting · " .. short(st.paidSum) .. " paid")
  cells(x + 1, y + 2, { { 1 }, { 7, "DATE", C.dim }, { 1 }, { 14, "TO", C.dim }, { 13, "AMOUNT", C.dim, "right" }, { 2 },
    { 12, "STATUS", C.dim }, { w - 52, "MEMO", C.dim }, { 1 } })
  local nb = #D.bonuses
  V.bScroll = max(0, min(V.bScroll, nb - BROWS))
  for r = 1, BROWS do
    local yy = BY + r - 1
    local b = D.bonuses[r + V.bScroll]
    if b then
      local s = STATUS[b.st] or STATUS.pend
      cells(x + 1, yy, { { 1 }, { 7, dayStamp(b.at), C.dim }, { 1 }, { 14, b.p }, { 13, money(b.amt), C.ink, "right" }, { 2 },
        { 12, s[1], s[2] }, { w - 52, tostring(b.m or ""), C.dim }, { 1 } })
      region(V.reg, x + 1, yy, w - 2, 1, function() bonusDetails(b) end)
    else
      textW(x + 1, yy, w - 2, (r == 2 and nb == 0) and "   No bonuses issued yet." or "", C.dim, C.white)
    end
  end
  textW(x + 2, BOT, w - 4, nb > BROWS and string.format("%d-%d of %d  ·  scroll  ·  click one for details", V.bScroll + 1,
    min(nb, V.bScroll + BROWS), nb) or "Click a bonus for details or to cancel it.", C.dim, C.white)
end

local function drawStatus(st)
  fill(WX + 1, SY, WW - 2, 1, K.face)
  local msg = V.msg or V.loadErr or "Salaries and bonuses go to each player's Lymanos Bank. Changes are saved at once."
  textW(WX + 2, SY, 96, msg, (V.msg and V.msgCol == C.red) and K.red or K.black, K.face)
  text(WX + 99, SY, "│", K.sh, K.face)
  textW(WX + 100, SY, 42, "Port " .. CONFIG.GOV_PORT .. "  ·  " .. st.online .. " online  ·  " .. st.waiting .. " waiting", K.black, K.face)
end

drawWindow = function()
  V.reg = {}
  local st, list = stats(), names()
  if V.sel and not D.users[V.sel] then V.sel = nil end
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "★ Government - Income", true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(V.reg, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(V.reg, bx + 7, WY + 1, 3, 1, function() V.open, V.focus = false, nil; activeApp = nil; drawAll() end)
  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  text(WX + 2, WY + 2, " Government ", K.black, K.face)
  text(WX + 14, WY + 2, " Help ", K.black, K.face)
  region(V.reg, WX + 2, WY + 2, 12, 1, function()
    popupMenu(WX + 2, WY + 3, {
      { "Pay everyone a bonus...", function() V.to, V.focus, V.input = EVERYONE, "amt", V.amt end },
      { "Clear finished bonuses", function()
          for i = #D.bonuses, 1, -1 do if D.bonuses[i].st ~= "pend" then table.remove(D.bonuses, i) end end
          saveData(); say("Paid and cancelled bonuses were cleared from the list.", C.dim)
        end },
      { "Ask everyone to check in", function()
          pcall(wlan.broadcast, CONFIG.GOV_PORT, "GOV", "HELLO"); say("Asked every Lymanos in range to check in.", C.dim)
        end },
      { "-" },
      { "Close Government", function() V.open = false; activeApp = nil end },
    })
  end)
  region(V.reg, WX + 14, WY + 2, 6, 1, function()
    popupMenu(WX + 14, WY + 3, { { "About Income...", function()
      dialog("About Income", {
        "Salary: each player's Lymanos deposits salary / 365 every day at " .. payTime() .. ".",
        "Players without their own salary get the default (" .. money(D.def) .. " a year).",
        "A changed salary is sent at once; Lymanos keeps the last one it heard.",
        "Bonuses: typed amounts (250000, 250k, 1.5m). One is paid into the player's savings",
        "the next time their Lymanos checks in (every 30 s while in range), exactly once.",
        "Players appear by themselves; names must match their Lymanos name exactly.",
      }, { { "OK" } })
    end } })
  end)
  header(st)
  fill(X0, TOP, CW, BOT - TOP + 1, C.page)
  drawPayroll(st, list)
  drawSelected()
  drawIssue(st, list)
  drawBonuses(st)
  drawStatus(st)
  V.redraw, V.lastDraw = false, computer.uptime()
end

---------------------------------------------------------------- input
local function blur()                            -- clicking elsewhere keeps what was typed in Amount / Memo
  if V.focus == "amt" then V.amt = V.input elseif V.focus == "memo" then V.memo = V.input end
  local had = V.focus ~= nil
  V.prev = had and { id = V.focus, input = V.input } or nil   -- for the Set / Add button clicked next
  V.focus, V.input = nil, ""
  return had
end

local function key(ch, code)
  local id = V.focus
  if not id then return end
  if code == 28 or code == 156 then              -- Enter
    local v = V.input
    V.focus, V.input = nil, ""
    if id == "amt" then V.amt = v; V.focus, V.input = "memo", V.memo
    elseif id == "memo" then V.memo = v; askIssue(); if overlay then return end
    elseif id == "sal" or id == "def" then
      local n = parseMoney(v)
      if v == "" then -- nothing typed: nothing changes
      elseif not n then say("\"" .. v .. "\" is not an amount. Try 120000, 120k or 1.2m.", C.red)
      elseif id == "def" then setDefault(n)
      elseif V.sel then setSalary(V.sel, n) end
    elseif id == "add" then addPlayer(v) end
    drawWindow()
  elseif code == 1 then V.focus, V.input = nil, ""; drawWindow()             -- Esc
  elseif code == 15 then                                                     -- Tab
    if id == "amt" then V.amt = V.input; V.focus, V.input = "memo", V.memo
    elseif id == "memo" then V.memo = V.input; V.focus, V.input = "amt", V.amt end
    drawWindow()
  elseif code == 14 then V.input = unicode.sub(V.input, 1, -2); drawWindow()  -- Backspace
  elseif ch and ch >= 32 and ch < 127 then
    local c = string.char(ch)
    local ok
    if id == "amt" or id == "sal" or id == "def" then ok = c:match("[%d%.,kKmMbB%$]") and #V.input < 16
    elseif id == "memo" then ok = c:match("[%w %-_%.'!%?,:&#%(%)/%+]") and #V.input < 40
    else ok = c:match("[%w %-_%.']") and #V.input < 16 end
    if ok then V.input = V.input .. c; drawWindow() end
  end
end

local function tick()
  local up = computer.uptime()
  if V.seenDirty and up - V.lastSave >= 300 then saveData() end     -- "last seen" times
  if visible() and (V.redraw or up - V.lastDraw >= 5) then drawWindow() end
end

return {
  drawWindow = function() drawWindow() end,
  regions = function() return V.reg end,
  isOpen = function() return V.open end,
  open = function() V.open = true; activeApp = "gov" end,
  onGov = onGov, onBank = onBank, key = key, tick = tick, stats = stats, blur = blur,
  focus = function() return V.focus ~= nil end,
  defaultSalary = function() return D.def end,
  load = function() loadData() end,
  save = function() saveData() end,
  scroll = function(x, y, dir)
    if x < RX and y >= PY and y < PY + PROWS then V.pScroll = max(0, V.pScroll - dir); drawWindow()
    elseif x >= RX and y >= BY and y < BY + BROWS then V.bScroll = max(0, V.bScroll - dir * 3); drawWindow() end
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
  local st = GOVT.stats()
  parts[#parts + 1] = st.online .. " of " .. st.players .. " players online"
  if st.waiting > 0 then parts[#parts + 1] = st.waiting .. " bonus" .. (st.waiting == 1 and "" or "es") .. " waiting" end
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
local focus, input = nil, ""
local LOCK_MINS = { 0, 5, 10, 15, 30, 60, 120 }
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
  PLAYER_NAME = SETTINGS.userName or CONFIG.PLAYER_NAME or "Government"
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
  field("system", L + FX - 18, 9, 28, SETTINGS.systemName or "Lymanos Gov")
end

local function drawWindow()
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ Settings - " .. tostring(SETTINGS.systemName or "Lymanos Gov"), true)
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
  note(L, 11, LWd - 2, "Your name is shown on the lock screen. Players are listed")
  note(L, 12, LWd - 2, "in the Government app. Click a box, type, press Enter.")

  -- desktop & clock
  groupBox(L - 2, 15, LWd + 2, 8, "Desktop & Clock")
  label(L, 17, "Desktop color:")
  local dc = DESK_COLORS[SETTINGS.desk] or DESK_COLORS[1]
  cycler(L + FX - 18, 17, 14, dc[1], function(d)
    SETTINGS.desk = ((SETTINGS.desk or 1) - 1 + d) % #DESK_COLORS + 1
    K.desk = DESK_COLORS[SETTINGS.desk][2]
    changed()
  end)
  fill(L + FX + 2, 17, 6, 1, dc[2])
  label(L, 19, "Clock:")
  cycler(L + FX - 18, 19, 14, SETTINGS.clock24 and "24-hour" or "12-hour", function()
    SETTINGS.clock24 = not SETTINGS.clock24; changed()
  end)
  note(L, 21, LWd - 2, "Used on the taskbar, lock screen and Government app.")

  -- about
  groupBox(L - 2, 24, LWd + 2, 19, "About This Computer")
  local total, free = computer.totalMemory(), computer.freeMemory()
  local rows = {
    { "System:", tostring(SETTINGS.systemName or "Lymanos Gov") .. "  (Lymanos Gov 1.0)" },
    { "User:", tostring(PLAYER_NAME) },
    { "Memory:", string.format("%d K used of %d K", floor((total - free) / 1024), floor(total / 1024)) },
    { "Network card:", wlan.address:sub(1, 8) .. (wlan.isWireless() and " (wireless)" or " (wired)") },
    { "Settings file:", CONFIG.SETTINGS_FILE },
    { "Data file:", CONFIG.DATA_FILE },
    { "Ports:", CONFIG.GOV_PORT .. " (government)    " .. CONFIG.BANK_PORT .. " (bank roster)" },
  }
  for i, r in ipairs(rows) do
    label(L, 25 + i, r[1])
    textW(L + FX - 18, 25 + i, LWd - FX + 16, r[2], K.black, K.face)
  end
  note(L, 33, LWd - 2, "Settings save automatically. CONFIG at the top of")
  note(L, 34, LWd - 2, "lymanosgov.lua holds the defaults and advanced options.")
  button(regions, L, 38, 24, "Reset to defaults", function()
    dialog("Reset Settings", { "Put every setting back to its default?",
      "(Salaries and bonuses are not touched.)" }, {
      { "Yes", function()
          SETTINGS.userName, SETTINGS.systemName, SETTINGS.lockMins, SETTINGS.lockStyle = nil, "Lymanos Gov", 30, 1
          SETTINGS.clock24, SETTINGS.desk = false, 2
          K.desk = DESK_COLORS[2][2]
          PLAYER_NAME = CONFIG.PLAYER_NAME or "Government"
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
    SETTINGS.lockStyle = ((SETTINGS.lockStyle or 1) - 1 + d) % LOCK.styleCount + 1; changed()
  end)
  LOCK.preview(R + FX - 15, 11, 22, 5, SETTINGS.lockStyle)
  note(R, 17, RWd - 2, "Salaries and bonuses keep working while locked.")
  button(regions, R, 18, 20, "Lock Now", function() LOCK.lock() end)

  -- government (read only here)
  groupBox(R - 2, 23, RWd + 2, 20, "Government")
  local st = GOVT.stats()
  local grows = {
    { "Name shown:", tostring(CONFIG.GOV_NAME) },
    { "Default salary:", "$" .. commas(GOVT.defaultSalary()) .. " a year" },
    { "Players:", st.players .. " known, " .. st.online .. " online now" },
    { "Payroll:", "$" .. commas(st.payroll) .. " a year" },
    { "Bonuses waiting:", st.waiting .. "  ($" .. commas(st.waitSum) .. ")" },
    { "Bonuses paid:", "$" .. commas(st.paidSum) .. " (in the list)" },
  }
  for i, r in ipairs(grows) do
    label(R, 24 + i, r[1])
    textW(R + FX - 18, 24 + i, RWd - FX + 16, r[2], K.black, K.face)
  end
  note(R, 32, RWd - 2, "Salaries, the default salary and bonuses are changed")
  note(R, 33, RWd - 2, "in the Government app (Income tab). The name shown to")
  note(R, 34, RWd - 2, "players is GOV_NAME in CONFIG.")
  button(regions, R, 37, 24, "Open Government", function() GOVT.open(); drawAll() end)

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
      SETTINGS.systemName = (v ~= "") and v or "Lymanos Gov"
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
  if activeApp == "gov" then
    GOVT.drawWindow()
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
  if mw < W or mh < H then error("Lymanos Gov needs a tier 3 GPU and screen (160x50).", 0) end
  gpu.setResolution(W, H)
  GOVT.load()
  drawAll()
  pcall(wlan.broadcast, CONFIG.GOV_PORT, "GOV", "HELLO")     -- every Lymanos in range checks in now

  local lastTick = 0
  while running do
    gpu.flush()                        -- show this pass's drawing in one go
    local ev = { event.pull(0.5) }
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
      elseif activeApp == "gov" then
        local wasFocus = GOVT.blur()
        if not hit(GOVT.regions(), x, y) then hit(regions, x, y) end
        if wasFocus and not GOVT.focus() and activeApp == "gov" and not overlay then GOVT.drawWindow() end
      else
        hit(regions, x, y)
      end
    elseif name == "scroll" and not overlay and activeApp == "sys" then
      SYS.scroll(ev[3], ev[4], ev[5])
    elseif name == "scroll" and not overlay and activeApp == "gov" then
      GOVT.scroll(ev[3], ev[4], ev[5])
    elseif name == "modem_message" and ev[4] == CONFIG.GOV_PORT and ev[6] == "GOV" then
      pcall(GOVT.onGov, ev[3], ev[7], ev[8], ev[9])
    elseif name == "modem_message" and ev[4] == CONFIG.BANK_PORT and ev[6] == "BANK" then
      pcall(GOVT.onBank, ev[3], ev[7], ev[8])
    elseif name == "key_down" and activeApp == "gov" and GOVT.focus() and not overlay then
      GOVT.key(ev[3], ev[4])
    elseif name == "key_down" and activeApp == "settings" and SET.focus() and not overlay then
      SET.key(ev[3], ev[4])
    end

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
      pcall(GOVT.tick)
      -- lock after the idle time set in Settings (0 = never)
      local mins = SETTINGS.lockMins or 0
      if mins > 0 and not LOCK.isLocked() and LOCK.idle() >= mins * 60 then LOCK.lock() end
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
pcall(GOVT.save)                   -- "last seen" times (everything else is saved when it changes)
gpu.setResolution(oldW, oldH)
rgpu.setBackground(0x000000)
rgpu.setForeground(0xFFFFFF)
term.clear()
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write(tostring(err) .. "\n")
end
