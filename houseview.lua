--[[
  houseview.lua  -  the House server for the Lymanos Casino
  (a stripped-down Lymanos: House View, My Computer, Settings, lock screen)

  Every Lymanos computer with the Casino app talks to this server:
    - it broadcasts the house rules + odds every few seconds (port 4044)
    - each bet a player places arrives here first: the house checks it,
      takes the money into the house wallet and confirms it (BETOK) - or
      refuses it (BETNO) and the player keeps their money
    - each finished hand / ride sends its result and payout: the house pays
      it out of the wallet (PAID). A payout of $0 means the house kept the bet.
  Repeated messages are recognised and answered again without paying twice,
  so a lost wireless packet never duplicates or loses money.

  Apps:
    House View    Wallet (balance + recent transactions), Ledger (every
                  transaction), Rules (odds and table rules, sent to all players)
    My Computer   storage, memory, power and hardware details
    Settings      your name, house name, lock screen, desktop color

  Files written on this computer:
    /home/houseview_journal.log    every transaction, one line each (append only)
    /home/houseview_snapshot.dat   compact state; the journal restarts after each one
    /home/houseview_settings.dat   Settings app

  Needs: tier 3 GPU + tier 3 screen (160x50), a Wireless Network Card
  (tier 2 recommended) in range of the Lymanos computers. Mouse + keyboard.
  Exit: Start > Shut Down, or Ctrl+C.
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  PORT = 4044,                  -- must match HOUSE_PORT in lymanos.lua
  BROADCAST_EVERY = 5,          -- seconds between rules broadcasts
  START_WALLET = 250000,        -- the house wallet of a brand-new house
  PLAYER_NAME = "House",        -- default user name (Settings)
  JOURNAL = "/home/houseview_journal.log",
  JOURNAL_OLD = "/home/houseview_journal.old",
  SNAPSHOT = "/home/houseview_snapshot.dat",
  JOURNAL_MAX = 262144,         -- bytes; then a snapshot is written and the journal restarts
  LOG_KEEP = 1500,              -- transactions kept in RAM for the Wallet / Ledger tabs (~120 bytes each)
  DONE_KEEP = 4000,             -- finished rounds remembered (repeat RESULTs are answered from this)
  CLIENT_STALE = 30,            -- a Lymanos computer not heard from for this long = offline
  SETTINGS_FILE = "/home/houseview_settings.dat",
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
local SETTINGS = {
  userName = nil, systemName = "Lymanos House", lockMins = 30, lockStyle = 1, clock24 = false, desk = 1,
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
  local a = component.list("modem")()
  if a then wlan = component.proxy(a) end
end
if not wlan then
  io.stderr:write("No network card found. Install a Wireless Network Card (tier 2).\n")
  return
end
wlan.open(CONFIG.PORT)
local PLAYER_NAME = SETTINGS.userName or CONFIG.PLAYER_NAME or "House"

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

------------------------------------------------------------------ FILES
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
local activeApp = "house"     -- window in front: "house" | "sys" | "settings" | nil (desktop)
local lockedFlag = false
local WX, WY, WW, WH = 14, 2, 144, 44
local drawAll                                    -- forward
local openSysApp, closeSysApp, sysAppOpen        -- forward (My Computer)
local openSettings, closeSettings, settingsOpen  -- forward (Settings)
local LOCK, SET, HV                              -- lock screen, Settings, House View (below)

--------------------------------------------------------------- DESKTOP
local function drawDesktop()
  fill(1, 1, W, 46, K.desk)
  -- My Computer
  fill(4, 2, 6, 2, K.face)
  fill(5, 2, 4, 2, K.navy)
  fill(5, 4, 4, 1, K.face)
  textW(1, 5, 12, "My Computer", K.white, K.desk, "center")
  region(regions, 1, 2, 12, 5, function() openSysApp(); drawAll() end)
  -- House View: a stack of gold coins
  text(4, 8, "▄▆▆▆▄", 0xF2C14E, K.desk)
  text(4, 9, "█$$$█", 0x9C7A2C, 0xF2C14E)
  text(4, 10, "▀▀▀▀▀", 0x9C7A2C, K.desk)
  textW(1, 11, 12, "House View", K.white, K.desk, "center")
  region(regions, 1, 8, 12, 5, function() activeApp = "house"; drawAll() end)
  -- Settings
  fill(4, 14, 8, 3, K.face)
  text(4, 14, "─●──────", K.navy, K.face)
  text(4, 15, "────●───", K.navy, K.face)
  text(4, 16, "──────●─", K.navy, K.face)
  textW(1, 17, 12, "Settings", K.white, K.desk, "center")
  region(regions, 1, 14, 12, 4, function() openSettings(); drawAll() end)
end

----------------------------------------------------------------- TASKBAR
local openStartMenu  -- forward

local function drawTray(t)
  bevel(144, 48, 16, 3, "sunken", K.face, K.face)
  local on = HV and HV.clients() > 0
  text(146, 49, "((•))", on and K.green or K.sh, K.face)
  textW(151, 49, 8, fmtTray(t), K.black, K.face, "right")
end

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
  taskButton(11, 25, " $ House View", "house")
  local tx = 37
  if sysAppOpen and sysAppOpen() then taskButton(tx, 25, " ▣ My Computer", "sys"); tx = tx + 26 end
  if settingsOpen and settingsOpen() then taskButton(tx, 25, " ▣ Settings", "settings") end
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

-------------------------------------------------------------- HOUSE VIEW
-- The house bank. Every money event is first appended to the journal (one
-- line), then applied in memory, and only then answered over wireless - so
-- after any crash or restart the journal rebuilds exactly the same wallet.
HV = (function()
local G = {
  bg = 0x07090D, panel = 0x10151C, panel2 = 0x19212C, line = 0x2A3544, header = 0x0F141B,
  text = 0xEEF1F5, dim = 0x8792A2, dark = 0x000000, gold = 0xF2C14E, green = 0x35D07F,
  red = 0xF0505A, blue = 0x4EA8FF, violet = 0xA77BFF, orange = 0xFF9F43, felt = 0x0D5C3B,
}
local X0, X1 = WX + 1, WX + WW - 2
local CW = X1 - X0 + 1
local TY, TOP, BOT, SY = WY + 3, WY + 4, WY + WH - 3, WY + WH - 2
local V = { tab = "wallet", reg = {}, scroll = 0, filter = 1, lastCast = 0, saved = nil, sel = nil }

local DEFR = { open = true, min = 1, max = 5000,
  bj = { on = true, decks = 6, pays = 1.5, h17 = false, dbl = "any", das = true, hands = 4, rsa = false, pen = 0.75 },
  ride = { on = true, edge = 0.03, cap = 100, speed = 0.1155 } }
local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end
local rules = copy(DEFR)
local H = { wallet = CONFIG.START_WALLET, start = CONFIG.START_WALLET, adj = 0, inn = 0, out = 0,
            nb = 0, np = 0, seq = 0, base = 0, dayKey = nil, dayNet = 0, big = nil }
local rounds, done, doneList, players, logs, wpts, clients = {}, {}, {}, {}, {}, {}, {}
local jsize = 0

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
local function signed(n) return (n > 0 and "+" or "") .. money(n) end
local function short(n)
  local a = math.abs(n)
  local s
  if a >= 1e9 then s = string.format("%.2fB", a / 1e9)
  elseif a >= 1e6 then s = string.format("%.2fM", a / 1e6)
  elseif a >= 1e4 then s = string.format("%.1fK", a / 1e3)
  else s = string.format("%.0f", a) end
  return (n < 0 and "-$" or "$") .. s
end
local function clean(s) return (tostring(s or ""):gsub("[\t\r\n]", " ")) end
local function split(s)
  local out = {}
  for f in (s .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = f end
  return out
end
local function dayOf(t) local e = toEastern(t); return daysFromCivil(e.year, e.month, e.day) end
local function visible() return activeApp == "house" and not overlay and not LOCK.isLocked() end
local function gameName(g) return g == "bj" and "Blackjack" or (g == "ride" and "Let it Ride" or tostring(g)) end
local drawWindow   -- forward

---------------------------------------------------------------- journal + state
local function player(name)
  name = tostring(name or "?")
  local p = players[name]
  if not p then p = { n = 0, wag = 0, paid = 0, last = 0, big = 0 }; players[name] = p end
  return p
end
local function markDone(rid, paid)
  if done[rid] == nil then doneList[#doneList + 1] = rid end
  done[rid] = paid
  while #doneList > CONFIG.DONE_KEEP do done[table.remove(doneList, 1)] = nil end
end
local function addLog(line)
  logs[#logs + 1] = line
  if #logs > CONFIG.LOG_KEEP then table.remove(logs, 1) end
end
local function point()
  wpts[#wpts + 1] = H.wallet
  if #wpts > 240 then table.remove(wpts, 1) end
end
local function dayAdd(t, v)
  local d = dayOf(t)
  if d ~= H.dayKey then H.dayKey, H.dayNet = d, 0 end
  H.dayNet = cents(H.dayNet + v)
end

-- the ONE place where money moves: used live and when the journal is replayed
--  B: n B t rid seq amount game kind player walletAfter capAdd   (bet accepted)
--  N: n N t rid seq reason player                                (bet refused)
--  P: n P t rid paid game player outcome walletAfter bets flag detail   (round paid)
--  A: n A t amount note walletAfter                              (owner adjustment)
--  R: n R t rules
local function apply(line)
  local f = split(line)
  local n, k, t = tonumber(f[1]), f[2], tonumber(f[3]) or 0
  if not n or n <= H.base then return end
  if n > H.seq then H.seq = n end
  if k == "B" then
    local rid, s, a = f[4], tonumber(f[5]), tonumber(f[6]) or 0
    local r = rounds[rid]
    if not r then r = { p = f[9], g = f[7], t = t, bets = {}, no = {}, tot = 0, cap = 0 }; rounds[rid] = r end
    r.bets[s] = a
    r.tot = cents(r.tot + a)
    r.cap = r.cap + (tonumber(f[11]) or a * 2)
    H.wallet, H.inn, H.nb = cents(H.wallet + a), cents(H.inn + a), H.nb + 1
    dayAdd(t, a)
    local p = player(f[9]); p.wag, p.last = cents(p.wag + a), t
    addLog(line); point()
  elseif k == "N" then
    local rid, s = f[4], tonumber(f[5])
    local r = rounds[rid]
    if not r then r = { p = f[7], g = "?", t = t, bets = {}, no = {}, tot = 0, cap = 0 }; rounds[rid] = r end
    r.bets[s], r.no[s] = false, f[6]
    addLog(line)
  elseif k == "P" then
    local rid, paid = f[4], tonumber(f[5]) or 0
    local r = rounds[rid]
    local bets = r and r.tot or (tonumber(f[10]) or 0)
    H.wallet, H.out, H.np = cents(H.wallet - paid), cents(H.out + paid), H.np + 1
    dayAdd(t, -paid)
    local p = player(f[7]); p.paid, p.n, p.last = cents(p.paid + paid), p.n + 1, t
    local net = paid - bets
    if net > p.big then p.big = cents(net) end
    if not H.big or net > H.big.v then H.big = { v = cents(net), p = f[7], g = f[6], t = t } end
    rounds[rid] = nil
    markDone(rid, paid)
    addLog(line); point()
  elseif k == "A" then
    local a = tonumber(f[4]) or 0
    H.wallet, H.adj = cents(H.wallet + a), cents(H.adj + a)
    addLog(line); point()
  elseif k == "R" then
    local ok, rt = pcall(serialization.unserialize, f[4])
    if ok and type(rt) == "table" then rules = rt end
  end
end

local snapshot   -- forward
local function jline(parts)
  local s = (H.seq + 1) .. "\t" .. table.concat(parts, "\t")
  local fh = io.open(CONFIG.JOURNAL, "a")
  if not fh then error("can't write " .. CONFIG.JOURNAL .. " - is the disk full?") end
  fh:write(s, "\n")
  fh:close()
  jsize = jsize + #s + 1
  apply(s)
  if jsize > CONFIG.JOURNAL_MAX then snapshot() end
  return s
end

local function yieldNow() os.sleep(0) end      -- only while loading, before any player is answered

-- compact state: written line by line (no big strings), then the journal restarts.
-- (no os.sleep in here: it would throw away bets arriving meanwhile)
snapshot = function()
  local tmp = CONFIG.SNAPSHOT .. ".tmp"
  local fh = io.open(tmp, "w")
  if not fh then return end
  fh:write("HVSNAP 1\n")
  fh:write("H ", serialization.serialize(H), "\n")
  fh:write("U ", serialization.serialize(rules), "\n")
  for rid, r in pairs(rounds) do fh:write("O ", serialization.serialize({ id = rid, r = r }), "\n") end
  for _, rid in ipairs(doneList) do
    fh:write("D ", rid, " ", string.format("%.2f", done[rid] or 0), "\n")
  end
  for name, p in pairs(players) do fh:write("P ", serialization.serialize({ name = name, p = p }), "\n") end
  for _, l in ipairs(logs) do fh:write("L ", l, "\n") end
  local w = {}
  for i, v in ipairs(wpts) do w[i] = string.format("%.2f", v) end
  fh:write("W ", table.concat(w, ","), "\n")
  fh:write("END\n")
  fh:close()
  pcall(filesystem.remove, CONFIG.SNAPSHOT)
  filesystem.rename(tmp, CONFIG.SNAPSHOT)
  pcall(filesystem.remove, CONFIG.JOURNAL_OLD)
  pcall(filesystem.rename, CONFIG.JOURNAL, CONFIG.JOURNAL_OLD)
  jsize = 0
end

local function loadSnap(path)
  local fh = io.open(path, "r")
  if not fh then return false end
  if fh:read("*l") ~= "HVSNAP 1" then fh:close(); return false end
  local okAll, i = false, 0
  for line in fh:lines() do
    i = i + 1
    if i % 400 == 0 then yieldNow() end
    local k, rest = line:sub(1, 1), line:sub(3)
    if k == "H" then
      local ok, t = pcall(serialization.unserialize, rest)
      if ok and type(t) == "table" then for kk, v in pairs(t) do H[kk] = v end end
    elseif k == "U" then
      local ok, t = pcall(serialization.unserialize, rest)
      if ok and type(t) == "table" then rules = t end
    elseif k == "O" then
      local ok, t = pcall(serialization.unserialize, rest)
      if ok and type(t) == "table" and t.id then rounds[t.id] = t.r end
    elseif k == "D" then
      local rid, v = rest:match("^(%S+) (%S+)")
      if rid then markDone(rid, tonumber(v) or 0) end
    elseif k == "P" then
      local ok, t = pcall(serialization.unserialize, rest)
      if ok and type(t) == "table" and t.name then players[t.name] = t.p end
    elseif k == "L" then logs[#logs + 1] = rest
    elseif k == "W" then for v in rest:gmatch("[^,]+") do wpts[#wpts + 1] = tonumber(v) end
    elseif line == "END" then okAll = true end
  end
  fh:close()
  H.base = H.seq
  return okAll
end

local function fresh()
  for k in pairs(H) do H[k] = nil end
  H.wallet, H.start, H.adj, H.inn, H.out = CONFIG.START_WALLET, CONFIG.START_WALLET, 0, 0, 0
  H.nb, H.np, H.seq, H.base, H.dayNet = 0, 0, 0, 0, 0
  rules = copy(DEFR)
  for _, t in ipairs({ rounds, done, doneList, players, logs, wpts }) do for k in pairs(t) do t[k] = nil end end
end
local function load()
  if not loadSnap(CONFIG.SNAPSHOT) then
    -- no (complete) snapshot: the temp file of an interrupted save, or a brand-new house
    fresh()
    if not loadSnap(CONFIG.SNAPSHOT .. ".tmp") then fresh() end
  end
  local fh = io.open(CONFIG.JOURNAL, "r")
  if fh then
    local i = 0
    for line in fh:lines() do
      i = i + 1
      jsize = jsize + #line + 1
      if line:match("^%d+\t%u\t") then pcall(apply, line) end   -- a half-written last line is skipped
      if i % 300 == 0 then yieldNow() end
    end
    fh:close()
  end
  H.base = 0
  if #wpts == 0 then point() end
end

---------------------------------------------------------------- the house desk (wireless)
local function reply(to, kind, a, b, c) pcall(wlan.send, to, CONFIG.PORT, "HOUSE", kind, a, b, c) end
local function packet()
  local t = copy(rules)
  t.wallet, t.name = H.wallet, tostring(SETTINGS.systemName or "House"):sub(1, 24)
  return serialization.serialize(t)
end
local function broadcast()
  pcall(wlan.broadcast, CONFIG.PORT, "HOUSE", "RULES", packet())
  V.lastCast = computer.uptime()
end
-- most a bet could ever cost the house (it must be able to pay it)
local function factor(g, kind)
  if g == "ride" then return rules.ride.cap end
  if kind == "main" then return 1 + max(1, rules.bj.pays) end
  return 2
end
local function seen(from, name)
  clients[from] = { name = tostring(name or (clients[from] and clients[from].name) or "?"), at = computer.uptime() }
end

local function onBet(from, t)
  local rid, s, a = tostring(t.r or ""), tonumber(t.s), tonumber(t.a)
  if rid == "" or not s or not a then return end
  a = cents(a)
  seen(from, t.p)
  if done[rid] ~= nil then reply(from, "BETNO", rid, s, "that round is already finished"); return end
  local r = rounds[rid]
  if r and r.bets[s] ~= nil then                    -- a repeat: same answer as before
    if r.bets[s] then reply(from, "BETOK", rid, s, H.wallet) else reply(from, "BETNO", rid, s, r.no[s]) end
    return
  end
  local g, kind = t.g, t.k
  local why
  if g ~= "bj" and g ~= "ride" then why = "unknown game"
  elseif a <= 0 then why = "invalid amount"
  elseif kind ~= "main" and kind ~= "double" and kind ~= "split" then why = "unknown bet type"
  elseif kind == "main" and r and r.tot > 0 then why = "that round already has a bet"
  elseif kind == "main" and not rules.open then why = "the casino is closed"
  elseif kind == "main" and g == "bj" and not rules.bj.on then why = "blackjack is closed"
  elseif kind == "main" and g == "ride" and not rules.ride.on then why = "Let it Ride is closed"
  elseif kind == "main" and (a < rules.min - 1e-9 or a > rules.max + 1e-9) then
    why = "table limits are " .. money(rules.min) .. " - " .. money(rules.max)
  elseif kind ~= "main" and (g ~= "bj" or not r or r.tot <= 0) then why = "no main bet for that round"
  elseif H.wallet + a < a * factor(g, kind) then why = "the house can't cover that bet right now"
  end
  if why then
    jline({ "N", floor(now()), rid, s, clean(why), clean(t.p) })
    reply(from, "BETNO", rid, s, why)
  else
    jline({ "B", floor(now()), rid, s, string.format("%.2f", a), g, kind, clean(t.p),
            string.format("%.2f", H.wallet + a), string.format("%.2f", a * factor(g, kind)) })
    reply(from, "BETOK", rid, s, H.wallet)
  end
end

local function onResult(from, t)
  local rid = tostring(t.r or "")
  if rid == "" then return end
  seen(from, t.pl)
  if done[rid] ~= nil then reply(from, "PAID", rid, done[rid]); return end    -- a repeat
  local r = rounds[rid]
  local p = cents(max(0, tonumber(t.p) or 0))
  local flag = ""
  if not r or r.tot <= 0 then flag = "NO BET ON RECORD"
  elseif p > r.cap + 0.005 then p, flag = cents(r.cap), "CAPPED" end
  jline({ "P", floor(now()), rid, string.format("%.2f", p), clean(t.g), clean(t.pl or (r and r.p)), clean(t.o),
          string.format("%.2f", H.wallet - p), string.format("%.2f", r and r.tot or 0), flag, clean(t.d):sub(1, 80) })
  reply(from, "PAID", rid, p)
end

local function onMessage(from, kind, a)
  if kind == "HELLO" then
    seen(from)
    reply(from, "RULES", packet())
    return
  elseif kind == "HI" then            -- a Lymanos computer saying it's still there
    seen(from, a)
    return
  end
  local ok, t = pcall(serialization.unserialize, a)
  if not ok or type(t) ~= "table" then return end
  if kind == "BET" then onBet(from, t) elseif kind == "RESULT" then onResult(from, t) end
  V.dirty = true
end

local function rulesChanged(msg)
  jline({ "R", floor(now()), serialization.serialize(rules) })
  broadcast()
  V.saved = msg or "Saved and sent to every Lymanos computer in range."
end
local function adjust(a, note)
  if H.wallet + a < 0 then a = -H.wallet end
  if math.abs(a) < 0.005 then return end
  jline({ "A", floor(now()), string.format("%.2f", a), clean(note), string.format("%.2f", H.wallet + a) })
  broadcast()
  V.saved = (a >= 0 and "Added " or "Withdrew ") .. money(math.abs(a)) .. (a >= 0 and " to" or " from") .. " the house wallet."
end

---------------------------------------------------------------- reading the log
-- one log line -> what the row shows
local function entry(l)
  local f = split(l)
  local k = f[2]
  local e = { n = tonumber(f[1]), k = k, t = tonumber(f[3]) or 0 }
  if k == "B" then
    e.rid, e.amt, e.g, e.kind, e.p, e.w = f[4], tonumber(f[6]) or 0, f[7], f[8], f[9], tonumber(f[10])
    e.type, e.col = "BET IN", G.green
    e.note = (e.kind == "main" and "bet" or e.kind) .. " #" .. tostring(f[5])
  elseif k == "N" then
    e.rid, e.p, e.amt, e.type, e.col, e.note = f[4], f[7], 0, "REFUSED", G.dim, f[6]
  elseif k == "P" then
    e.rid, e.amt, e.g, e.p, e.o, e.w, e.bets, e.flag, e.d = f[4], tonumber(f[5]) or 0, f[6], f[7], f[8], tonumber(f[9]), tonumber(f[10]) or 0, f[11], f[12]
    if e.amt > 0 then e.type, e.col = "PAYOUT", G.red else e.type, e.col = "KEPT", G.gold end
    e.note = (e.o or "") .. ((e.flag and e.flag ~= "") and ("  [" .. e.flag .. "]") or "")
  elseif k == "A" then
    e.amt, e.note, e.w, e.p = tonumber(f[4]) or 0, f[5], tonumber(f[6]), "owner"
    e.type, e.col = "ADJUST", G.violet
  end
  return e
end
local FILTERS = {
  { "All", function() return true end },
  { "Bets in", function(e) return e.k == "B" end },
  { "Payouts", function(e) return e.k == "P" and e.amt > 0 end },
  { "Kept", function(e) return e.k == "P" and e.amt <= 0 end },
  { "Blackjack", function(e) return e.g == "bj" end },
  { "Let it Ride", function(e) return e.g == "ride" end },
  { "Refused", function(e) return e.k == "N" end },
  { "Adjustments", function(e) return e.k == "A" end },
}
local function stampT(t)
  local e = toEastern(t)
  if SETTINGS.clock24 then return string.format("%02d/%02d %02d:%02d:%02d", e.month, e.day, e.hour, e.min, e.sec) end
  local h, ap = h12(e)
  return string.format("%02d/%02d %2d:%02d:%02d %s", e.month, e.day, h, e.min, e.sec, ap)
end
local function amountText(e)
  if e.k == "B" then return "+" .. money(e.amt), G.green end
  if e.k == "P" and e.amt > 0 then return "-" .. money(e.amt), G.red end
  if e.k == "P" then return "+" .. money(e.bets or 0) .. " kept", G.gold end
  if e.k == "A" then return signed(e.amt), G.violet end
  return "--", G.dim
end

---------------------------------------------------------------- big digits (5x7)
local FONT = {
  ["0"] = "01110100011001110101110011000101110", ["1"] = "00100011000010000100001000010001110",
  ["2"] = "01110100010000100010001000100011111", ["3"] = "11110000010000101110000010000111110",
  ["4"] = "00010001100101010010111110001000010", ["5"] = "11111100001111000001000011000101110",
  ["6"] = "00110010001000011110100011000101110", ["7"] = "11111000010001000100010000100001000",
  ["8"] = "01110100011000101110100011000101110", ["9"] = "01110100011000101111000010001001100",
  ["$"] = "00100011111010001110001011111000100", [","] = "00000000001110",
  ["."] = "00000000001111", ["-"] = "00000000000000011111000000000000000",
}
local function glyphW(ch) local g = FONT[ch]; return g and floor(#g / 7) or 3 end
local function bigWidth(s) local w = 0; for i = 1, #s do w = w + glyphW(s:sub(i, i)) + 1 end; return w - 1 end
local function bigText(x, y, s, col, bgc)
  local w = bigWidth(s)
  local cv = newCanvas(w, 14, bgc)
  local cx = 1
  for i = 1, #s do
    local ch = s:sub(i, i)
    local g, gw = FONT[ch], glyphW(ch)
    if g then
      for r = 0, 6 do for c = 1, gw do
        if g:sub(r * gw + c, r * gw + c) == "1" then cset(cv, cx + c - 1, r * 2 + 1, col); cset(cv, cx + c - 1, r * 2 + 2, col) end
      end end
    end
    cx = cx + gw + 1
  end
  crender(cv, x, y)
  return w
end

---------------------------------------------------------------- drawing
local function panel(x, y, w, h, title, col, right)
  fill(x, y, w, h, G.panel)
  fill(x, y, w, 1, G.panel2)
  text(x, y, " " .. title .. " ", col or G.gold, G.panel2)
  if right then textW(x + w - unicode.len(right) - 1, y, unicode.len(right), right, G.dim, G.panel2) end
end
local function kv(x, y, w, k, v, col)
  textW(x, y, w, k, G.dim, G.panel)
  textW(x + 18, y, w - 18, v, col or G.text, G.panel, "right")
end
local function openMoney()
  local n, m = 0, 0
  for _, r in pairs(rounds) do if r.tot > 0 then n, m = n + 1, m + r.tot end end
  return n, m
end
local function online()
  local n, up = 0, computer.uptime()
  for _, c in pairs(clients) do if up - c.at <= CONFIG.CLIENT_STALE then n = n + 1 end end
  return n
end

local function walletGraph(x, y, w, rows)
  local cw, ph = w, rows * 2
  local cv = newCanvas(cw, ph, G.panel)
  local n = #wpts
  local lo, hi = H.start, H.start
  for i = 1, n do lo, hi = min(lo, wpts[i]), max(hi, wpts[i]) end
  if hi - lo < 1 then hi, lo = hi + 1, lo - 1 end
  local pad = (hi - lo) * 0.1
  lo, hi = lo - pad, hi + pad
  local function py(v) return ph - floor((v - lo) / (hi - lo) * (ph - 1) + 0.5) end
  local sy = py(H.start)
  for xx = 1, cw, 3 do cset(cv, xx, sy, G.line) end
  local up = H.wallet >= H.start
  local col = up and G.green or G.red
  local area = lerp(col, G.panel, 0.82)
  local px2, py2
  for c = 1, cw do
    local f = (n > 1) and ((c - 1) / (cw - 1) * (n - 1) + 1) or 1
    local i = min(n, floor(f))
    local v = n == 0 and H.wallet or (i < n and (wpts[i] + (wpts[i + 1] - wpts[i]) * (f - i)) or wpts[n])
    local yy = py(v)
    if yy < sy then for y2 = yy + 1, sy do cset(cv, c, y2, area) end else for y2 = sy, yy - 1 do cset(cv, c, y2, area) end end
    if px2 then cline(cv, px2, py2, c, yy, lerp(col, 0xFFFFFF, 0.2)) else cset(cv, c, yy, col) end
    px2, py2 = c, yy
  end
  crender(cv, x, y)
  textW(x, y + rows, w, "last " .. n .. " transactions   - - start " .. money(H.start), G.dim, G.panel)
end

local function drawWallet()
  local lw = 72
  local x, w = X0, lw
  panel(x, TOP, w, 15, "HOUSE WALLET", G.gold, "port " .. CONFIG.PORT)
  local s = money(H.wallet)
  if bigWidth(s) > w - 4 then s = s:gsub("%.%d%d$", "") end
  local bw = bigWidth(s)
  bigText(x + floor((w - bw) / 2), TOP + 2, s, H.wallet >= 0 and G.gold or G.red, G.panel)
  local profit = H.inn - H.out
  textW(x + 1, TOP + 10, w - 2, "Started with " .. money(H.start) .. (math.abs(H.adj) > 0.004 and ("  ·  owner " .. signed(H.adj)) or ""), G.dim, G.panel, "center")
  textW(x + 1, TOP + 11, w - 2, "Games " .. signed(profit) .. string.format("  (%.2f%% of %s wagered)", H.inn > 0 and profit / H.inn * 100 or 0, short(H.inn)),
    profit >= 0 and G.green or G.red, G.panel, "center")
  local today = (H.dayKey == dayOf(now())) and H.dayNet or 0
  textW(x + 1, TOP + 12, w - 2, "Today " .. signed(today), today >= 0 and G.green or G.red, G.panel, "center")
  local on = online()
  textW(x + 1, TOP + 13, w - 2, (rules.open and "● CASINO OPEN" or "○ CASINO CLOSED") .. "   ·   " .. on .. " Lymanos computer" .. (on == 1 and "" or "s") .. " connected",
    rules.open and G.green or G.orange, G.panel, "center")
  panel(x, TOP + 16, w, 11, "WALLET HISTORY", G.gold)
  walletGraph(x + 1, TOP + 17, w - 2, 8)
  panel(x, TOP + 28, w, BOT - TOP - 27, "STATS", G.gold)
  local n, m = openMoney()
  kv(x + 2, TOP + 29, 33, "Bets received", commas(H.nb))
  kv(x + 2, TOP + 30, 33, "Total wagered", money(H.inn))
  kv(x + 2, TOP + 31, 33, "Paid to players", money(H.out))
  kv(x + 2, TOP + 32, 33, "Rounds settled", commas(H.np))
  kv(x + 37, TOP + 29, 33, "Rounds in play", commas(n))
  kv(x + 37, TOP + 30, 33, "Money in play", money(m))
  local bigW = H.big and H.big.v > 0 and (short(H.big.v) .. " " .. tostring(H.big.p)) or "--"
  kv(x + 37, TOP + 31, 33, "Biggest player win", bigW, G.gold)
  kv(x + 37, TOP + 32, 33, "Players", commas((function() local c = 0; for _ in pairs(players) do c = c + 1 end; return c end)()))
  -- players
  local list = {}
  for name, p in pairs(players) do list[#list + 1] = { name, p } end
  table.sort(list, function(a, b) return a[2].last > b[2].last end)
  textW(x + 2, TOP + 34, w - 4, string.format("%-14s %6s %14s %14s %12s", "PLAYER", "ROUNDS", "WAGERED", "PLAYER NET", "LAST SEEN"), G.dim, G.panel)
  for i = 1, BOT - TOP - 35 do
    local it = list[i]
    local y = TOP + 34 + i
    if it then
      local p = it[2]
      local net = p.paid - p.wag
      textW(x + 2, y, 14, it[1], G.text, G.panel)
      textW(x + 17, y, 6, commas(p.n), G.text, G.panel, "right")
      textW(x + 24, y, 14, money(p.wag), G.text, G.panel, "right")
      textW(x + 39, y, 14, signed(net), net > 0 and G.red or (net < 0 and G.green or G.dim), G.panel, "right")
      textW(x + 54, y, 13, p.last > 0 and stampT(p.last):sub(1, 11) or "--", G.dim, G.panel, "right")
    else fill(x + 2, y, w - 4, 1, G.panel) end
  end
  -- right: recent transactions
  local rx, rw = X0 + lw + 1, CW - lw - 1
  panel(rx, TOP, rw, BOT - TOP + 1, "RECENT TRANSACTIONS", G.gold, #logs .. " in memory")
  textW(rx + 1, TOP + 1, rw - 2, string.format("%-12s %-8s %-12s %-11s %20s", "TIME", "TYPE", "PLAYER", "GAME", "AMOUNT"), G.dim, G.panel)
  local rows = BOT - TOP - 1
  for i = 1, rows do
    local l = logs[#logs - i + 1]
    local y = TOP + 1 + i
    local b = (i % 2 == 0) and 0x131922 or G.panel
    if l then
      local e = entry(l)
      local h, ap = h12(toEastern(e.t))
      local tm = SETTINGS.clock24 and string.format("%02d:%02d:%02d", toEastern(e.t).hour, toEastern(e.t).min, toEastern(e.t).sec)
        or string.format("%2d:%02d:%02d %s", h, toEastern(e.t).min, toEastern(e.t).sec, ap)
      textW(rx + 1, y, 13, tm, G.dim, b)
      textW(rx + 14, y, 9, e.type, e.col, b)
      textW(rx + 23, y, 13, tostring(e.p or ""), G.text, b)
      textW(rx + 36, y, 12, e.g and gameName(e.g) or "", G.dim, b)
      local at, ac = amountText(e)
      textW(rx + 48, y, rw - 49, at, ac, b, "right")
    else fill(rx, y, rw, 1, G.panel) end
  end
  if #logs == 0 then textW(rx + 1, TOP + 4, rw - 2, "No transactions yet. Waiting for players...", G.dim, G.panel, "center") end
end

local LCOLS = { { "#", 7 }, { "DATE / TIME", 18 }, { "TYPE", 8 }, { "PLAYER", 13 }, { "GAME", 11 }, { "AMOUNT", 17 }, { "WALLET AFTER", 15 }, { "ROUND", 13 }, { "DETAILS", 0 } }
local LROWS = BOT - TOP - 4
local function filtered()
  local fn = FILTERS[V.filter][2]
  if V.filter == 1 then return nil, #logs end
  local idx = {}
  for i = #logs, 1, -1 do if fn(entry(logs[i])) then idx[#idx + 1] = i end end
  return idx, #idx
end
local function drawLedgerRows()
  local idx, n = filtered()
  V.scroll = max(0, min(V.scroll, n - LROWS))
  for r = 1, LROWS do
    local y = TOP + 2 + r
    local k = r + V.scroll
    local li = idx and idx[k] or (n - k + 1)
    local l = (k <= n) and logs[li]
    local b = (r % 2 == 0) and 0x131922 or G.panel
    if l then
      local e = entry(l)
      local at, ac = amountText(e)
      local cells = { tostring(e.n), stampT(e.t), e.type, tostring(e.p or ""), e.g and gameName(e.g) or "", at,
                      e.w and money(e.w) or "", tostring(e.rid or ""), tostring(e.note or "") .. ((e.d and e.d ~= "") and ("  " .. e.d) or "") }
      local cols = { G.dim, G.dim, e.col, G.text, G.dim, ac, G.text, G.dim, G.dim }
      local cx = X0 + 1
      for i, c in ipairs(LCOLS) do
        local cwid = c[2] > 0 and c[2] or (X1 - cx - 1)
        textW(cx, y, cwid, cells[i], cols[i], b, (i == 6 or i == 7) and "right" or nil)
        cx = cx + cwid + 1
        if c[2] > 0 then text(cx - 1, y, " ", nil, b) end
      end
      fill(cx - 1, y, X1 - cx + 2, 1, b)
    else fill(X0, y, CW - 1, 1, G.panel) end
  end
  local sx = X1
  text(sx, TOP + 3, "▲", G.text, G.line)
  text(sx, TOP + 2 + LROWS, "▼", G.text, G.line)
  vtext(sx, TOP + 4, string.rep("░", LROWS - 2), G.dim, G.panel2)
  local maxS = max(0, n - LROWS)
  if maxS > 0 then text(sx, TOP + 4 + floor((LROWS - 3) * V.scroll / maxS + 0.5), "█", G.gold, G.panel2) end
  textW(X0 + 1, BOT, CW - 2, string.format("%d transactions shown (%s)  ·  newest first  ·  scroll with the mouse wheel  ·  full history: %s",
    n, FILTERS[V.filter][1], CONFIG.JOURNAL), G.dim, G.panel)
end
local function drawLedger()
  panel(X0, TOP, CW, BOT - TOP + 1, "LEDGER  ·  EVERY TRANSACTION", G.gold)
  local fx = X0 + CW - 2
  for i = #FILTERS, 1, -1 do
    local lab = " " .. FILTERS[i][1] .. " "
    fx = fx - unicode.len(lab)
    local on = V.filter == i
    text(fx, TOP, lab, on and G.dark or G.dim, on and G.gold or G.panel2)
    region(V.reg, fx, TOP, unicode.len(lab), 1, function() V.filter, V.scroll = i, 0; drawWindow() end)
    fx = fx - 1
  end
  local cx = X0 + 1
  for _, c in ipairs(LCOLS) do
    textW(cx, TOP + 1, c[2] > 0 and c[2] or 30, c[1], G.dim, G.panel)
    cx = cx + c[2] + 1
  end
  text(X0 + 1, TOP + 2, string.rep("─", CW - 3), G.line, G.panel)
  region(V.reg, X1, TOP + 3, 1, 1, function() V.scroll = V.scroll - 1; drawLedgerRows() end)
  region(V.reg, X1, TOP + 2 + LROWS, 1, 1, function() V.scroll = V.scroll + 1; drawLedgerRows() end)
  drawLedgerRows()
end

-- rules tab: every option is { label, current text, step function }
local function idxNear(list, v)
  local best, bd = 1, math.huge
  for i, x in ipairs(list) do
    local d = (type(x) == "number" and type(v) == "number") and math.abs(x - v) or (x == v and 0 or 1)
    if d < bd then best, bd = i, d end
  end
  return best
end
local function stepper(list, get, set)
  return function(d)
    local i = idxNear(list, get())
    set(list[(i - 1 + d) % #list + 1])
  end
end
local function yesno(v, a, b) return v and (a or "Yes") or (b or "No") end
local function payName(p) return ({ [1.5] = "3 to 2", [1.2] = "6 to 5", [2] = "2 to 1", [1] = "1 to 1" })[p] or string.format("%.2f to 1", p) end
local SPEEDS = { 3, 4, 5, 6, 8, 10, 15 }

local function options()
  local B, Rr = rules.bj, rules.ride
  return {
    { "CASINO" },
    { "Casino", yesno(rules.open, "OPEN", "CLOSED"), function() rules.open = not rules.open end },
    { "Minimum bet", money(rules.min), stepper({ 1, 5, 10, 25, 50, 100, 250, 500, 1000 }, function() return rules.min end,
        function(v) rules.min = v; if rules.max < v then rules.max = v end end) },
    { "Maximum bet", money(rules.max), stepper({ 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000, 1000000 },
        function() return rules.max end, function(v) rules.max = max(v, rules.min) end) },
    { "BLACKJACK" },
    { "Table", yesno(B.on, "OPEN", "CLOSED"), function() B.on = not B.on end },
    { "Decks in the shoe", tostring(B.decks), stepper({ 1, 2, 4, 6, 8 }, function() return B.decks end, function(v) B.decks = v end) },
    { "Blackjack pays", payName(B.pays), stepper({ 1.5, 1.2, 2, 1 }, function() return B.pays end, function(v) B.pays = v end) },
    { "Dealer on soft 17", yesno(B.h17, "HITS", "STANDS"), function() B.h17 = not B.h17 end },
    { "Double down on", B.dbl == "any" and "any 2 cards" or B.dbl, stepper({ "any", "9-11", "10-11" }, function() return B.dbl end, function(v) B.dbl = v end) },
    { "Double after split", yesno(B.das), function() B.das = not B.das end },
    { "Split up to", B.hands <= 1 and "no splits" or (B.hands .. " hands"), stepper({ 1, 2, 3, 4 }, function() return B.hands end, function(v) B.hands = v end) },
    { "Re-split aces", yesno(B.rsa), function() B.rsa = not B.rsa end },
    { "Reshuffle at", floor(B.pen * 100 + 0.5) .. "% of the shoe", stepper({ 0.5, 0.6, 0.7, 0.75, 0.8, 0.9 }, function() return B.pen end, function(v) B.pen = v end) },
    { "LET IT RIDE" },
    { "Game", yesno(Rr.on, "OPEN", "CLOSED"), function() Rr.on = not Rr.on end },
    { "House edge", string.format("%.1f%%  (RTP %.1f%%)", Rr.edge * 100, (1 - Rr.edge) * 100),
        stepper({ 0.005, 0.01, 0.02, 0.03, 0.04, 0.05, 0.075, 0.1, 0.15, 0.2 }, function() return Rr.edge end, function(v) Rr.edge = v end) },
    { "Max multiplier", (Rr.cap >= 100 and string.format("%dx", Rr.cap) or string.format("%.0fx", Rr.cap)),
        stepper({ 10, 25, 50, 100, 250, 500, 1000, 10000 }, function() return Rr.cap end, function(v) Rr.cap = v end) },
    { "Speed", string.format("2x after %.1f s", math.log(2) / Rr.speed),
        stepper(SPEEDS, function() return math.log(2) / Rr.speed end, function(v) Rr.speed = math.log(2) / v end) },
  }
end

local function drawRules()
  local lw = 74
  panel(X0, TOP, lw, BOT - TOP + 1, "GAME RULES & ODDS", G.gold, "changes are sent to players right away")
  local y = TOP + 2
  for i, o in ipairs(options()) do
    if not o[2] then
      if i > 1 then y = y + 1 end
      text(X0 + 2, y, o[1], G.gold, G.panel)
      text(X0 + 2 + #o[1] + 1, y, string.rep("─", lw - #o[1] - 5), G.line, G.panel)
    else
      textW(X0 + 4, y, 26, o[1], G.text, G.panel)
      text(X0 + 32, y, " ◄ ", G.text, G.line)
      textW(X0 + 35, y, 26, o[2], G.gold, G.panel2, "center")
      text(X0 + 61, y, " ► ", G.text, G.line)
      local fn = o[3]
      region(V.reg, X0 + 32, y, 3, 1, function() fn(-1); rulesChanged(); drawWindow() end)
      region(V.reg, X0 + 61, y, 3, 1, function() fn(1); rulesChanged(); drawWindow() end)
      region(V.reg, X0 + 35, y, 26, 1, function() fn(1); rulesChanged(); drawWindow() end)
    end
    y = y + 1
  end
  -- right column: wallet + odds summary + connected computers
  local rx, rw = X0 + lw + 1, CW - lw - 1
  panel(rx, TOP, rw, 9, "WALLET", G.gold)
  textW(rx + 2, TOP + 1, rw - 4, "Balance " .. money(H.wallet), G.text, G.panel)
  local bx = rx + 2
  for _, a in ipairs({ { "+ $10K", 10000 }, { "+ $100K", 100000 }, { "- $10K", -10000 }, { "- $100K", -100000 } }) do
    local lab = " " .. a[1] .. " "
    text(bx, TOP + 3, lab, G.text, a[2] > 0 and 0x1F5A2E or 0x6A2020)
    region(V.reg, bx, TOP + 3, unicode.len(lab), 1, function() adjust(a[2], a[2] > 0 and "owner deposit" or "owner withdrawal"); drawWindow() end)
    bx = bx + unicode.len(lab) + 1
  end
  local lab = " Reset to " .. short(CONFIG.START_WALLET) .. "... "
  text(rx + 2, TOP + 5, lab, G.text, G.line)
  region(V.reg, rx + 2, TOP + 5, unicode.len(lab), 1, function()
    dialog("Reset House Wallet", { "Set the house wallet back to " .. money(CONFIG.START_WALLET) .. "?",
      "It's logged as an owner adjustment; nothing else changes." }, {
      { "Reset", function() adjust(CONFIG.START_WALLET - H.wallet, "wallet reset") end }, { "Cancel" } })
  end)
  textW(rx + 2, TOP + 7, rw - 4, "Owner deposits / withdrawals show as ADJUST.", G.dim, G.panel)
  panel(rx, TOP + 10, rw, 9, "WHAT THE PLAYER GETS", G.gold)
  local B, Rr = rules.bj, rules.ride
  textW(rx + 2, TOP + 11, rw - 4, "Blackjack pays " .. payName(B.pays) .. ", wins 1 to 1, " .. (B.h17 and "dealer hits soft 17." or "dealer stands on 17s."), G.text, G.panel)
  textW(rx + 2, TOP + 12, rw - 4, string.format("Let it Ride: x is reached in %.1f%% / x of rounds,", (1 - Rr.edge) * 100), G.text, G.panel)
  textW(rx + 2, TOP + 13, rw - 4, string.format("2x in %.1f%%, 10x in %.1f%%, %.1f%% bust at 1.00x.", (1 - Rr.edge) / 2 * 100, (1 - Rr.edge) / 10 * 100, (1 - (1 - Rr.edge) / 1.01) * 100), G.text, G.panel)
  textW(rx + 2, TOP + 15, rw - 4, "Biggest possible payout per bet:", G.dim, G.panel)
  textW(rx + 2, TOP + 16, rw - 4, string.format("Blackjack %.1fx the bet, Let it Ride %sx.", 1 + max(1, B.pays), commas(Rr.cap)), G.dim, G.panel)
  textW(rx + 2, TOP + 17, rw - 4, "Bets the wallet can't cover are refused.", G.dim, G.panel)
  panel(rx, TOP + 20, rw, BOT - TOP - 19, "LYMANOS COMPUTERS", G.gold, "broadcast every " .. CONFIG.BROADCAST_EVERY .. " s")
  local list = {}
  for addr, c in pairs(clients) do list[#list + 1] = { addr, c } end
  table.sort(list, function(a, b) return a[2].at > b[2].at end)
  local up = computer.uptime()
  for i = 1, BOT - TOP - 22 do
    local it = list[i]
    local y = TOP + 20 + i
    if it then
      local ago = up - it[2].at
      textW(rx + 2, y, rw - 4, (ago <= CONFIG.CLIENT_STALE and "● " or "○ ") .. it[2].name .. "  (" .. it[1]:sub(1, 8) .. ")  " .. fmtDurLong(ago) .. " ago",
        ago <= CONFIG.CLIENT_STALE and G.green or G.dim, G.panel)
    end
  end
  if #list == 0 then textW(rx + 2, TOP + 21, rw - 4, "None yet. Lymanos computers show up when they ask for the rules or bet.", G.dim, G.panel) end
  textW(rx + 2, BOT, rw - 4, "Last broadcast " .. fmtDurLong(up - V.lastCast) .. " ago", G.dim, G.panel)
end

local function drawStatus()
  fill(WX + 1, SY, WW - 2, 1, K.face)
  textW(WX + 2, SY, 70, V.saved or ("Wallet " .. money(H.wallet) .. "   ·   " .. (rules.open and "casino open" or "casino closed")), V.saved and K.navy or K.black, K.face)
  text(WX + 73, SY, "│", K.sh, K.face)
  textW(WX + 74, SY, 30, online() .. " player computer(s) online", K.black, K.face)
  text(WX + 105, SY, "│", K.sh, K.face)
  textW(WX + 106, SY, 36, "Journal " .. floor(jsize / 1024) .. " KB  ·  #" .. H.seq, K.black, K.face)
  V.saved = nil
end

drawWindow = function()
  V.reg = {}
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ House View - " .. tostring(SETTINGS.systemName or "House"), true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(V.reg, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(V.reg, bx + 7, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  text(WX + 2, WY + 2, " House ", K.black, K.face)
  text(WX + 9, WY + 2, " Help ", K.black, K.face)
  region(V.reg, WX + 2, WY + 2, 7, 1, function()
    popupMenu(WX + 2, WY + 3, {
      { "Wallet", function() V.tab = "wallet" end },
      { "Ledger", function() V.tab = "ledger" end },
      { "Rules", function() V.tab = "rules" end },
      { "-" },
      { rules.open and "Close the casino" or "Open the casino", function() rules.open = not rules.open; rulesChanged() end },
      { "Broadcast rules now", function() broadcast(); V.saved = "Rules sent." end },
      { "Save snapshot now", function() snapshot(); V.saved = "Snapshot saved, journal restarted." end },
    })
  end)
  region(V.reg, WX + 9, WY + 2, 6, 1, function()
    popupMenu(WX + 9, WY + 3, { { "About House View...", function()
      dialog("About House View", {
        "The bank of the Lymanos Casino. Bets come in from Lymanos computers on",
        "port " .. CONFIG.PORT .. "; each is checked, logged and confirmed, and every result is",
        "paid from this wallet. Repeated messages are answered without paying twice.",
        "Every transaction is appended to " .. CONFIG.JOURNAL .. " before it",
        "is answered, so a restart rebuilds the exact same wallet.",
      }, { { "OK" } })
    end } })
  end)
  -- tab strip
  fill(X0, TY, CW, 1, G.header)
  text(X0 + 1, TY, "$ HOUSE VIEW", G.gold, G.header)
  local x = X0 + 15
  for _, t in ipairs({ { "wallet", " WALLET " }, { "ledger", " LEDGER " }, { "rules", " RULES & ODDS " } }) do
    local on = V.tab == t[1]
    text(x, TY, t[2], on and G.dark or G.dim, on and G.gold or G.panel2)
    region(V.reg, x, TY, unicode.len(t[2]), 1, function() V.tab = t[1]; drawWindow() end)
    x = x + unicode.len(t[2]) + 1
  end
  textW(X1 - 40, TY, 40, money(H.wallet) .. "  ", G.gold, G.header, "right")
  fill(X0, TOP, CW, BOT - TOP + 1, G.bg)
  if V.tab == "wallet" then drawWallet() elseif V.tab == "ledger" then drawLedger() else drawRules() end
  drawStatus()
end

local function tick()
  local up = computer.uptime()
  if up - V.lastCast >= CONFIG.BROADCAST_EVERY then broadcast() end
  -- forget rounds that never got a bet (all refused) after an hour
  for rid, r in pairs(rounds) do
    if r.tot <= 0 and now() - (r.t or 0) > 3600 then rounds[rid] = nil end
  end
  if visible() and V.tab == "rules" then
    textW(X0 + 75 + 2, BOT, CW - 75 - 4, "Last broadcast " .. fmtDurLong(up - V.lastCast) .. " ago", G.dim, G.panel)
  end
end

-- redraw after money moved, at most ~3 times a second (busy tables send a lot)
local function flush()
  if not V.dirty or computer.uptime() - (V.drawn or 0) < 0.35 then return end
  V.dirty, V.drawn = false, computer.uptime()
  if visible() then drawWindow() elseif not overlay and not LOCK.isLocked() then drawTray(now()) end
end

local function scroll(x, y, dir)
  if V.tab == "ledger" and y > TOP + 2 and y < BOT then
    V.scroll = V.scroll - dir * 3
    drawLedgerRows()
  end
end

return {
  load = load, drawWindow = function() drawWindow() end, tick = tick, scroll = scroll,
  onMessage = onMessage, broadcast = broadcast, flush = flush, snapshot = function() pcall(snapshot) end,
  regions = function() return V.reg end,
  clients = online,
  wallet = function() return H.wallet end,
  openRounds = function() return (openMoney()) end,
  note = function(m) V.saved, V.dirty = m, true end,
}
end)()

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
  textW(x + 2, y + 31, PW - 8, "houseview is using about " ..
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
-- Uses the overlay; the house keeps taking bets underneath.
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
  parts[#parts + 1] = "House wallet $" .. commas(HV.wallet())
  parts[#parts + 1] = HV.clients() .. " player computer(s) online"
  parts[#parts + 1] = HV.openRounds() .. " round(s) in play"
  parts[#parts + 1] = string.format("RAM %dK free", floor(computer.freeMemory() / 1024))
  local s = table.concat(parts, "   ·   ")
  textW(W - 81, 49, 80, s, style()[4], rowBg(49), "right")
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
local saved = nil
local FX = 36

local function idxOf(list, v)
  for i, x in ipairs(list) do if x == v then return i end end
  return 1
end
local function step(list, v, d) return list[(idxOf(list, v) - 1 + d) % #list + 1] end
local function changed(msg) saveSettings(); saved = msg or "Saved"; drawAll() end

local function field(id, x, y, w, value)
  if focus == id then textW(x, y, w, " " .. input .. "_", K.black, 0xFFFFC0)
  else textW(x, y, w, " " .. value, K.navy, K.white) end
  region(regions, x, y, w, 1, function() focus, input = id, ""; drawAll() end)
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
  field("user", 36, 7, 28, PLAYER_NAME)
  field("system", 36, 9, 28, SETTINGS.systemName or "Lymanos House")
end

local function drawWindow()
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ Settings - " .. tostring(SETTINGS.systemName or "Lymanos House"), true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(regions, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(regions, bx + 7, WY + 1, 3, 1, function() closeSettings() end)
  local L, R, LWd, RWd = 18, 88, 66, 66
  groupBox(L - 2, 5, LWd + 2, 9, "Name")
  label(L, 7, "Your name:")
  label(L, 9, "House name:")
  drawFields()
  note(L, 11, LWd - 2, "The house name is shown to every player in the Casino.")
  note(L, 12, LWd - 2, "Click a box, type, press Enter.")
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
  note(L, 21, LWd - 2, "Used on the taskbar, lock screen and House View.")
  groupBox(L - 2, 24, LWd + 2, 19, "About This Computer")
  local total, free = computer.totalMemory(), computer.freeMemory()
  local rows = {
    { "System:", tostring(SETTINGS.systemName) .. "  (houseview 1.0)" },
    { "User:", tostring(PLAYER_NAME) },
    { "Memory:", string.format("%d K used of %d K", floor((total - free) / 1024), floor(total / 1024)) },
    { "Network card:", wlan.address:sub(1, 8) .. (wlan.isWireless() and " (wireless)" or " (wired)") },
    { "House port:", tostring(CONFIG.PORT) .. "  (HOUSE_PORT in lymanos.lua)" },
    { "Journal:", CONFIG.JOURNAL },
    { "Settings file:", CONFIG.SETTINGS_FILE },
  }
  for i, r in ipairs(rows) do
    label(L, 25 + i, r[1])
    textW(L + FX - 18, 25 + i, LWd - FX + 16, r[2], K.black, K.face)
  end
  note(L, 34, LWd - 2, "Game rules and odds are in House View > Rules & Odds.")
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
  note(R, 17, RWd - 2, "The house keeps taking bets while the screen is locked.")
  button(regions, R, 18, 20, "Lock Now", function() LOCK.lock() end)
  local yy = WY + WH - 2
  fill(WX + 1, yy, WW - 2, 1, K.face)
  textW(WX + 2, yy, WW - 4, saved or "Changes are saved automatically.", saved and K.navy or K.black, K.face)
  saved = nil
end

local function key(ch, code)
  if code == 28 or code == 156 then
    local v, id = input, focus
    focus, input = nil, ""
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    if id == "user" then
      SETTINGS.userName = (v ~= "") and v or nil
      PLAYER_NAME = SETTINGS.userName or CONFIG.PLAYER_NAME or "House"
      changed("Name saved")
    elseif id == "system" then
      SETTINGS.systemName = (v ~= "") and v or "Lymanos House"
      HV.broadcast()
      changed("House name saved - players see it on their next update")
    end
  elseif code == 1 then focus, input = nil, ""; drawFields()
  elseif code == 14 then input = input:sub(1, -2); drawFields()
  elseif ch and ch >= 32 and ch < 127 then
    local c = string.char(ch)
    if c:match("[%w %-_%.']") and #input < 20 then input = input .. c; drawFields() end
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

local function confirmExit()
  dialog("Shut Down", { "Close the house? Players can't bet until it runs again.",
    "(Nothing is lost: unfinished bets are re-sent when it's back.)" },
    { { "Yes", function() running = false end }, { "No" } })
end

openStartMenu = function()
  popupMenu(1, 47, {
    { "House View", function() activeApp = "house" end },
    { "My Computer", function() openSysApp() end },
    { "Settings", function() openSettings() end },
    { "-" },
    { "Lock", function() LOCK.lock() end },
    { "-" },
    { "Shut Down...", confirmExit },
  }, { banner = true, above = true, start = true })
end

drawAll = function(keepOverlay)
  if LOCK.isLocked() then LOCK.draw(); return end
  local t = now()
  regions = {}
  SYS.resetRegions()
  if not keepOverlay then overlay = nil end
  drawDesktop()
  if activeApp == "house" then HV.drawWindow()
  elseif activeApp == "sys" then SYS.drawWindow()
  elseif activeApp == "settings" then SET.drawWindow() end
  drawTaskbar(t)
end

------------------------------------------------------------- MAIN LOOP
local oldW, oldH = gpu.getResolution()

local function main()
  local mw, mh = gpu.maxResolution()
  if mw < W or mh < H then error("houseview needs a tier 3 GPU and screen (160x50).", 0) end
  gpu.setResolution(W, H)
  fill(1, 1, W, H, 0x000000)
  text(2, 2, "Loading the house journal...", 0xF2C14E, 0x000000)
  HV.load()
  drawAll()
  HV.broadcast()
  local lastTick = 0
  while running do
    local ev = { event.pull(0.25) }
    local name = ev[1]
    if name == "touch" or name == "drag" or name == "scroll" or name == "key_down" then LOCK.poke() end
    if name == "interrupted" then
      running = false
    elseif name == "modem_message" and ev[4] == CONFIG.PORT and ev[6] == "HOUSE" then
      local ok, err = pcall(HV.onMessage, ev[3], ev[7], ev[8])
      if not ok then HV.note("Error: " .. tostring(err)) end
    elseif name == "key_down" and LOCK.isLocked() then
      LOCK.key(ev[4])
    elseif name == "touch" then
      local x, y = ev[3], ev[4]
      if overlay then
        if not hit(overlay.regions, x, y) and not overlay.modal then closeOverlay() end
      elseif hit(taskRegions, x, y) then
        -- taskbar
      elseif activeApp == "house" then
        if not hit(HV.regions(), x, y) then hit(regions, x, y) end
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
    elseif name == "scroll" and not overlay and activeApp == "house" then
      HV.scroll(ev[3], ev[4], ev[5])
    elseif name == "scroll" and not overlay and activeApp == "sys" then
      SYS.scroll(ev[3], ev[4], ev[5])
    elseif name == "key_down" and activeApp == "settings" and SET.focus() and not overlay then
      SET.key(ev[3], ev[4])
    end
    HV.flush()
    local up = computer.uptime()
    if running and up - lastTick >= 1 then
      lastTick = up
      local t = now()
      HV.tick()
      if LOCK.isLocked() then LOCK.tick(t)
      elseif not overlay then drawTray(t) end
      SYS.tick(activeApp == "sys" and not overlay)
      local mins = SETTINGS.lockMins or 0
      if mins > 0 and not LOCK.isLocked() and LOCK.idle() >= mins * 60 then LOCK.lock() end
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
gpu.setResolution(oldW, oldH)
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
term.clear()
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write(tostring(err) .. "\n")
end
