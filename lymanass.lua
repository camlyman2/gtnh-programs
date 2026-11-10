--[[
  lymasm.lua  -  Lymanos Assembly (a stripped-down Lymanos for the Assembly Line computer)
  Version 2: ME Export Buses instead of one transposer per input bus.

  Apps:
    Assembly Line  feeds a GregTech Assembly Line with exact item counts per
                   input bus. AE2 still starts every craft; this program tells
                   an ME Export Bus under every input bus what to export.
                     Monitor  what is happening right now
                     Recipes  recipes you taught it by hand
                     Setup    which export bus belongs to which slice, devices
    My Computer    storage, memory, power and hardware details
    Settings       your name, system name, lock screen, desktop color

  How a craft runs:
    1. AE2 pushes one recipe's items into the INBOX chest (fluids keep going
       to the input hatches through your fluid storage buses, as before).
    2. The slice order and counts come from, in this order:
         - the data stick in the pattern (last ingredient), if this pack lets
           the computer read the recipe written on it
         - a recipe you taught on the Recipes tab
         - slot order: first stack = slice 1 (what the storage buses did)
    3. The main transposer moves exact counts into the OUTBOX chest, the only
       storage of the dispatch network. Each export bus is set to its item and
       can only export what is in the outbox - so every count is exact.
       Items used by one slice go together; an item used by several slices
       goes one slice at a time; slice 1 goes last.
    4. A data stick is put into slot 1 of the data access hatch before slice 1
       and taken out again after the line has started.
    5. When the first input bus is empty the line has taken the items, and the
       next recipe is sent - also while the line is still working.

  Build (per Assembly Line):
    - "holding" network = your present Assembly Line subnetwork (interface with
      advanced blocking card, fluid storage buses). Its only ITEM storage is
      one ME Storage Bus on the inbox chest.
    - "dispatch" network = a separate small AE2 network: one ME Export Bus
      under every input bus (acceleration cards make it faster) and one ME
      Storage Bus on the outbox chest. Nothing else stores items on it.
    - an Adapter touching the cable of every export bus; a Database Upgrade
      (tier 2) in any one of them
    - main Transposer: inbox chest below, outbox chest above
    - checker Transposer: touching the first input bus (any free face)
    - optional, for data sticks: an Automatable Data Access Hatch and an ME
      Interface of the main network, both touching the main transposer.
      Never put your own sticks in slot 1 of that hatch.
    - optional: an Adapter touching the Assembly Line controller (shows
      working / idle and warns when the line does not start)
  Then: Assembly Line > Setup > Detect devices, and Start mapping.

  Files written on this computer:
    /home/lymasm_data.dat       slice mapping, devices, taught recipes, log
    /home/lymasm_settings.dat   Settings app

  Needs: tier 3 GPU + tier 3 screen (160x50), mouse + keyboard. Every export
  bus, transposer and database is a component (slices + 3): more than about 8
  slices needs a server with a Component Bus. A network card is optional
  (status broadcast). Exit: Start > Shut Down or Ctrl+C.
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  DATA_FILE = "/home/lymasm_data.dat",
  SETTINGS_FILE = "/home/lymasm_settings.dat",   -- written by the Settings app

  POLL = 0.5,                  -- seconds between looks into the inbox chest
  PASS_DELAY = 3,              -- untaught items must sit unchanged this long before they are sent
  EXPORT_TIMEOUT = 15,         -- an export bus moves nothing for this long = error
  JAM_SECONDS = 20,            -- items in the buses + Assembly Line idle this long = warning
                               -- (only with an Adapter on the Assembly Line controller)
  MACHINE = nil,               -- nil = first gt_machine found, or the start of its address
  LOG_MAX = 40,                -- activity lines kept

  PLAYER_NAME = nil,           -- default name; normally set in the Settings app

  -- Status broadcast for other programs (only when a network card is installed).
  -- Message: "ASSLINE", serialized { state, recipe, made, recipes, slices, t }
  STATUS_PORT = 4046,          -- nil = do not broadcast
  STATUS_EVERY = 10,           -- seconds
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
  function gpu.flush()
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
            if bgc ~= rb then rgpu.setBackground(bgc); rb = bgc end
            if fgc and fgc ~= rf then rgpu.setForeground(fgc); rf = fgc end
            rgpu.set(x, y, table.concat(parts))
            x = x2
          else
            x = x + 1
          end
        end
      end
    end
  end
end

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
-- Optional: only used to broadcast the dispatcher's status.
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

local function fmtStamp(t)
  if not t then return "--" end
  local e = toEastern(t)
  local h, ap = h12(e)
  return string.format("%02d/%02d %2d:%02d:%02d %s", e.month, e.day, h, e.min, e.sec, ap)
end

local function fmtTray(t)
  if not clockOK then return "--:--" end
  local e = toEastern(t)
  if SETTINGS.clock24 then return string.format("%02d:%02d", e.hour, e.min) end
  local h, ap = h12(e)
  return string.format("%d:%02d %s", h, e.min, ap)
end

------------------------------------------------------------------- FILES
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
local activeApp = "asm"       -- window in front: "asm" | "sys" | "settings" | nil (desktop)
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
local openAsm, closeAsm, asmOpen                         -- forward (Assembly Line)
local openSysApp, closeSysApp, sysAppOpen                -- forward (My Computer)
local openSettings, closeSettings, settingsOpen          -- forward (Settings)
local AL, LOCK, SET                                      -- Assembly Line, lock screen, Settings (below)

local function drawDesktop()
  fill(1, 1, W, 46, K.desk)
  drawIcon(3, 2, "pc", "My Computer")
  region(regions, 1, 2, 12, 5, function() openSysApp(); drawAll() end)
  -- Assembly Line icon: parts riding a conveyor belt
  text(4, 8, "▄ ▄▄ ▄ ▄", 0xFFD060, K.desk)
  fill(4, 9, 8, 1, K.face)
  text(4, 9, "════════", K.sh, K.face)
  text(4, 10, "●  ●  ● ", K.black, K.desk)
  textW(1, 11, 12, "Assembly", K.white, K.desk, "center")
  textW(1, 12, 12, "Line", K.white, K.desk, "center")
  region(regions, 1, 8, 12, 5, function() openAsm(); drawAll() end)
  -- Settings icon: a little control panel with sliders
  fill(4, 15, 8, 3, K.face)
  text(4, 15, "─●──────", K.navy, K.face)
  text(4, 16, "────●───", K.navy, K.face)
  text(4, 17, "──────●─", K.navy, K.face)
  textW(1, 18, 12, "Settings", K.white, K.desk, "center")
  region(regions, 1, 15, 12, 4, function() openSettings(); drawAll() end)
  drawIcon(3, 43, "bin", "Recycle Bin")
end

----------------------------------------------------------------- TASKBAR

local function drawTray(t)
  bevel(144, 48, 16, 3, "sunken", K.face, K.face)
  text(146, 49, "●", AL and AL.trayColor() or K.sh, K.face)     -- dispatcher state
  textW(149, 49, 10, fmtTray(t), K.black, K.face, "right")
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
  if asmOpen and asmOpen() then
    list[#list + 1] = { (AL and AL.alert()) and " ▣ Assembly Line - CHECK!" or " ▣ Assembly Line", "asm" }
  end
  if sysAppOpen and sysAppOpen() then list[#list + 1] = { " ▣ My Computer", "sys" } end
  if settingsOpen and settingsOpen() then list[#list + 1] = { " ▣ Settings", "settings" } end
  local bw = min(28, floor(132 / max(1, #list)) - 1)
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
  dialog("About Lymanos Assembly", {
    tostring(SETTINGS.systemName or "Lymanos") .. "  -  Assembly (Lymanos 2.2, stripped down)",
    "Feeds a GregTech Assembly Line with exact item counts per",
    "input bus. AE2 starts the craft, this computer tells an ME",
    "export bus under every input bus what to send.",
    "",
    "Data file: " .. CONFIG.DATA_FILE,
  }, { { "OK" } })
end

local function confirmExit()
  dialog("Shut Down", { "Are you sure you want to close Lymanos?",
    "The Assembly Line stops getting items while it is closed." },
    { { "Yes", function() running = false end }, { "No" } })
end

openStartMenu = function()
  popupMenu(1, 47, {
    { "Assembly Line", function() openAsm() end },
    { "My Computer", function() openSysApp() end },
    { "Settings", function() openSettings() end },
    { "-" },
    { "Lock", function() LOCK.lock() end },
    { "About...", about },
    { "-" },
    { "Shut Down...", confirmExit },
  }, { banner = true, above = true, start = true })
end


------------------------------------------------------- ASSEMBLY LINE APP
-- AE2 drops a recipe's ingredients into the INBOX chest. One transposer moves
-- exact counts into the OUTBOX chest, which is the only storage of a small
-- "dispatch" AE2 network. Under every input bus sits an ME Export Bus of that
-- network; the program tells each bus which item to export (through an Adapter
-- and a Database Upgrade). A bus can only export what is in the outbox, so the
-- count per bus is exact.
--   * items used by one slice only are sent together (in parallel)
--   * an item used by several slices is sent one slice at a time
--   * slice 1 goes last, so the line cannot start half-filled
-- Own function = own local-variable budget.
AL = (function()
local PX0, PY0, PW, PH = 16, 7, 140, 36    -- tab panel (same as My Computer)
local X, XW = PX0 + 2, PW - 4              -- inside the panel
local AMBER, OKBG, BADBG, FIELD = 0xA06000, 0xC8F0C8, 0xFFB0B0, 0xFFFFC0
local SIDE = { [0] = "bottom", "top", "north", "south", "west", "east" }
local RROWS, MROWS = 19, 19                -- list rows: recipes, slice mapping
local FX, FY, FWID = X + 9, 36, 34         -- recipe name field
local tab = "monitor"                      -- "monitor" | "recipes" | "setup"
local reg = {}
local proxies = {}

-- saved in DATA_FILE
--   slices[i] = { addr = export bus component, side = the way the bus faces }
--   dev = { main, inbox, outbox, hatch, ret, check, checkSide, db, dbSize }
local D = { slices = {}, dev = {}, recipes = {}, log = {}, passThrough = true, made = 0 }
-- live
local S = { state = "idle", msg = "", paused = false, err = nil, buffer = {}, outbox = 0, cur = nil, since = 0,
            lastPoll = 0, sig = nil, sigAt = 0, busView = {}, mapping = false, sel = 1, rscroll = 0,
            msel = 1, focus = false, input = "", flash = nil, flashAt = 0, mach = nil, machText = nil,
            machActive = nil, lastCast = 0, dirty = true, dbKeys = {}, cfg = {}, perCall = 64,
            stickIn = false, fetch = false, cleaned = false, source = nil }

local function visible() return activeApp == "asm" and not overlay and not LOCK.isLocked() end
local function trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
local function flash(m) S.flash, S.flashAt = m, computer.uptime() end

local function save()
  local ok, s = pcall(serialization.serialize, D)
  if ok then writeFile(CONFIG.DATA_FILE, s) end
end

local function logLine(s, kind)
  local L = D.log
  L[#L + 1] = { t = now(), s = s, k = kind }
  while #L > (CONFIG.LOG_MAX or 40) do table.remove(L, 1) end
  S.dirty = true
end

local function load()
  local raw = readFile(CONFIG.DATA_FILE)
  if raw then
    local ok, t = pcall(serialization.unserialize, raw)
    if ok and type(t) == "table" then
      for k, v in pairs(t) do D[k] = v end
    end
  end
  if type(D.slices) ~= "table" then D.slices = {} end
  if type(D.dev) ~= "table" then D.dev = {} end
  if type(D.recipes) ~= "table" then D.recipes = {} end
  if type(D.log) ~= "table" then D.log = {} end
  D.made = tonumber(D.made) or 0
  if #D.slices == 0 then tab = "setup" end
end

-- components -------------------------------------------------------------------
local function px(addr)
  if not addr then return nil end
  local p = proxies[addr]
  if p == nil then
    local ok, v = pcall(component.proxy, addr)
    p = (ok and v) or false
    proxies[addr] = p
  end
  return p or nil
end

-- returns true, result...  or  false, reason
local function ccall(addr, method, ...)
  if not addr then return false, "not set up yet" end
  local p = px(addr)
  if not p then return false, "component " .. addr:sub(1, 8) .. " is not connected" end
  local ok, a, b = pcall(p[method], ...)
  if not ok then return false, tostring(a) end
  return true, a, b
end

local function ready(sl) return px(sl.addr) ~= nil end

-- name + damage + label: renamed copies ("Helper1") count as different items
local function keyOf(s)
  return tostring(s.name) .. "@" .. tostring(floor(tonumber(s.damage) or 0)) .. "@" .. tostring(s.label or "")
end

local function isStick(s)
  return s.label == "Data Stick" or
    (tostring(s.name):find("gt.metaitem.01", 1, true) ~= nil and floor(tonumber(s.damage) or 0) == 32708)
end

-- every stack in the inventory on one side of a transposer:
-- { slot, name, damage, label, size, key [, stick = the full stack table] }
local function readInv(addr, side)
  if side == nil then return nil, "side not set up yet" end
  local ok, it, why = ccall(addr, "getAllStacks", side)
  if not ok then return nil, it end
  if not it then return nil, tostring(why or "no inventory on the " .. tostring(SIDE[side]) .. " side") end
  -- number of slots: asked from the list itself, else from the inventory, so an
  -- empty slot can never be mistaken for the end of the list
  local n
  local okc, c = pcall(function() return it.count() end)
  if okc and type(c) == "number" then n = c end
  if not n then
    local oks, size = ccall(addr, "getInventorySize", side)
    n = (oks and tonumber(size)) or 0
  end
  local out = {}
  for i = 1, min(n, 512) do
    local ok2, s = pcall(it)
    if not ok2 then return nil, tostring(s) end
    if type(s) == "table" and s.name and s.name ~= "minecraft:air" and (tonumber(s.size) or 0) > 0 then
      out[#out + 1] = { slot = i, name = s.name, damage = floor(tonumber(s.damage) or 0),
                        label = tostring(s.label or s.name), size = floor(s.size), key = keyOf(s),
                        stick = isStick(s) and s or nil }
    end
  end
  return out, n
end

local function moved(ok, n, asked)
  if not ok then return 0 end
  if n == true then return asked end
  return floor(tonumber(n) or 0)
end

-- devices --------------------------------------------------------------------------
-- which way does the export bus next to this adapter face
local function detectBus(sl)
  for _, side in ipairs({ 1, 0, 2, 3, 4, 5 }) do
    local ok, a, b = ccall(sl.addr, "getExportConfiguration", side, 1)
    if ok and not (a == nil and type(b) == "string") then sl.side = side; sl.note = nil; return true end
  end
  sl.side = sl.side or 1
  sl.note = ready(sl) and "no export bus found next to the adapter" or "not connected"
  return false
end

local function isExportBus(addr, ctype)
  if ctype == "me_exportbus" then return true end
  if S.byMethod == nil then           -- only when this pack names the component differently
    S.byMethod = component.list("me_exportbus")() == nil
  end
  if not S.byMethod then return false end
  local ok, m = pcall(component.methods, addr)
  return ok and type(m) == "table" and m.setExportConfiguration ~= nil and m.exportIntoSlot ~= nil
end

local function listExportBuses()
  local out = {}
  S.byMethod = nil
  for addr, ctype in component.list() do
    if isExportBus(addr, ctype) then out[#out + 1] = addr end
  end
  table.sort(out)
  return out
end

-- does this inventory name belong to a GregTech block (bus, hatch, controller)?
-- Depending on the version the transposer reports the block name
-- ("gregtech:gt.blockmachines") or the inventory name ("hatch.input_bus.tier.00").
local function looksGT(name)
  name = name:lower()
  return name:find("blockmachines", 1, true) or name:find("gregtech", 1, true) or name:find("^gt%.")
    or name:find("hatch", 1, true) or name:find("input_bus", 1, true) or name:find("inputbus", 1, true)
end

-- what every transposer touches: { addr, sides = { [side] = { size, name, gt } }, gt = {sides}, other = {sides} }
local function survey()
  local list = {}
  for addr in component.list("transposer") do
    proxies[addr] = nil
    local t = { addr = addr, sides = {}, gt = {}, other = {} }
    for side = 0, 5 do
      local ok, n = ccall(addr, "getInventorySize", side)
      if ok and type(n) == "number" and n > 0 then
        local okn, name = ccall(addr, "getInventoryName", side)
        name = (okn and type(name) == "string") and name or "?"
        local gt = looksGT(name) and true or false
        t.sides[side] = { size = floor(n), name = name, gt = gt }
        if gt then t.gt[#t.gt + 1] = side else t.other[#t.other + 1] = side end
      end
    end
    list[#list + 1] = t
  end
  table.sort(list, function(a, b) return a.addr < b.addr end)
  return list
end

-- finds the two transposers and the database, and what touches them
local function detectDevices()
  local dev = {}
  S.dbKeys = {}
  local db = component.list("database")()
  if db then
    dev.db = db
    for _, n in ipairs({ 81, 25, 9 }) do
      if pcall(component.invoke, db, "get", n) then dev.dbSize = n; break end
    end
  end
  local list = survey()
  -- main transposer: best a chest straight below and above, else any two chests
  local main
  for _, t in ipairs(list) do
    local b, u = t.sides[0], t.sides[1]
    if b and u and not b.gt and not u.gt then main = t; break end
  end
  if not main then
    for _, t in ipairs(list) do if #t.other >= 2 then main = t; break end end
  end
  if main then
    dev.main = main.addr
    local other = {}
    for _, sd in ipairs(main.other) do other[#other + 1] = sd end
    local function take(want)
      for k, sd in ipairs(other) do if sd == want then table.remove(other, k); return sd end end
    end
    dev.inbox = take(0) or table.remove(other, 1)
    dev.outbox = take(1) or table.remove(other, 1)
    dev.hatch = main.gt[1]
    dev.ret = other[1]
  end
  -- checker: touches a GT block; else (name not recognised) the transposer that touches one inventory
  local check
  for _, t in ipairs(list) do if t ~= main and #t.gt >= 1 then check = t; break end end
  if not check then
    for _, t in ipairs(list) do
      if t ~= main and #t.gt + #t.other == 1 then check = t; break end
    end
  end
  if check then dev.check, dev.checkSide = check.addr, check.gt[1] or check.other[1] end
  D.dev = dev
  return list
end

-- what Detect devices saw, for the dialog
local function surveyLines(list)
  if #list == 0 then
    return { "No transposer is connected to this computer.", "",
      "- OC cable: plain cable, or the same color everywhere",
      "- server rack: the server's connector must go to the side the cable is on",
      "- in the shell, 'components transposer' must list them" }
  end
  local lines = {}
  for _, t in ipairs(list) do
    local role = (t.addr == D.dev.main) and "MAIN" or ((t.addr == D.dev.check) and "CHECKER" or "not used")
    lines[#lines + 1] = "Transposer " .. t.addr:sub(1, 8) .. "  ->  " .. role
    local any = false
    for side = 0, 5 do
      local v = t.sides[side]
      if v and #lines < 34 then
        any = true
        lines[#lines + 1] = "    " .. SIDE[side] .. ": " .. unicode.sub(v.name, 1, 70) .. "  (" .. v.size .. " slots)" ..
          (v.gt and "  = GregTech" or "")
      end
    end
    if not any then lines[#lines + 1] = "    touches no inventory" end
  end
  return lines
end

local function devProblem()
  local d = D.dev
  if not d.main then return "No main transposer found (it touches the inbox chest and the outbox chest). Setup > Detect devices." end
  if not px(d.main) then return "The main transposer is not connected." end
  if d.inbox == nil or d.outbox == nil then return "The main transposer needs an inbox chest and an outbox chest." end
  if not d.check then return "No checker transposer found (it touches the first input bus). Setup > Detect devices." end
  if not px(d.check) then return "The checker transposer is not connected." end
  if not d.db or not px(d.db) then return "No Database Upgrade found (put one in any of the adapters)." end
end

-- items in the first input bus (its programmed-circuit slot is not an ingredient)
local function firstBusCount()
  local stacks, why = readInv(D.dev.check, D.dev.checkSide)
  if not stacks then return nil, why end
  local n = 0
  for _, st in ipairs(stacks) do
    if not st.name:find("integrated_circuit", 1, true) then n = n + st.size end
  end
  return n
end

local function clearBus(i)
  local sl = D.slices[i]
  S.cfg[i] = nil
  if sl then return ccall(sl.addr, "setExportConfiguration", sl.side, 1) end
end

local function clearAllBuses()
  for i = 1, #D.slices do clearBus(i) end
end

-- everything that is still in the outbox goes back to the inbox
local function outboxBack()
  local d = D.dev
  local stacks = readInv(d.main, d.outbox) or {}
  local n = 0
  for _, st in ipairs(stacks) do
    n = n + moved(ccall(d.main, "transferItem", d.outbox, d.inbox, st.size, st.slot))
  end
  return n
end

-- recipes ----------------------------------------------------------------------
local function totals(stacks)
  local tot, n = {}, 0
  for _, st in ipairs(stacks) do
    if not tot[st.key] then tot[st.key] = 0; n = n + 1 end
    tot[st.key] = tot[st.key] + st.size
  end
  return tot, n
end

-- does the buffer hold exactly a whole number of sets of this plan?
local function setsOf(plan, tot, nKeys)
  local need, nNeed = {}, 0
  for _, s in ipairs(plan) do
    if not need[s.key] then need[s.key] = 0; nNeed = nNeed + 1 end
    need[s.key] = need[s.key] + s.count
  end
  if nNeed ~= nKeys then return nil end
  local sets
  for key, n in pairs(need) do
    local have = tot[key]
    if not have or have % n ~= 0 or (sets and have / n ~= sets) then return nil end
    sets = have / n
  end
  return (sets and sets >= 1) and sets or nil
end

-- a taught recipe whose ingredients are what the buffer holds. Returns recipe, index, sets.
local function matchRecipe(tot, nKeys)
  for idx, r in ipairs(D.recipes) do
    local sets = setsOf(r.slices, tot, nKeys)
    if sets then return r, idx, sets end
  end
end

-- the recipe written on a data stick, if this pack lets the computer read it:
-- { { label, count }, ... } in slice order, matched to the items in the buffer
local function stickPlan(stick, items)
  local list = type(stick) == "table" and stick.inputItems
  if type(list) ~= "table" then return nil end
  local idx = {}
  for k in pairs(list) do
    local n = tonumber(k)
    if not n then return nil end
    idx[#idx + 1] = { n, k }
  end
  table.sort(idx, function(a, b) return a[1] < b[1] end)
  local byLabel = {}
  for _, st in ipairs(items) do
    if byLabel[st.label] and byLabel[st.label] ~= st.key then return nil end   -- two items, one name
    byLabel[st.label] = st.key
  end
  local plan = {}
  for _, e in ipairs(idx) do
    local v = list[e[2]]
    if type(v) ~= "table" then return nil end
    local label = v[1] or v.label or v.name or v.displayName
    local count = tonumber(v[2] or v.count or v.size or v.amount or v.stackSize)
    if type(label) ~= "string" or not count or count < 1 or not byLabel[label] then return nil end
    plan[#plan + 1] = { key = byLabel[label], label = label, count = floor(count) }
  end
  if #plan == 0 then return nil end
  local tot, nKeys = totals(items)
  if not setsOf(plan, tot, nKeys) then return nil end
  return plan
end

local function signature(stacks)
  local t = {}
  for i, st in ipairs(stacks) do t[i] = st.slot .. ":" .. st.key .. ":" .. st.size end
  return table.concat(t, "|")
end

-- status -------------------------------------------------------------------------
local function machine()
  if S.mach == nil then
    local found
    for a in component.list("gt_machine") do
      if not CONFIG.MACHINE or a:sub(1, #CONFIG.MACHINE) == CONFIG.MACHINE then found = a; break end
    end
    S.mach = (found and component.proxy(found)) or false
  end
  return S.mach or nil
end

local function readMachine()
  local m = machine()
  S.machText, S.machActive = nil, nil
  if not m then return end
  local ok, act = pcall(m.isMachineActive)
  if not ok then S.mach = nil; return end
  S.machActive = act and true or false
  if not act then S.machText = "idle"; return end
  local ok1, p = pcall(m.getWorkProgress)
  local ok2, mx = pcall(m.getWorkMaxProgress)
  p, mx = ok1 and tonumber(p) or nil, ok2 and tonumber(mx) or nil
  if p and mx and mx > 0 then
    S.machText = string.format("working  %d%%  (%s of %s)", floor(p / mx * 100 + 0.5), fmtDurLong(p / 20), fmtDurLong(mx / 20))
  else
    S.machText = "working"
  end
end

-- name, color, detail
local function stateInfo()
  local up = computer.uptime()
  if S.err then return "ERROR", K.red, S.err end
  if S.mapping then return "MAPPING", K.navy, "Nothing is sent while you map the export buses (Setup tab)." end
  if #D.slices == 0 then return "NOT SET UP", K.red, "Open the Setup tab and map the export buses." end
  if S.paused then return "PAUSED", AMBER, "Nothing is sent to the Assembly Line until you press Resume." end
  if S.state == "dispatching" then return "SENDING", K.navy, S.msg end
  if S.state == "waiting" then
    if S.cur then
      local d = "Sent " .. S.cur.title .. ". Waiting for the Assembly Line to take the items (" .. fmtDurLong(up - S.since) .. ")."
      if S.machActive == false and up - S.since > (CONFIG.JAM_SECONDS or 20) then
        return "NOT STARTING", K.red, "Sent " .. S.cur.title .. " " .. fmtDurLong(up - S.since) ..
          " ago but the Assembly Line is idle - check fluids, data stick and slice order."
      end
      return "WAITING", AMBER, d
    end
    return "WAITING", AMBER, S.msg
  end
  if S.state == "hold" then return "HOLD", K.red, S.msg end
  if S.state == "offline" then return "OFFLINE", K.red, S.msg end
  if S.state == "receiving" then return "RECEIVING", K.navy, S.msg end
  return "IDLE", K.green, "Waiting for ingredients from AE2."
end

local function setState(st, msg)
  if S.state ~= st or S.msg ~= msg then S.state, S.msg, S.dirty = st, msg or "", true end
end

local function fail(msg)
  S.err, S.paused, S.cur = msg, true, nil
  S.state, S.dirty, S.redraw = "idle", true, true
  logLine(msg, "bad")
end

-- dispatch --------------------------------------------------------------------------
local drawStatusBox, drawSlices      -- forward (progress while sending)

local function progress()
  if visible() and tab == "monitor" then
    drawStatusBox(false); drawSlices(false); gpu.flush()
  end
end

-- remember the item of slice i in database entry i (the export bus is set from it)
local function prepare(i, inv, need)
  if S.dbKeys[i] == need.key then return true end
  for _, st in ipairs(inv) do
    if st.key == need.key and st.size > 0 then
      local ok, a, b = ccall(D.dev.main, "store", D.dev.inbox, st.slot, D.dev.db, i)
      if not ok then return false, a end
      if a == nil and b then return false, tostring(b) end
      S.dbKeys[i] = need.key
      return true
    end
  end
  return false, tostring(need.label) .. " is not in the inbox"
end

-- exactly need.count of the item: inbox -> outbox
local function feed(inv, need)
  local d = D.dev
  local left = need.count
  for _, st in ipairs(inv) do
    if left <= 0 then break end
    if st.key == need.key and st.size > 0 then
      local n = min(left, st.size)
      local got = moved(ccall(d.main, "transferItem", d.inbox, d.outbox, n, st.slot))
      st.size, left = st.size - got, left - got
      if got < n then break end
    end
  end
  if left > 0 then return false, "could not move " .. need.count .. " x " .. tostring(need.label) .. " to the outbox (" .. left .. " short)" end
  return true
end

local function setBus(i)
  local sl = D.slices[i]
  local ok, a, b = ccall(sl.addr, "setExportConfiguration", sl.side, 1, D.dev.db, i)
  if not ok then return false, a end
  if a == false or (a == nil and b) then return false, tostring(b or "the export bus refused the setting") end
  S.cfg[i] = true
  return true
end

-- make the buses of this step export until their items have left the outbox.
-- A bus can only export what is in the outbox, so the count is exact.
local function drain(step, plan)
  local rem = {}
  for _, i in ipairs(step) do rem[i] = plan[i].count end
  local lastMove = computer.uptime()
  while true do
    local did = {}
    for _, i in ipairs(step) do
      if rem[i] > 0 then
        local sl = D.slices[i]
        local n = max(1, min(64, ceil(rem[i] / S.perCall)))
        for _ = 1, n do
          local ok, why = ccall(sl.addr, "exportIntoSlot", sl.side, 1)
          if not ok then return false, "Slice " .. i .. ": " .. tostring(why) end
        end
        did[i] = n
      end
    end
    local stacks, why = readInv(D.dev.main, D.dev.outbox)
    if not stacks then return false, why end
    S.outbox = #stacks
    local tot = totals(stacks)
    local open, stuck, any = 0, nil, false
    for _, i in ipairs(step) do
      if rem[i] > 0 then
        local left = tot[plan[i].key] or 0
        local went = rem[i] - left
        if went > 0 then
          any = true
          -- how many items one export moves (depends on the acceleration cards)
          if left > 0 then S.perCall = max(1, min(S.perCall, floor(went / did[i]))) end
        end
        rem[i] = left
        if left > 0 then open = open + 1; stuck = stuck or i end
      end
    end
    if open == 0 then return true end
    local up = computer.uptime()
    if any then lastMove = up
    elseif up - lastMove > (CONFIG.EXPORT_TIMEOUT or 15) then
      return false, "Slice " .. stuck .. ": the input bus does not take " .. tostring(plan[stuck].label) ..
        " (" .. rem[stuck] .. " left in the outbox)", rem
    else
      os.sleep(0.25)
    end
  end
end

-- plan[i] = { key, label, count } per slice. A slice with left = 0 is already in
-- its bus (a dispatch that was interrupted and is being finished).
local function dispatch(plan, title, recipe, stick, source)
  local d = D.dev
  S.state, S.msg, S.sig, S.perCall = "dispatching", "Sending " .. title .. "...", nil, 64
  if not S.resume then S.busView = {} end
  S.resume = nil
  local inv = readInv(d.main, d.inbox)
  if not inv then fail("Cannot read the inbox chest."); return false end
  local todo = {}                       -- what each slice still needs
  for i = 1, #plan do todo[i] = { key = plan[i].key, label = plan[i].label, count = plan[i].left or plan[i].count } end

  -- steps: [items of one slice only, together] [shared items, slice by slice] [slice 1]
  local uses = {}
  for i = 1, #todo do if todo[i].count > 0 then uses[todo[i].key] = (uses[todo[i].key] or 0) + 1 end end
  local steps, batch = {}, {}
  for i = 2, #todo do if todo[i].count > 0 and uses[todo[i].key] == 1 then batch[#batch + 1] = i end end
  if #batch > 0 then steps[1] = batch end
  for i = 2, #todo do if todo[i].count > 0 and uses[todo[i].key] > 1 then steps[#steps + 1] = { i } end end
  if todo[1].count > 0 then steps[#steps + 1] = { 1, last = true } end

  local function giveUp(why, rem)
    clearAllBuses()
    local back = outboxBack()
    if rem then for i, n in pairs(rem) do todo[i].count = n end end
    local open, keep = 0, {}
    for i = 1, #plan do
      keep[i] = { key = plan[i].key, label = plan[i].label, count = plan[i].count, left = todo[i].count }
      if todo[i].count > 0 then open = open + 1 end
    end
    -- Resume finishes exactly this recipe: the slices that are already in their buses stay there
    S.resume = { plan = keep, title = title, recipe = recipe, source = source }
    fail(tostring(why) .. ". " .. (#plan - open) .. " of " .. #plan .. " slices are in the input buses, " ..
      back .. " item(s) went back to the inbox. Fix it, then Resume sends the rest.")
    return false
  end

  for _, step in ipairs(steps) do
    if step.last and stick then            -- the data stick goes in just before slice 1
      local n
      if d.hatch ~= nil and d.ret ~= nil then
        n = moved(ccall(d.main, "transferItem", d.inbox, d.hatch, 1, stick.slot, 1))
        if n == 1 then S.stickIn = true end
      else
        n = moved(ccall(d.main, "transferItem", d.inbox, d.ret, 1, stick.slot))
      end
      if n ~= 1 then return giveUp("The data stick could not be moved out of the inbox (hatch moved or full? Setup > Detect devices)") end
    end
    for _, i in ipairs(step) do
      local ok, why = prepare(i, inv, todo[i])
      if ok then ok, why = feed(inv, todo[i]) end
      if ok then ok, why = setBus(i) end
      if not ok then return giveUp("Slice " .. i .. ": " .. tostring(why)) end
    end
    progress()
    local ok, why, rem = drain(step, todo)
    if not ok then return giveUp(why, rem) end
    for _, i in ipairs(step) do
      clearBus(i)
      todo[i].count = 0
      S.busView[i] = { label = plan[i].label, count = plan[i].count }
    end
  end
  S.state, S.since, S.dirty, S.source = "waiting", computer.uptime(), true, source
  S.cur = { title = title, n = #plan, r = recipe, stick = S.stickIn }
  logLine("Sent " .. title .. " (" .. #plan .. " slices, " .. source .. ")")
  return true
end

local function finish()
  D.made = (D.made or 0) + 1
  local r = S.cur.r
  if r then r.made = (r.made or 0) + 1; r.last = now() end
  if S.cur.stick then S.fetch = true end
  logLine("Assembly Line took " .. S.cur.title, "good")
  S.cur = nil
  save()
end

-- take the used data stick out of the hatch (not possible while the line is working)
local function tryFetch()
  local d = D.dev
  if d.hatch == nil or d.ret == nil then S.fetch, S.stickIn = false, false; return true end
  local n = moved(ccall(d.main, "transferItem", d.hatch, d.ret, 1, 1))
  if n >= 1 then
    S.fetch, S.stickIn = false, false
    logLine("Data stick taken out of the hatch")
    return true
  end
  return false
end

local function broadcast()
  if not wlan or not CONFIG.STATUS_PORT then return end
  local up = computer.uptime()
  if up - S.lastCast < (CONFIG.STATUS_EVERY or 10) then return end
  S.lastCast = up
  local name = stateInfo()
  pcall(wlan.broadcast, CONFIG.STATUS_PORT, "ASSLINE", serialization.serialize({
    state = name, recipe = S.cur and S.cur.title or nil, made = D.made, recipes = #D.recipes,
    slices = #D.slices, t = now() }))
end

-- the dispatcher: called from the main loop
local function poll()
  local up = computer.uptime()
  if up - S.lastPoll < (CONFIG.POLL or 0.5) then return end
  S.lastPoll = up
  if S.mapping or #D.slices == 0 then return end
  local d = D.dev
  local problem = devProblem()
  if problem and up - (S.lastDetect or -99) >= 10 then      -- look again by itself
    S.lastDetect = up
    detectDevices()
    problem = devProblem()
    if not problem then save(); logLine("Devices found") end
  end
  if problem then setState("offline", problem); return end
  local stacks, why = readInv(d.main, d.inbox)
  if not stacks then
    setState("offline", "Cannot read the inbox chest: " .. tostring(why))
    return
  end
  local sig = signature(stacks)
  if sig ~= S.sig then S.sig, S.sigAt, S.dirty = sig, up, true end
  S.buffer = stacks
  if S.paused then return end
  if S.state == "offline" then setState(S.cur and "waiting" or "idle") end

  if not S.cleaned then         -- after a restart no bus may still export something old
    clearAllBuses()
    S.cleaned = true
  end

  local checked = false
  if S.state == "waiting" then
    local n, why2 = firstBusCount()               -- the line takes every bus at once
    if n == nil then setState("offline", "Cannot read the first input bus: " .. tostring(why2)); return end
    if n > 0 then return end
    if S.cur then finish() end
    S.busView = {}
    setState("idle")
    checked = true
  end
  if S.fetch then tryFetch() end

  if #stacks == 0 then setState("idle"); return end

  local items, stick = {}, nil
  for _, st in ipairs(stacks) do
    if st.stick then stick = stick or st else items[#items + 1] = st end
  end
  if stick and d.ret == nil then
    setState("hold", "The inbox holds a data stick but the main transposer has no return inventory (an ME interface).")
    return
  end
  if #items == 0 then           -- a stray data stick: hand it back
    ccall(d.main, "transferItem", d.inbox, d.ret, 1, stick.slot)
    return
  end

  -- where the slice order and counts come from: data stick > taught recipe > slot order
  local tot, nKeys = totals(items)
  local plan, title, recipe, source
  if S.resume then              -- finish the recipe that was interrupted
    local rest = {}
    for _, p in ipairs(S.resume.plan) do
      if p.left > 0 then rest[#rest + 1] = { key = p.key, count = p.left } end
    end
    if setsOf(rest, tot, nKeys) ~= 1 then
      setState("hold", "The inbox no longer matches the interrupted recipe. Empty the input buses and the inbox by hand, then press 'Clear outbox'.")
      return
    end
    local out = readInv(d.main, d.outbox)
    if not out or #out > 0 then setState("hold", "The outbox chest is not empty. Press 'Clear outbox'."); return end
    local r = S.resume
    dispatch(r.plan, r.title, r.recipe, stick, r.source)
    return
  end
  if stick then
    plan = stickPlan(stick.stick, items)
    if plan then
      local out = stick.stick.output
      title = (type(out) == "string" and out ~= "") and out or "data stick recipe"
      source = "data stick"
    end
  end
  if not plan then
    recipe = matchRecipe(tot, nKeys)
    if recipe then plan, title, source = recipe.slices, recipe.name, "taught" end
  end
  if not plan then
    if not D.passThrough then
      setState("hold", "Items in the inbox match no taught recipe. Teach it on the Recipes tab (or allow slot order in Setup).")
      return
    end
    if up - S.sigAt < (CONFIG.PASS_DELAY or 3) then
      setState("receiving", "New items in the inbox (no data stick or taught recipe) - sending in slot order shortly...")
      return
    end
    plan = {}
    for i, st in ipairs(items) do plan[i] = { key = st.key, count = st.size, label = st.label } end
    title, source = "untaught recipe", "slot order"
  end
  if #plan > #D.slices then
    setState("hold", "'" .. title .. "' needs " .. #plan .. " slices but only " .. #D.slices .. " export buses are mapped.")
    return
  end
  if #plan > (d.dbSize or 9) then
    setState("hold", "'" .. title .. "' needs " .. #plan .. " database entries: use a tier 2 Database Upgrade (25 entries).")
    return
  end

  local out = readInv(d.main, d.outbox)
  if not out then setState("offline", "Cannot read the outbox chest."); return end
  S.outbox = #out
  if #out > 0 then
    setState("hold", "The outbox chest is not empty. Press 'Clear outbox' (top of this window) to put its items back.")
    return
  end
  if not checked then
    local n, why2 = firstBusCount()
    if n == nil then setState("offline", "Cannot read the first input bus: " .. tostring(why2)); return end
    if n > 0 then
      S.cur = nil
      setState("waiting", "The input buses still hold items - waiting for the Assembly Line to take them.")
      return
    end
  end
  if stick and d.hatch ~= nil then              -- hatch slot 1 must be free for the new stick
    local ok, n = ccall(d.main, "getSlotStackSize", d.hatch, 1)
    if ok and (tonumber(n) or 0) > 0 and not tryFetch() then
      setState("waiting", "Waiting for the data access hatch to release the previous data stick.")
      S.cur = nil
      return
    end
  end
  dispatch(plan, title, recipe, stick, source)
end

-- drawing helpers -------------------------------------------------------------------
local function clock(t)
  if not t or t < 1e9 then return "--" end
  local e = toEastern(t)
  if SETTINGS.clock24 then return string.format("%02d:%02d:%02d", e.hour, e.min, e.sec) end
  local h, ap = h12(e)
  return string.format("%2d:%02d:%02d %s", h, e.min, e.sec, ap)
end

local function stamp(t)
  if not t or t < 1e9 then return "--" end
  local e = toEastern(t)
  local h, ap = h12(e)
  return string.format("%02d/%02d %2d:%02d %s", e.month, e.day, h, e.min, ap)
end

local function cycler(x, y, w, value, onStep)
  text(x, y, " ◄ ", K.black, 0xD4D0C8)
  textW(x + 3, y, w, value, K.navy, K.white, "center")
  text(x + 3 + w, y, " ► ", K.black, 0xD4D0C8)
  region(reg, x, y, 3, 1, function() onStep(-1) end)
  region(reg, x + 3 + w, y, 3, 1, function() onStep(1) end)
end

-- Monitor tab ------------------------------------------------------------------------
drawStatusBox = function(full)
  local y = PY0 + 1
  if full then groupBox(X, y, XW, 6, "Dispatcher") end
  local name, col, detail = stateInfo()
  detail = tostring(detail or "")
  local dw = XW - 19
  textW(X + 2, y + 1, 15, "● " .. name, col, K.face)
  textW(X + 17, y + 1, dw, unicode.sub(detail, 1, dw), K.black, K.face)
  if unicode.len(detail) > dw then          -- a long message continues on the next line
    textW(X + 2, y + 2, 15, "", K.black, K.face)
    textW(X + 17, y + 2, dw, unicode.sub(detail, dw + 1, 2 * dw), K.black, K.face)
  else
    textW(X + 2, y + 2, XW - 4, "Assembly Line: " .. (S.machText or
      "status unknown (optional: an Adapter touching the controller shows it here)"), K.sh, K.face)
  end
  textW(X + 2, y + 3, XW - 4, "Crafts done: " .. commas(D.made or 0) .. "      Taught recipes: " .. #D.recipes ..
    "      Slices mapped: " .. #D.slices .. "      Untaught recipes: " ..
    (D.passThrough and "sent in slot order" or "held"), K.black, K.face)
  local hatch = (D.dev.hatch == nil or D.dev.ret == nil) and "not automated" or (S.stickIn and "stick in the hatch" or "hatch slot 1 free")
  textW(X + 2, y + 4, XW - 4, "Last recipe read from: " .. (S.source or "-") .. "      Outbox: " .. S.outbox ..
    " stack(s)      Data sticks: " .. hatch .. "      Slice 1 is always sent last.", K.sh, K.face)
end

drawSlices = function(full)
  local y = PY0 + 7
  if full then groupBox(X, y, XW, 10, "Input buses   (slice 1 = controller end)") end
  local n = #D.slices
  if n == 0 then
    textW(X + 2, y + 4, XW - 4, "No slices mapped yet - open the Setup tab.", K.sh, K.face)
    return
  end
  local cw = max(6, min(16, floor((XW - 4) / n)))
  n = min(n, floor((XW - 4) / cw))
  for i = 1, n do
    local x = X + 2 + (i - 1) * cw
    local w = cw - 1
    local sl, v = D.slices[i], S.busView[i]
    local ok = ready(sl)
    local b = (not ok) and BADBG or (v and OKBG or K.white)
    textW(x, y + 2, w, tostring(i), K.white, ok and K.navy or K.red, "center")
    if not ok then
      textW(x, y + 3, w, "", K.black, b); textW(x, y + 4, w, "?", K.red, b, "center")
      textW(x, y + 5, w, "", K.black, b); textW(x, y + 6, w, "", K.black, b); textW(x, y + 7, w, "", K.black, b)
    elseif v then
      local lab = tostring(v.label)
      for r = 0, 2 do textW(x, y + 3 + r, w, unicode.sub(lab, r * w + 1, (r + 1) * w), K.black, b) end
      textW(x, y + 6, w, "", K.black, b)
      textW(x, y + 7, w, "x" .. v.count, K.navy, b, "center")
    else
      textW(x, y + 3, w, "", K.black, b); textW(x, y + 4, w, "", K.black, b)
      textW(x, y + 5, w, "empty", K.sh, b, "center")
      textW(x, y + 6, w, "", K.black, b); textW(x, y + 7, w, "", K.black, b)
    end
  end
end

local function drawBuffer(full)
  local y, w = PY0 + 17, 66
  if full then
    groupBox(X, y, w, 18, "Inbox chest")
    textW(X + 2, y + 1, 5, "Slot", K.sh, K.face)
    textW(X + 8, y + 1, 46, "Item", K.sh, K.face)
    textW(X + 55, y + 1, 8, "Count", K.sh, K.face, "right")
  end
  local list = S.buffer
  for r = 1, 15 do
    local st = list[r]
    local yy = y + 1 + r
    if r == 15 and #list > 15 then
      textW(X + 2, yy, w - 4, "+ " .. (#list - 14) .. " more stacks", K.sh, K.face)
    elseif st then
      textW(X + 2, yy, 5, tostring(st.slot), K.black, K.face, "right")
      textW(X + 8, yy, 46, st.label, st.stick and K.navy or K.black, K.face)
      textW(X + 55, yy, 8, tostring(st.size), K.black, K.face, "right")
    else
      textW(X + 2, yy, w - 4, (r == 1) and "(empty)" or "", K.sh, K.face)
    end
  end
end

local function drawActivity(full)
  local x, y, w = X + 67, PY0 + 17, XW - 67
  if full then groupBox(x, y, w, 18, "Activity") end
  local L = D.log
  for r = 1, 16 do
    local e = L[#L - r + 1]
    local yy = y + r
    if e then
      textW(x + 2, yy, 12, clock(e.t), K.sh, K.face)
      textW(x + 14, yy, w - 16, tostring(e.s), e.k == "bad" and K.red or (e.k == "good" and K.green or K.black), K.face)
    else
      textW(x + 2, yy, w - 4, (r == 1) and "(nothing yet)" or "", K.sh, K.face)
    end
  end
end

local function drawMonitor(full)
  drawStatusBox(full); drawSlices(full); drawBuffer(full); drawActivity(full)
end

-- Recipes tab ------------------------------------------------------------------------
local function drawRecipeRows()
  local x, y = X, PY0 + 1
  S.rscroll = max(0, min(S.rscroll, max(0, #D.recipes - RROWS)))
  S.sel = max(1, min(S.sel, max(1, #D.recipes)))
  for r = 1, RROWS do
    local i = S.rscroll + r
    local rc = D.recipes[i]
    local yy = y + 1 + r
    local sel = (i == S.sel)
    local b, f = sel and K.navy or K.white, sel and K.white or K.black
    if rc then
      textW(x + 1, yy, 31, " " .. tostring(rc.name), f, b)
      textW(x + 32, yy, 7, tostring(#rc.slices), f, b, "right")
      textW(x + 39, yy, 8, commas(rc.made or 0), f, b, "right")
      textW(x + 47, yy, 16, "  " .. (rc.last and stamp(rc.last) or "never"), f, b)
    else
      textW(x + 1, yy, 62, (i == 1) and " (no recipes taught yet)" or "", K.sh, K.white)
    end
  end
end

local function drawRecipeDetail()
  local x, y, w = X + 66, PY0 + 1, XW - 66
  groupBox(x, y, w, 22, "Recipe details")
  local rc = D.recipes[S.sel]
  if not rc then
    textW(x + 2, y + 2, w - 4, "Select a recipe on the left.", K.sh, K.face)
    return
  end
  textW(x + 2, y + 1, w - 4, tostring(rc.name), K.navy, K.face)
  textW(x + 2, y + 2, w - 4, #rc.slices .. " slices   sent " .. commas(rc.made or 0) .. " times", K.sh, K.face)
  for i = 1, min(#rc.slices, 17) do
    local s = rc.slices[i]
    textW(x + 2, y + 2 + i, 4, i .. ".", K.sh, K.face, "right")
    textW(x + 7, y + 2 + i, w - 18, tostring(s.label), K.black, K.face)
    textW(x + w - 10, y + 2 + i, 8, "x " .. s.count, K.black, K.face, "right")
  end
end

local function drawField()
  if S.focus then
    textW(FX, FY, FWID, " " .. S.input .. "_", K.black, FIELD)
  else
    textW(FX, FY, FWID, " " .. (S.input ~= "" and S.input or "(click, then type a name)"),
      S.input ~= "" and K.navy or K.sh, K.white)
  end
end

local function learn()
  if not S.paused then
    dialog("Teach a Recipe", { "Press Pause first (top of this window).",
      "Otherwise the items you put in the inbox are sent to the",
      "Assembly Line before you can press Learn." }, { { "OK" } })
    return
  end
  local all, why = readInv(D.dev.main, D.dev.inbox)
  if not all then
    dialog("Teach a Recipe", { "Cannot read the inbox chest:", tostring(why) }, { { "OK" } })
    return
  end
  local stacks = {}
  for _, st in ipairs(all) do if not st.stick then stacks[#stacks + 1] = st end end
  if #stacks == 0 then
    dialog("Teach a Recipe", { "The inbox chest is empty.", "",
      "Put the ingredients in the inbox chest: one stack per slice,",
      "in NEI order, the first slice in the first slot." }, { { "OK" } })
    return
  end
  if #stacks > #D.slices then
    dialog("Teach a Recipe", { "The inbox holds " .. #stacks .. " stacks but only " .. #D.slices .. " slices are mapped." }, { { "OK" } })
    return
  end
  local slices = {}
  for i, st in ipairs(stacks) do
    slices[i] = { key = st.key, name = st.name, damage = st.damage, label = st.label, count = st.size }
  end
  local name = trim(S.input)
  local tot, nKeys = totals(stacks)
  local old, oldIdx, sets = matchRecipe(tot, nKeys)
  S.input, S.focus = "", false
  if old and sets == 1 then            -- same ingredients: replace the old order
    old.slices = slices
    if name ~= "" then old.name = name end
    S.sel = oldIdx
    flash("Updated '" .. old.name .. "' (" .. #slices .. " slices)")
    logLine("Recipe updated: " .. old.name)
  else
    if name == "" then name = "Recipe " .. (#D.recipes + 1) end
    D.recipes[#D.recipes + 1] = { name = name, slices = slices, made = 0 }
    S.sel = #D.recipes
    S.rscroll = max(0, #D.recipes - RROWS)
    flash("Learned '" .. name .. "' (" .. #slices .. " slices)")
    logLine("Recipe learned: " .. name)
  end
  save()
  drawAll()
end

local function renameSel()
  local rc = D.recipes[S.sel]
  local name = trim(S.input)
  if not rc then flash("Select a recipe first")
  elseif name == "" then flash("Type the new name in the Name box first")
  else
    rc.name = name
    S.input, S.focus = "", false
    save(); flash("Renamed to '" .. name .. "'")
  end
  drawAll()
end

local function deleteSel()
  local rc = D.recipes[S.sel]
  if not rc then flash("Select a recipe first"); drawAll(); return end
  dialog("Delete Recipe", { "Delete '" .. tostring(rc.name) .. "'?",
    "Its items will then be sent in slot order again." }, {
    { "Yes", function()
        for i, v in ipairs(D.recipes) do if v == rc then table.remove(D.recipes, i); break end end
        if S.cur and S.cur.r == rc then S.cur.r = nil end
        save(); flash("Recipe deleted")
      end },
    { "No" } })
end

local function drawRecipes(full)
  local x, y = X, PY0 + 1
  if full then
    bevel(x, y, 64, RROWS + 3, "sunken", K.face, K.white)
    textW(x + 1, y + 1, 31, " Name", K.black, K.face)
    textW(x + 32, y + 1, 7, "Slices", K.black, K.face, "right")
    textW(x + 39, y + 1, 8, "Sent", K.black, K.face, "right")
    textW(x + 47, y + 1, 16, "  Last sent", K.black, K.face)
    for r = 1, RROWS do
      region(reg, x + 1, y + 1 + r, 62, 1, function()
        if D.recipes[S.rscroll + r] then S.sel = S.rscroll + r; drawRecipeRows(); drawRecipeDetail() end
      end)
    end
    local ty = PY0 + 24
    groupBox(X, ty, XW, 11, "Teach a recipe  (for the same item in more than one slice, when its pattern has no data stick)")
    textW(X + 2, ty + 1, XW - 4, "1. Press Pause.   2. Put the ingredients in the inbox chest: one stack per slice, " ..
      "in NEI order, slice 1 in the first slot.", K.black, K.face)
    textW(X + 2, ty + 2, XW - 4, "   The same item in two slices = two separate stacks, each with its own count.   " ..
      "3. Type a name and press Learn.", K.black, K.face)
    textW(X + 2, ty + 3, XW - 4, "4. Take the items out again, press Resume, then order the item from AE2 as usual. " ..
      "(Items AE2 already sent can stay in.)", K.black, K.face)
    textW(X + 2, FY, 6, "Name:", K.black, K.face)
    region(reg, FX, FY, FWID, 1, function() S.focus = true; drawField() end)
    button(reg, X + 2, ty + 7, 24, "Learn from inbox", learn)
    button(reg, X + 28, ty + 7, 22, "Rename selected", renameSel)
    button(reg, X + 52, ty + 7, 22, "Delete selected", deleteSel)
    textW(X + 76, ty + 8, XW - 78, S.paused and "Paused - ready to learn." or "Not paused - press Pause before teaching.",
      S.paused and K.green or AMBER, K.face)
  end
  drawRecipeRows()
  drawRecipeDetail()
  drawField()
end

-- Setup tab --------------------------------------------------------------------------
local function drawMapRows()
  local x, y = X, PY0 + 1
  S.msel = max(1, min(S.msel, max(1, #D.slices)))
  for r = 1, MROWS do
    local sl = D.slices[r]
    local yy = y + 1 + r
    local sel = (r == S.msel)
    local b, f = sel and K.navy or K.white, sel and K.white or K.black
    if sl then
      local ok = ready(sl) and not sl.note
      local note = ok and "OK" or (ready(sl) and sl.note or "not connected")
      textW(x + 1, yy, 7, " " .. r, f, b)
      textW(x + 8, yy, 13, sl.addr:sub(1, 8), f, b)
      textW(x + 21, yy, 14, sl.side and SIDE[sl.side] or "?", f, b)
      textW(x + 35, yy, 53, note, ok and f or (sel and K.yellow or K.red), b)
    else
      textW(x + 1, yy, 87, (r == 1) and " (no slices mapped - press Start mapping)" or "", K.sh, K.white)
    end
  end
end

local function drawMapInfo()
  local x = X + 92
  textW(x + 2, PY0 + 19, 40, "Export buses connected: " .. #listExportBuses(), K.black, K.face)
  textW(x + 2, PY0 + 20, 40, "Slices mapped: " .. #D.slices, K.black, K.face)
  textW(x + 2, PY0 + 21, 40, S.mapping and "MAPPING - place the next adapter" or "", K.red, K.face)
end

local function drawDevices()
  local d, ty = D.dev, PY0 + 24
  local function a(addr) return addr and addr:sub(1, 8) or "NOT FOUND" end
  local function s(side) return side ~= nil and SIDE[side] or "none" end
  textW(X + 2, ty + 3, XW - 4, "Main transposer " .. a(d.main) .. ":   inbox chest " .. s(d.inbox) .. "   outbox chest " .. s(d.outbox) ..
    "   data access hatch " .. s(d.hatch) .. "   stick return " .. s(d.ret), d.main and K.black or K.red, K.face)
  textW(X + 2, ty + 4, 70, "Checker transposer " .. a(d.check) .. ":   first input bus " .. s(d.checkSide),
    d.check and K.black or K.red, K.face)
  textW(X + 72, ty + 4, XW - 74, "Database " .. a(d.db) .. (d.dbSize and ("  (" .. d.dbSize .. " entries)") or ""),
    d.db and K.black or K.red, K.face)
end

local function addSlice(addr)
  for _, sl in ipairs(D.slices) do if sl.addr == addr then return false end end
  local sl = { addr = addr }
  D.slices[#D.slices + 1] = sl
  detectBus(sl)
  return true
end

local function mapButtons()
  local x1, x2, y, w = X + 94, X + 114, PY0 + 3, 19
  local function sel() return D.slices[S.msel] end
  local function done(msg) save(); if msg then flash(msg) end; drawAll() end
  button(reg, x1, y, w, S.mapping and "Finish mapping" or "Start mapping", function()
    if S.mapping then
      S.mapping = false
      logLine("Mapping finished: " .. #D.slices .. " slices")
      done(#D.slices .. " slices mapped")
    else
      dialog("Start Mapping", { "This clears the current slice list.", "",
        "Then place the ADAPTERS next to the export buses ONE AT A TIME,",
        "starting at slice 1 (the controller end). Each new one becomes the",
        "next slice. Adapters that are already placed: break and re-place them." }, {
        { "Start", function() D.slices, S.mapping, S.msel, S.busView, S.cur, S.cfg = {}, true, 1, {}, nil, {}; save() end },
        { "Cancel" } })
    end
  end, S.mapping)
  button(reg, x2, y, w, "Add all found", function()
    flash("Looking at every export bus..."); drawAll(); gpu.flush()
    local n = 0
    for _, a in ipairs(listExportBuses()) do if addSlice(a) then n = n + 1 end end
    done(n .. " export bus(es) added - check the order")
  end)
  button(reg, x1, y + 3, w, "Move up", function()
    local i = S.msel
    if i > 1 and D.slices[i] then
      D.slices[i], D.slices[i - 1] = D.slices[i - 1], D.slices[i]; S.msel = i - 1; S.dbKeys = {}; done()
    end
  end)
  button(reg, x2, y + 3, w, "Move down", function()
    local i = S.msel
    if D.slices[i] and D.slices[i + 1] then
      D.slices[i], D.slices[i + 1] = D.slices[i + 1], D.slices[i]; S.msel = i + 1; S.dbKeys = {}; done()
    end
  end)
  button(reg, x1, y + 6, w, "Reverse order", function()
    local n = #D.slices
    for i = 1, floor(n / 2) do D.slices[i], D.slices[n + 1 - i] = D.slices[n + 1 - i], D.slices[i] end
    done("Order reversed")
  end)
  button(reg, x2, y + 6, w, "Remove slice", function()
    if sel() then table.remove(D.slices, S.msel); done("Slice removed") end
  end)
  button(reg, x1, y + 9, w, "Bus faces: next", function()
    local sl = sel()
    if sl then sl.side = ((sl.side or 1) + 1) % 6; sl.note = nil; done("Slice " .. S.msel .. ": export bus faces " .. SIDE[sl.side]) end
  end)
  button(reg, x2, y + 9, w, "Detect devices", function()
    flash("Looking at the transposers..."); drawAll(); gpu.flush()
    local list = detectDevices()
    for _, sl in ipairs(D.slices) do proxies[sl.addr] = nil; detectBus(sl) end
    done(devProblem() or "Transposers and database found")
    local lines = surveyLines(list)
    lines[#lines + 1] = ""
    lines[#lines + 1] = devProblem() or "Everything found."
    dialog("Detect Devices", lines, { { "OK" } })
  end)
  button(reg, x1, y + 12, w, "Swap chests", function()
    D.dev.inbox, D.dev.outbox = D.dev.outbox, D.dev.inbox
    done("Inbox and outbox chest swapped")
  end)
end

local function drawSetup(full)
  local x, y = X, PY0 + 1
  if full then
    bevel(x, y, 90, MROWS + 3, "sunken", K.face, K.white)
    textW(x + 1, y + 1, 7, " Slice", K.black, K.face)
    textW(x + 8, y + 1, 13, "Export bus", K.black, K.face)
    textW(x + 21, y + 1, 14, "Bus faces", K.black, K.face)
    textW(x + 35, y + 1, 53, "Status", K.black, K.face)
    for r = 1, MROWS do
      region(reg, x + 1, y + 1 + r, 88, 1, function()
        if D.slices[r] then S.msel = r; drawMapRows() end
      end)
    end
    groupBox(X + 92, y, XW - 92, 22, "Slice mapping")
    mapButtons()
    local ty = PY0 + 24
    groupBox(X, ty, XW, 11, "Devices, options & help")
    textW(X + 2, ty + 1, 18, "Untaught recipes:", K.black, K.face)
    cycler(X + 20, ty + 1, 24, D.passThrough and "Send in slot order" or "Hold in the inbox", function()
      D.passThrough = not D.passThrough; S.sig = nil; save(); drawAll()
    end)
    textW(X + 52, ty + 1, XW - 54, "Slot order: first stack to slice 1, as the storage buses did.",
      K.sh, K.face)
    textW(X + 2, ty + 6, XW - 4, "Under every input bus: an ME Export Bus of the dispatch network, with an Adapter touching " ..
      "its cable. Map them in slice order.", K.sh, K.face)
    textW(X + 2, ty + 7, XW - 4, "Main transposer: inbox chest below it (AE2 puts the recipe there), outbox chest above it " ..
      "(the dispatch network's only storage).", K.sh, K.face)
    textW(X + 2, ty + 8, XW - 4, "Checker transposer: touches the first input bus. Database Upgrade (tier 2): in any adapter. " ..
      "Then press Detect devices.", K.sh, K.face)
    textW(X + 2, ty + 9, XW - 4, "Data sticks (optional): an Automatable Data Access Hatch and an ME Interface of the main " ..
      "network, both touching the main transposer.", K.sh, K.face)
  end
  drawMapRows()
  drawMapInfo()
  drawDevices()
end

-- window --------------------------------------------------------------------------------
local TABS = { { "monitor", "Monitor" }, { "recipes", "Recipes" }, { "setup", "Setup" } }

local function drawTabs()
  fill(WX + 1, 5, WW - 2, 2, K.face)
  local x = PX0
  for _, t in ipairs(TABS) do
    local w = unicode.len(t[2]) + 4
    text(x, 5, "┌" .. string.rep("─", w - 2) .. "┐", K.hi, K.face)
    text(x, 6, "│", K.hi, K.face)
    textW(x + 1, 6, w - 2, t[2], (tab == t[1]) and K.navy or K.black, K.face, "center")
    text(x + w - 1, 6, "│", K.sh, K.face)
    region(reg, x, 5, w, 2, function() tab = t[1]; S.focus = false; drawAll() end)
    t.x, t.w = x, w
    x = x + w
  end
end

local function drawStatusBar()
  local yy = WY + WH - 2
  if S.flash and computer.uptime() - S.flashAt > 8 then S.flash = nil end
  local name = stateInfo()
  fill(WX + 1, yy, WW - 2, 1, K.face)
  textW(WX + 2, yy, 70, S.flash or ("Dispatcher: " .. name), S.flash and K.navy or K.black, K.face)
  text(WX + 73, yy, "│", K.sh, K.face)
  textW(WX + 74, yy, 34, "Inbox: " .. #S.buffer .. " stack(s)", K.black, K.face)
  text(WX + 109, yy, "│", K.sh, K.face)
  textW(WX + 110, yy, 32, #D.recipes .. " recipes   " .. commas(D.made or 0) .. " crafts done", K.black, K.face)
end

local function setPaused(v)
  S.paused = v
  if not v then S.err, S.sig = nil, nil end
  logLine(v and "Paused" or "Resumed")
  drawAll()
end

local function clearOutbox()
  dialog("Clear Outbox", { "Switch every export bus off and move what is left in the outbox",
    "chest back to the inbox? Sending is paused afterwards.",
    "(Items that are already inside the input buses stay there.)" }, {
    { "Yes", function()
        S.paused = true
        clearAllBuses()
        local n = outboxBack()
        S.busView, S.cur, S.state, S.sig, S.outbox, S.resume, S.err = {}, nil, "idle", nil, 0, nil, nil
        logLine("Export buses switched off, " .. n .. " item(s) moved back to the inbox")
        flash(n .. " item(s) moved back to the inbox - paused")
      end },
    { "No" } })
end

local function drawToolbar()
  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  local x = WX + 2
  local function item(label, fn, f, b)
    text(x, WY + 2, label, f or K.black, b or K.face)
    region(reg, x, WY + 2, unicode.len(label), 1, fn)
    x = x + unicode.len(label) + 1
  end
  if S.paused then item(" Resume ", function() setPaused(false) end, K.white, K.green)
  else item(" Pause ", function() setPaused(true) end) end
  item(" Clear outbox ", clearOutbox)
  item(" Refresh ", function() drawAll() end)
end

local function drawWindow()
  reg = {}
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ Assembly Line - Item Dispatcher", true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(reg, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(reg, bx + 7, WY + 1, 3, 1, function() closeAsm() end)
  drawToolbar()
  drawTabs()
  bevel(PX0, PY0, PW, PH, "raised", K.face, K.face)
  for _, t in ipairs(TABS) do      -- open the border under the active tab
    if tab == t[1] and t.x then text(t.x + 1, PY0, string.rep(" ", t.w - 2), K.black, K.face) end
  end
  if tab == "monitor" then readMachine(); drawMonitor(true)
  elseif tab == "recipes" then drawRecipes(true)
  else drawSetup(true) end
  drawStatusBar()
  S.dirty = false
end

-- once per second from the main loop
local function tick()
  pcall(broadcast)
  if not visible() then return end
  if tab == "monitor" then
    readMachine()
    drawMonitor(false)
  end
  drawStatusBar()
  S.dirty = false
end

local function alert() return S.err ~= nil or S.state == "hold" or S.state == "offline" end
local lastAlert = false

-- after the dispatcher ran: show what changed right away
local function refresh()
  local a = alert()
  if a ~= lastAlert or S.redraw then       -- toolbar + taskbar button change too
    lastAlert, S.redraw = a, false
    if not overlay and not LOCK.isLocked() then
      if activeApp == "asm" then drawAll() else drawTaskbar(now()) end
    end
    return
  end
  if S.dirty and visible() then
    if tab == "monitor" then drawMonitor(false) end
    drawStatusBar()
    S.dirty = false
  end
end

local function onComponent(name, addr, ctype)
  proxies[addr] = nil
  if ctype == "gt_machine" then S.mach = nil end
  if ctype == "transposer" or ctype == "database" then S.dirty = true; return end
  if name == "component_added" then
    if not isExportBus(addr, ctype) then return end
    if S.mapping and addSlice(addr) then save() end
  end
  S.dirty = true
  if visible() then
    if tab == "setup" then drawMapRows(); drawMapInfo() else refresh() end
  end
end

local function key(ch, code)
  if code == 28 or code == 156 or code == 1 then
    if code == 1 then S.input = "" end
    S.focus = false
  elseif code == 14 then S.input = S.input:sub(1, -2)
  elseif ch and ch >= 32 and ch < 127 and #S.input < FWID - 3 then
    S.input = S.input .. string.char(ch)
  end
  drawField()
end

local function scroll(x, y, dir)
  if tab == "recipes" and x < X + 64 and y > PY0 + 2 and y <= PY0 + 2 + RROWS then
    S.rscroll = S.rscroll - dir
    drawRecipeRows()
    return true
  end
end

return {
  drawWindow = drawWindow, tick = tick, poll = poll, refresh = refresh, load = load, save = save,
  onComponent = onComponent, key = key, scroll = scroll, drawField = drawField,
  regions = function() return reg end,
  resetRegions = function() reg = {} end,
  focus = function(v) if v == false then S.focus = false end return S.focus and tab == "recipes" end,
  crash = function(e) fail("Program error in the dispatcher: " .. tostring(e)) end,
  alert = alert,
  summary = function() local n = stateInfo(); return n:lower() end,
  trayColor = function()
    local _, col = stateInfo()
    return col
  end,
}
end)()

local asmOpenFlag = true
openAsm = function() asmOpenFlag = true; activeApp = "asm" end
closeAsm = function() asmOpenFlag = false; AL.focus(false); activeApp = nil; drawAll() end
asmOpen = function() return asmOpenFlag end

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
  local parts = { "Assembly Line: " .. AL.summary() }
  parts[#parts + 1] = string.format("RAM %dK free", floor(computer.freeMemory() / 1024))
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
  note(L, 21, LWd - 2, "Used on the taskbar, lock screen and Assembly Line log.")

  -- about
  groupBox(L - 2, 24, LWd + 2, 19, "About This Computer")
  local total, free = computer.totalMemory(), computer.freeMemory()
  local rows = {
    { "System:", tostring(SETTINGS.systemName or "Lymanos") .. "  (Lymanos Assembly 2.0)" },
    { "User:", tostring(PLAYER_NAME) },
    { "Memory:", string.format("%d K used of %d K", floor((total - free) / 1024), floor(total / 1024)) },
    { "Network card:", wlan and (wlan.address:sub(1, 8) .. (wlan.isWireless() and " (wireless)" or " (wired)")) or "none (optional)" },
    { "Settings file:", CONFIG.SETTINGS_FILE },
    { "Data file:", CONFIG.DATA_FILE },
    { "Status port:", wlan and CONFIG.STATUS_PORT and (tostring(CONFIG.STATUS_PORT) .. "  (\"ASSLINE\" broadcast)") or "off" },
  }
  for i, r in ipairs(rows) do
    label(L, 25 + i, r[1])
    textW(L + FX - 18, 25 + i, LWd - FX + 16, r[2], K.black, K.face)
  end
  note(L, 34, LWd - 2, "Settings save automatically. CONFIG at the top of")
  note(L, 35, LWd - 2, "lymasm.lua holds the defaults and advanced options.")
  button(regions, L, 38, 24, "Reset to defaults", function()
    dialog("Reset Settings", { "Put every setting back to its default?",
      "(Slice mapping and recipes are not touched.)" }, {
      { "Yes", function()
          SETTINGS.userName, SETTINGS.systemName, SETTINGS.lockMins, SETTINGS.lockStyle = nil, "Lymanos", 30, 1
          SETTINGS.clock24, SETTINGS.desk = false, 1
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
  note(R, 17, RWd - 2, "The Assembly Line keeps being fed while the screen is locked.")
  button(regions, R, 18, 20, "Lock Now", function() LOCK.lock() end)

  -- assembly line
  groupBox(R - 2, 23, RWd + 2, 20, "Assembly Line")
  note(R, 25, RWd - 2, "Slice mapping, devices, taught recipes and the slot-order")
  note(R, 26, RWd - 2, "option are in the Assembly Line app (Recipes, Setup tabs).")
  note(R, 28, RWd - 2, "Timing (CONFIG at the top of lymasm.lua):")
  label(R, 30, "Inbox check:")
  textW(R + FX - 18, 30, 30, "every " .. tostring(CONFIG.POLL) .. " s", K.black, K.face)
  label(R, 31, "Slot-order delay:")
  textW(R + FX - 18, 31, 30, tostring(CONFIG.PASS_DELAY) .. " s", K.black, K.face)
  label(R, 32, "Idle warning:")
  textW(R + FX - 18, 32, 30, "after " .. tostring(CONFIG.JAM_SECONDS) .. " s", K.black, K.face)
  label(R, 33, "Export timeout:")
  textW(R + FX - 18, 33, 30, tostring(CONFIG.EXPORT_TIMEOUT) .. " s without movement", K.black, K.face)
  button(regions, R, 38, 26, "Open Assembly Line", function() openAsm(); drawAll() end)

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
  AL.resetRegions()
  if not keepOverlay then overlay = nil end
  drawDesktop()
  if activeApp == "asm" then
    AL.drawWindow()
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
  AL.load()
  drawAll()

  local lastTick = 0
  while running do
    gpu.flush()                        -- show this pass's drawing in one go
    local ev = { event.pull(0.25) }
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
      elseif activeApp == "asm" then
        local wasFocus = AL.focus()
        AL.focus(false)
        if not hit(AL.regions(), x, y) then hit(regions, x, y) end
        if wasFocus and not AL.focus() and activeApp == "asm" and not overlay then AL.drawField() end
      else
        hit(regions, x, y)
      end
    elseif name == "scroll" and not overlay and activeApp == "sys" then
      SYS.scroll(ev[3], ev[4], ev[5])
    elseif name == "scroll" and not overlay and activeApp == "asm" then
      AL.scroll(ev[3], ev[4], ev[5])
    elseif name == "component_added" or name == "component_removed" then
      pcall(AL.onComponent, name, ev[2], ev[3])
    elseif name == "key_down" and activeApp == "asm" and AL.focus() and not overlay then
      AL.key(ev[3], ev[4])
    elseif name == "key_down" and activeApp == "settings" and SET.focus() and not overlay then
      SET.key(ev[3], ev[4])
    end

    -- the dispatcher: looks into the buffer chest and feeds the Assembly Line
    if running then
      local okp, pe = pcall(AL.poll)
      if not okp then AL.crash(pe) end
      AL.refresh()
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
      SYS.tick(activeApp == "sys" and not overlay and not LOCK.isLocked())
      pcall(AL.tick)
      -- lock after the idle time set in Settings (0 = never)
      local mins = SETTINGS.lockMins or 0
      if mins > 0 and not LOCK.isLocked() and LOCK.idle() >= mins * 60 then LOCK.lock() end
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
pcall(AL.save)                     -- slice mapping, recipes, activity log
gpu.setResolution(oldW, oldH)
rgpu.setBackground(0x000000)
rgpu.setForeground(0xFFFFFF)
term.clear()
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write(tostring(err) .. "\n")
end
