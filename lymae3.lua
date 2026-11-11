--[[
  lymae.lua  -  Lymanos AE (a stripped-down Lymanos for a dedicated AE2 server)

  Apps:
    Applied Energistics
        Level Control  keeps an item or fluid between two levels: when the
                       amount in AE2 drops below "Turn ON below" the machine
                       for it is switched on, at "Turn OFF at" it is switched
                       off again (hysteresis, like treefarm). Any number of
                       rules, each with its own item/fluid, levels and machine.
        Craftables     everything AE2 can craft, with the amount in the
                       system and "Can craft" / "Cannot craft" (= are the
                       materials there for one craft). Pin items to keep them
                       at the top.
        Setup          what was found, pattern reading, probe file, activity log
    My Computer    storage, memory, power and hardware details
    Settings       your name, system name, lock screen, desktop color

  Build:
    - an Adapter touching an ME Interface of your main network (the program
      reads stock and craftables through it)
    - an Adapter touching every machine you want to switch (e.g. the Large
      Chemical Reactor controller). GregTech machines are switched like a soft
      mallet (work allowed / not allowed). Or use a Redstone I/O + a Machine
      Controller cover.
    - for "Can craft" / "Cannot craft": an Adapter touching an ME Interface
      Terminal (GTNH 2.9+). AE2 does not tell OpenComputers whether a craft
      would succeed, so the program reads every pattern through the terminal
      and works it out itself (see Setup).
  Then: Applied Energistics > Level Control, pick the machine for each rule.

  Files written on this computer:
    /home/lymae_data.dat        rules, pins, history, activity log
    /home/lymae_settings.dat    Settings app
    /home/lymae_probe.txt       only when you press "Write probe file" (Setup)

  Needs: tier 3 GPU + tier 3 screen (160x50), mouse + keyboard. A server with
  lots of memory (patterns of a big base take RAM). A network card is optional
  (status broadcast). Exit: Start > Shut Down or Ctrl+C. Machines keep the
  state they have when the program stops.
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  DATA_FILE = "/home/lymae_data.dat",
  SETTINGS_FILE = "/home/lymae_settings.dat",   -- written by the Settings app
  PROBE_FILE = "/home/lymae_probe.txt",

  ME = nil,                    -- nil = first ME interface / controller found, or the start of its address

  -- Level Control
  LEVEL_POLL = 5,              -- seconds between level checks
  HISTORY_STEP = 30,           -- seconds per graph point (120 points = 1 hour)

  -- Craftables
  AMOUNT_REFRESH = 30,         -- seconds between amount updates of the craftable list
  CRAFT_REFRESH = 1800,        -- seconds between full rereads of every craftable (finds new / removed patterns)
  DEEP_SCAN = true,            -- also walk getCraftables() (finds fluid craftables and items AE2 lists only there)
  PATTERN_REFRESH = 1800,      -- seconds between rereads of every pattern (ME Interface Terminal)
  STOCK_TTL = 60,              -- seconds a stock reading is reused by the "can craft" check
  STATUS_TTL = 60,             -- shown / pinned rows are checked again after this many seconds
  PLAN_DEPTH = 24,             -- deepest sub-craft chain the check follows
  PLAN_MAX_STEPS = 4000,       -- bigger crafts are shown as "?" (too big to check)
  WORK_BUDGET = 0.05,          -- seconds of background AE work per screen update
  MAX_PINS = 60,

  LOG_MAX = 60,                -- activity lines kept
  PLAYER_NAME = nil,           -- default name; normally set in the Settings app

  -- Status broadcast for other programs (only when a network card is installed).
  -- Message: "LYMAE", serialized { rules = { { label, amount, low, high, on, active } }, t }
  STATUS_PORT = 4047,          -- nil = do not broadcast
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
-- Optional: only used to broadcast the Level Control status.
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
  if n >= 1e12 then return string.format("%.2fT", n / 1e12)
  elseif n >= 1e9 then return string.format("%.2fG", n / 1e9)
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
  if not t or t < 1e9 then return "--" end
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
local listRegions = {}        -- list rows + scrollbar (rebuilt by drawList)
local panelRegions = {}       -- chess side panel (rebuilt by drawChessRight)
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
local activeApp = "ae"        -- window in front: "ae" | "sys" | "settings" | nil (desktop)
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
local openAE, closeAE, aeOpen                            -- forward (Applied Energistics)
local openSysApp, closeSysApp, sysAppOpen                -- forward (My Computer)
local openSettings, closeSettings, settingsOpen          -- forward (Settings)
local AEX, AE, LOCK, SET                                 -- AE core, AE app, lock screen, Settings (below)

local function drawDesktop()
  fill(1, 1, W, 46, K.desk)
  drawIcon(3, 2, "pc", "My Computer")
  region(regions, 1, 2, 12, 5, function() openSysApp(); drawAll() end)
  -- Applied Energistics icon: an ME drive with cells
  fill(4, 8, 8, 3, 0x404850)
  text(5, 8, "▬▬ ▬▬ ", 0x7CF5D0, 0x404850)
  text(5, 9, "▬▬ ▬▬ ", 0x7CF5D0, 0x404850)
  text(5, 10, "▬▬ ▬▬ ", 0xFFB060, 0x404850)
  textW(1, 11, 12, "Applied", K.white, K.desk, "center")
  textW(1, 12, 12, "Energistics", K.white, K.desk, "center")
  region(regions, 1, 8, 12, 5, function() openAE(); drawAll() end)
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
  text(146, 49, "●", AE and AE.trayColor() or K.sh, K.face)     -- Level Control state
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
  if aeOpen and aeOpen() then
    list[#list + 1] = { (AE and AE.alert()) and " ▣ Applied Energistics - CHECK!" or " ▣ Applied Energistics", "ae" }
  end
  if sysAppOpen and sysAppOpen() then list[#list + 1] = { " ▣ My Computer", "sys" } end
  if settingsOpen and settingsOpen() then list[#list + 1] = { " ▣ Settings", "settings" } end
  local bw = min(34, floor(132 / max(1, #list)) - 1)
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
  if y + h > 47 then y = max(1, 47 - h) end
  if x + w + banner > W then x = max(1, W - w - banner) end
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
      textW(x + 1 + banner, iy, w - 2, "  " .. it[1], it[2] and K.black or K.sh, K.face)
      if it[2] then
        region(overlay.regions, x + 1 + banner, iy, w - 2, 1, function()
          overlay = { regions = {}, busy = true }
          it[2]()
          if overlay and overlay.busy then overlay = nil; nextDialogOrRedraw() end
        end)
      end
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
  local x, y = floor((W - w) / 2), max(1, floor((46 - h) / 2))
  overlay = { regions = {}, modal = true, reshow = function() dialog(title, lines, buttons) end }
  drawAll(true)
  bevel(x, y, w, h, "raised", K.desk, K.face)
  titleBar(x + 1, y + 1, w - 2, title, true)
  text(x + w - 4, y + 1, " X ", K.black, K.face)
  region(overlay.regions, x + w - 4, y + 1, 3, 1, closeOverlay)
  text(x + 3, y + 3, "(i)", K.white, K.navy)
  for i, l in ipairs(lines) do textW(x + 8, y + 2 + i, w - 10, l, K.black, K.face) end
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
  dialog("About Lymanos AE", {
    tostring(SETTINGS.systemName or "Lymanos") .. "  -  AE (Lymanos 2.2, stripped down)",
    "Keeps items and fluids between two levels by switching the",
    "machines that make them, and lists everything AE2 can craft",
    "with its amount and whether the materials are there.",
    "",
    "Data file: " .. CONFIG.DATA_FILE,
  }, { { "OK" } })
end

local function confirmExit()
  dialog("Shut Down", { "Are you sure you want to close Lymanos?",
    "The machines keep the state they have now (nothing switches them).", },
    { { "Yes", function() running = false end }, { "No" } })
end

openStartMenu = function()
  popupMenu(1, 47, {
    { "Applied Energistics", function() openAE() end },
    { "My Computer", function() openSysApp() end },
    { "Settings", function() openSettings() end },
    { "-" },
    { "Lock", function() LOCK.lock() end },
    { "About...", about },
    { "-" },
    { "Shut Down...", confirmExit },
  }, { banner = true, above = true, start = true })
end


------------------------------------------------------ AE CORE (no drawing)
-- Everything that talks to Applied Energistics and the machines:
--   * amounts of items and fluids
--   * the list of craftables (with amounts)
--   * every pattern, read through an ME Interface Terminal (GTNH 2.9+)
--   * "can craft": AE2 does not tell OpenComputers whether a craft would
--     work, so this plans it the way AE2 does (stock first, then sub-crafts)
--   * switching machines on / off
-- Slow work (scans, pattern reading, checking) runs in a background coroutine
-- that gets a small time slice per screen update, so the screen never freezes.
-- Own function = own local-variable budget.
AEX = (function()
local X = {}
local SIDE = { [0] = "bottom", "top", "north", "south", "west", "east" }
local up = computer.uptime
local proxies = {}

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

local function exists(addr)
  if not addr then return false end
  local ok, t = pcall(component.type, addr)
  return ok and t ~= nil
end

local function methodsOf(addr)
  local ok, m = pcall(component.methods, addr)
  return (ok and type(m) == "table") and m or {}
end

-- the background worker gives control back with pause() when its slice is used
local inWorker, sliceStart, budget = false, 0, CONFIG.WORK_BUDGET or 0.05
local function pause()
  if inWorker and up() - sliceStart >= budget then coroutine.yield() end
end

-- ME access ----------------------------------------------------------------------
local meAddr, meType
local function me()
  if meAddr and exists(meAddr) then return px(meAddr) end
  meAddr, meType = nil, nil
  local want = CONFIG.ME
  local function okAddr(a) return not want or a:sub(1, #want) == want end
  for _, t in ipairs({ "me_interface", "me_controller" }) do
    for a in component.list(t, true) do
      if okAddr(a) then meAddr, meType = a, t; return px(a) end
    end
  end
  for a, t in component.list() do         -- other names (dual interface, ...)
    if t:find("^me_") and okAddr(a) and methodsOf(a).getItemsInNetwork then
      meAddr, meType = a, t
      return px(a)
    end
  end
end
X.me = me
function X.meInfo() return meAddr, meType end

local termAddr
local function term()
  if termAddr and exists(termAddr) then return px(termAddr) end
  termAddr = component.list("me_interface_terminal", true)()
  return px(termAddr)
end
function X.termInfo() return termAddr end

function X.forget(addr)
  proxies[addr] = nil
  if addr == meAddr then meAddr = nil end
  if addr == termAddr then termAddr = nil end
end

-- OpenComputers often returns an iterator object instead of a list: a table
-- with count(), reset() and getAll() that gives the next entry each time it is
-- called (getInterfaces, getAllStacks, ...). These helpers accept either.
local function isIter(v)
  return type(v) == "table" and v.getAll ~= nil and v.count ~= nil and v.reset ~= nil
end

-- calls fn(entry) for every entry of a list or an iterator object
local function eachOf(v, fn)
  if type(v) ~= "table" then return end
  if not isIter(v) then
    for _, x in pairs(v) do if type(x) == "table" then fn(x) end end
    return
  end
  local got = 0
  local ok = pcall(function()
    pcall(function() v.reset() end)
    local okc, n = pcall(function() return v.count() end)
    n = (okc and tonumber(n)) or 100000
    for _ = 1, n do
      local x = v()
      if x == nil then break end
      got = got + 1
      fn(x)
    end
  end)
  if ok and got > 0 then return end
  local ok2, all = pcall(function() return v.getAll() end)       -- the iterator cannot be called: take everything
  if ok2 and type(all) == "table" then
    for _, x in pairs(all) do if type(x) == "table" then fn(x) end end
  end
end

local function listOf(v)
  if not isIter(v) then return v end
  local out = {}
  eachOf(v, function(x) out[#out + 1] = x end)
  return out
end

-- stacks and keys ----------------------------------------------------------------
-- An item is "i:<name>@<damage>", a fluid is "f:<fluid name, lower case>".
-- AE2 fluid drops (ae2fc) are counted as the fluid they stand for.
X.label = {}                         -- key -> display name

local function isFluid(s)
  if s.type == "fluid" or s.type == "FluidStack" or s.isFluid == true then return true end
  local n = tostring(s.name or "")
  if n:find("fluid_drop", 1, true) or n:find("fluid_packet", 1, true) then return true end
  return s.amount ~= nil and s.damage == nil      -- GTNH 2.9 fluids have size + amount, items have damage
end

local function fluidLabel(s)
  local l = tostring(s.label or s.name or "?")
  l = l:gsub("^[Dd]rop of ", ""):gsub(" [Dd]rop$", "")
  return l
end

local function keyOf(s)
  if isFluid(s) then return "f:" .. fluidLabel(s):lower(), true end
  return "i:" .. tostring(s.name) .. "@" .. floor(tonumber(s.damage) or 0), false
end
X.keyOf = keyOf

local function labelOfStack(s, fl)
  if fl then return fluidLabel(s) end
  return tostring(s.label or s.name or "?")
end

function X.labelOf(k)
  if not k then return "?" end
  local l = X.label[k]
  if l then return l end
  local name = k:match("^i:(.+)@") or k:match("^f:(.+)$")
  return name or k
end

function X.isFluidKey(k) return k and k:sub(1, 2) == "f:" end

-- amounts ---------------------------------------------------------------------------
local fmap, fmapAt = nil, -1e9
X.fluidCraft = {}

-- every fluid in the network: key -> mB (cached for maxAge seconds)
function X.fluids(maxAge)
  if fmap and up() - fmapAt <= (maxAge or 2) then return fmap end
  local m = me()
  if not m then return nil, "no ME interface found" end
  if not m.getFluidsInNetwork then return nil, "this ME component cannot read fluids" end
  local ok, list = pcall(m.getFluidsInNetwork)
  if not ok or type(list) ~= "table" then return nil, tostring(list) end
  local map, craft = {}, {}
  for i = 1, (list.n or #list) do
    local f = list[i]
    if type(f) == "table" then
      local k = "f:" .. fluidLabel(f):lower()
      map[k] = (map[k] or 0) + (tonumber(f.amount) or tonumber(f.size) or 0)
      X.label[k] = X.label[k] or fluidLabel(f)
      if f.isCraftable then craft[#craft + 1] = k end
    end
  end
  fmap, fmapAt, X.fluidCraft = map, up(), craft
  return map
end

-- The lookup this pack understands: GTNH 2.9 getItemInNetwork({name, damage}),
-- older getItemInNetwork(name, damage), or a filtered getItemsInNetwork.
local itemForm
function X.itemAmount(name, damage)
  local m = me()
  if not m then return nil, "no ME interface found" end
  if m.getItemInNetwork and itemForm ~= "scan" then
    if itemForm == nil or itemForm == "detail" then
      local ok, r = pcall(m.getItemInNetwork, { name = name, damage = damage })
      if ok and type(r) == "table" then itemForm = "detail"; return tonumber(r.size) or 0 end
      if ok and itemForm == "detail" then return 0 end
    end
    if itemForm == nil or itemForm == "pos" then
      local ok, r = pcall(m.getItemInNetwork, name, damage)
      if ok and type(r) == "table" then itemForm = "pos"; return tonumber(r.size) or 0 end
      if ok and itemForm == "pos" then return 0 end
    end
  end
  local ok, list = pcall(m.getItemsInNetwork, { name = name, damage = damage })
  if not ok or type(list) ~= "table" then return nil, tostring(list) end
  local n = 0
  for i = 1, (list.n or #list) do
    local s = list[i]
    if type(s) == "table" then n = n + (tonumber(s.size) or 0) end
  end
  if n > 0 and itemForm == nil then itemForm = "scan" end   -- the direct lookups did not see it
  return n
end
function X.itemForm() return itemForm end

function X.amountOf(k)
  if not k then return nil, "nothing chosen" end
  if k:sub(1, 2) == "f:" then
    local m, err = X.fluids()
    if not m then return nil, err end
    return m[k] or 0
  end
  local name, dmg = k:match("^i:(.+)@(%-?%d+)$")
  if not name then return nil, "bad key " .. k end
  return X.itemAmount(name, tonumber(dmg))
end

-- items whose display name matches (for the target finder)
function X.find(text)
  local out, seen = {}, {}
  local q = tostring(text):lower()
  if q == "" then return out end
  local function add(k, l, fl)
    if not seen[k] and #out < 16 then seen[k] = true; out[#out + 1] = { k = k, l = l, f = fl } end
  end
  local fm = X.fluids(0)
  if fm then
    for k in pairs(fm) do
      local l = X.label[k] or k
      if l:lower():find(q, 1, true) then add(k, l, true) end
    end
  end
  for _, e in ipairs(X.list) do
    if e.ll:find(q, 1, true) then add(e.k, e.l, e.f) end
  end
  local m = me()
  if m then        -- an item that is stocked but not craftable: exact name only
    local ok, list = pcall(m.getItemsInNetwork, { label = text })
    if ok and type(list) == "table" then
      for i = 1, min(8, list.n or #list) do
        local s = list[i]
        if type(s) == "table" then local k, fl = keyOf(s); add(k, labelOfStack(s, fl), fl) end
      end
    end
  end
  table.sort(out, function(a, b) return a.l:lower() < b.l:lower() end)
  return out
end

-- craftables --------------------------------------------------------------------------
-- X.list = { { k = key, l = label, ll = lower label, f = fluid?, a = amount }, ... }
X.list, X.byKey, X.listGen = {}, {}, 0
X.scan = { msg = "not read yet", at = nil, deepAt = nil, deepDone = 0, deepTotal = 0, busy = nil }

local function addCraftable(k, label, fl, amt, seen)
  local e = X.byKey[k]
  if not e then
    e = { k = k, l = label, ll = label:lower(), f = fl }
    X.byKey[k] = e
    X.list[#X.list + 1] = e
    X.listGen = X.listGen + 1
  end
  if amt then e.a = amt end
  X.label[k] = X.label[k] or label
  if seen then seen[k] = true end
  return e
end

-- one call: every craftable item with its amount (AE2 lists craftables with the stock)
local function fastScan(seen)
  local m = me()
  if not m then return false, "no ME interface found" end
  local ok, list = pcall(m.getItemsInNetwork, { isCraftable = true })
  if not ok or type(list) ~= "table" then return false, tostring(list) end
  local n = list.n or #list
  local fm = X.fluids(0)
  for i = 1, n do
    local s = list[i]
    list[i] = nil
    if type(s) == "table" and s.isCraftable ~= false then
      local k, fl = keyOf(s)
      local amt = fl and (fm and fm[k] or 0) or (tonumber(s.size) or 0)
      addCraftable(k, labelOfStack(s, fl), fl, amt, seen)
    end
    if i % 100 == 0 then pause() end
  end
  if fm then
    for _, k in ipairs(X.fluidCraft or {}) do addCraftable(k, X.label[k] or k, true, fm[k] or 0, seen) end
    for _, e in ipairs(X.list) do if e.f then e.a = fm[e.k] or 0 end end
  end
  return true, n
end

-- every pattern output, one getItemStack at a time (slow, finds fluid craftables)
-- the stack a getCraftables() entry stands for (older OC: c.getItemStack(); else the entry itself)
local function craftableStack(c)
  if type(c) ~= "table" then return nil end
  if c.getItemStack then
    local ok, s = pcall(function() return c.getItemStack() end)
    if ok and type(s) == "table" then return s end
  end
  if c.name or c.label then return c end
  if type(c.item) == "table" then return c.item end
  if type(c.stack) == "table" then return c.stack end
  if type(c.output) == "table" then return c.output end
end

local function deepScan(seen)
  local m = me()
  if not m or not m.getCraftables then return false, "no getCraftables" end
  local ok, list = pcall(m.getCraftables)
  if not ok or type(list) ~= "table" then return false, tostring(list) end
  local n = list.n or #list
  X.scan.deepTotal, X.scan.deepDone = n, 0
  for i = 1, n do
    local c = list[i]
    list[i] = nil
    X.scan.deepDone = i
    if c then
      local s = craftableStack(c)
      if s then
        local k, fl = keyOf(s)
        local new = X.byKey[k] == nil
        local e = addCraftable(k, labelOfStack(s, fl), fl, nil, seen)
        if new then e.a = X.amountOf(k) end
      end
    end
    pause()
  end
  return true, n
end

-- patterns ------------------------------------------------------------------------------
-- PAT[outputKey] = "n\tinKey\tcount\tinKey\tcount...\n<next pattern>"  (compact: strings, not tables)
local PAT, WANT = nil, {}
X.pat = { n = 0, at = nil, err = nil, inexact = 0, outputs = 0 }

local function stacksOf(v)
  local out = {}
  if type(v) ~= "table" then return out end
  v = listOf(v)
  if v.name or v.label then out[1] = v; return out end
  for _, s in pairs(v) do
    if type(s) == "table" then
      if type(s.stack) == "table" then s = s.stack
      elseif type(s.item) == "table" and not s.name then
        local it = s.item
        it.size = it.size or s.size or s.count or s.amount
        s = it
      end
      if s.name or s.label then out[#out + 1] = s end
    end
  end
  return out
end

local function patternParts(p, depth)
  local ins = p.inputs or p.input or p.ins or p.ingredients or p["in"]
  local outs = p.outputs or p.output or p.outs or p.results or p.result or p.out
  if (ins == nil or outs == nil) and type(p.pattern) == "table" and (depth or 0) < 2 then
    return patternParts(p.pattern, (depth or 0) + 1)
  end
  return stacksOf(ins), stacksOf(outs)
end

local function countOf(s)
  return tonumber(s.size) or tonumber(s.amount) or tonumber(s.count) or tonumber(s.stackSize) or 0
end

local function patternsOfInterface(itf)
  local p = itf.patterns or itf.pattern or itf.items
  if type(p) == "table" then return listOf(p) end
  if itf.inputs or itf.outputs then return { itf } end      -- the entry is a pattern itself
  return {}
end

local function readPatterns()
  local t = term()
  if not t then
    PAT = nil
    X.pat.err, X.pat.short = "No ME Interface Terminal (put an Adapter next to one).", "needs an Interface Terminal"
    return false
  end
  if not t.getInterfaces then
    PAT = nil
    X.pat.err, X.pat.short = "This terminal has no getInterfaces() - needs GTNH 2.9 or newer.", "terminal too old"
    return false
  end
  local ok, list = pcall(t.getInterfaces)
  if not ok or type(list) ~= "table" then
    X.pat.err, X.pat.short = "getInterfaces() failed: " .. tostring(list), "pattern read failed"
    return false
  end
  local idx, want, n, inexact, nItf = {}, {}, 0, 0, 0
  eachOf(list, function(itf)
    if type(itf) ~= "table" then return end
    nItf = nItf + 1
    for _, p in pairs(patternsOfInterface(itf)) do
      if type(p) == "table" then
        local ins, outs = patternParts(p)
        if #outs > 0 then
          local exact, merged, order = true, {}, {}
          for _, s in ipairs(ins) do
            local k, fl = keyOf(s)
            local c = countOf(s)
            if c <= 0 then c, exact = 1, false end
            if not merged[k] then merged[k] = 0; order[#order + 1] = k end
            merged[k] = merged[k] + c
            want[k] = true
            if not X.label[k] then X.label[k] = labelOfStack(s, fl) end
          end
          local parts = {}
          for _, k in ipairs(order) do parts[#parts + 1] = k .. "\t" .. floor(merged[k]) end
          local tail = table.concat(parts, "\t")
          for _, o in ipairs(outs) do
            local k, fl = keyOf(o)
            local c = countOf(o)
            if c <= 0 then c, exact = 1, false end
            local enc = floor(c) .. (tail ~= "" and ("\t" .. tail) or "")
            idx[k] = idx[k] and (idx[k] .. "\n" .. enc) or enc
            if not X.label[k] then X.label[k] = labelOfStack(o, fl) end
          end
          n = n + 1
          if not exact then inexact = inexact + 1 end
        end
      end
    end
    pause()
  end)
  list = nil
  X.pat.interfaces = nItf
  local outputs = 0
  for _ in pairs(idx) do outputs = outputs + 1 end
  if n == 0 then
    X.pat.err = "No readable patterns - press 'Write probe file'."
    X.pat.short = "no readable patterns"
  else
    X.pat.err, X.pat.short = nil, nil
  end
  PAT, WANT = (n > 0) and idx or nil, want
  X.pat.n, X.pat.at, X.pat.inexact, X.pat.outputs = n, now(), inexact, outputs
  X.status = {}                 -- every answer may have changed
  return n > 0
end

function X.hasPattern(k) return PAT ~= nil and PAT[k] ~= nil end

-- stock for the planner ------------------------------------------------------------------
-- One pass over the whole network, keeping only items some pattern needs.
-- Without allItems() / with too little memory: one lookup per item instead.
local snap, snapAt, snapMode = nil, -1e9, nil
X.snapInfo = function() return snapMode, snap and (up() - snapAt) or nil end

local function takeSnapshot()
  local m = me()
  if not m then return false end
  local map = {}
  local function add(s)
    if type(s) == "table" then
      local k, fl = keyOf(s)
      if not fl and WANT[k] then map[k] = (map[k] or 0) + (tonumber(s.size) or 0) end
    end
  end
  local done = false
  if (snapMode == nil or snapMode == "stream") and m.allItems then
    local ok = pcall(function()
      local it = m.allItems()
      local i = 0
      if type(it) == "table" and getmetatable(it) == nil then
        for _, s in pairs(it) do add(s); i = i + 1; if i % 200 == 0 then pause() end end
      else
        for s in it do add(s); i = i + 1; if i % 200 == 0 then pause() end end
      end
    end)
    if ok then done, snapMode = true, "stream" end
  end
  if not done and (snapMode == nil or snapMode == "full") then
    local ok, list = pcall(m.getItemsInNetwork)
    if ok and type(list) == "table" then
      for i = 1, (list.n or #list) do
        add(list[i]); list[i] = nil
        if i % 300 == 0 then pause() end
      end
      done, snapMode = true, "full"
    end
    list = nil
  end
  if not done then snapMode = "lookup"; snap = nil; return false end
  local fm = X.fluids(0)
  if fm then for k, v in pairs(fm) do if WANT[k] then map[k] = v end end end
  snap, snapAt = map, up()
  return true
end

local lk = {}
local function stockOf(k)
  if snap then return snap[k] or 0 end
  local c = lk[k]
  if c and up() - c[2] < (CONFIG.STOCK_TTL or 60) then return c[1] end
  local v = X.amountOf(k) or 0
  lk[k] = { v, up() }
  pause()
  return v
end

-- the planner ------------------------------------------------------------------------------
-- Stock is kept in layers: a sub-craft gets its own layer on top of its parent,
-- which is merged down only when the sub-craft works (AE2 tries the next
-- pattern of an item when the first one cannot be made).
X.status = {}       -- key -> { s = "can" | "cannot" | "unknown", m = missing key / reason, at = uptime }
local steps = 0

local function get(L, k)
  local o = L
  while o do
    local v = o.v[k]
    if v ~= nil then return v end
    o = o.p
  end
  local v = stockOf(k)
  L.r.v[k] = v
  return v
end

local need
-- one pattern (enc) as often as needed for amt of out; on success L holds the stock after it
local function make(L, enc, amt, out, depth, path)
  local f = enc:gmatch("[^\t]+")
  local n = tonumber(f()) or 1
  local b = ceil(amt / max(1, n))
  while true do
    local ik = f()
    if not ik then break end
    local c = tonumber(f()) or 1
    local ok, miss = need(L, ik, c * b, depth + 1, path)
    if not ok then return false, miss end
  end
  L.v[out] = (L.v[out] or 0) + b * n - amt     -- what is left over goes back to stock
  return true
end

need = function(L, k, amt, depth, path)
  steps = steps + 1
  if steps > (CONFIG.PLAN_MAX_STEPS or 4000) then error("too big", 0) end
  local have = get(L, k)
  if have >= amt then L.v[k] = have - amt; return true end
  amt = amt - have
  local pats = PAT[k]
  if not pats or depth >= (CONFIG.PLAN_DEPTH or 24) or path[k] then return false, k end
  path[k] = true
  local miss
  for enc in pats:gmatch("[^\n]+") do
    local C = { p = L, r = L.r, v = { [k] = 0 } }
    local ok, m2 = make(C, enc, amt, k, depth, path)
    if ok then
      for kk, vv in pairs(C.v) do L.v[kk] = vv end
      path[k] = nil
      return true
    end
    miss = miss or m2
  end
  path[k] = nil
  return false, miss
end

local function evaluate(k)
  local st = X.status[k] or {}
  X.status[k] = st
  st.at = up()
  if not PAT then st.s, st.m = "unknown", X.pat.short or "patterns not read yet"; return end
  local pats = PAT[k]
  if not pats then st.s, st.m = "unknown", "no pattern found for it"; return end
  if snapMode ~= "lookup" and (not snap or up() - snapAt > (CONFIG.STOCK_TTL or 60)) then takeSnapshot() end
  steps = 0
  local root = { v = {} }
  root.r = root
  local res, miss
  local ok, err = pcall(function()
    for enc in pats:gmatch("[^\n]+") do
      local L = { p = root, r = root, v = {} }
      local n = tonumber(enc:match("^[^\t]+")) or 1
      local r, m = make(L, enc, n, k, 0, { [k] = true })
      if r then res = true; return end
      miss = miss or m
    end
    res = false
  end)
  st.at = up()
  if not ok then
    st.s, st.m = "unknown", (tostring(err) == "too big") and "too big to check" or ("error: " .. tostring(err))
  elseif res then st.s, st.m = "can", nil
  else st.s, st.m = "cannot", miss end
end

-- background worker ---------------------------------------------------------------------------
X.want = {}                 -- keys on screen right now (set by the window), checked first
local rr = 0
local function nextKey()
  local t = up()
  for _, k in ipairs(X.want) do
    local st = X.status[k]
    if X.byKey[k] and (not st or t - st.at > (CONFIG.STATUS_TTL or 60)) then return k end
  end
  local n = #X.list
  for _ = 1, min(n, 300) do
    rr = rr % n + 1
    local e = X.list[rr]
    local st = e and X.status[e.k]
    if e and (not st or t - st.at > (CONFIG.STATUS_TTL or 60) * 5) then return e.k end
  end
end

local nextFast, nextDeep, nextPat = 0, 0, 0
local cycleSeen = {}
X.task = nil

local function work()
  while true do
    local t = up()
    if not me() then
      X.scan.msg = "No ME interface found."
      coroutine.yield()
    elseif t >= nextFast then
      nextFast = t + (CONFIG.AMOUNT_REFRESH or 30)
      X.task = "reading amounts"
      local ok, n = fastScan(cycleSeen)
      X.scan.msg = ok and (n .. " craftable stacks read") or ("Amounts: " .. tostring(n))
      if ok then X.scan.at = now() end
    elseif t >= nextPat then
      X.task = "reading patterns"
      local ok = readPatterns()
      nextPat = up() + ((ok or term()) and (CONFIG.PATTERN_REFRESH or 1800) or 60)
    elseif CONFIG.DEEP_SCAN and t >= nextDeep then
      X.task = "reading every craftable"
      local ok, n = deepScan(cycleSeen)
      nextDeep = up() + (CONFIG.CRAFT_REFRESH or 1800)
      if ok then
        local keep = {}
        for _, e in ipairs(X.list) do
          if cycleSeen[e.k] then keep[#keep + 1] = e else X.byKey[e.k] = nil; X.status[e.k] = nil end
        end
        if #keep ~= #X.list then X.listGen = X.listGen + 1 end
        X.list = keep
        X.scan.deepAt = now()
      else
        X.scan.msg = "Craftables: " .. tostring(n)
      end
      cycleSeen = {}
    else
      local k = nextKey()
      if k then
        X.task = "checking " .. X.labelOf(k)
        evaluate(k)
      else
        X.task = nil
        coroutine.yield()
      end
    end
    pause()
  end
end

local co
X.err = nil
function X.step(b)
  if not co or coroutine.status(co) == "dead" then co = coroutine.create(work) end
  sliceStart, budget, inWorker = up(), b or CONFIG.WORK_BUDGET or 0.05, true
  local ok, err = coroutine.resume(co)
  inWorker = false
  if not ok then
    X.err = tostring(err)
    co = nil
  end
end

function X.busy() return X.task ~= nil end

function X.rescan(what)
  if what == nil or what == "amounts" then nextFast = 0 end
  if what == nil or what == "patterns" then nextPat = 0; snap = nil; snapMode = nil end
  if what == nil or what == "craftables" then nextDeep = 0 end
end

function X.recheck(k)
  if k then X.status[k] = nil else X.status = {} end
  snap = nil
end

-- machines ------------------------------------------------------------------------------------
-- { kind = "gt", addr }  or  { kind = "rs", addr, side, inv }
function X.machines()
  local out = {}
  for a in component.list("gt_machine", true) do
    local p = px(a)
    local ok, name = pcall(function() return p.getName() end)
    out[#out + 1] = { kind = "gt", addr = a, name = (ok and name) and tostring(name) or "GregTech machine" }
  end
  table.sort(out, function(a, b) return a.name .. a.addr < b.name .. b.addr end)
  for a in component.list("redstone", true) do
    for s = 0, 5 do out[#out + 1] = { kind = "rs", addr = a, side = s, name = "Redstone " .. a:sub(1, 8) .. " " .. SIDE[s] } end
  end
  return out
end

function X.machineText(m)
  if not m then return "(none)" end
  if m.kind == "rs" then
    return "Redstone " .. m.addr:sub(1, 8) .. "  " .. SIDE[m.side or 1] .. (m.inv and "  (inverted)" or "")
  end
  local p = exists(m.addr) and px(m.addr)
  local name = m.name
  if p then
    local ok, n = pcall(function() return p.getName() end)
    if ok and n then name = tostring(n) end
  end
  return tostring(name or "GregTech machine") .. "  [" .. m.addr:sub(1, 8) .. "]"
end

-- { allowed, active, prog, maxp, err }
function X.readMachine(m)
  if not m then return { err = "no machine chosen" } end
  if not exists(m.addr) then return { err = "not connected (" .. m.addr:sub(1, 8) .. ")" } end
  local p = px(m.addr)
  if not p then return { err = "not connected" } end
  if m.kind == "rs" then
    local ok, lvl = pcall(p.getOutput, m.side or 1)
    if not ok then return { err = tostring(lvl) } end
    return { allowed = ((tonumber(lvl) or 0) > 0) ~= (m.inv == true), level = lvl }
  end
  local i = {}
  local ok, a = pcall(function() return p.isWorkAllowed() end)
  if ok then i.allowed = a and true or false end
  ok, a = pcall(function() return p.isMachineActive() end)
  if ok then i.active = a and true or false end
  ok, a = pcall(function() return p.getWorkProgress() end)
  if ok then i.prog = tonumber(a) end
  ok, a = pcall(function() return p.getWorkMaxProgress() end)
  if ok then i.maxp = tonumber(a) end
  if i.allowed == nil and i.active == nil then i.err = "does not answer" end
  return i
end

function X.setMachine(m, on)
  if not m then return false, "no machine chosen" end
  local p = exists(m.addr) and px(m.addr)
  if not p then return false, "not connected" end
  if m.kind == "rs" then
    local lvl = (on ~= (m.inv == true)) and 15 or 0
    return pcall(p.setOutput, m.side or 1, lvl)
  end
  if not p.setWorkAllowed then return false, "this machine cannot be switched (no setWorkAllowed)" end
  return pcall(p.setWorkAllowed, on)
end

-- probe file: what this pack's AE components really return ---------------------------------------
local function dumpTo(L, v, ind, depth, limit)
  if #L > limit then return end
  if isIter(v) then
    local all = listOf(v)
    L[#L + 1] = ind .. "(iterator object, " .. #all .. " entries, first 3 shown)"
    v = { all[1], all[2], all[3] }
  end
  if type(v) ~= "table" then L[#L + 1] = ind .. tostring(v) .. "  (" .. type(v) .. ")"; return end
  if depth <= 0 then L[#L + 1] = ind .. "{...}"; return end
  local n = 0
  for k, x in pairs(v) do
    n = n + 1
    if n > 40 then L[#L + 1] = ind .. "... more"; break end
    if type(x) == "table" then
      L[#L + 1] = ind .. tostring(k) .. " = {"
      dumpTo(L, x, ind .. "  ", depth - 1, limit)
      L[#L + 1] = ind .. "}"
    else
      L[#L + 1] = ind .. tostring(k) .. " = " .. tostring(x) .. "  (" .. type(x) .. ")"
    end
    if #L > limit then return end
  end
end

function X.probe(path)
  local L = { "lymae probe file   " .. fmtStamp(now()) }
  local function sec(s) L[#L + 1] = ""; L[#L + 1] = "== " .. s end
  local function methods(addr)
    local names = {}
    for k in pairs(methodsOf(addr)) do names[#names + 1] = k end
    table.sort(names)
    L[#L + 1] = "methods: " .. table.concat(names, ", ")
  end
  local m = me()
  sec("ME component: " .. tostring(meAddr) .. "  " .. tostring(meType))
  if m then
    methods(meAddr)
    sec("getItemsInNetwork({isCraftable=true})  first 2")
    local ok, l = pcall(m.getItemsInNetwork, { isCraftable = true })
    if ok and type(l) == "table" then
      L[#L + 1] = "count: " .. tostring(l.n or #l)
      L[#L + 1] = "  [1]"; dumpTo(L, l[1], "    ", 4, 400); L[#L + 1] = "  [2]"; dumpTo(L, l[2], "    ", 4, 400)
    else L[#L + 1] = tostring(l) end
    l = nil
    sec("getFluidsInNetwork()  first 3")
    ok, l = pcall(m.getFluidsInNetwork)
    if ok and type(l) == "table" then
      L[#L + 1] = "count: " .. tostring(l.n or #l)
      for i = 1, 3 do L[#L + 1] = "  [" .. i .. "]"; dumpTo(L, l[i], "    ", 3, 500) end
    else L[#L + 1] = tostring(l) end
    l = nil
    sec("getCraftables()  first 3 (the entry, then its stack)")
    ok, l = pcall(m.getCraftables)
    if ok and type(l) == "table" then
      L[#L + 1] = "count: " .. tostring(l.n or #l)
      for i = 1, 3 do
        local c = l[i]
        if c then
          L[#L + 1] = "  [" .. i .. "] entry (" .. type(c) .. ")"
          dumpTo(L, c, "    ", 2, 700)
          L[#L + 1] = "  [" .. i .. "] stack"
          dumpTo(L, craftableStack(c) or "none found", "    ", 3, 700)
        end
      end
    else L[#L + 1] = tostring(l) end
    l = nil
    sec("item lookup form in use: " .. tostring(itemForm) .. "   allItems: " .. tostring(m.allItems ~= nil))
  end
  local t = term()
  sec("ME Interface Terminal: " .. tostring(termAddr))
  if t then
    methods(termAddr)
    if t.getInterfaces then
      local ok, l = pcall(t.getInterfaces)
      if ok and type(l) == "table" then
        L[#L + 1] = "returned: " .. (isIter(l) and "an iterator object" or "a plain list")
        local all = listOf(l)
        local n = 0
        for _ in pairs(all) do n = n + 1 end
        L[#L + 1] = "interfaces: " .. n .. "   (first 2 below)"
        local i = 0
        for k, v in pairs(all) do
          i = i + 1
          if i > 2 then break end
          local keys = {}
          if type(v) == "table" then for kk in pairs(v) do keys[#keys + 1] = tostring(kk) end end
          table.sort(keys)
          L[#L + 1] = "[" .. tostring(k) .. "]  keys: " .. table.concat(keys, ", ")
          L[#L + 1] = "[" .. tostring(k) .. "] = {"
          dumpTo(L, v, "  ", 7, #L + 260)
          L[#L + 1] = "}"
        end
        all = nil
      else L[#L + 1] = "getInterfaces failed: " .. tostring(l) end
    end
  end
  sec("interfaces walked: " .. tostring(X.pat.interfaces) .. "   patterns read: " .. tostring(X.pat.n) .. "   outputs: " .. tostring(X.pat.outputs) ..
    "   inexact: " .. tostring(X.pat.inexact) .. "   error: " .. tostring(X.pat.err))
  writeFile(path, table.concat(L, "\n") .. "\n")
  return #L
end

return X
end)()


------------------------------------------------- APPLIED ENERGISTICS APP
-- Tabs:  Level Control  (hysteresis rules)  |  Craftables  |  Setup
-- Own function = own local-variable budget.
AE = (function()
local PX0, PY0, PW, PH = 16, 7, 140, 36    -- tab panel (same as My Computer)
local X0, XW = PX0 + 2, PW - 4             -- inside the panel
local AMBER, FIELD, ALT = 0xA06000, 0xFFFFC0, 0xF0F0F0
local GOOD, BAD = K.green, K.red
local up = computer.uptime
local tab = "level"                        -- "level" | "craft" | "setup"
local reg = {}
local fields = {}                          -- field id -> redraw function

-- saved in DATA_FILE
local D = { rules = {}, pins = {}, pinInfo = {}, log = {}, sel = 1, filter = 1, sort = 1 }
-- live
local S = { focus = nil, input = "", flash = nil, flashAt = 0, search = "", pinScroll = 0, allScroll = 0,
            view = nil, viewGen = -1, viewAt = 0, lastPoll = -99, lastCast = 0, lastSave = 0,
            mlist = nil, pinSet = {}, dirty = false }

local function visible() return activeApp == "ae" and not overlay and not LOCK.isLocked() end
local function flash(m) S.flash, S.flashAt = m, up() end
local function fmtAmt(n, fluid)
  if n == nil then return "--" end
  return commas(n) .. (fluid and " L" or "")
end

local function save()
  local keep = {}
  for k, v in pairs(D) do keep[k] = v end
  local ok, s = pcall(serialization.serialize, keep)
  if ok then writeFile(CONFIG.DATA_FILE, s) end
  S.lastSave = up()
end

local function logLine(s, kind)
  local L = D.log
  L[#L + 1] = { t = now(), s = s, k = kind }
  while #L > (CONFIG.LOG_MAX or 60) do table.remove(L, 1) end
end

local function rebuildPins()
  S.pinSet = {}
  for _, k in ipairs(D.pins) do S.pinSet[k] = true end
end

local function newRule(key, label, fluid)
  return { key = key, label = label, fluid = fluid, low = fluid and 100000 or 1000,
           high = fluid and 500000 or 10000, mode = "auto", hist = {} }
end

local function load()
  local raw = readFile(CONFIG.DATA_FILE)
  if raw then
    local ok, t = pcall(serialization.unserialize, raw)
    if ok and type(t) == "table" then for k, v in pairs(t) do D[k] = v end end
  end
  for _, k in ipairs({ "rules", "pins", "pinInfo", "log" }) do
    if type(D[k]) ~= "table" then D[k] = {} end
  end
  if #D.rules == 0 and not D.started then
    -- first start: the Sulfuric Acid rule; the machine is picked below
    D.rules[1] = newRule("f:sulfuric acid", "Sulfuric Acid", true)
    D.rules[1].findMachine = "chemical"
  end
  D.started = true
  for _, r in ipairs(D.rules) do if type(r.hist) ~= "table" then r.hist = {} end end
  D.sel = max(1, min(tonumber(D.sel) or 1, max(1, #D.rules)))
  D.filter, D.sort = tonumber(D.filter) or 1, tonumber(D.sort) or 1
  rebuildPins()
end

local function rule() return D.rules[D.sel] end

-- Level Control logic -------------------------------------------------------------------
local MODES = { { "auto", "Automatic (use the levels)" }, { "on", "Always ON" }, { "off", "Always OFF" },
                { "watch", "Watch only (do not switch)" } }
local function modeName(m) for _, v in ipairs(MODES) do if v[1] == m then return v[2] end end return "?" end

local function control(r)
  -- first start: find the machine by name (e.g. the Large Chemical Reactor)
  if not r.mach and r.findMachine then
    for _, m in ipairs(AEX.machines()) do
      if m.kind == "gt" and m.name:lower():find(r.findMachine, 1, true) then
        r.mach = { kind = "gt", addr = m.addr, name = m.name }
        r.findMachine = nil
        logLine(r.label .. ": machine found - " .. m.name .. " [" .. m.addr:sub(1, 8) .. "]")
        save()
        break
      end
    end
  end
  if not r.key then
    r.amt, r.why, r.bad = nil, "Choose what to watch: type a name in 'Find another' and press Enter.", true
    r.minfo = r.mach and AEX.readMachine(r.mach) or nil
    return
  end
  local amt, err = AEX.amountOf(r.key)
  r.minfo = r.mach and AEX.readMachine(r.mach) or nil
  if amt == nil then
    r.amt, r.why, r.bad = nil, "Cannot read AE2: " .. tostring(err), true
    return
  end
  r.amt, r.bad = amt, false
  if not r.mach then r.why, r.bad = "No machine chosen - pick one with Machine ◄ ►.", true; return end
  local i = r.minfo
  if i.err then r.why, r.bad = "Machine " .. i.err .. ".", true; return end
  if r.mode == "watch" then r.why = "Watch only - the machine is not switched."; return end
  local cur, want = i.allowed, i.allowed
  if r.mode == "on" then want, r.why = true, "Always ON (mode)."
  elseif r.mode == "off" then want, r.why = false, "Always OFF (mode)."
  elseif (r.low or 0) >= (r.high or 0) then
    r.why, r.bad = "'Turn ON below' must be smaller than 'Turn OFF at'.", true
    return
  elseif amt < r.low then want, r.why = true, "Below " .. fmtAmt(r.low, r.fluid) .. "  ->  machine ON."
  elseif amt >= r.high then want, r.why = false, "Reached " .. fmtAmt(r.high, r.fluid) .. "  ->  machine OFF."
  else
    r.why = "Between the levels  ->  machine stays " .. (cur == true and "ON" or (cur == false and "OFF" or "as it is")) .. "."
  end
  if want ~= nil and want ~= cur then
    local ok, e = AEX.setMachine(r.mach, want)
    if ok then
      r.last = { t = now(), on = want, amt = amt }
      logLine(r.label .. ": machine " .. (want and "ON" or "OFF") .. " at " .. fmtAmt(amt, r.fluid), want and "good" or nil)
      r.minfo = AEX.readMachine(r.mach)
      save()
    else
      r.why, r.bad = "Could not switch the machine: " .. tostring(e), true
      logLine(r.label .. ": could not switch the machine: " .. tostring(e), "bad")
    end
  end
end

local function record(r)
  local t = up()
  if r.amt == nil or (r.histT and t - r.histT < (CONFIG.HISTORY_STEP or 30)) then return end
  r.histT = t
  local h = r.hist
  h[#h + 1] = r.amt
  while #h > 120 do table.remove(h, 1) end
end

-- name, color of a rule's machine state
local function ruleState(r)
  if r.mode == "watch" then return "WATCHING", K.sh end
  if not r.mach then return "NO MACHINE", BAD end
  local i = r.minfo
  if not i then return "...", K.sh end
  if i.err then return "OFFLINE", BAD end
  if i.allowed == true then return i.active == false and "ON (idle)" or "ON", GOOD end
  if i.allowed == false then return "OFF", AMBER end
  return "?", K.sh
end

local function alert()
  for _, r in ipairs(D.rules) do if r.bad then return true end end
  return AEX.err ~= nil
end

-- numbers like 100000, 100k, 1.5M, 2,000,000, 64000L
local function parseNum(s)
  s = tostring(s):lower():gsub("[,%s_]", ""):gsub("mb$", ""):gsub("l$", "")
  local n, suf = s:match("^([%d%.]+)([kmgt]?)$")
  n = tonumber(n)
  if not n then return nil end
  return floor(n * (({ k = 1e3, m = 1e6, g = 1e9, t = 1e12 })[suf] or 1) + 0.5)
end

-- drawing helpers -------------------------------------------------------------------------
local function clock(t)
  if not t or t < 1e9 then return "--" end
  local e = toEastern(t)
  if SETTINGS.clock24 then return string.format("%02d:%02d:%02d", e.hour, e.min, e.sec) end
  local h, ap = h12(e)
  return string.format("%2d:%02d:%02d %s", h, e.min, e.sec, ap)
end

local function cycler(x, y, w, value, onStep)
  text(x, y, " ◄ ", K.black, 0xD4D0C8)
  textW(x + 3, y, w, value, K.navy, K.white, "center")
  text(x + 3 + w, y, " ► ", K.black, 0xD4D0C8)
  region(reg, x, y, 3, 1, function() onStep(-1) end)
  region(reg, x + 3 + w, y, 3, 1, function() onStep(1) end)
end

local function link(x, y, label, fn)
  text(x, y, label, K.black, 0xD4D0C8)
  region(reg, x, y, unicode.len(label), 1, fn)
  return x + unicode.len(label) + 1
end

-- a text box; click to type, Enter to confirm, Esc to cancel
local function field(id, x, y, w, value, hint)
  local function draw()
    if S.focus == id then
      local s = S.input
      if unicode.len(s) > w - 3 then s = unicode.sub(s, -(w - 3)) end
      textW(x, y, w, " " .. s .. "_", K.black, FIELD)
    else
      local v = tostring(value or "")
      textW(x, y, w, " " .. (v ~= "" and v or (hint or "")), v ~= "" and K.navy or K.sh, K.white)
    end
  end
  fields[id] = draw
  draw()
  region(reg, x, y, w, 1, function()
    S.focus = id
    S.input = (id == "search") and S.search or ""
    draw()
  end)
end

-- Level Control tab ---------------------------------------------------------------------
local RL_ROWS = 22
local GX, GW = X0 + 52, XW - 52           -- detail box

local function drawRuleRows()
  local x, y = X0, PY0 + 1
  for i = 1, RL_ROWS do
    local r = D.rules[i]
    local yy = y + 1 + i
    local sel = (i == D.sel)
    local b, f = sel and K.navy or K.white, sel and K.white or K.black
    if r then
      local name, col = ruleState(r)
      textW(x + 1, yy, 22, " " .. tostring(r.label), f, b)
      textW(x + 23, yy, 14, r.amt and shortL(r.amt) .. (r.fluid and " L" or "") or "--", f, b, "right")
      textW(x + 37, yy, 12, "  " .. name, sel and K.white or col, b)
    else
      textW(x + 1, yy, 48, (i == 1) and " (no rules - press Add rule)" or "", K.sh, K.white)
    end
  end
end

local function drawBar(r, x, y, w)
  local high = max(1, r.high or 1)
  local scale = max(high * 1.25, r.amt or 0)
  local frac = (r.amt or 0) / scale
  local col = (r.amt == nil) and K.sh or ((r.amt < (r.low or 0)) and BAD or ((r.amt >= high) and GOOD or AMBER))
  local n = floor(frac * w + 0.5)
  for row = 0, 1 do
    fill(x, y + row, n, 1, col)
    fill(x + n, y + row, w - n, 1, 0xE0E0E0)
  end
  local lx = x + min(w - 1, floor((r.low or 0) / scale * w))
  local hx = x + min(w - 1, floor(high / scale * w))
  fill(x, y + 2, w, 1, K.face)
  text(lx, y + 2, "▲ON", AMBER, K.face)
  text(min(hx, x + w - 4), y + 2, "▲OFF", K.navy, K.face)
  local lb = (lx < x + w and lx >= x) and ((lx - x) < n and col or 0xE0E0E0)
  text(lx, y, "┃", K.black, lb); text(lx, y + 1, "┃", K.black, lb)
  local hb = (hx - x) < n and col or 0xE0E0E0
  text(hx, y, "┃", K.black, hb); text(hx, y + 1, "┃", K.black, hb)
end

local function drawGraph(r, x, y, w, rows)
  local cv = newCanvas(w, rows * 2, K.white)
  local h = r.hist or {}
  local top = max(1, (r.high or 1) * 1.25)
  for _, v in ipairs(h) do if v > top then top = v end end
  local function py(v) return rows * 2 - floor(max(0, v) / top * (rows * 2 - 1) + 0.5) end
  local ly, hy = py(r.low or 0), py(r.high or 0)
  for xx = 1, w, 2 do cset(cv, xx, ly, 0xFFB060); cset(cv, xx, hy, 0x8080FF) end
  local n = #h
  local lx, lyy
  for i = 1, n do
    local xx = w - (n - i) * max(1, floor(w / 120))
    if xx >= 1 then
      local yy = py(h[i])
      if lx then cline(cv, lx, lyy, xx, yy, K.navy) else cset(cv, xx, yy, K.navy) end
      lx, lyy = xx, yy
    end
  end
  crender(cv, x, y)
end

local function drawRuleLive()
  local r = rule()
  local x, y, w = GX + 2, PY0 + 1, GW - 4
  if not r then return end
  local name, col = ruleState(r)
  textW(x, y + 13, 16, "In AE2:", K.black, K.face)
  textW(x + 16, y + 13, 30, fmtAmt(r.amt, r.fluid), r.amt and K.navy or K.sh, K.face)
  textW(x + 46, y + 13, w - 46, " Machine: " .. name .. " ", K.white, col)
  drawBar(r, x, y + 15, w)
  local i = r.minfo or {}
  local work = ""
  if i.err then work = "Machine " .. i.err
  elseif i.active and i.prog and i.maxp and i.maxp > 0 then
    work = string.format("Working: %d%%  (%s of %s)", floor(i.prog / i.maxp * 100 + 0.5), fmtDurLong(i.prog / 20), fmtDurLong(i.maxp / 20))
  elseif i.allowed ~= nil then work = (i.allowed and "Allowed to work" or "Switched off") .. (i.active == false and ", not working right now" or "")
  end
  textW(x, y + 19, w, work, K.sh, K.face)
  textW(x, y + 20, w, tostring(r.why or "Waiting for the first check..."), r.bad and BAD or K.black, K.face)
  local last = r.last
  textW(x, y + 21, w, last and ("Last switched " .. (last.on and "ON" or "OFF") .. " at " .. fmtStamp(last.t) ..
    "  (" .. fmtAmt(last.amt, r.fluid) .. ")") or "Not switched by this program yet.", K.sh, K.face)
  drawGraph(r, x, y + 24, w, 7)
  textW(x, y + 31, w, "Last " .. floor(#(r.hist or {}) * (CONFIG.HISTORY_STEP or 30) / 60) ..
    " min    orange dots = Turn ON below    blue dots = Turn OFF at", K.sh, K.face)
end

local function setTarget(e)
  local r = rule()
  if not r then return end
  r.key, r.label, r.fluid, r.hist, r.amt = e.k, e.l, e.f, {}, nil
  save()
  flash("Now watching " .. e.l)
  logLine("Rule now watches " .. e.l)
  drawAll()
end

local function finder(textv)
  local list = AEX.find(textv)
  if #list == 0 then
    flash("Nothing found for '" .. textv .. "' (fluids, craftables, or the exact item name)")
    drawAll()
    return
  end
  local items = {}
  for _, e in ipairs(list) do
    items[#items + 1] = { e.l .. (e.f and "   (fluid)" or ""), function() setTarget(e) end }
  end
  popupMenu(GX + 12, PY0 + 3, items)
end

local function stepMachine(d)
  local r = rule()
  if not r then return end
  local list = AEX.machines()
  if #list == 0 then flash("No machine found: put an Adapter next to the controller."); drawAll(); return end
  local idx = 0
  for i, m in ipairs(list) do
    if r.mach and m.addr == r.mach.addr and m.side == r.mach.side then idx = i end
  end
  idx = (idx - 1 + d) % #list + 1
  local m = list[idx]
  r.mach = { kind = m.kind, addr = m.addr, side = m.side, name = m.name }
  r.findMachine, r.minfo = nil, AEX.readMachine(r.mach)
  save()
  drawAll()
end

local function drawLevel(full)
  local x, y = X0, PY0 + 1
  if full then
    bevel(x, y, 50, RL_ROWS + 3, "sunken", K.face, K.white)
    textW(x + 1, y + 1, 22, " Watching", K.black, K.face)
    textW(x + 23, y + 1, 14, "In AE2", K.black, K.face, "right")
    textW(x + 37, y + 1, 12, "  Machine", K.black, K.face)
    for i = 1, RL_ROWS do
      region(reg, x + 1, y + 1 + i, 48, 1, function()
        if D.rules[i] then D.sel = i; S.focus = nil; drawAll() end
      end)
    end
    button(reg, x, y + RL_ROWS + 4, 16, "Add rule", function()
      local r = newRule(nil, "(choose what to watch)", false)
      D.rules[#D.rules + 1] = r
      D.sel = #D.rules
      save(); flash("Rule added - type what it should watch in Target and press Enter")
      drawAll()
    end)
    button(reg, x + 17, y + RL_ROWS + 4, 16, "Remove rule", function()
      local r = rule()
      if not r then return end
      dialog("Remove Rule", { "Stop watching '" .. tostring(r.label) .. "'?",
        "The machine keeps the state it has now." }, {
        { "Yes", function()
            table.remove(D.rules, D.sel)
            D.sel = max(1, min(D.sel, #D.rules))
            logLine("Rule removed: " .. tostring(r.label))
            save()
          end },
        { "No" } })
    end)
    button(reg, x + 34, y + RL_ROWS + 4, 16, "Check now", function() S.lastPoll = -99; flash("Checking..."); drawAll() end)

    local r = rule()
    groupBox(GX, y, GW, 34, r and ("Rule " .. D.sel .. ":  " .. tostring(r.label)) or "Rule")
    local gx, gw = GX + 2, GW - 4
    if not r then
      textW(gx, y + 2, gw, "No rule selected. Press Add rule.", K.sh, K.face)
    else
      textW(gx, y + 2, 16, "Target:", K.black, K.face)
      textW(gx + 16, y + 2, gw - 16, tostring(r.label) .. (r.fluid and "   (fluid, amounts in L)" or "   (item)"),
        K.navy, K.face)
      textW(gx, y + 3, 16, "Find another:", K.black, K.face)
      field("find", gx + 16, y + 3, 36, "", "(type a name, press Enter)")
      textW(gx + 54, y + 3, gw - 54, "fluids, craftables or", K.sh, K.face)
      textW(gx + 54, y + 4, gw - 54, "an exact item name", K.sh, K.face)
      textW(gx, y + 5, 16, "Turn ON below:", K.black, K.face)
      field("low", gx + 16, y + 5, 20, fmtAmt(r.low, r.fluid), "")
      textW(gx + 38, y + 5, gw - 38, "the machine starts below this", K.sh, K.face)
      textW(gx, y + 6, 16, "Turn OFF at:", K.black, K.face)
      field("high", gx + 16, y + 6, 20, fmtAmt(r.high, r.fluid), "")
      textW(gx + 38, y + 6, gw - 38, "and stops when it reaches this", K.sh, K.face)
      textW(gx, y + 8, 16, "Machine:", K.black, K.face)
      cycler(gx + 16, y + 8, gw - 22, AEX.machineText(r.mach), stepMachine)
      if r.mach and r.mach.kind == "rs" then
        textW(gx, y + 9, 16, "", K.black, K.face)
        link(gx + 16, y + 9, r.mach.inv and " Signal ON = machine OFF (click) " or " Signal ON = machine ON (click) ",
          function() r.mach.inv = not r.mach.inv; save(); drawAll() end)
      else
        textW(gx, y + 9, gw, "GregTech machines are switched like a soft mallet (Adapter on the controller).", K.sh, K.face)
      end
      textW(gx, y + 10, 16, "Mode:", K.black, K.face)
      cycler(gx + 16, y + 10, 30, modeName(r.mode), function(d)
        local idx = 1
        for i, m in ipairs(MODES) do if m[1] == r.mode then idx = i end end
        r.mode = MODES[(idx - 1 + d) % #MODES + 1][1]
        logLine(r.label .. ": mode " .. modeName(r.mode))
        save(); S.lastPoll = -99; drawAll()
      end)
      text(gx, y + 12, string.rep("─", gw), K.sh, K.face)
    end
  end
  drawRuleRows()
  drawRuleLive()
end

-- Craftables tab ---------------------------------------------------------------------------
local FILTERS = { "All", "Can craft", "Cannot craft", "Not checked", "Items", "Fluids" }
local SORTS = { "Name", "Amount (most)", "Amount (least)", "Status" }
local PIN_ROWS, ALL_ROWS = 12, 14
local PIN_Y, ALL_Y = PY0 + 3, PY0 + 18     -- top of the two boxes

local function statusOf(k) local st = AEX.status[k]; return st and st.s or nil end

local function buildView()
  local q = S.search:lower()
  local f = D.filter
  local v = {}
  for _, e in ipairs(AEX.list) do
    if q == "" or e.ll:find(q, 1, true) then
      local s = statusOf(e.k)
      if f == 1 or (f == 2 and s == "can") or (f == 3 and s == "cannot") or (f == 4 and (s == nil or s == "unknown"))
        or (f == 5 and not e.f) or (f == 6 and e.f) then
        v[#v + 1] = e
      end
    end
  end
  local so = D.sort
  local rank = { can = 1, cannot = 2, unknown = 3 }
  table.sort(v, function(a, b)
    if so == 2 and (a.a or -1) ~= (b.a or -1) then return (a.a or -1) > (b.a or -1) end
    if so == 3 and (a.a or 0) ~= (b.a or 0) then return (a.a or 0) < (b.a or 0) end
    if so == 4 then
      local ra, rb = rank[statusOf(a.k)] or 4, rank[statusOf(b.k)] or 4
      if ra ~= rb then return ra < rb end
    end
    return a.ll < b.ll
  end)
  S.view, S.viewGen, S.viewAt = v, AEX.listGen, up()
end

local function view()
  -- amounts and statuses change all the time: rebuild every few seconds
  if not S.view or S.viewGen ~= AEX.listGen or up() - S.viewAt > 3 then buildView() end
  return S.view
end

local function togglePin(k, label, fl)
  if S.pinSet[k] then
    for i, v in ipairs(D.pins) do if v == k then table.remove(D.pins, i); break end end
    D.pinInfo[k] = nil
    flash("Unpinned " .. label)
  else
    if #D.pins >= (CONFIG.MAX_PINS or 60) then flash("At most " .. CONFIG.MAX_PINS .. " pins (CONFIG.MAX_PINS)"); return end
    D.pins[#D.pins + 1] = k
    D.pinInfo[k] = { l = label, f = fl }
    flash("Pinned " .. label)
  end
  rebuildPins()
  save()
end

local function statusCell(k)
  local st = AEX.status[k]
  if not st then return "checking...", K.sh, "" end
  if st.s == "can" then return "Can craft", GOOD, "" end
  if st.s == "cannot" then return "Cannot craft", BAD, "needs " .. AEX.labelOf(st.m) end
  return "?", AMBER, tostring(st.m or "")
end

local function craftRow(y, k, pinned, alt, gone)
  local b = alt and ALT or K.white
  local x = X0
  if not k then fill(x + 1, y, XW - 3, 1, b); return end
  local e = AEX.byKey[k]
  local info = D.pinInfo[k]
  local label = (e and e.l) or (info and info.l) or AEX.labelOf(k)
  local fl = (e and e.f) or (info and info.f) or AEX.isFluidKey(k)
  text(x + 1, y, pinned and " ★ " or " ☆ ", pinned and 0xC08000 or K.sh, b)
  textW(x + 4, y, 52, " " .. label, K.black, b)
  textW(x + 56, y, 6, fl and "fluid" or "item", K.sh, b)
  textW(x + 62, y, 20, e and fmtAmt(e.a, fl) or "--", K.black, b, "right")
  if not e then
    textW(x + 82, y, 15, "  not craftable", K.sh, b)
    textW(x + 97, y, XW - 100, "  (no pattern seen in the last scan)", K.sh, b)
    return
  end
  local s, col, more = statusCell(k)
  textW(x + 82, y, 15, "  " .. s, col, b)
  textW(x + 97, y, XW - 100, "  " .. more, K.sh, b)
end

local function pinRows()
  local n = #D.pins
  S.pinScroll = max(0, min(S.pinScroll, max(0, n - PIN_ROWS)))
  for r = 1, PIN_ROWS do
    craftRow(PIN_Y + 1 + r, D.pins[S.pinScroll + r], true, r % 2 == 0)
  end
  if n == 0 then textW(X0 + 5, PIN_Y + 2, 70, " Nothing pinned yet - click ☆ in front of a craftable below.", K.sh, K.white) end
  local more = (n > PIN_ROWS) and string.format("%d-%d of %d  ", S.pinScroll + 1, min(n, S.pinScroll + PIN_ROWS), n) or ""
  textW(X0 + XW - 30, PIN_Y + 1, 22, more .. "", K.sh, K.face, "right")
end

local function allRows()
  local v = view()
  S.allScroll = max(0, min(S.allScroll, max(0, #v - ALL_ROWS)))
  for r = 1, ALL_ROWS do
    local e = v[S.allScroll + r]
    craftRow(ALL_Y + 1 + r, e and e.k, e and S.pinSet[e.k], r % 2 == 0)
  end
  if #v == 0 then
    textW(X0 + 5, ALL_Y + 2, 90, #AEX.list == 0 and (" " .. (AEX.task and ("AE2 is being read: " .. AEX.task) or AEX.scan.msg))
      or " Nothing matches the search / filter.", K.sh, K.white)
  end
  local more = string.format("%d-%d of %d  ", min(#v, S.allScroll + 1), min(#v, S.allScroll + ALL_ROWS), #v)
  textW(X0 + XW - 30, ALL_Y + 1, 22, more, K.sh, K.face, "right")
end

local function wantKeys()
  local w = {}
  for r = 1, PIN_ROWS do local k = D.pins[S.pinScroll + r]; if k then w[#w + 1] = k end end
  for _, k in ipairs(D.pins) do w[#w + 1] = k end
  local v = S.view or {}
  for r = 1, ALL_ROWS do local e = v[S.allScroll + r]; if e then w[#w + 1] = e.k end end
  AEX.want = w
end

local function craftCounts()
  local can, cannot = 0, 0
  for _, e in ipairs(AEX.list) do
    local s = statusOf(e.k)
    if s == "can" then can = can + 1 elseif s == "cannot" then cannot = cannot + 1 end
  end
  local t = AEX.task and ("  ·  " .. AEX.task) or ""
  if AEX.scan.deepTotal > 0 and AEX.scan.deepDone < AEX.scan.deepTotal and AEX.task == "reading every craftable" then
    t = string.format("  ·  reading every craftable %d/%d", AEX.scan.deepDone, AEX.scan.deepTotal)
  end
  textW(X0, PY0 + 2, XW, #AEX.list .. " craftable  ·  " .. can .. " can  ·  " .. cannot .. " cannot" .. t,
    K.sh, K.face, "right")
end

local function boxHeader(y, title)
  local x = X0
  textW(x + 1, y, 3, "", K.black, K.face)
  textW(x + 4, y, 52, " " .. title, K.black, K.face)
  textW(x + 56, y, 6, "Type", K.black, K.face)
  textW(x + 62, y, 20, "In system", K.black, K.face, "right")
  textW(x + 82, y, 15, "  Status", K.black, K.face)
  textW(x + 97, y, XW - 100, "  Missing / note", K.black, K.face)
end

local function drawCraft(full)
  if full then
    local x = X0
    textW(x, PY0 + 1, 8, "Search:", K.black, K.face)
    field("search", x + 8, PY0 + 1, 26, S.search, "(name)")
    textW(x + 35, PY0 + 1, 5, "Show:", K.black, K.face)
    cycler(x + 40, PY0 + 1, 13, FILTERS[D.filter] or "All", function(d)
      D.filter = (D.filter - 1 + d) % #FILTERS + 1; S.view = nil; S.allScroll = 0; save(); drawAll()
    end)
    textW(x + 60, PY0 + 1, 5, "Sort:", K.black, K.face)
    cycler(x + 65, PY0 + 1, 14, SORTS[D.sort] or "Name", function(d)
      D.sort = (D.sort - 1 + d) % #SORTS + 1; S.view = nil; save(); drawAll()
    end)
    link(x + 86, PY0 + 1, " Re-check ", function() AEX.recheck(); flash("Checking everything again..."); drawAll() end)
    bevel(x, PIN_Y, XW, PIN_ROWS + 3, "sunken", K.face, K.white)
    boxHeader(PIN_Y + 1, "Pinned")
    text(x + XW - 7, PIN_Y + 1, " ▲ ▼ ", K.black, K.face)
    region(reg, x + XW - 6, PIN_Y + 1, 1, 1, function() S.pinScroll = S.pinScroll - PIN_ROWS; pinRows() end)
    region(reg, x + XW - 4, PIN_Y + 1, 1, 1, function() S.pinScroll = S.pinScroll + PIN_ROWS; pinRows() end)
    bevel(x, ALL_Y, XW, ALL_ROWS + 3, "sunken", K.face, K.white)
    boxHeader(ALL_Y + 1, "All craftables  (click ☆ to pin)")
    text(x + XW - 7, ALL_Y + 1, " ▲ ▼ ", K.black, K.face)
    region(reg, x + XW - 6, ALL_Y + 1, 1, 1, function() S.allScroll = S.allScroll - ALL_ROWS; allRows() end)
    region(reg, x + XW - 4, ALL_Y + 1, 1, 1, function() S.allScroll = S.allScroll + ALL_ROWS; allRows() end)
    for r = 1, PIN_ROWS do
      region(reg, x + 1, PIN_Y + 1 + r, 3, 1, function()
        local k = D.pins[S.pinScroll + r]
        if k then togglePin(k, AEX.labelOf(k), AEX.isFluidKey(k)); drawAll() end
      end)
    end
    for r = 1, ALL_ROWS do
      region(reg, x + 1, ALL_Y + 1 + r, 3, 1, function()
        local e = (S.view or {})[S.allScroll + r]
        if e then togglePin(e.k, e.l, e.f); drawAll() end
      end)
    end
  end
  allRows()       -- first: builds the view
  pinRows()
  craftCounts()
  wantKeys()
end

-- Setup tab -------------------------------------------------------------------------------
local function drawSetupLive()
  local x, y, w = X0 + 2, PY0 + 2, 62
  local ma, mt = AEX.meInfo()
  local ta = AEX.termInfo()
  local smode, sage = AEX.snapInfo()
  local rows = {
    { "ME access:", ma and (mt .. "  " .. ma:sub(1, 8)) or "NOT FOUND - Adapter next to an ME Interface", ma and K.black or BAD },
    { "Item lookups:", AEX.itemForm() and ("getItemInNetwork (" .. AEX.itemForm() .. ")") or "not needed yet", K.black },
    { "Craftables:", #AEX.list .. "   (" .. tostring(AEX.scan.msg) .. ")", K.black },
    { "  amounts read:", fmtStamp(AEX.scan.at), K.black },
    { "  full reread:", AEX.scan.deepAt and fmtStamp(AEX.scan.deepAt) or (CONFIG.DEEP_SCAN and "running / not yet" or "off"), K.black },
    { "Interface Terminal:", ta and ta:sub(1, 8) or "not found (needed for Can / Cannot craft)", ta and K.black or AMBER },
    { "Patterns read:", AEX.pat.n .. " patterns from " .. tostring(AEX.pat.interfaces or 0) .. " interfaces   " ..
      (AEX.pat.at and fmtStamp(AEX.pat.at) or ""), K.black },
    { "  inexact counts:", AEX.pat.inexact .. "  (count 0 in pattern = taken as 1)", K.sh },
    { "  problem:", AEX.pat.err or "none", AEX.pat.err and BAD or K.green },
    { "Stock for checks:", smode == "stream" and "one pass over the network (allItems)" or
      (smode == "full" and "one full read (getItemsInNetwork)" or (smode == "lookup" and "one lookup per item (slower)" or "not taken yet")), K.black },
    { "Background:", AEX.task or "idle", K.black },
    { "Worker error:", AEX.err or "none", AEX.err and BAD or K.green },
    { "Memory free:", string.format("%d K of %d K", floor(computer.freeMemory() / 1024), floor(computer.totalMemory() / 1024)), K.black },
  }
  for i, r in ipairs(rows) do
    textW(x, y + i - 1, 20, r[1], K.sh, K.face)
    textW(x + 20, y + i - 1, w - 20, r[2], r[3], K.face)
  end
end

local function drawLog()
  local x, y, w = X0, PY0 + 22, XW
  local L = D.log
  for r = 1, 11 do
    local e = L[#L - r + 1]
    local yy = y + r
    if e then
      textW(x + 2, yy, 14, clock(e.t), K.sh, K.face)
      textW(x + 16, yy, w - 18, tostring(e.s), e.k == "bad" and BAD or (e.k == "good" and GOOD or K.black), K.face)
    else
      textW(x + 2, yy, w - 4, (r == 1) and "(nothing yet)" or "", K.sh, K.face)
    end
  end
end

local function drawSetup(full)
  if full then
    groupBox(X0, PY0 + 1, 66, 20, "AE2 access")
    groupBox(X0 + 67, PY0 + 1, XW - 67, 20, "Machines this computer can switch")
    local list = AEX.machines()
    S.mlist = list
    local x, n = X0 + 69, 0
    for _, m in ipairs(list) do
      if m.kind == "gt" or m.side == 1 then
        n = n + 1
        if n <= 11 then
          textW(x, PY0 + 1 + n, XW - 71, (m.kind == "gt") and (m.name .. "  [" .. m.addr:sub(1, 8) .. "]")
            or ("Redstone I/O " .. m.addr:sub(1, 8) .. "  (any side)"), K.black, K.face)
        end
      end
    end
    if n == 0 then textW(x, PY0 + 2, XW - 71, "None. Put an Adapter next to each controller.", BAD, K.face) end
    local bx, by = X0 + 69, PY0 + 14
    button(reg, bx, by, 20, "Re-read AE2", function() AEX.rescan(); flash("Reading AE2 again..."); drawAll() end)
    button(reg, bx + 21, by, 20, "Read patterns", function() AEX.rescan("patterns"); flash("Reading patterns..."); drawAll() end)
    button(reg, bx + 42, by, 22, "Write probe file", function()
      flash("Writing the probe file..."); drawAll(); gpu.flush()
      local ok, n2 = pcall(AEX.probe, CONFIG.PROBE_FILE)
      dialog("Probe File", ok and { "Written to " .. CONFIG.PROBE_FILE .. " (" .. tostring(n2) .. " lines).", "",
        "It shows what this pack's AE2 components return. If the",
        "Craftables tab or the patterns look wrong, send me this file." } or { "Failed: " .. tostring(n2) },
        { { "OK" } })
    end)
    textW(bx, by + 3, XW - 71, "Probe file: what AE2 returns here (for fixing pattern reading).", K.sh, K.face)
    groupBox(X0, PY0 + 22, XW, 13, "Activity")
  end
  drawSetupLive()
  drawLog()
end

-- window -------------------------------------------------------------------------------------
local TABS = { { "level", "Level Control" }, { "craft", "Craftables" }, { "setup", "Setup" } }

local function drawTabs()
  fill(WX + 1, 5, WW - 2, 2, K.face)
  local x = PX0
  for _, t in ipairs(TABS) do
    local w = unicode.len(t[2]) + 4
    text(x, 5, "┌" .. string.rep("─", w - 2) .. "┐", K.hi, K.face)
    text(x, 6, "│", K.hi, K.face)
    textW(x + 1, 6, w - 2, t[2], (tab == t[1]) and K.navy or K.black, K.face, "center")
    text(x + w - 1, 6, "│", K.sh, K.face)
    region(reg, x, 5, w, 2, function() tab = t[1]; S.focus = nil; drawAll() end)
    t.x, t.w = x, w
    x = x + w
  end
end

local function drawStatusBar()
  local yy = WY + WH - 2
  if S.flash and up() - S.flashAt > 8 then S.flash = nil end
  fill(WX + 1, yy, WW - 2, 1, K.face)
  local on, bad = 0, 0
  for _, r in ipairs(D.rules) do
    if r.minfo and r.minfo.allowed then on = on + 1 end
    if r.bad then bad = bad + 1 end
  end
  local msg = S.flash or (#D.rules .. " rule(s), " .. on .. " machine(s) on" .. (bad > 0 and (", " .. bad .. " need attention") or ""))
  textW(WX + 2, yy, 70, msg, S.flash and K.navy or (bad > 0 and BAD or K.black), K.face)
  text(WX + 73, yy, "│", K.sh, K.face)
  textW(WX + 74, yy, 68, #AEX.list .. " craftables   " .. AEX.pat.n .. " patterns   " ..
    (AEX.task and ("busy: " .. AEX.task) or "idle"), K.black, K.face)
end

local function drawToolbar()
  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  local x = WX + 2
  x = link(x, WY + 2, " Refresh ", function() drawAll() end)
  x = link(x, WY + 2, " Re-read AE2 ", function() AEX.rescan(); flash("Reading AE2 again..."); drawAll() end)
end

local function drawWindow()
  reg, fields = {}, {}
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ Applied Energistics - Level Control & Craftables", true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(reg, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(reg, bx + 7, WY + 1, 3, 1, function() closeAE() end)
  drawToolbar()
  drawTabs()
  bevel(PX0, PY0, PW, PH, "raised", K.face, K.face)
  for _, t in ipairs(TABS) do      -- open the border under the active tab
    if tab == t[1] and t.x then text(t.x + 1, PY0, string.rep(" ", t.w - 2), K.black, K.face) end
  end
  if tab == "level" then drawLevel(true)
  elseif tab == "craft" then drawCraft(true)
  else drawSetup(true) end
  drawStatusBar()
end

-- typing ------------------------------------------------------------------------------------
local function commit(id, v)
  local r = rule()
  if id == "low" or id == "high" then
    if not r then return end
    local n = parseNum(v)
    if not n then flash("'" .. v .. "' is not a number (examples: 100000, 100k, 1.5M)")
    else
      r[id] = n
      flash((id == "low" and "Turn ON below " or "Turn OFF at ") .. fmtAmt(n, r.fluid))
      logLine(r.label .. ": " .. (id == "low" and "Turn ON below " or "Turn OFF at ") .. fmtAmt(n, r.fluid))
      save()
      S.lastPoll = -99
    end
    drawAll()
  elseif id == "find" then
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    if v ~= "" then finder(v) else drawAll() end
  else
    drawAll()
  end
end

local function key(ch, code)
  local id = S.focus
  if not id then return end
  if code == 28 or code == 156 then
    S.focus = nil
    commit(id, S.input)
    return
  elseif code == 1 then
    S.focus = nil
    if id == "search" then S.search, S.view = "", nil end
    drawAll()
    return
  elseif code == 14 then
    S.input = unicode.sub(S.input, 1, -2)
  elseif ch and ch >= 32 and ch < 127 and #S.input < 40 then
    S.input = S.input .. string.char(ch)
  end
  if id == "search" then
    S.search, S.view, S.allScroll = S.input, nil, 0
    allRows(); wantKeys()
  end
  if fields[id] then fields[id]() end
end

local function scroll(x, y, dir)
  if tab == "craft" then
    if y > PIN_Y + 1 and y <= PIN_Y + 1 + PIN_ROWS then
      S.pinScroll = S.pinScroll - dir * 3; pinRows(); wantKeys(); return true
    elseif y > ALL_Y + 1 and y <= ALL_Y + 1 + ALL_ROWS then
      S.allScroll = S.allScroll - dir * 3; allRows(); wantKeys(); return true
    end
  end
end

-- main loop hooks -------------------------------------------------------------------------------
local function broadcast()
  if not wlan or not CONFIG.STATUS_PORT then return end
  local t = up()
  if t - S.lastCast < (CONFIG.STATUS_EVERY or 10) then return end
  S.lastCast = t
  local out = {}
  for _, r in ipairs(D.rules) do
    out[#out + 1] = { label = r.label, amount = r.amt, low = r.low, high = r.high, fluid = r.fluid,
                      on = r.minfo and r.minfo.allowed, active = r.minfo and r.minfo.active }
  end
  pcall(wlan.broadcast, CONFIG.STATUS_PORT, "LYMAE", serialization.serialize({ rules = out, t = now() }))
end

local lastAlert = false
-- every main-loop pass: level checks (every LEVEL_POLL s) and a slice of background AE work
local function poll()
  local t = up()
  if t - S.lastPoll >= (CONFIG.LEVEL_POLL or 5) then
    S.lastPoll = t
    for _, r in ipairs(D.rules) do
      local ok, e = pcall(control, r)
      if not ok then r.why, r.bad = "Program error: " .. tostring(e), true end
      record(r)
    end
    S.dirty = true
    if t - S.lastSave > 300 then save() end
  end
  AEX.step(CONFIG.WORK_BUDGET)
  pcall(broadcast)
end

local function refresh()
  local a = alert()
  if a ~= lastAlert then
    lastAlert = a
    if not overlay and not LOCK.isLocked() then
      if activeApp == "ae" then drawAll() else drawTaskbar(now()) end
    end
    return
  end
  if S.dirty and visible() and tab == "level" and not S.focus then
    drawRuleRows(); drawRuleLive(); drawStatusBar()
    S.dirty = false
  end
end

-- once per second
local function tick()
  if not visible() then return end
  if tab == "craft" then
    if not S.focus or S.focus == "search" then allRows(); pinRows(); craftCounts(); wantKeys() end
  elseif tab == "setup" then drawSetupLive(); drawLog()
  end
  drawStatusBar()
end

local function onComponent(name, addr, ctype)
  AEX.forget(addr)
  if ctype == "gt_machine" or ctype == "redstone" then S.lastPoll = -99 end
  if ctype and ctype:find("^me_") then AEX.rescan() end
  if visible() and tab == "setup" then drawAll() end
end

return {
  drawWindow = drawWindow, tick = tick, poll = poll, refresh = refresh, load = load, save = save,
  onComponent = onComponent, key = key, scroll = scroll,
  regions = function() return reg end,
  resetRegions = function() reg = {} end,
  focus = function(v) if v == false then S.focus = nil end return S.focus ~= nil end,
  redrawFields = function() for _, f in pairs(fields) do f() end end,
  alert = alert,
  summary = function()
    local on = 0
    for _, r in ipairs(D.rules) do if r.minfo and r.minfo.allowed then on = on + 1 end end
    return #D.rules .. " rules, " .. on .. " on" .. (alert() and " - CHECK" or "")
  end,
  trayColor = function() return alert() and K.red or K.green end,
  busy = function() return AEX.busy() end,
}
end)()

local aeOpenFlag = true
openAE = function() aeOpenFlag = true; activeApp = "ae" end
closeAE = function() aeOpenFlag = false; AE.focus(false); activeApp = nil; drawAll() end
aeOpen = function() return aeOpenFlag end


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
  local parts = { "AE: " .. AE.summary() }
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
  note(L, 21, LWd - 2, "Used on the taskbar, lock screen and the activity log.")

  -- about
  groupBox(L - 2, 24, LWd + 2, 19, "About This Computer")
  local total, free = computer.totalMemory(), computer.freeMemory()
  local rows = {
    { "System:", tostring(SETTINGS.systemName or "Lymanos") .. "  (Lymanos AE 1.0)" },
    { "User:", tostring(PLAYER_NAME) },
    { "Memory:", string.format("%d K used of %d K", floor((total - free) / 1024), floor(total / 1024)) },
    { "Network card:", wlan and (wlan.address:sub(1, 8) .. (wlan.isWireless() and " (wireless)" or " (wired)")) or "none (optional)" },
    { "Settings file:", CONFIG.SETTINGS_FILE },
    { "Data file:", CONFIG.DATA_FILE },
    { "Status port:", wlan and CONFIG.STATUS_PORT and (tostring(CONFIG.STATUS_PORT) .. "  (\"LYMAE\" broadcast)") or "off" },
  }
  for i, r in ipairs(rows) do
    label(L, 25 + i, r[1])
    textW(L + FX - 18, 25 + i, LWd - FX + 16, r[2], K.black, K.face)
  end
  note(L, 34, LWd - 2, "Settings save automatically. CONFIG at the top of")
  note(L, 35, LWd - 2, "lymae.lua holds the defaults and advanced options.")
  button(regions, L, 38, 24, "Reset to defaults", function()
    dialog("Reset Settings", { "Put every setting back to its default?",
      "(Rules, pins and history are not touched.)" }, {
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
  note(R, 17, RWd - 2, "Levels keep being controlled while the screen is locked.")
  button(regions, R, 18, 20, "Lock Now", function() LOCK.lock() end)

  -- applied energistics
  groupBox(R - 2, 23, RWd + 2, 20, "Applied Energistics")
  note(R, 25, RWd - 2, "Rules, levels, machines and pins are set in the")
  note(R, 26, RWd - 2, "Applied Energistics app. Timing (CONFIG in lymae.lua):")
  local tr = {
    { "Level check:", "every " .. tostring(CONFIG.LEVEL_POLL) .. " s" },
    { "Graph point:", "every " .. tostring(CONFIG.HISTORY_STEP) .. " s" },
    { "Amounts:", "every " .. tostring(CONFIG.AMOUNT_REFRESH) .. " s" },
    { "All craftables:", "every " .. floor((CONFIG.CRAFT_REFRESH or 0) / 60) .. " min" },
    { "Patterns:", "every " .. floor((CONFIG.PATTERN_REFRESH or 0) / 60) .. " min" },
    { "Status re-check:", "after " .. tostring(CONFIG.STATUS_TTL) .. " s (shown rows)" },
  }
  for i, r in ipairs(tr) do
    label(R, 27 + i, r[1])
    textW(R + FX - 18, 27 + i, 30, r[2], K.black, K.face)
  end
  button(regions, R, 38, 30, "Open Applied Energistics", function() openAE(); drawAll() end)

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
  AE.resetRegions()
  if not keepOverlay then overlay = nil end
  drawDesktop()
  if activeApp == "ae" then
    AE.drawWindow()
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
  AE.load()
  drawAll()

  local lastTick = 0
  while running do
    gpu.flush()                        -- show this pass's drawing in one go
    -- shorter waits while the background AE work has something to do
    local ev = { event.pull(AE.busy() and 0.05 or 0.25) }
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
      elseif activeApp == "ae" then
        local wasFocus = AE.focus()
        AE.focus(false)
        if not hit(AE.regions(), x, y) then hit(regions, x, y) end
        if wasFocus and not AE.focus() and activeApp == "ae" and not overlay then AE.redrawFields() end
      else
        hit(regions, x, y)
      end
    elseif name == "scroll" and not overlay and activeApp == "sys" then
      SYS.scroll(ev[3], ev[4], ev[5])
    elseif name == "scroll" and not overlay and activeApp == "ae" then
      AE.scroll(ev[3], ev[4], ev[5])
    elseif name == "component_added" or name == "component_removed" then
      pcall(AE.onComponent, name, ev[2], ev[3])
    elseif name == "key_down" and activeApp == "ae" and AE.focus() and not overlay then
      AE.key(ev[3], ev[4])
    elseif name == "key_down" and activeApp == "settings" and SET.focus() and not overlay then
      SET.key(ev[3], ev[4])
    end

    -- level control + a slice of background AE work (scans, patterns, craft checks)
    if running then
      local okp, pe = pcall(AE.poll)
      if not okp then AEX.err = "Program error: " .. tostring(pe) end
      AE.refresh()
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
      if not overlay then pcall(AE.tick) end
      -- lock after the idle time set in Settings (0 = never)
      local mins = SETTINGS.lockMins or 0
      if mins > 0 and not LOCK.isLocked() and LOCK.idle() >= mins * 60 then LOCK.lock() end
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
pcall(AE.save)                     -- rules, pins, history, activity log
gpu.setResolution(oldW, oldH)
rgpu.setBackground(0x000000)
rgpu.setForeground(0xFFFFFF)
term.clear()
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write(tostring(err) .. "\n")
end
