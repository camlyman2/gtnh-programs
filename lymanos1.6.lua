--[[
  lymanos.lua  -  Lymanos (a Windows 98 style desktop for OpenComputers)
  (formerly lscview)

  Apps:
    Logs          LSC charging-cycle log received from lscstats over
                  wireless: overview, log lists and two graph panels
                  you can switch with a dropdown.
    Chess         two-player chess between two Lymanos computers (port 4041)
    Brokerage     watchlist, price graphs and a paper-trading portfolio
                  (needs an Internet Card)
    Bank          your savings account (the money every app spends from and pays
                  into), investments, a daily salary and the size of the economy
                  (port 4045)
    Casino        Blackjack (solo or with a friend, port 4043), Let it Ride (a
                  crash game), Roulette and a daily Prize Wheel. Plays with your Brokerage cash; every bet and
                  result is confirmed by the house server (houseview.lua, port 4044)
    My Computer   storage, memory, power and hardware details
    Settings      your name, system name, lock screen, desktop color,
                  Brokerage options. Saved to /home/lymanos_settings.dat

  Lock screen: Start > Lock, or automatically after a period without
  activity (Settings). Everything keeps running while locked.

  Files written on this computer:
    /home/lscstats_copy.dat     latest copy of the lscstats log as received
    /home/lymanos_*.dat         archive, chess game, stocks, portfolio, casino, settings
    /home/lymanos_portfolio_<name>.dat   bank account (savings + history) and holdings
    /home/lymanos_economy.dat   other players' last known balances + 7-day economy history
    (old /home/lscview_*.dat files are renamed to lymanos_*.dat on first start)

  Needs: tier 3 GPU + tier 3 screen (160x50) and a Wireless Network
  Card (tier 2 recommended). Mouse + keyboard. Exit: Start > Shut Down,
  File > Exit Lymanos, or Ctrl+C.
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  PORT = 4040,                 -- must match WIRELESS_PORT in lscstats.lua
  SENDER = nil,                -- nil = accept any lscstats computer, or put its card address
  ARCHIVE_MAX = 100,           -- cycles kept in the local archive
  GRAPH_CYCLES = 8,            -- cycles shown in the chart
  STALE_SECONDS = 75,          -- no packet for this long = "Not Responding"
  COPY_FILE = "/home/lscstats_copy.dat",
  ARCHIVE_FILE = "/home/lymanos_archive.dat",

  -- Chess
  PLAYER_NAME = nil,           -- default name; normally set in the Settings app
  CHESS_PORT = 4041,           -- must be the same on both computers

  -- Live feeds for the Logs graphs (wireless broadcasts from other programs)
  FUEL_PORT = 4041,            -- lscfuel.lua (LSC EU in/out, charge %). Shares 4041 with chess - that's fine
  FARM_PORT = 4042,            -- treefarm2.lua (Oak Wood count, farm running / last ON)
  FEED_STALE = 30,             -- seconds without a packet = that feed is offline
  FEED_STEP = 60,              -- graph point every N seconds (averaged); 240 points kept = 4 hours
  CHESS_FILE = "/home/lymanos_chess.dat",   -- saved game (resumes after restart)

  -- Brokerage (needs an Internet Card)
  STOCK_PROVIDER = "yahoo",    -- "yahoo" (no key needed) or "finnhub" (free key from finnhub.io)
  FINNHUB_KEY = nil,           -- e.g. "abc123..." when STOCK_PROVIDER = "finnhub"
  STOCK_REFRESH = 60,          -- seconds between price refreshes
  STOCK_LOG_EVERY = 300,       -- seconds between saved history points (graph)
  STOCK_LOG_MAX = 1170,        -- 5-minute prices kept per ticker (about 15 trading days, 4 bytes each;
                               -- every +1170 costs about 90 KB of RAM with 12 tickers)
                               -- (each point costs ~32 bytes of RAM per ticker)
  STOCK_MAX_TICKERS = 12,
  STOCK_FILE = "/home/lymanos_stocks.dat",

  -- Paper trading (Brokerage > Portfolio). Fake money, real prices.
  PORTFOLIO_FILE = "/home/lymanos_portfolio_%s.dat", -- %s = your name, one account per player
  PORTFOLIO_START_CASH = 100000,   -- cash in a brand-new account
  PORTFOLIO_SET_CASH = nil,        -- set a number (e.g. 250000) to set the cash once; counts as a deposit
  PORTFOLIO_MARKET_HOURS = true,   -- only trade Mon-Fri 9:30-4:00 ET (crypto -USD and forex =X always)
  OPTION_RATE = 0.04,              -- interest rate used in option prices
  OPTION_DEFAULT_VOL = 0.35,       -- volatility used until there are enough saved prices
  OPTION_SPREAD = 0.02,            -- formula prices: buy 2% above / sell 2% below
  OPTION_VOL = {},                 -- your own volatility per ticker for the formula,
                                   -- e.g. { AAPL = 0.28, TSLA = 0.55 }
  OPTION_REAL_PRICES = true,       -- use Yahoo's real option bid/ask when it answers
  OPTION_CHAIN_REFRESH = 120,      -- seconds between option-quote refreshes (market open)
  OPTION_FEED_RETRY = 600,         -- after Yahoo refuses, wait this long before trying again

  -- Bank: the savings account every app pays from / into, salary, economy
  BANK_NAME = "Lymanos Bank",
  SALARY = 100000,                 -- dollars per year; SALARY / 365 is deposited every day
  PAYDAY_HOUR = 21,                -- 0-23, US Eastern time (21 = 9 PM)
  PAYDAY_MINUTE = 0,
  SALARY_BACKPAY_DAYS = 30,        -- missed paydays (Lymanos was off) paid later, at most this many
  DAILY_SPINS = 1,                 -- free Prize Wheel spins given with each payday
  BANK_PORT = 4045,                -- every Lymanos announces its owner's balances here (Economy tab)
  BANK_HISTORY = 120,              -- transactions kept in the account file
  ECON_FILE = "/home/lymanos_economy.dat",

  -- Casino (Blackjack + Let it Ride). Money comes from your Bank savings account.
  CASINO_PORT = 4043,              -- blackjack tables between Lymanos computers
  HOUSE_PORT = 4044,               -- must match PORT in houseview.lua (the house server)
  HOUSE_ADDR = nil,                -- nil = use the house that broadcasts, or put its card address
  HOUSE_STALE = 20,                -- seconds without the house's broadcast = house offline
  CASINO_FILE = "/home/lymanos_casino_%s.dat",   -- %s = your name (tables, history)

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
  userName = nil,       -- your name (Chess + Brokerage account)
  systemName = "Lymanos",
  lockMins = 30,        -- auto-lock after this many idle minutes (0 = never)
  lockStyle = 1,        -- lock screen color theme
  clock24 = false,      -- 24-hour clock on the taskbar and lock screen
  desk = 1,             -- desktop color
  stockRefresh = nil,   -- seconds between Brokerage refreshes
  optReal = nil,        -- Yahoo option prices on/off
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
if SETTINGS.stockRefresh then CONFIG.STOCK_REFRESH = SETTINGS.stockRefresh end
if SETTINGS.optReal ~= nil then CONFIG.OPTION_REAL_PRICES = SETTINGS.optReal end

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
  -- a wired network card still works if both computers share a cable network
  local a = component.list("modem")()
  if a then wlan = component.proxy(a) end
end
if not wlan then
  io.stderr:write("No network card found. Install a Wireless Network Card (tier 2).\n")
  return
end
wlan.open(CONFIG.PORT)
wlan.open(CONFIG.CHESS_PORT)
wlan.open(CONFIG.FUEL_PORT)
wlan.open(CONFIG.FARM_PORT)
wlan.open(CONFIG.CASINO_PORT)
wlan.open(CONFIG.HOUSE_PORT)
wlan.open(CONFIG.BANK_PORT)
local PLAYER_NAME = SETTINGS.userName or CONFIG.PLAYER_NAME or ("Player-" .. wlan.address:sub(1, 4))

local function requestUpdate()
  pcall(wlan.broadcast, CONFIG.PORT, "LSCSTATS_REQ")
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

---------------------------------------------------------- CHESS ENGINE
-- Board: squares 0..63, sq = rank*8 + file (a1 = 0, h8 = 63).
-- Piece: { c = "w"|"b", t = "p"|"n"|"b"|"r"|"q"|"k" }, empty = nil.
local CH = {}

local function sqName(s) return string.char(97 + s % 8) .. tostring(floor(s / 8) + 1) end
CH.sqName = sqName

local KN = { { 1, 2 }, { 2, 1 }, { -1, 2 }, { -2, 1 }, { 1, -2 }, { 2, -1 }, { -1, -2 }, { -2, -1 } }
local KG = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local DIAG = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local ORTH = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local LETTER = { p = "P", n = "N", b = "B", r = "R", q = "Q", k = "K" }
CH.LETTER = LETTER

local function opp(c) return c == "w" and "b" or "w" end
CH.opp = opp

-- false = off the board, nil = empty square, table = piece
local function at(b, f, r)
  if f < 0 or f > 7 or r < 0 or r > 7 then return false end
  return b[r * 8 + f]
end

local function slideHits(b, f, r, dirs, by, t1, t2)
  for _, d in ipairs(dirs) do
    local ff, rr = f + d[1], r + d[2]
    while true do
      local p = at(b, ff, rr)
      if p == false then break end
      if p then
        if p.c == by and (p.t == t1 or p.t == t2) then return true end
        break
      end
      ff, rr = ff + d[1], rr + d[2]
    end
  end
  return false
end

-- is square sq attacked by color `by`?
function CH.attacked(b, sq, by)
  local f, r = sq % 8, floor(sq / 8)
  local pr = (by == "w") and r - 1 or r + 1
  for _, df in ipairs({ -1, 1 }) do
    local p = at(b, f + df, pr)
    if p and p.c == by and p.t == "p" then return true end
  end
  for _, d in ipairs(KN) do
    local p = at(b, f + d[1], r + d[2])
    if p and p.c == by and p.t == "n" then return true end
  end
  for _, d in ipairs(KG) do
    local p = at(b, f + d[1], r + d[2])
    if p and p.c == by and p.t == "k" then return true end
  end
  return slideHits(b, f, r, DIAG, by, "b", "q") or slideHits(b, f, r, ORTH, by, "r", "q")
end

function CH.kingSq(b, c)
  for i = 0, 63 do
    local p = b[i]
    if p and p.c == c and p.t == "k" then return i end
  end
end

local function pseudo(st, c)
  local b, out = st.board, {}
  local function add(from, to, flag, promo)
    out[#out + 1] = { from = from, to = to, flag = flag, promo = promo }
  end
  for sq = 0, 63 do
    local p = b[sq]
    if p and p.c == c then
      local f, r = sq % 8, floor(sq / 8)
      if p.t == "p" then
        local dir = (c == "w") and 1 or -1
        local startR, promoR = (c == "w") and 1 or 6, (c == "w") and 7 or 0
        local function pawnAdd(to, flag)
          if floor(to / 8) == promoR then
            for _, pt in ipairs({ "q", "r", "b", "n" }) do add(sq, to, flag, pt) end
          else
            add(sq, to, flag)
          end
        end
        if at(b, f, r + dir) == nil then
          pawnAdd(sq + dir * 8)
          if r == startR and at(b, f, r + 2 * dir) == nil then add(sq, sq + 16 * dir, "double") end
        end
        for _, df in ipairs({ -1, 1 }) do
          local t = at(b, f + df, r + dir)
          if t and t.c ~= c then
            pawnAdd(sq + dir * 8 + df)
          elseif t == nil and st.ep == sq + dir * 8 + df then
            add(sq, st.ep, "ep")
          end
        end
      elseif p.t == "n" or p.t == "k" then
        for _, d in ipairs(p.t == "n" and KN or KG) do
          local t = at(b, f + d[1], r + d[2])
          if t ~= false and (t == nil or t.c ~= c) then add(sq, (r + d[2]) * 8 + f + d[1]) end
        end
      else
        local dirs = (p.t == "b") and DIAG or (p.t == "r") and ORTH or KG
        for _, d in ipairs(dirs) do
          local ff, rr = f + d[1], r + d[2]
          while true do
            local t = at(b, ff, rr)
            if t == false then break end
            if t == nil then
              add(sq, rr * 8 + ff)
            else
              if t.c ~= c then add(sq, rr * 8 + ff) end
              break
            end
            ff, rr = ff + d[1], rr + d[2]
          end
        end
      end
    end
  end
  -- castling (king may not start in, pass through, or land in check)
  local base, o = (c == "w") and 0 or 56, opp(c)
  local k = b[base + 4]
  if k and k.t == "k" and k.c == c and not CH.attacked(b, base + 4, o) then
    local rk = b[base + 7]
    if st.castle[c .. "K"] and rk and rk.t == "r" and rk.c == c and not b[base + 5] and not b[base + 6]
        and not CH.attacked(b, base + 5, o) and not CH.attacked(b, base + 6, o) then
      add(base + 4, base + 6, "castleK")
    end
    local rq = b[base]
    if st.castle[c .. "Q"] and rq and rq.t == "r" and rq.c == c and not b[base + 1] and not b[base + 2]
        and not b[base + 3] and not CH.attacked(b, base + 3, o) and not CH.attacked(b, base + 2, o) then
      add(base + 4, base + 2, "castleQ")
    end
  end
  return out
end

local function boardAfter(b, m, c)
  local nb = {}
  for i = 0, 63 do nb[i] = b[i] end
  local p = nb[m.from]
  nb[m.to] = m.promo and { c = c, t = m.promo } or p
  nb[m.from] = nil
  if m.flag == "ep" then nb[m.to + ((c == "w") and -8 or 8)] = nil end
  if m.flag == "castleK" then nb[m.from + 1] = nb[m.from + 3]; nb[m.from + 3] = nil end
  if m.flag == "castleQ" then nb[m.from - 1] = nb[m.from - 4]; nb[m.from - 4] = nil end
  return nb
end

function CH.legal(st)
  local c, o, out = st.turn, opp(st.turn), {}
  for _, m in ipairs(pseudo(st, c)) do
    local nb = boardAfter(st.board, m, c)
    if not CH.attacked(nb, CH.kingSq(nb, c), o) then out[#out + 1] = m end
  end
  return out
end

function CH.uci(m) return sqName(m.from) .. sqName(m.to) .. (m.promo or "") end

-- new position after move m (no bookkeeping)
function CH.apply(st, m)
  local c, b = st.turn, st.board
  local p = b[m.from]
  local capture = (b[m.to] ~= nil) or m.flag == "ep"
  local ns = {
    board = boardAfter(b, m, c), turn = opp(c),
    castle = { wK = st.castle.wK, wQ = st.castle.wQ, bK = st.castle.bK, bQ = st.castle.bQ },
    ep = (m.flag == "double") and (m.from + ((c == "w") and 8 or -8)) or nil,
    half = (p.t == "p" or capture) and 0 or st.half + 1,
    full = (c == "b") and st.full + 1 or st.full,
    uci = st.uci, notes = st.notes, reps = st.reps,
  }
  if p.t == "k" then ns.castle[c .. "K"], ns.castle[c .. "Q"] = false, false end
  for _, s in ipairs({ m.from, m.to }) do
    if s == 0 then ns.castle.wQ = false elseif s == 7 then ns.castle.wK = false
    elseif s == 56 then ns.castle.bQ = false elseif s == 63 then ns.castle.bK = false end
  end
  return ns, capture, p
end

function CH.key(st)
  local t = {}
  for i = 0, 63 do
    local p = st.board[i]
    t[#t + 1] = p and (p.c == "w" and LETTER[p.t] or p.t) or "."
  end
  local cs = (st.castle.wK and "K" or "") .. (st.castle.wQ and "Q" or "")
          .. (st.castle.bK and "k" or "") .. (st.castle.bQ and "q" or "")
  return table.concat(t) .. st.turn .. cs .. (st.ep and sqName(st.ep) or "-")
end

-- "ok" | "check" | "checkmate" | "stalemate" | "fifty" | "repetition" | "material"
function CH.status(st, legalList)
  local c = st.turn
  local inCheck = CH.attacked(st.board, CH.kingSq(st.board, c), opp(c))
  legalList = legalList or CH.legal(st)
  if #legalList == 0 then return inCheck and "checkmate" or "stalemate" end
  if st.half >= 100 then return "fifty" end
  if (st.reps[CH.key(st)] or 0) >= 3 then return "repetition" end
  local minors, other = 0, 0
  for i = 0, 63 do
    local p = st.board[i]
    if p and p.t ~= "k" then
      if p.t == "b" or p.t == "n" then minors = minors + 1 else other = other + 1 end
    end
  end
  if other == 0 and minors <= 1 then return "material" end
  return inCheck and "check" or "ok"
end

function CH.new()
  local b = {}
  local back = { "r", "n", "b", "q", "k", "b", "n", "r" }
  for f = 0, 7 do
    b[f] = { c = "w", t = back[f + 1] }
    b[8 + f] = { c = "w", t = "p" }
    b[48 + f] = { c = "b", t = "p" }
    b[56 + f] = { c = "b", t = back[f + 1] }
  end
  local st = { board = b, turn = "w", castle = { wK = true, wQ = true, bK = true, bQ = true },
               ep = nil, half = 0, full = 1, uci = {}, notes = {}, reps = {}, state = "ok" }
  st.reps[CH.key(st)] = 1
  st.legalList = CH.legal(st)
  return st
end

-- play a move for real: returns the new state with history, notation and status
function CH.play(st, m)
  local ns, capture, p = CH.apply(st, m)
  local note
  if m.flag == "castleK" then note = "O-O"
  elseif m.flag == "castleQ" then note = "O-O-O"
  else
    note = (p.t ~= "p" and LETTER[p.t] or "") .. sqName(m.from) .. (capture and "x" or "-")
        .. sqName(m.to) .. (m.promo and ("=" .. LETTER[m.promo]) or "")
  end
  ns.uci[#ns.uci + 1] = CH.uci(m)
  local k = CH.key(ns)
  ns.reps[k] = (ns.reps[k] or 0) + 1
  ns.last = { from = m.from, to = m.to }
  ns.legalList = CH.legal(ns)
  ns.state = CH.status(ns, ns.legalList)
  if ns.state == "checkmate" then note = note .. "#" elseif ns.state == "check" then note = note .. "+" end
  ns.notes[#ns.notes + 1] = note
  return ns
end

function CH.findMove(st, uci)
  for _, m in ipairs(st.legalList or CH.legal(st)) do
    if CH.uci(m) == uci then return m end
  end
end

-- rebuild a game from a list of uci moves; nil if any move is illegal
function CH.replay(list, yield)
  local st = CH.new()
  for i, u in ipairs(list) do
    local m = CH.findMove(st, u)
    if not m then return nil end
    st = CH.play(st, m)
    if yield and i % 8 == 0 then yield() end
  end
  return st
end

-- 8x8 piece silhouettes; an outline is added automatically around them
local SPRITES = {
  p = { "........", "........", "...xx...", "..xxxx..", "...xx...", "..xxxx..", "..xxxx..", "........" },
  r = { "........", ".x.xx.x.", ".xxxxxx.", "..xxxx..", "..xxxx..", ".xxxxxx.", ".xxxxxx.", "........" },
  n = { "........", "...xx...", "..xxxx..", ".xxxxxx.", ".xx.xxx.", "....xxx.", "..xxxxx.", "........" },
  b = { "........", "...xx...", "..x.xx..", "..xxxx..", "...xx...", "..xxxx..", ".xxxxxx.", "........" },
  q = { "........", "x..xx..x", ".xxxxxx.", "..xxxx..", "..xxxx..", "..xxxx..", ".xxxxxx.", "........" },
  k = { "........", "...xx...", ".xxxxxx.", "...xx...", "..xxxx..", "..xxxx..", ".xxxxxx.", "........" },
}
local MASKS = {}
for t, rows in pairs(SPRITES) do
  local body, line = {}, {}
  for y = 1, 8 do for x = 1, 8 do
    if rows[y]:sub(x, x) == "x" then body[y * 10 + x] = true end
  end end
  for y = 1, 8 do for x = 1, 8 do
    local k = y * 10 + x
    if not body[k] and (body[k - 10] or body[k + 10] or body[k - 1] or body[k + 1]) then line[k] = true end
  end end
  MASKS[t] = { body = body, line = line }
end

local function pieceOnCanvas(cv, p, fillC, lineC)
  local m = MASKS[p]
  for k in pairs(m.line) do cset(cv, k % 10, floor(k / 10), lineC) end
  for k in pairs(m.body) do cset(cv, k % 10, floor(k / 10), fillC) end
end

------------------------------------------------------------------ STATE
local running = true
local activeApp = "viewer"    -- window in front: "viewer" | "chess" | nil (desktop)
local chessOpen, chessAlert = false, false
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

local drawAll, openChess, openStockApp, stockAppOpen   -- forward
local openSysApp, closeSysApp, sysAppOpen                -- forward (My Computer)
local openSettings, closeSettings, settingsOpen          -- forward (Settings)
local LOCK, SET, CAS, BANK                               -- lock screen, Settings, Casino, Bank (below)

local function drawDesktop()
  fill(1, 1, W, 46, K.desk)
  drawIcon(3, 2, "pc", "My Computer")
  drawIcon(3, 8, "doc", "Logs")
  -- Bank icon: a little bank building
  text(4, 14, "▗▄▟██▙▄▖", 0x14874C, K.desk)
  text(4, 15, "▐▌ ▐▌ ▐▌", 0x0B6B3A, 0xFFFFFF)
  text(4, 16, "▀▀▀▀▀▀▀▀", 0x0B6B3A, K.desk)
  textW(1, 17, 12, "Bank", K.white, K.desk, "center")
  region(regions, 1, 14, 12, 4, function() BANK.open(); drawAll() end)
  drawIcon(3, 43, "bin", "Recycle Bin")
  local cv = newCanvas(8, 8, K.desk)
  pieceOnCanvas(cv, "n", K.white, K.black)
  crender(cv, 4, 20)
  textW(1, 24, 12, "Chess", K.white, K.desk, "center")
  region(regions, 1, 2, 12, 5, function() openSysApp(); drawAll() end)
  region(regions, 1, 8, 12, 5, function() activeApp = "viewer"; drawAll() end)
  region(regions, 1, 20, 12, 5, function() openChess(); drawAll() end)
  -- Brokerage icon: a little rising chart
  fill(4, 26, 8, 3, K.white)
  text(4, 26, "    ▗▞▀", 0x007A00, K.white)
  text(4, 27, "▁▗▄▞   ", 0x007A00, K.white)
  text(4, 28, "▔▔▔▔▔▔▔▔", K.sh, K.white)
  textW(1, 29, 12, "Brokerage", K.white, K.desk, "center")
  region(regions, 1, 26, 12, 4, function() openStockApp(); drawAll() end)
  -- Settings icon: a little control panel with sliders
  fill(4, 32, 8, 3, K.face)
  text(4, 32, "─●──────", K.navy, K.face)
  text(4, 33, "────●───", K.navy, K.face)
  text(4, 34, "──────●─", K.navy, K.face)
  textW(1, 35, 12, "Settings", K.white, K.desk, "center")
  region(regions, 1, 32, 12, 4, function() openSettings(); drawAll() end)
  -- Casino icon: two playing cards
  fill(4, 38, 5, 3, K.white)
  text(4, 38, "A♠", K.black, K.white)
  fill(7, 39, 5, 3, K.white)
  text(8, 40, "K♥", K.red, K.white)
  text(7, 39, "▐", K.sh, K.white)
  textW(1, 42, 12, "Casino", K.white, K.desk, "center")
  region(regions, 1, 38, 12, 5, function() CAS.open(); drawAll() end)
end

----------------------------------------------------------------- TASKBAR

local function drawTray(t)
  bevel(144, 48, 16, 3, "sunken", K.face, K.face)
  local ok = responding(t)
  text(146, 49, "((•))", ok and K.green or K.sh, K.face)
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
    if app == "chess" and activeApp == "chess" then chessAlert = false end
    drawAll()
  end)
end

local function drawTaskbar(t)
  taskRegions = {}
  fill(1, 47, W, 4, K.face)
  text(1, 47, string.rep("▔", W), K.hi, K.face)
  button(taskRegions, 1, 48, 9, "◆ Start", function() openStartMenu() end, overlay and overlay.start)
  local list = { { " ▣ Logs", "viewer" } }
  if chessOpen then list[#list + 1] = { chessAlert and " ▣ Chess - YOUR MOVE!" or " ▣ Chess", "chess" } end
  if stockAppOpen and stockAppOpen() then list[#list + 1] = { " ▣ Brokerage", "stock" } end
  if BANK and BANK.isOpen() then list[#list + 1] = { " ⌂ Bank", "bank" } end
  if CAS and CAS.isOpen() then list[#list + 1] = { CAS.alert() and " ♠ Casino - YOUR TURN!" or " ♠ Casino", "casino" } end
  if sysAppOpen and sysAppOpen() then list[#list + 1] = { " ▣ My Computer", "sys" } end
  if settingsOpen and settingsOpen() then list[#list + 1] = { " ▣ Settings", "settings" } end
  local bw = min(25, floor(132 / #list) - 1)      -- buttons shrink when many apps are open
  for i, it in ipairs(list) do taskButton(11 + (i - 1) * (bw + 1), bw, it[1], it[2]) end
  drawTray(t)
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
    lastFrom and (lastFrom:sub(1, 8) .. (lastDist and ("  " .. floor(lastDist + 0.5) .. " blocks") or "")) or "")
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
    if not f then return { { "Waiting for lscfuel on port " .. CONFIG.FUEL_PORT .. " (needs its wireless card)", G.warn } } end
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
    if not f then return { { "Waiting for treefarm2 on port " .. CONFIG.FARM_PORT .. " (needs its wireless card)", G.warn } } end
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
  local title = "Logs - LSC charging cycles"
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
    { "  │  port " .. CONFIG.PORT .. (wlan.isWireless() and " wireless" or " wired"), G.dim },
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
    tostring(SETTINGS.systemName or "Lymanos") .. "  -  Logs (Lymanos 2.0)",
    "Receives the charging-cycle log from lscstats",
    "over wireless (port " .. CONFIG.PORT .. ") and keeps an archive.",
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
  dialog("Shut Down", { "Are you sure you want to close Lymanos?" },
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
  popupMenu(1, 47, {
    { "Logs", function() activeApp = "viewer" end },
    { "Chess", function() openChess() end },
    { "Brokerage", function() openStockApp() end },
    { "Bank", function() BANK.open() end },
    { "Casino", function() CAS.open() end },
    { "My Computer", function() openSysApp() end },
    { "Settings", function() openSettings() end },
    { "-" },
    { "Lock", function() LOCK.lock() end },
    { "Request Update", function() requestUpdate(); statusMsg = "Update requested..." end },
    { "Clear Archive...", confirmClear },
    { "About...", about },
    { "-" },
    { "Shut Down...", confirmExit },
  }, { banner = true, above = true, start = true })
end


--------------------------------------------------------------- CHESS APP
local CK = {
  light = 0xEEEED2, dark = 0x769656,       -- board squares
  lastL = 0xF6F680, lastD = 0xBACA44,      -- last move
  selL = 0xF7EC74, selD = 0xDAC34B,        -- selected piece
  check = 0xE04848, target = 0x2E4A22,     -- king in check / move dots
  wFill = 0xFFFFFF, wLine = 0x000000,      -- white pieces
  bFill = 0x1A1A1A, bLine = 0x9A9A9A,      -- black pieces
}
local BX, BY, PX = 20, 6, 89               -- board origin, side panel x
local game = nil        -- { id, opp, oppName, color, uci, result }
local cs = CH.new()     -- position shown on the board
local sel, targets = nil, {}
local players = {}      -- address -> { name, dist }
local pendingInvite = nil
local chessMsg = "Click Find Players to look for an opponent."
local drawChessRight    -- forward

local function flipped() return game ~= nil and game.color == "b" end
local function colorName(c) return c == "w" and "White" or "Black" end

local function chessSend(to, kind, ...)
  pcall(wlan.send, to, CONFIG.CHESS_PORT, "CHESS", kind, ...)
end

local function saveGame()
  if game then writeFile(CONFIG.CHESS_FILE, serialization.serialize(game))
  else pcall(filesystem.remove, CONFIG.CHESS_FILE) end
end

local function sendMoves()
  if game then chessSend(game.opp, "MOVES", game.id, table.concat(game.uci, " ")) end
end

-- board drawing ---------------------------------------------------------
local function squareXY(sq)
  local f, r = sq % 8, floor(sq / 8)
  local col = flipped() and 7 - f or f
  local row = flipped() and r or 7 - r
  return BX + col * 8, BY + row * 4
end

local function checkSquare()
  if cs.state == "check" or cs.state == "checkmate" then return CH.kingSq(cs.board, cs.turn) end
end

local function drawSquare(sq, chk)
  local f, r = sq % 8, floor(sq / 8)
  local light = (f + r) % 2 == 1
  local base = light and CK.light or CK.dark
  if cs.last and (sq == cs.last.from or sq == cs.last.to) then base = light and CK.lastL or CK.lastD end
  if sq == sel then base = light and CK.selL or CK.selD end
  if sq == chk then base = CK.check end
  local cv = newCanvas(8, 8, base)
  local p = cs.board[sq]
  if p then
    pieceOnCanvas(cv, p.t, p.c == "w" and CK.wFill or CK.bFill, p.c == "w" and CK.wLine or CK.bLine)
  end
  if targets[sq] then
    if p then    -- capture: mark the corners
      for _, xy in ipairs({ { 1, 1 }, { 2, 1 }, { 1, 2 }, { 8, 1 }, { 7, 1 }, { 8, 2 },
                            { 1, 8 }, { 2, 8 }, { 1, 7 }, { 8, 8 }, { 7, 8 }, { 8, 7 } }) do
        cset(cv, xy[1], xy[2], CK.target)
      end
    else         -- quiet move: dot in the middle
      for x = 4, 5 do for y = 4, 5 do cset(cv, x, y, CK.target) end end
    end
  end
  local x, y = squareXY(sq)
  crender(cv, x, y)
end

local function drawBoard()
  local chk = checkSquare()
  for sq = 0, 63 do drawSquare(sq, chk) end
end

local function drawSquares(list)
  local chk = checkSquare()
  for _, sq in ipairs(list) do drawSquare(sq, chk) end
end

local function drawChessStatus()
  local y = WY + WH - 2
  fill(WX + 1, y, WW - 2, 1, K.face)
  textW(WX + 2, y, 60, chessMsg, K.black, K.face)
  text(WX + 63, y, "│", K.sh, K.face)
  textW(WX + 64, y, 30, "You: " .. PLAYER_NAME, K.black, K.face)
  text(WX + 95, y, "│", K.sh, K.face)
  textW(WX + 96, y, 46, "Chess port " .. CONFIG.CHESS_PORT, K.black, K.face)
end

-- refresh the chess window if it is visible and nothing covers it
local function refreshChess(boardToo)
  if activeApp == "chess" and not overlay then
    if boardToo then drawBoard() end
    drawChessRight()
    drawChessStatus()
  end
  if not overlay then drawTaskbar(now()) end
end

-- game flow -------------------------------------------------------------
local function startGame(id, oppAddr, oppName, color)
  game = { id = id, opp = oppAddr, oppName = oppName, color = color, uci = {} }
  cs = CH.new()
  game.uci = cs.uci
  sel, targets, pendingInvite = nil, {}, nil
  chessMsg = (color == "w") and "Game on! You play White - your move." or ("Game on! You play Black - " .. oppName .. " moves first.")
  saveGame()
end

local function resultFor(winner, how)
  return colorName(winner) .. " wins " .. how
end

local function checkGameOver()
  if not game or game.result then return end
  local s = cs.state
  if s == "checkmate" then
    game.result = resultFor(CH.opp(cs.turn), "by checkmate")
  elseif s == "stalemate" then game.result = "Draw by stalemate"
  elseif s == "fifty" then game.result = "Draw by the 50-move rule"
  elseif s == "repetition" then game.result = "Draw by threefold repetition"
  elseif s == "material" then game.result = "Draw - insufficient material"
  end
  if game.result then
    saveGame()
    local line
    if s == "checkmate" then
      line = (CH.opp(cs.turn) == game.color) and "Checkmate - you win!" or "Checkmate - you lost."
    else
      line = game.result .. "."
    end
    chessMsg = line
    showOrQueue(function() dialog("Game Over", { line }, { { "OK" } }) end)
  end
end

local function doMove(m)
  cs = CH.play(cs, m)
  game.uci = cs.uci
  sel, targets = nil, {}
  saveGame()
  sendMoves()
  chessMsg = "Waiting for " .. game.oppName .. "..."
  refreshChess(true)
  checkGameOver()
end

local function onMoves(from, id, list)
  if not game or game.id ~= id or from ~= game.opp then return end
  local moves = {}
  for mv in (list or ""):gmatch("%S+") do moves[#moves + 1] = mv end
  local mine = game.uci
  if #moves < #mine then sendMoves(); return end    -- they missed our move: resend
  if #moves == #mine then return end
  local prefix = true
  for i = 1, #mine do if mine[i] ~= moves[i] then prefix = false; break end end
  local st = cs
  if prefix then
    for i = #mine + 1, #moves do
      local m = CH.findMove(st, moves[i])
      if not m then st = nil; break end
      st = CH.play(st, m)
    end
  end
  if not st or not prefix then st = CH.replay(moves) end
  if not st then return end
  cs = st
  game.uci = cs.uci
  sel, targets = nil, {}
  saveGame()
  chessMsg = (cs.turn == game.color) and "Your move." or ("Waiting for " .. game.oppName .. "...")
  if activeApp ~= "chess" and cs.turn == game.color then chessAlert = true end
  refreshChess(true)
  checkGameOver()
end

local function onBoardClick(x, y)
  local col, row = floor((x - BX) / 8), floor((y - BY) / 4)
  if col < 0 or col > 7 or row < 0 or row > 7 then return end
  local f = flipped() and 7 - col or col
  local r = flipped() and row or 7 - row
  local sq = r * 8 + f
  if not game or game.result or cs.turn ~= game.color then
    chessMsg = (not game) and "Start a game first (Find Players)." or game.result and "This game is over."
               or ("It's " .. game.oppName .. "'s turn.")
    refreshChess(false)
    return
  end
  if sel and targets[sq] then
    local cands = {}
    for _, m in ipairs(cs.legalList) do
      if m.from == sel and m.to == sq then cands[#cands + 1] = m end
    end
    if #cands > 1 then           -- pawn promotion: ask which piece
      local function pick(t)
        return function() for _, m in ipairs(cands) do if m.promo == t then doMove(m) end end end
      end
      dialog("Promote Pawn", { "Choose a piece for your pawn:" },
        { { "Queen", pick("q") }, { "Rook", pick("r") }, { "Bishop", pick("b") }, { "Knight", pick("n") } })
    else
      doMove(cands[1])
    end
    return
  end
  local dirty = {}
  if sel then dirty[#dirty + 1] = sel end
  for s2 in pairs(targets) do dirty[#dirty + 1] = s2 end
  local p = cs.board[sq]
  if p and p.c == game.color and sq ~= sel then
    sel, targets = sq, {}
    for _, m in ipairs(cs.legalList) do if m.from == sq then targets[m.to] = true end end
    dirty[#dirty + 1] = sq
    for s2 in pairs(targets) do dirty[#dirty + 1] = s2 end
  else
    sel, targets = nil, {}
  end
  drawSquares(dirty)
end

local function findPlayers()
  players = {}
  pcall(wlan.broadcast, CONFIG.CHESS_PORT, "CHESS", "HELLO", PLAYER_NAME)
  chessMsg = "Searching for players in range..."
  refreshChess(false)
end

local function challenge(addr, name)
  local id = string.format("%d-%04d", floor(now()), math.random(0, 9999))
  pendingInvite = { id = id, addr = addr, name = name }
  chessSend(addr, "INVITE", id, PLAYER_NAME)
  chessMsg = "Challenge sent to " .. name .. ". Waiting for an answer..."
  refreshChess(false)
end

local function offerDraw()
  if not game or game.result then return end
  chessSend(game.opp, "DRAWOFFER", game.id)
  chessMsg = "Draw offered to " .. game.oppName .. "."
  refreshChess(false)
end

local function confirmResign()
  if not game or game.result then return end
  dialog("Resign", { "Resign this game against " .. game.oppName .. "?" }, {
    { "Yes", function()
        game.result = resultFor(CH.opp(game.color), "- " .. PLAYER_NAME .. " resigned")
        chessMsg = "You resigned."
        chessSend(game.opp, "RESIGN", game.id)
        saveGame()
      end },
    { "No" },
  })
end

local function backToLobby()
  local function go()
    game, cs, sel, targets = nil, CH.new(), nil, {}
    chessMsg = "Click Find Players to look for an opponent."
    saveGame()
  end
  if game and not game.result then
    dialog("New Game", { "Leave the current game? This counts as resigning." }, {
      { "Yes", function() chessSend(game.opp, "RESIGN", game.id); go() end },
      { "No" },
    })
  else
    go()
    if not overlay then drawAll() end
  end
end

local function onChessMessage(from, dist, kind, a, b)
  dist = dist or 0
  if kind == "HELLO" then
    players[from] = { name = a or "?", dist = dist }
    chessSend(from, "HERE", PLAYER_NAME)
    if not game then refreshChess(false) end
  elseif kind == "HERE" then
    players[from] = { name = a or "?", dist = dist }
    if not game then chessMsg = "Found players - click Challenge."; refreshChess(false) end
  elseif kind == "INVITE" then
    local id, name = a, b or "?"
    players[from] = { name = name, dist = dist }
    if game and not game.result and game.opp ~= from then chessSend(from, "BUSY", id); return end
    showOrQueue(function()
      dialog("Chess Challenge", {
        name .. " (" .. floor(dist + 0.5) .. " blocks away) wants to play chess.",
        "You will play Black. Accept?",
      }, {
        { "Accept", function()
            startGame(id, from, name, "b")
            chessSend(from, "ACCEPT", id, PLAYER_NAME)
            openChess()
          end },
        { "Decline", function() chessSend(from, "DECLINE", id) end },
      })
    end)
  elseif kind == "ACCEPT" then
    if pendingInvite and pendingInvite.id == a and pendingInvite.addr == from then
      startGame(a, from, b or pendingInvite.name, "w")
      openChess()
      if not overlay then drawAll() end
    end
  elseif kind == "DECLINE" or kind == "BUSY" then
    if pendingInvite and pendingInvite.id == a then
      chessMsg = pendingInvite.name .. (kind == "BUSY" and " is busy in another game." or " declined the challenge.")
      pendingInvite = nil
      refreshChess(false)
    end
  elseif game and game.id == a and from == game.opp then
    if kind == "MOVES" then
      onMoves(from, a, b)
    elseif kind == "RESIGN" and not game.result then
      game.result = resultFor(game.color, "- " .. game.oppName .. " resigned")
      chessMsg = game.oppName .. " resigned. You win!"
      saveGame()
      refreshChess(false)
      showOrQueue(function() dialog("Game Over", { game.oppName .. " resigned - you win!" }, { { "OK" } }) end)
    elseif kind == "DRAWOFFER" and not game.result then
      showOrQueue(function()
        dialog("Draw Offer", { game.oppName .. " offers a draw. Accept?" }, {
          { "Accept", function()
              game.result = "Draw by agreement"; chessMsg = "Draw agreed."
              chessSend(game.opp, "DRAWACCEPT", game.id); saveGame()
            end },
          { "Decline", function() chessSend(game.opp, "DRAWDECLINE", game.id) end },
        })
      end)
    elseif kind == "DRAWACCEPT" and not game.result then
      game.result = "Draw by agreement"; chessMsg = "Draw agreed."
      saveGame()
      refreshChess(false)
      showOrQueue(function() dialog("Game Over", { game.oppName .. " accepted the draw." }, { { "OK" } }) end)
    elseif kind == "DRAWDECLINE" then
      chessMsg = game.oppName .. " declined the draw."
      refreshChess(false)
    end
  end
end

-- side panel ------------------------------------------------------------
local function infoRow(y, k, v, col)
  textW(PX + 2, y, 14, k, K.black, K.face)
  textW(PX + 16, y, 49, v, col or K.black, K.face)
end

drawChessRight = function()
  panelRegions = {}
  groupBox(PX, 5, 67, 12, game and "Game" or "Chess Lobby")
  if game then
    infoRow(7, "You:", PLAYER_NAME .. " (" .. colorName(game.color) .. ")")
    infoRow(8, "Opponent:", game.oppName .. " (" .. colorName(CH.opp(game.color)) .. ")")
    local myTurn = not game.result and cs.turn == game.color
    infoRow(10, "Turn:", game.result and "Game over" or (myTurn and "YOUR MOVE" or ("Waiting for " .. game.oppName)),
      myTurn and K.green or K.black)
    infoRow(11, "Move:", tostring(cs.full))
    infoRow(12, "Status:", game.result or (cs.state == "check" and "Check!" or "In progress"),
      (game.result or cs.state == "check") and K.red or K.black)
  else
    infoRow(7, "You:", PLAYER_NAME)
    infoRow(8, "Opponent:", pendingInvite and ("waiting for " .. pendingInvite.name .. "...") or "none")
    infoRow(10, "How to play:", "Find Players, then Challenge someone.")
    infoRow(11, "", "Whoever sends the challenge plays White.")
  end
  textW(PX + 2, 14, 63, chessMsg, K.navy, K.face)

  if game then
    groupBox(PX, 18, 67, 19, "Moves")
    local n = #cs.notes
    local rowsN = ceil(n / 2)
    local first = max(1, rowsN - 16)
    for i = first, rowsN do
      textW(PX + 2, 19 + i - first, 63,
        string.format("%3d.  %-16s %-16s", i, cs.notes[i * 2 - 1] or "", cs.notes[i * 2] or ""), K.black, K.face)
    end
    if n == 0 then textW(PX + 2, 19, 63, "(no moves yet)", K.sh, K.face) end
  else
    groupBox(PX, 18, 67, 19, "Players in Range")
    local y, any = 20, false
    for addr, p in pairs(players) do
      if y <= 34 then
        any = true
        textW(PX + 2, y, 46, p.name .. "  (" .. floor(p.dist + 0.5) .. " blocks)", K.black, K.face)
        textW(PX + 51, y, 13, "[Challenge]", K.navy, K.face)
        region(panelRegions, PX + 51, y, 13, 1, function() challenge(addr, p.name) end)
        y = y + 2
      end
    end
    if not any then
      textW(PX + 2, 20, 63, "No players found yet. Click Find Players.", K.sh, K.face)
      textW(PX + 2, 21, 63, "(The other computer must run Lymanos or lscview.)", K.sh, K.face)
    end
  end

  fill(PX, 38, 67, 3, K.face)
  if not game then
    button(panelRegions, PX, 38, 20, "Find Players", findPlayers)
  elseif not game.result then
    button(panelRegions, PX, 38, 20, "Offer Draw", offerDraw)
    button(panelRegions, PX + 22, 38, 20, "Resign", confirmResign)
  else
    button(panelRegions, PX, 38, 20, "New Game", backToLobby)
  end
end

local function closeChess()
  chessOpen = false
  activeApp = nil
  drawAll()
end

openChess = function()
  chessOpen, chessAlert = true, false
  activeApp = "chess"
end

local function chessGameMenu()
  popupMenu(WX + 2, WY + 3, {
    { "Find Players", function() if not game then findPlayers() end end },
    { "Offer Draw", offerDraw },
    { "Resign...", confirmResign },
    { "New Game", backToLobby },
    { "-" },
    { "Close Chess", function() chessOpen = false; activeApp = "viewer" end },
  })
end

local function chessHelpMenu()
  popupMenu(WX + 8, WY + 3, { { "How to Play...", function()
    dialog("How to Play", {
      "1. Both computers run Lymanos (in wireless range).",
      "2. Click Find Players, then Challenge your friend.",
      "3. Click a piece to see its moves, click a dot to move.",
      "Castling: move the king two squares. Full chess rules apply.",
      "Games are saved and resume after a restart.",
    }, { { "OK" } })
  end } })
end

local function drawChessWindow()
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  local title = "Chess - " .. (game and (PLAYER_NAME .. " vs " .. game.oppName) or "Lobby")
  titleBar(WX + 1, WY + 1, WW - 2, "▣ " .. title, true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(regions, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(regions, bx + 7, WY + 1, 3, 1, closeChess)

  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  text(WX + 2, WY + 2, " Game ", K.black, K.face)
  text(WX + 8, WY + 2, " Help ", K.black, K.face)
  region(regions, WX + 2, WY + 2, 6, 1, chessGameMenu)
  region(regions, WX + 8, WY + 2, 6, 1, chessHelpMenu)

  bevel(BX - 1, BY - 1, 66, 34, "sunken", K.face, K.face)
  for i = 0, 7 do
    text(BX - 3, BY + i * 4 + 1, tostring(flipped() and i + 1 or 8 - i), K.black, K.face)
    text(BX + i * 8 + 3, BY + 33, string.char(97 + (flipped() and 7 - i or i)), K.black, K.face)
  end
  drawBoard()
  region(regions, BX, BY, 64, 32, onBoardClick)
  drawChessRight()
  drawChessStatus()
end

local function loadGame()
  local raw = readFile(CONFIG.CHESS_FILE)
  if not raw then return end
  local ok, t = pcall(serialization.unserialize, raw)
  if ok and type(t) == "table" and t.id then
    local st = CH.replay(t.uci or {}, function() os.sleep(0) end)
    if st then
      game, cs = t, st
      game.uci = cs.uci
      chessOpen = true
      chessMsg = game.result or ((cs.turn == game.color) and "Your move." or ("Waiting for " .. game.oppName .. "..."))
      if not game.result then sendMoves() end   -- resync with the opponent
    end
  end
end

------------------------------------------------------------- BROKERAGE
-- Watchlist, price graphs and a paper-trading account (formerly "Stock Track").
-- Lives in its own function so it gets its own local-variable budget
-- (Lua allows only 200 locals in the main part of a file).
local ST = (function()
local inet = nil
do
  local a = component.list("internet")()
  if a then inet = component.proxy(a) end
end


-- dark "monitor" colors (same family as gtgraphs / the archive's Storage Report)
local G = {
  bg = 0x0B0B0B, panel = 0x161616, alt = 0x1B1B1B, header = 0x0E2A38, text = 0xE6E6E6,
  dim = 0x8C8C8C, dark = 0x000000, accent = 0x00C8FF, good = 0x3FE06A, warn = 0xFFB000,
  bad = 0xFF4D4D, grid = 0x333333, axis = 0x6E6E6E, button = 0x2E4A5A, track = 0x2A2A2A,
  gold = 0xE8C547, violet = 0xB07CFF,
}
local SK = { up = G.good, down = G.bad, flat = G.dim, prevLine = G.axis, grid = G.grid }

local stocks = { tickers = {}, history = {} }   -- saved
local quotes = {}           -- live: sym -> { price, prev, high, low, time, name, currency, err }
local stockSel = nil        -- selected ticker
local stockView = "dashboard"   -- "dashboard" | "details" | "portfolio"
local stockInput, stockFocus = "", false
local stockMsg = inet and "Ready." or "No Internet Card found - install one to get prices."
local stockOpen = false
local nextRefresh = 0       -- computer.uptime() of the next refresh
local stockRegions = {}     -- rebuilt by drawStockWindow
local backoff = 0           -- extra delay after errors (rate limiting)
local V = { range = 2, pfRange = 1, hScroll = 0, oScroll = 0, dirty = false, savedAt = 0,
            gsel = nil, psel = nil }   -- view state (one table = one local)

-- crypto (-USD) and forex (=X) trade around the clock
local function alwaysOpen(sym) return sym:find("%-USD$") or sym:find("=X$") end
local function perDay(sym) return alwaysOpen(sym) and 288 or 78 end   -- 5-minute bars per day

------------------------------------------------------------ PACKED SERIES
-- Prices are kept 4 bytes each inside one string (7 significant digits)
-- instead of two Lua number lists (32 bytes a point), so ten times the
-- history fits in about the same RAM. Points sit on a fixed time step;
-- runs = { start, count, start, count, ... } - one run per stretch without
-- gaps (a trading session). Works on Lua 5.2 and 5.3.
local SR = {}
local HEX = {}
for i = 0, 255 do HEX[string.char(i)] = string.format("%02x", i) end

function SR.enc(v)
  if type(v) ~= "number" or v ~= v or v <= 0 or v == math.huge then return "\0\0\0\0" end
  local e = floor(math.log(v, 10))
  local m = floor(v / 10 ^ (e - 6) + 0.5)
  if m >= 10000000 then m, e = floor(m / 10 + 0.5), e + 1 end
  if m < 1000000 then m, e = m * 10, e - 1 end
  local x = e + 122                                   -- (e - 6) + 128
  if x < 1 or x > 255 then return "\0\0\0\0" end
  return string.char(x, floor(m / 65536), floor(m / 256) % 256, m % 256)
end

function SR.dec(s, i)
  local a, b, c, d = s:byte(i * 4 - 3, i * 4)
  if not a or a == 0 then return nil end
  return (b * 65536 + c * 256 + d) * 10 ^ (a - 128)
end

function SR.new(step, maxN) return { step = step, max = maxN, runs = {}, data = "" } end
function SR.count(S) return floor(#S.data / 4) end

function SR.lastT(S)
  local r = S.runs
  local k = #r
  if k == 0 then return nil end
  return r[k - 1] + (r[k] - 1) * S.step
end

function SR.trim(S)
  local extra = SR.count(S) - S.max
  if extra <= 0 then return end
  S.data = S.data:sub(extra * 4 + 1)
  local r = S.runs
  while extra > 0 and #r > 0 do
    if r[2] <= extra then
      extra = extra - r[2]
      table.remove(r, 1); table.remove(r, 1)
    else
      r[1], r[2], extra = r[1] + extra * S.step, r[2] - extra, 0
    end
  end
end

-- add a value at time t (same step = replace). buf: collect bytes, SR.commit later
function SR.put(S, t, v, buf)
  if type(t) ~= "number" or type(v) ~= "number" then return false end
  local slot = floor(t / S.step) * S.step
  local last = SR.lastT(S)
  if last and slot < last then return false end
  local e = SR.enc(v)
  if last and slot == last then
    if buf and #buf > 0 then buf[#buf] = e
    else
      if S.data:sub(-4) == e then return false end
      S.data = S.data:sub(1, -5) .. e
    end
    return true
  end
  local r, k = S.runs, #S.runs
  if last and slot == last + S.step then r[k] = r[k] + 1
  else r[k + 1], r[k + 2] = slot, 1 end
  if buf then buf[#buf + 1] = e
  else S.data = S.data .. e; SR.trim(S) end
  return true
end

function SR.commit(S, buf)
  if #buf > 0 then S.data = S.data .. table.concat(buf); SR.trim(S) end
end

-- fn(i, t, v, startsRun) for points from..to
function SR.each(S, fn, from, to)
  local r, i = S.runs, 0
  from, to = from or 1, to or math.huge
  for k = 1, #r, 2 do
    local n = r[k + 1]
    if i + n >= from then
      for j = max(1, from - i), n do
        local idx = i + j
        if idx > to then return end
        fn(idx, r[k] + (j - 1) * S.step, SR.dec(S.data, idx), j == 1)
      end
    end
    i = i + n
  end
end

function SR.time(S, idx)
  local r = S.runs
  for k = 1, #r, 2 do
    if idx <= r[k + 1] then return r[k] + (idx - 1) * S.step end
    idx = idx - r[k + 1]
  end
end

-- index where each Eastern calendar day starts (oldest first), from times only
local function nextMidnight(t)
  local e = toEastern(t)
  return t - (e.hour * 3600 + e.min * 60 + e.sec) + 86400
end
function SR.dayStarts(S)
  local out, r, base = {}, S.runs, 0
  local lastDay
  for k = 1, #r, 2 do
    local t0, n = r[k], r[k + 1]
    local t1 = t0 + (n - 1) * S.step
    local m = nextMidnight(t0)
    local d0 = floor((m - 86400 + 7200) / 86400)
    if d0 ~= lastDay then out[#out + 1] = base + 1; lastDay = d0 end
    while m <= t1 do
      out[#out + 1] = base + 1 + ceil((m - t0) / S.step)
      lastDay = floor((m + 7200) / 86400)
      m = m + 86400
    end
    base = base + n
  end
  return out
end

-- save as "start:count,start:count hexbytes"; written in pieces (no big strings)
function SR.write(f, S)
  local rs = {}
  for k = 1, #S.runs, 2 do rs[#rs + 1] = string.format("%d:%d", S.runs[k], S.runs[k + 1]) end
  f:write(#rs > 0 and table.concat(rs, ",") or "-", " ")
  for i = 1, #S.data, 512 do f:write((S.data:sub(i, i + 511):gsub(".", HEX))) end
end

function SR.read(S, runsTxt, hex)
  S.runs, S.data = {}, ""
  for t0, n in (runsTxt or ""):gmatch("(%d+):(%d+)") do
    S.runs[#S.runs + 1] = tonumber(t0); S.runs[#S.runs + 1] = tonumber(n)
  end
  local parts = {}
  for i = 1, #(hex or ""), 2048 do
    parts[#parts + 1] = hex:sub(i, i + 2047):gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
  end
  S.data = table.concat(parts)
  local want = 0
  for k = 2, #S.runs, 2 do want = want + S.runs[k] end
  if want ~= SR.count(S) then S.runs, S.data = {}, "" end    -- damaged line: start over
  SR.trim(S)
end

-- Price history per ticker (5-minute points). The file is plain text:
--   line 1: LSCSTOCKS 3
--   line 2: T AAPL MSFT ...
--   then  : H AAPL <runs> <hex>    (older version 2 files are converted)
local function histOf(sym)
  local h = stocks.history[sym]
  if not h then h = SR.new(300, CONFIG.STOCK_LOG_MAX); stocks.history[sym] = h end
  return h
end

local function saveStocks()
  local f = io.open(CONFIG.STOCK_FILE, "w")
  if not f then return end
  f:write("LSCSTOCKS 3\nT ", table.concat(stocks.tickers, " "), "\n")
  for _, sym in ipairs(stocks.tickers) do
    local h = stocks.history[sym]
    if h and SR.count(h) > 0 then
      f:write("H ", sym, " ")
      SR.write(f, h)
      f:write("\n")
    end
  end
  f:close()
  V.dirty, V.savedAt = false, computer.uptime()
end

local function loadStocks()
  local f = io.open(CONFIG.STOCK_FILE, "r")
  if not f then return end
  local first = f:read("*l")
  if first == "LSCSTOCKS 3" or first == "LSCSTOCKS 2" then
    local v3 = first == "LSCSTOCKS 3"
    for line in f:lines() do
      local kind, rest = line:match("^(%a) (.*)$")
      if kind == "T" then
        for sym in rest:gmatch("%S+") do stocks.tickers[#stocks.tickers + 1] = sym end
      elseif kind == "H" and v3 then
        local sym, runs, hex = rest:match("^(%S+) (%S+) ?(%x*)")
        if sym then SR.read(histOf(sym), runs, hex) end
      elseif kind == "H" then                               -- version 2: "t:price t:price ..."
        local sym, pts = rest:match("^(%S+)(.*)$")
        local h, buf = histOf(sym), {}
        for t, p in pts:gmatch("(%d+):([%-%d%.eE]+)") do SR.put(h, tonumber(t), tonumber(p), buf) end
        SR.commit(h, buf)
      end
    end
    f:close()
    if not v3 then saveStocks() end
  else
    -- very old (version 1) file: keep the ticker list only
    local raw = (first or "") .. (f:read("*a") or "")
    f:close()
    local list = raw:match("tickers%s*=%s*(%b{})") or raw:match('%["tickers"%]%s*=%s*(%b{})')
    raw = nil
    if list then for sym in list:gmatch('"([^"]+)"') do stocks.tickers[#stocks.tickers + 1] = sym end end
    saveStocks()
  end
  stockSel = stocks.tickers[1]
  if #stocks.tickers > 0 then stockOpen = true end
end

local function fmtPrice(p)
  if not p then return "--" end
  if math.abs(p) < 1 then return string.format("%.4f", p) end
  local whole = floor(math.abs(p))
  local s = commas(whole) .. string.format("%.2f", math.abs(p) - whole):sub(2)
  return (p < 0 and "-" or "") .. s
end

local function changeOf(q)
  if not q or not q.price or not q.prev or q.prev == 0 then return nil end
  local d = q.price - q.prev
  return d, d / q.prev * 100
end

local function fmtChange(q)
  local d, pct = changeOf(q)
  if not d then return "--", "--", SK.flat end
  local sign = d > 0 and "+" or (d < 0 and "-" or "")
  local col = d > 0 and SK.up or (d < 0 and SK.down or SK.flat)
  return sign .. fmtPrice(math.abs(d)), string.format("%s%.2f%%", sign, math.abs(pct)), col
end

local function fmtMarketTime(t)
  if not t then return "--" end
  local e = toEastern(t)
  local h, ap = h12(e)
  return string.format("%02d/%02d %d:%02d %s %s", e.month, e.day, h, e.min, ap, e.tz)
end

-- non-blocking HTTP queue -------------------------------------------------
local httpQueue, httpCur = {}, nil
local function urlEncode(s)
  return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end


-- kind "quote": just today's price (small reply, ~1.5 KB)
-- kind "bars":  5-minute prices for the graph (~12 KB) - only every few minutes.
--               A ticker with less than a day saved gets the last 5 days once.
local function quoteURL(sym, kind)
  if CONFIG.STOCK_PROVIDER == "finnhub" then
    return "https://finnhub.io/api/v1/quote?symbol=" .. urlEncode(sym) .. "&token=" .. tostring(CONFIG.FINNHUB_KEY)
  end
  local range = "1d"
  if kind == "bars" and not alwaysOpen(sym) then
    local h = stocks.history[sym]
    if not h or SR.count(h) < perDay(sym) then range = "5d" end
  end
  return "https://query1.finance.yahoo.com/v8/finance/chart/" .. urlEncode(sym)
    .. (kind == "bars" and ("?interval=5m&range=" .. range) or "?interval=1d&range=1d")
end

local function jnum(body, key) return tonumber(body:match('"' .. key .. '"%s*:%s*([%-%d%.eE+]+)')) end
local function jstr(body, key) return body:match('"' .. key .. '"%s*:%s*"([^"]*)"') end

local function parseQuote(body)
  if CONFIG.STOCK_PROVIDER == "finnhub" then
    local c, t = jnum(body, "c"), jnum(body, "t")
    if not c or (c == 0 and (t or 0) == 0) then
      return nil, jstr(body, "error") or "Unknown ticker"
    end
    return { price = c, prev = jnum(body, "pc"), high = jnum(body, "h"), low = jnum(body, "l"),
             time = t, currency = "USD" }
  end
  local price = jnum(body, "regularMarketPrice")
  if not price then
    return nil, jstr(body, "description") or jstr(body, "code") or "No price in reply"
  end
  -- today's 5-minute closes: "timestamp":[...] and "close":[...] (gaps are null)
  local st, sp = {}, {}
  local ts, cl = body:match('"timestamp"%s*:%s*%[(.-)%]'), body:match('"close"%s*:%s*%[(.-)%]')
  if ts and cl then
    local clist = {}
    for v in cl:gmatch("[^,]+") do clist[#clist + 1] = tonumber(v) or false end
    local i = 0
    for v in ts:gmatch("[^,]+") do
      i = i + 1
      local t, p = tonumber(v), clist[i]
      if t and p then st[#st + 1] = t; sp[#sp + 1] = p end
    end
  end
  return { price = price, prev = jnum(body, "chartPreviousClose") or jnum(body, "previousClose"),
           high = jnum(body, "regularMarketDayHigh"), low = jnum(body, "regularMarketDayLow"),
           time = jnum(body, "regularMarketTime"), currency = jstr(body, "currency"),
           name = jstr(body, "shortName") or jstr(body, "longName"), st = st, sp = sp }
end

local onQuote   -- forward: called when a fetch finishes

-- Yahoo option quotes + trading helpers. Filled in by the portfolio section
-- below; kept in one table to stay under Lua's local-variable limit.
local OF = { cookie = nil, crumb = nil, offUntil = 0, retried = false, status = nil,
             chains = {}, settle = {} }

local lastBars = {}       -- sym -> computer.uptime() of the last 5-minute-bars fetch
local BARS_PER_REFRESH = 3

-- every request has a key; the same key is never queued twice
local function queueItem(item, front)
  item.key = item.key or item.sym
  for _, q in ipairs(httpQueue) do if q.key == item.key then
    if item.kind == "bars" then q.kind = "bars" end
    return false
  end end
  if httpCur and httpCur.key == item.key then return false end
  if front then table.insert(httpQueue, 1, item) else httpQueue[#httpQueue + 1] = item end
  return true
end

local function queueFetch(sym, front, kind)
  queueItem({ sym = sym, kind = kind or "quote" }, front)
end
OF.queue = queueItem

local function refreshAll()
  local up = computer.uptime()
  -- the few tickers whose graph data is most out of date get the bigger "bars" request
  local due = {}
  if CONFIG.STOCK_PROVIDER ~= "finnhub" then
    for _, sym in ipairs(stocks.tickers) do
      if up - (lastBars[sym] or -math.huge) >= CONFIG.STOCK_LOG_EVERY then due[#due + 1] = sym end
    end
    table.sort(due, function(a, b) return (lastBars[a] or -math.huge) < (lastBars[b] or -math.huge) end)
  end
  local bars = {}
  for i = 1, min(BARS_PER_REFRESH, #due) do bars[due[i]] = true end
  for _, sym in ipairs(stocks.tickers) do queueFetch(sym, false, bars[sym] and "bars" or "quote") end
  -- symbols you trade or own that aren't on the watchlist: price only
  if OF.extras then for _, sym in ipairs(OF.extras()) do queueFetch(sym, false, "quote") end end
  nextRefresh = up + CONFIG.STOCK_REFRESH + backoff
end

local function finishHttp(err)
  local cur = httpCur
  httpCur = nil
  pcall(cur.h.close)
  if cur.kind ~= "quote" and cur.kind ~= "bars" then   -- option-data requests
    local ok, e = pcall(OF.done, cur, err)
    if not ok then OF.status = "option data error: " .. tostring(e) end
    return
  end
  if err then
    onQuote(cur.sym, nil, err, cur.kind)
    return
  end
  local body = table.concat(cur.parts)     -- join the pieces once
  cur.parts = nil
  local q, perr = parseQuote(body)
  body = nil
  if q and cur.kind ~= "bars" then q.st, q.sp = nil, nil end   -- daily bar is not graph data
  if q and cur.kind == "bars" then lastBars[cur.sym] = computer.uptime() end
  onQuote(cur.sym, q, perr, cur.kind)
end

-- call often from the main loop; does a little work and returns
local function pumpHttp()
  if not inet then return end
  if not httpCur then
    local item = table.remove(httpQueue, 1)
    if not item then return end
    local sym = item.sym
    local quoteKind = item.kind == "quote" or item.kind == "bars"
    if quoteKind and CONFIG.STOCK_PROVIDER == "finnhub" and not CONFIG.FINNHUB_KEY then
      onQuote(sym, nil, "Set FINNHUB_KEY in the config")
      return
    end
    local url, extra = quoteKind and quoteURL(sym, item.kind), nil
    if not quoteKind then
      url, extra = OF.start(item)
      if not url then return end            -- skipped (or moved to the back of the queue)
    end
    local hdr = { ["User-Agent"] = "Mozilla/5.0 (compatible; OpenComputers Lymanos)",
                  ["Accept"] = quoteKind and "application/json" or "*/*" }
    if extra then for k, v in pairs(extra) do hdr[k] = v end end
    local ok, h = pcall(inet.request, url, nil, hdr)
    if not ok or not h then
      if quoteKind then onQuote(sym, nil, "Request failed: " .. tostring(h))
      else pcall(OF.done, item, "Request failed: " .. tostring(h)) end
      return
    end
    item.h, item.parts, item.size, item.started = h, {}, 0, computer.uptime()
    httpCur = item
  end
  local cur = httpCur
  local ok, done = pcall(cur.h.finishConnect)
  if not ok or (done == nil and cur.kind == "cookie") then
    if cur.kind == "cookie" then   -- the cookie page answers 404 on purpose: headers may still be there
      local okc, _, _, hd = pcall(cur.h.response)
      if okc then cur.headers = hd end
    end
    finishHttp(tostring(done)); return
  end
  if done and cur.kind == "cookie" then   -- only the headers matter, skip the page
    local okc, code, _, hd = pcall(cur.h.response)
    if okc then cur.code, cur.headers = code, hd end
    finishHttp(nil); return
  end
  if done then
    for _ = 1, 16 do
      local okr, chunk = pcall(cur.h.read, 8192)
      if not okr then finishHttp(tostring(chunk)); return end
      if chunk == nil then
        local okc, code = pcall(cur.h.response)
        if okc then cur.code = code end
        if okc and code and code ~= 200 and cur.size == 0 then finishHttp("HTTP " .. tostring(code)); return end
        if okc and code == 429 then finishHttp("HTTP 429 (too many requests)"); return end
        finishHttp(nil)
        return
      elseif chunk == "" then
        break
      elseif cur.kind == "chain" then
        cur.size = cur.size + #chunk
        OF.feed(cur, chunk)                          -- parsed piece by piece, never stored whole
      else
        cur.parts[#cur.parts + 1] = chunk           -- collect pieces; joined once at the end
        cur.size = cur.size + #chunk
      end
    end
  end
  if computer.uptime() - cur.started > 15 then finishHttp("Timed out") end
end

local function httpBusy() return inet ~= nil and (httpCur ~= nil or #httpQueue > 0) end

-- history -----------------------------------------------------------------
-- add Yahoo's 5-minute bars (oldest first); the newest bar is still moving
local function mergeSeries(sym, st, sp)
  if not st or #st == 0 then return false end
  local h, buf, changed = histOf(sym), {}, false
  if SR.count(h) < #st and (SR.lastT(h) or 0) > st[1] then
    -- the reply covers more than we have saved (e.g. a live quote arrived before
    -- the first 5-day download): start from the reply, keep anything newer
    local nh = SR.new(300, CONFIG.STOCK_LOG_MAX)
    for i = 1, #st do SR.put(nh, st[i], sp[i], buf) end
    SR.each(h, function(_, t, v) if t > st[#st] then SR.put(nh, t, v, buf) end end)
    SR.commit(nh, buf)
    stocks.history[sym] = nh
    return true
  end
  for i = 1, #st do if SR.put(h, st[i], sp[i], buf) then changed = true end end
  SR.commit(h, buf)
  return changed
end

-- every quote also updates the current 5-minute point (Finnhub has no bars at all)
local function logPrice(sym, q)
  return SR.put(histOf(sym), q.time or now(), q.price)
end

------------------------------------------------------------ DRAWING KIT
local D = {}
local X0, CW = WX + 1, WW - 2                 -- inside the window border
local TOP, BOT = WY + 7, WY + WH - 3          -- content rows (below the header strip)

function D.segs(x, y, w, list, right, b, rcol)
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

-- panel with a colored title strip (the Storage Report look)
function D.panel(x, y, w, h, title, color, right)
  fill(x, y, w, h, G.panel)
  fill(x, y, w, 1, color)
  text(x, y, " " .. title .. " ", G.dark, color)
  if right and right ~= "" then
    local rw = unicode.len(right)
    textW(x + w - rw - 1, y, rw, right, G.dark, color)
  end
end

-- clickable tabs drawn on a title strip, right-aligned (click areas only
-- when reg is true, i.e. on a full redraw - live refreshes just repaint)
function D.tabs(xr, y, list, cur, color, fn, reg)
  local x = xr
  for i = #list, 1, -1 do
    local lab = " " .. list[i][1] .. " "
    x = x - unicode.len(lab)
    local on = (i == cur)
    text(x, y, lab, on and G.text or G.dark, on and G.dark or color)
    local idx = i
    if reg then region(stockRegions, x, y, unicode.len(lab), 1, function() fn(idx) end) end
    x = x - 1
  end
end

function D.labelRow(width, items)
  local chars = {}
  for i = 1, width do chars[i] = " " end
  for _, it in ipairs(items) do
    local lab = it[2]
    local len = unicode.len(lab)
    local lx = max(1, min(it[1] - floor(len / 2), width - len + 1))
    for i = 1, len do if lx + i - 1 <= width then chars[lx + i - 1] = unicode.sub(lab, i, i) end end
  end
  return table.concat(chars)
end

function D.shortMoney(n)
  if not n then return "--" end
  local a = math.abs(n)
  local s
  if a >= 1e9 then s = string.format("%.2fB", a / 1e9)
  elseif a >= 1e6 then s = string.format("%.2fM", a / 1e6)
  elseif a >= 1e4 then s = string.format("%.1fK", a / 1e3)
  else s = string.format("%.2f", a) end
  return (n < 0 and "-$" or "$") .. s
end

-- Draws points i0..i1 of series S as a chart: one screen column holds many
-- points, drawn as a low-high band with the closing value as the line, so a
-- month of 5-minute prices still shows every spike. Day starts get a faint
-- divider. opts: color, prev (dashed level), label (value -> text), labelW,
-- bg. Returns info for labels and clicks, or nil when there is too little data.
function D.chart(x, y, w, rows, S, i0, i1, opts)
  local bgc = opts.bg or G.panel
  local lw = opts.labelW or 0
  local gx, cw, ph = x + lw, w - lw, rows * 2
  local n = i1 - i0 + 1
  local cv = newCanvas(cw, ph, bgc)
  if n < 2 then
    crender(cv, gx, y)
    return nil
  end
  -- per-column low / high / last
  local lo, hi, last, ct = {}, {}, {}, {}
  local vmin, vmax = math.huge, -math.huge
  local spread = n < cw
  SR.each(S, function(i, t, v)
    if not v then return end
    local c = spread and (1 + floor((i - i0) * (cw - 1) / (n - 1) + 0.5)) or (floor((i - i0) * cw / n) + 1)
    if not lo[c] or v < lo[c] then lo[c] = v end
    if not hi[c] or v > hi[c] then hi[c] = v end
    last[c], ct[c] = v, t
    if v < vmin then vmin = v end
    if v > vmax then vmax = v end
  end, i0, i1)
  if vmin == math.huge then crender(cv, gx, y); return nil end
  if spread then              -- fewer points than columns: fill the columns in between
    local a
    for c = 1, cw do
      if ct[c] then
        if a and c - a > 1 then
          for k = a + 1, c - 1 do
            local v = last[a] + (last[c] - last[a]) * (k - a) / (c - a)
            lo[k], hi[k], last[k] = v, v, v
          end
        end
        a = c
      end
    end
  end
  local p = opts.prev
  if p and opts.stretch ~= false then vmin, vmax = min(vmin, p), max(vmax, p) end
  if vmax - vmin < 1e-9 then vmax, vmin = vmax + 0.5, vmin - 0.5 end
  local pad = (vmax - vmin) * 0.08
  vmin, vmax = vmin - pad, vmax + pad
  local function py(v) return ph - floor((v - vmin) / (vmax - vmin) * (ph - 1) + 0.5) end
  if not opts.noGrid then
    for k = 1, 3 do
      local yy = 1 + floor(k * (ph - 1) / 4)
      for xx = 2, cw, 3 do cset(cv, xx, yy, G.grid) end
    end
  end
  -- day dividers
  local days = opts.days
  if days then
    for _, di in ipairs(days) do
      if di > i0 and di <= i1 then
        local c = spread and (1 + floor((di - i0) * (cw - 1) / (n - 1) + 0.5)) or (floor((di - i0) * cw / n) + 1)
        for yy = 1, ph, 2 do cset(cv, c, yy, G.track) end
      end
    end
  end
  local col = opts.color
  local band = lerp(col, bgc, 0.62)
  local area = opts.area and lerp(col, bgc, 0.85)
  if opts.sel and lo[opts.sel] then
    for yy = 1, ph do cset(cv, opts.sel, yy, lerp(G.accent, bgc, 0.75)) end
  end
  for c = 1, cw do
    if lo[c] then
      if area then for yy = py(last[c]) + 1, ph do cset(cv, c, yy, area) end end
      for yy = py(hi[c]), py(lo[c]) do cset(cv, c, yy, band) end
    end
  end
  if p and p >= vmin and p <= vmax then        -- dashed level (previous close / deposits)
    local yy = py(p)
    for xx = 1, cw, 3 do cset(cv, xx, yy, SK.prevLine) end
  end
  local lc = lerp(col, 0xFFFFFF, 0.2)
  local px2, py2
  for c = 1, cw do
    if last[c] then
      local yy = py(last[c])
      if px2 then cline(cv, px2, py2, c, yy, lc) else cset(cv, c, yy, lc) end
      px2, py2 = c, yy
    end
  end
  crender(cv, gx, y)
  if lw > 0 then
    local fmt = opts.label or fmtPrice
    for k = 0, 2 do
      local v = vmax - (vmax - vmin) * (k * 2 + 1) / 6
      textW(x, y + floor((py(v) - 1) / 2), lw - 1, fmt(v), G.dim, bgc, "right")
    end
  end
  return { cw = cw, gx = gx, last = last, lo = lo, hi = hi, ct = ct, vmin = vmin, vmax = vmax,
           first = SR.time(S, i0), lastT = SR.time(S, i1), n = n }
end

-- first point index of the last `days` calendar days (0 = everything)
local function rangeStart(S, days)
  local n = SR.count(S)
  if days == 0 or n == 0 then return 1, nil end
  local ds = SR.dayStarts(S)
  return ds[max(1, #ds - days + 1)] or 1, ds
end

local function dateLabels(info, S, i0, i1, ds, width)
  local items = {}
  if not info then return "" end
  local span = (info.lastT or 0) - (info.first or 0)
  local function lab(t)
    local e = toEastern(t)
    if span <= 86400 * 1.2 then local h, ap = h12(e); return string.format("%d:%02d%s", h, e.min, ap:sub(1, 1)) end
    return string.format("%02d/%02d", e.month, e.day)
  end
  if span <= 86400 * 1.2 or not ds then
    for k = 0, 4 do
      local i = i0 + floor((i1 - i0) * k / 4)
      local c = 1 + floor((i - i0) * (width - 1) / max(1, i1 - i0))
      items[#items + 1] = { c, lab(SR.time(S, i)) }
    end
  else
    local shown, every = {}, max(1, ceil(#ds / 8))
    for k, di in ipairs(ds) do
      if di >= i0 and di <= i1 and (k % every == 0 or k == #ds) then
        local c = 1 + floor((di - i0) * (width - 1) / max(1, i1 - i0))
        shown[#shown + 1] = { c, lab(SR.time(S, di)) }
      end
    end
    items = shown
  end
  return D.labelRow(width, items)
end

-- drawing -----------------------------------------------------------------
local SCOLS = {
  { "SYMBOL", 9 }, { "NAME", 22 }, { "PRICE", 12 }, { "CHANGE", 11 }, { "CHANGE %", 9 },
  { "DAY LOW", 11 }, { "DAY HIGH", 11 }, { "PREV CLOSE", 11 }, { "MARKET TIME", 21 },
}
local LIST_Y = TOP                      -- watchlist panel (title, header, 12 rows)
local GRAPH_Y = TOP + 15                -- graph panel
local RANGES = { { "1D", 1 }, { "5D", 5 }, { "ALL", 0 } }

local function drawStockStatus()
  local y = WY + WH - 2
  fill(WX + 1, y, WW - 2, 1, K.face)
  textW(WX + 2, y, 66, stockMsg, K.black, K.face)
  text(WX + 69, y, "│", K.sh, K.face)
  local src = CONFIG.STOCK_PROVIDER == "finnhub" and "Finnhub" or "Yahoo Finance"
  textW(WX + 70, y, 24, "Source: " .. src, K.black, K.face)
  text(WX + 95, y, "│", K.sh, K.face)
  local left = max(0, floor(nextRefresh - computer.uptime() + 0.5))
  textW(WX + 96, y, 46, httpBusy() and "Updating..." or
    (#stocks.tickers > 0 and ("Next refresh in " .. left .. "s") or "No tickers"), K.black, K.face)
end

local function drawInput()
  bevel(25, 5, 18, 3, "sunken", K.face, K.white)
  textW(26, 6, 16, stockInput .. (stockFocus and "_" or ""), stockFocus and K.black or K.sh, K.white)
  if stockInput == "" and not stockFocus then textW(26, 6, 16, "click to type", K.sh, K.white) end
end

local function stockListRow(i)
  local sym = stocks.tickers[i]
  local y = LIST_Y + 1 + i
  local b = (i % 2 == 0) and G.alt or G.panel
  if not sym then fill(X0, y, CW, 1, G.panel); return end
  local q = quotes[sym]
  local sel = (sym == stockSel)
  if sel then b = G.button end
  local chg, pct, col = fmtChange(q)
  local cells = {
    { (sel and "►" or " ") .. sym, G.accent },
    { q and (q.err and ("! " .. q.err) or q.name) or "loading...", (q and q.err) and G.bad or G.dim },
    { q and fmtPrice(q.price) or "--", G.text },
    { chg, col }, { pct, col },
    { q and fmtPrice(q.low) or "--", G.text }, { q and fmtPrice(q.high) or "--", G.text },
    { q and fmtPrice(q.prev) or "--", G.dim }, { q and fmtMarketTime(q.time) or "--", G.dim },
  }
  local cx = X0 + 1
  fill(X0, y, 1, 1, b)
  for c, col2 in ipairs(SCOLS) do
    textW(cx, y, col2[2] + 1, " " .. cells[c][1], cells[c][2], b, (c >= 3 and c <= 8) and "right" or nil)
    cx = cx + col2[2] + 1
  end
  fill(cx, y, X0 + CW - cx, 1, b)
end

local function stockList()
  D.panel(X0, LIST_Y, CW, 15, "WATCHLIST", G.accent,
    #stocks.tickers .. " of " .. CONFIG.STOCK_MAX_TICKERS .. " tickers - click one for its graph")
  local cx = X0 + 1
  for c, col in ipairs(SCOLS) do
    textW(cx, LIST_Y + 1, col[2] + 1, " " .. col[1], G.dim, G.panel, (c >= 3 and c <= 8) and "right" or nil)
    cx = cx + col[2] + 1
  end
  for i = 1, 12 do stockListRow(i) end
  if #stocks.tickers == 0 then
    textW(X0, LIST_Y + 4, CW, "Type a ticker (e.g. AAPL, MSFT, SPY, BTC-USD) and click Add.", G.dim, G.panel, "center")
  end
end

local function stockGraph(reg)
  local y0 = GRAPH_Y
  local h = BOT - y0 + 1
  D.panel(X0, y0, CW, h, stockSel and ("PRICE HISTORY · " .. stockSel) or "PRICE HISTORY", G.gold)
  D.tabs(X0 + CW - 1, y0, RANGES, V.range, G.gold, function(i) V.range, V.gsel = i, nil; stockGraph() end, reg)
  local rows = h - 6
  local gy = y0 + 2
  if not stockSel then
    textW(X0, gy + 5, CW, "Select a ticker to see its graph.", G.dim, G.panel, "center")
    return
  end
  local S = histOf(stockSel)
  local q = quotes[stockSel]
  local n = SR.count(S)
  local i0, ds = rangeStart(S, RANGES[V.range][2])
  local first = i0 <= n and SR.dec(S.data, i0)
  local lastV = n > 0 and SR.dec(S.data, n)
  local up = (lastV or 0) >= (first or 0)
  local info = D.chart(X0 + 1, gy, CW - 3, rows, S, i0, n, {
    color = up and SK.up or SK.down, prev = (V.range == 1) and q and q.prev or nil, labelW = 11,
    days = ds or SR.dayStarts(S), sel = V.gsel, area = true })
  V.ginfo, V.gi0 = info, i0
  if not info then
    textW(X0, gy + 4, CW, "Not enough price data yet for a graph.", G.dim, G.panel, "center")
    textW(X0, gy + 6, CW, CONFIG.STOCK_PROVIDER == "finnhub"
      and "Finnhub has no free intraday history: a point is saved every 5 min while the market is open."
      or "Waiting for price data from Yahoo...", G.dim, G.panel, "center")
  end
  -- stats line
  local lo2, hi2 = math.huge, -math.huge
  SR.each(S, function(_, _, v) if v then lo2, hi2 = min(lo2, v), max(hi2, v) end end, i0, n)
  local chg, pct, ccol = fmtChange(q)
  local rchg = (first and lastV) and (lastV - first) or nil
  D.segs(X0 + 1, y0 + 1, CW - 2, {
    { "LAST ", G.dim }, { (q and fmtPrice(q.price) or "--") .. " " .. ((q and q.currency) or "") .. "   ", G.text },
    { "TODAY ", G.dim }, { chg .. " (" .. pct .. ")   ", ccol },
    { RANGES[V.range][1] .. " ", G.dim },
    { rchg and string.format("%s%s (%+.2f%%)   ", rchg >= 0 and "+" or "-", fmtPrice(math.abs(rchg)), rchg / first * 100) or "--   ",
      rchg and (rchg >= 0 and SK.up or SK.down) or G.dim },
    { "RANGE ", G.dim }, { lo2 < math.huge and (fmtPrice(lo2) .. " - " .. fmtPrice(hi2)) or "--", G.text } },
    commas(n - i0 + 1) .. " of " .. commas(n) .. " points")
  local ly = gy + rows
  text(X0 + 12, ly, dateLabels(info, S, i0, n, ds, CW - 14), G.dim, G.panel)
  -- legend / click readout
  local c = V.gsel
  if info and c and info.ct[c] then
    D.segs(X0 + 1, ly + 1, CW - 2, { { "► ", G.accent }, { fmtStamp(info.ct[c]) .. "   ", G.text },
      { "close ", G.dim }, { fmtPrice(info.last[c]) .. "   ", up and SK.up or SK.down },
      { "low ", G.dim }, { fmtPrice(info.lo[c]) .. "   ", G.text }, { "high ", G.dim }, { fmtPrice(info.hi[c]), G.text } },
      "click again to clear")
  else
    D.segs(X0 + 1, ly + 1, CW - 2, { { "━ ", up and SK.up or SK.down }, { "price   ", G.dim },
      { "█ ", lerp(up and SK.up or SK.down, G.panel, 0.62) }, { "low-high per column   ", G.dim },
      { "┆ ", G.track }, { "new day   ", G.dim },
      { V.range == 1 and "- - " or "", SK.prevLine }, { V.range == 1 and "previous close" or "", G.dim } },
      "click the graph to read a value")
  end
  if reg then region(stockRegions, X0 + 12, gy, CW - 14, rows, function(px)
    if not V.ginfo then return end
    local col = px - V.ginfo.gx + 1
    for d = 0, 6 do
      if V.ginfo.ct[col - d] then col = col - d; break end
      if V.ginfo.ct[col + d] then col = col + d; break end
    end
    V.gsel = (V.gsel ~= col and V.ginfo.ct[col]) and col or nil
    stockGraph()
  end) end
end

-- dashboard tiles
local TW, TH, TCOLS = 34, 11, 4
local function tileXY(i)
  local c, r = (i - 1) % TCOLS, floor((i - 1) / TCOLS)
  return X0 + 1 + c * (TW + 1), TOP + r * (TH + 1)
end

local function stockTile(i)
  local x, y = tileXY(i)
  local sym = stocks.tickers[i]
  if not sym then
    fill(x, y, TW, TH, G.bg)
    if i == #stocks.tickers + 1 then
      fill(x, y, TW, TH, G.panel)
      textW(x, y + 4, TW, "+ add a ticker", G.dim, G.panel, "center")
      textW(x, y + 5, TW, "type it in the box above", G.grid, G.panel, "center")
    end
    return
  end
  local q = quotes[sym]
  local chg, pct, col = fmtChange(q)
  local strip = (q and q.err) and G.bad or (col == SK.flat and G.axis or col)
  local sel = sym == stockSel
  D.panel(x, y, TW, TH, sym, strip, q and (q.err and "error" or unicode.sub(q.name or "", 1, TW - #sym - 4)) or "loading")
  if sel then text(x + TW - 1, y + TH - 1, "◢", G.accent, G.panel) end
  if q and q.err then
    textW(x + 1, y + 2, TW - 2, q.err, G.bad, G.panel)
  else
    D.segs(x + 1, y + 1, TW - 2, { { q and fmtPrice(q.price) or "--", G.text }, { " " .. ((q and q.currency) or ""), G.dim } },
      chg .. " " .. pct, G.panel, col)
  end
  local S = histOf(sym)
  local n = SR.count(S)
  local i0, ds = rangeStart(S, 1)
  local info = D.chart(x + 1, y + 2, TW - 2, 6, S, i0, n, {
    color = (col == SK.down) and SK.down or SK.up, prev = q and q.prev, days = ds, noGrid = true, area = true })
  if not info then textW(x + 1, y + 4, TW - 2, "waiting for price data...", G.dim, G.panel, "center") end
  D.segs(x + 1, y + 8, TW - 2, { { "L ", G.dim }, { q and fmtPrice(q.low) or "--", G.text },
    { "  H ", G.dim }, { q and fmtPrice(q.high) or "--", G.text } }, commas(n) .. " pts")
  textW(x + 1, y + 9, TW - 2, q and fmtMarketTime(q.time) or "", G.dim, G.panel)
end

local function stockDashboard()
  fill(X0, TOP, CW, BOT - TOP + 1, G.bg)
  for i = 1, CONFIG.STOCK_MAX_TICKERS do stockTile(i) end
end

------------------------------------------------------- PAPER PORTFOLIO
-- Fake-money trading account (one per PLAYER_NAME) using Brokerage's real prices.
-- Stocks: market orders at the last price (any ticker can be typed in the ticket).
-- Options: Yahoo's real bid/ask when Yahoo answers, else a Black-Scholes price;
-- settled in cash at expiry. Nothing here talks to any real broker.
local drawStockWindow   -- forward (defined further down)

local pf = nil                         -- the account, loaded by pfLoad()
local tk = { mode = "stock", sym = nil, qty = 0, otype = "C", exp = 1, strikeOff = 0, oqty = 1,
             selHold = nil, selOpt = nil, msg = nil, focus = false, input = "", flash = nil }
local pfLastTick = 0
local CONTRACT = 100

local function pfPath()
  local safe = tostring(PLAYER_NAME):gsub("[^%w%-_]", "_")
  return (CONFIG.PORTFOLIO_FILE or "/home/lymanos_portfolio_%s.dat"):gsub("%%s", safe)
end

local function money(n)
  if not n then return "--" end
  local neg = n < 0
  n = math.abs(n)
  local whole = floor(n)
  local cents = floor((n - whole) * 100 + 0.5)
  if cents >= 100 then whole, cents = whole + 1, cents - 100 end
  return (neg and "-$" or "$") .. commas(whole) .. string.format(".%02d", cents)
end

local function signedMoney(n)
  if not n then return "--" end
  return (n > 0 and "+" or "") .. money(n)
end

-- save / load: readable text, safe to edit while Lymanos is closed ---------
local function pfSave()
  if not pf then return end
  local f = io.open(pfPath(), "w")
  if not f then return end
  f:write("# LSC paper-trading account for ", pf.owner, "\n",
    "# Edit only while Lymanos is closed. Money you add should also be added to\n",
    "# 'deposits', otherwise it counts as trading profit. Or use PORTFOLIO_SET_CASH\n",
    "# in Lymanos's CONFIG, which does that for you.\n",
    "LSCPORT 1\n",
    "owner ", pf.owner, "\n",
    "cash ", string.format("%.2f", pf.cash), "\n",
    "deposits ", string.format("%.2f", pf.deposits), "\n",
    "setcash ", tostring(pf.setcash or "none"), "\n",
    "lastpay ", tostring(pf.lastPay or "none"), "\n",
    "spins ", tostring(pf.spins or 0), "\n",
    "prizetotal ", string.format("%.2f", pf.prizeTotal or 0), "\n",
    "gids ", table.concat(pf.gids or {}, ","), "\n")
  -- Prize Wheel prizes not finished yet (waiting for a price / for the house to log them)
  for _, z in ipairs(pf.prz or {}) do f:write("Z ", serialization.serialize(z), "\n") end
  local syms = {}
  for s in pairs(pf.stocks) do syms[#syms + 1] = s end
  table.sort(syms)
  for _, s in ipairs(syms) do
    local h = pf.stocks[s]
    f:write("S ", s, " ", tostring(h.sh), " ", string.format("%.4f", h.avg), "\n")
  end
  for _, o in ipairs(pf.options) do
    f:write("O ", o.sym, " ", o.otype, " ", string.format("%.4f", o.K), " ", string.format("%d", o.exp),
      " ", tostring(o.qty), " ", string.format("%.4f", o.paid), "\n")
  end
  for _, t in ipairs(pf.trades) do f:write("T ", t, "\n") end
  -- the Bank's transaction history, newest first: time, kind, amount, balance after, description
  for _, x in ipairs(pf.bank) do f:write("X ", x, "\n") end
  -- casino bets/results the house hasn't answered yet (see CASINO below)
  for rid, r in pairs(pf.cas or {}) do f:write("C ", serialization.serialize({ id = rid, r = r }), "\n") end
  f:close()
end

-- THE place savings change: every app's money moves through here, so the
-- Bank's history always adds up to the balance
local function bankTx(amt, kind, desc)
  pf.cash = pf.cash + amt
  table.insert(pf.bank, 1, string.format("%d\t%s\t%.2f\t%.2f\t%s", floor(now()), kind, amt, pf.cash,
    (tostring(desc or ""):gsub("[\t\r\n]", " "))))
  while #pf.bank > (CONFIG.BANK_HISTORY or 120) do table.remove(pf.bank) end
end

local function pfLoad()
  pf = { owner = PLAYER_NAME, cash = CONFIG.PORTFOLIO_START_CASH or 100000,
         deposits = CONFIG.PORTFOLIO_START_CASH or 100000, setcash = nil,
         stocks = {}, options = {}, trades = {}, cas = {}, bank = {}, prz = {}, gids = {} }
  local f = io.open(pfPath(), "r")
  if f then
    for line in f:lines() do
      local k, rest = line:match("^(%S+)%s*(.*)$")
      if k == "cash" then pf.cash = tonumber(rest) or pf.cash
      elseif k == "deposits" then pf.deposits = tonumber(rest) or pf.deposits
      elseif k == "setcash" then pf.setcash = tonumber(rest)
      elseif k == "lastpay" then pf.lastPay = tonumber(rest)
      elseif k == "spins" then pf.spins = tonumber(rest)
      elseif k == "prizetotal" then pf.prizeTotal = tonumber(rest)
      elseif k == "gids" then for id in rest:gmatch("[^,]+") do pf.gids[#pf.gids + 1] = id end
      elseif k == "Z" then
        local ok, z = pcall(serialization.unserialize, rest)
        if ok and type(z) == "table" and z.id then pf.prz[#pf.prz + 1] = z end
      elseif k == "X" then pf.bank[#pf.bank + 1] = rest
      elseif k == "S" then
        local s, sh, avg = rest:match("^(%S+)%s+(%S+)%s+(%S+)")
        if s and tonumber(sh) and tonumber(sh) > 0 then pf.stocks[s] = { sh = tonumber(sh), avg = tonumber(avg) or 0 } end
      elseif k == "O" then
        local s, ot, K2, ex, q, paid = rest:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if s and tonumber(q) and tonumber(q) > 0 then
          pf.options[#pf.options + 1] = { sym = s, otype = ot, K = tonumber(K2), exp = tonumber(ex),
                                          qty = tonumber(q), paid = tonumber(paid) or 0 }
        end
      elseif k == "T" then pf.trades[#pf.trades + 1] = rest
      elseif k == "C" then
        local ok, c = pcall(serialization.unserialize, rest)
        if ok and type(c) == "table" and c.id and type(c.r) == "table" then pf.cas[c.id] = c.r end
      end
    end
    f:close()
  end
  if not pf.spins then pf.spins = 1 end    -- a welcome spin for the Prize Wheel
  -- a new account (or one from before the Bank): its history starts with the balance it has
  if #pf.bank == 0 then
    pf.bank[1] = string.format("%d\tOPEN\t%.2f\t%.2f\t%s", floor(now()), pf.cash, pf.cash, "Opening balance")
  end
  -- PORTFOLIO_SET_CASH in the config: applied once each time you change it
  local want = CONFIG.PORTFOLIO_SET_CASH
  if type(want) == "number" and want ~= pf.setcash then
    local delta = want - pf.cash
    bankTx(delta, "ADJUST", "Balance set by the server owner")
    pf.deposits, pf.setcash = pf.deposits + delta, want
    table.insert(pf.trades, 1, fmtStamp(now()) .. "  SAVINGS set to " .. money(want) .. " from the config")
  end
  pfSave()
end

local function logTrade(s)
  table.insert(pf.trades, 1, fmtStamp(now()) .. "  " .. s)
  while #pf.trades > 40 do table.remove(pf.trades) end
end

-- market rules --------------------------------------------------------------


-- NYSE regular hours Mon-Fri 9:30-16:00 Eastern (holidays are not known)
local function marketOpen(sym)
  if alwaysOpen(sym) or not CONFIG.PORTFOLIO_MARKET_HOURS then return true end
  local t = now()
  local e = toEastern(t)
  local off = (e.tz == "EDT") and -4 or -5
  local wd = (floor((floor(t) + off * 3600) / 86400) + 4) % 7
  local mins = e.hour * 60 + e.min
  return wd >= 1 and wd <= 5 and mins >= 570 and mins < 960
end

-- usable price + why not
local function tradePrice(sym)
  local q = quotes[sym]
  if q and q.err then return nil, sym .. ": " .. q.err end
  if not q or not q.price then return nil, "No price for " .. sym .. " yet - still loading." end
  if (now() - (q.at or 0)) > max(180, CONFIG.STOCK_REFRESH * 3) then
    return nil, "The price for " .. sym .. " is out of date. Check the Internet Card, then Refresh."
  end
  if not marketOpen(sym) then return nil, "The market is closed (Mon-Fri 9:30 AM - 4:00 PM ET). Trading is paused." end
  return q.price
end

-- options math ----------------------------------------------------------------
local function ncdf(x)   -- standard normal CDF (Abramowitz & Stegun 26.2.17)
  local t = 1 / (1 + 0.2316419 * math.abs(x))
  local d = 0.3989422804014327 * math.exp(-x * x / 2)
  local p = d * t * (0.319381530 + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429))))
  return (x > 0) and (1 - p) or p
end

local function blackScholes(S, K2, T, r, v, isCall)
  if T <= 0 or v <= 0 or S <= 0 then return isCall and max(0, S - K2) or max(0, K2 - S) end
  local sq = v * math.sqrt(T)
  local d1 = (math.log(S / K2) + (r + v * v / 2) * T) / sq
  local d2 = d1 - sq
  if isCall then return S * ncdf(d1) - K2 * math.exp(-r * T) * ncdf(d2) end
  return K2 * math.exp(-r * T) * ncdf(-d2) - S * ncdf(-d1)
end


-- yearly volatility for the formula. Order: your OPTION_VOL setting, then the
-- saved prices (every move, overnight jumps included), then OPTION_DEFAULT_VOL.
local function volatility(sym)
  local ov = type(CONFIG.OPTION_VOL) == "table" and CONFIG.OPTION_VOL[sym]
  if type(ov) == "number" and ov > 0 then return ov, "set in config" end
  local h = stocks.history[sym]
  local intra, sum2, pt, pp, t1, t2 = 0, 0, nil, nil, nil, nil
  if h then
    SR.each(h, function(_, t, p)
      if p and p > 0 then
        if pt then
          local dt = t - pt
          -- gaps up to 4 days are overnight/weekend moves; longer ones are missing data
          if dt > 0 and dt <= 4 * 86400 then
            local r = math.log(p / pp)
            sum2 = sum2 + r * r
            if dt <= 600 then intra = intra + 1 end
          end
        end
        pt, pp = t, p
        t1, t2 = t1 or t, t
      end
    end)
  end
  local var
  if alwaysOpen(sym) then                     -- crypto/forex: trades around the clock
    local span = (t1 and t2) and (t2 - t1) or 0
    if span < 12 * 3600 then return CONFIG.OPTION_DEFAULT_VOL or 0.35, "default" end
    var = sum2 / span * 365 * 86400
  else
    if intra < 39 then return CONFIG.OPTION_DEFAULT_VOL or 0.35, "default" end   -- half a day
    var = sum2 / (intra / 77) * 252           -- 77 five-minute moves per trading day
  end
  return max(0.05, min(3.0, math.sqrt(var))), "saved prices"
end


local function askBid(mid)
  local spread = CONFIG.OPTION_SPREAD or 0.02
  return mid * (1 + spread) + 0.01, max(0, mid * (1 - spread) - 0.01)
end

-- Yahoo option quotes ----------------------------------------------------------
-- Yahoo wants a login cookie + "crumb" for option data: get a cookie from
-- fc.yahoo.com, trade it for a crumb, then ask for one expiry's chain. When
-- any step fails the formula is used instead and Yahoo is retried later.
local COOKIE_URLS = { "https://fc.yahoo.com/", "https://finance.yahoo.com/quote/SPY/" }

local function kstr(K2) return string.format("%.2f", K2) end
function OF.dateOf(exp)                 -- Yahoo's expiry id: 00:00 UTC of that Friday
  local e = toEastern(exp)
  return daysFromCivil(e.year, e.month, e.day) * 86400
end

function OF.watched(sym)
  for _, s2 in ipairs(stocks.tickers) do if s2 == sym then return true end end
  return false
end

-- a usable chain (fresh enough) or nil
function OF.chain(sym, exp)
  if not sym or not exp then return nil end
  local e = OF.chains[sym .. "@" .. OF.dateOf(exp)]
  if e and e.ok and now() - e.at < 1800 then return e end
  return nil
end

local function authQueued()
  if httpCur and (httpCur.kind == "cookie" or httpCur.kind == "crumb") then return true end
  for _, q in ipairs(httpQueue) do if q.kind == "cookie" or q.kind == "crumb" then return true end end
  return false
end

local function queueAuth()
  OF.queue({ key = "#crumb", kind = "crumb" }, true)
  if not OF.cookie then OF.queue({ key = "#cookie", kind = "cookie", step = 1 }, true) end
end

function OF.ensure(sym, exp, background)
  if not inet or CONFIG.OPTION_REAL_PRICES == false or not sym or not exp then return end
  local date = OF.dateOf(exp)
  local key = sym .. "@" .. date
  local e = OF.chains[key]
  local every = CONFIG.OPTION_CHAIN_REFRESH or 120
  if not marketOpen(sym) then every = 900 end
  if e and (e.pending or now() - e.at < every) then return end
  if computer.uptime() < OF.offUntil then return end
  -- keep at most 4 chains in memory (about 10 KB each)
  local n, oldK, oldT = 0, nil, math.huge
  for k, c in pairs(OF.chains) do
    n = n + 1
    if not c.pending and c.at < oldT then oldK, oldT = k, c.at end
  end
  if n >= 4 and not OF.chains[key] then
    -- full: the ticket always gets its chain; held positions only replace stale ones
    if not oldK or (background and now() - oldT < every * 2) then return end
    OF.chains[oldK] = nil
  end
  e = e or { at = 0 }
  e.pending = true
  OF.chains[key] = e
  OF.queue({ key = "#chain:" .. key, kind = "chain", sym = sym, date = date, ckey = key }, true)
  if not OF.crumb then queueAuth() end
end

-- called by pumpHttp when one of these requests reaches the front of the queue
function OF.start(item)
  local k = item.kind
  if k == "cookie" then return COOKIE_URLS[item.step or 1] end
  if k == "crumb" then
    if not OF.cookie then return nil end
    return "https://query1.finance.yahoo.com/v1/test/getcrumb", { Cookie = OF.cookie }
  end
  if k == "settle" then
    return "https://query1.finance.yahoo.com/v8/finance/chart/" .. urlEncode(item.sym)
      .. string.format("?interval=1d&period1=%d&period2=%d", item.exp - 8 * 86400, item.exp + 86400)
  end
  -- chain
  if not OF.crumb then
    if authQueued() then httpQueue[#httpQueue + 1] = item     -- wait for the login to finish
    else
      local e = OF.chains[item.ckey]
      if e then e.pending, e.at, e.ok, e.err = nil, now(), false, OF.status or "no Yahoo login" end
    end
    return nil
  end
  local q = quotes[item.sym]
  item.S = q and q.price
  item.C, item.P, item.n = {}, {}, 0
  return "https://query1.finance.yahoo.com/v7/finance/options/" .. urlEncode(item.sym)
    .. "?date=" .. item.date .. "&crumb=" .. urlEncode(OF.crumb), { Cookie = OF.cookie }
end

-- one option contract: {"contractSymbol":"AAPL261113C00180000","strike":180.0,...}
local function takeContract(cur, obj)
  local K2 = jnum(obj, "strike")
  local cs = jstr(obj, "contractSymbol") or ""
  local typ = cs:match("%d%d%d%d%d%d([CP])%d+$")
  if not K2 or not typ or cur.n >= 160 then return end
  if cur.S and (K2 < cur.S * 0.75 or K2 > cur.S * 1.25) then return end   -- far strikes: skip (RAM)
  local side = typ == "C" and cur.C or cur.P
  side[kstr(K2)] = { K2, jnum(obj, "bid") or 0, jnum(obj, "ask") or 0, jnum(obj, "lastPrice") or 0,
                     jnum(obj, "impliedVolatility") or 0 }
  cur.n = cur.n + 1
end

-- chain replies can be 50+ KB: parse each piece as it arrives
function OF.feed(cur, chunk)
  local s = (cur.buf or "") .. chunk
  if not cur.exp0 then cur.exp0 = tonumber(s:match('"expirationDate"%s*:%s*(%d+)')) end
  if not cur.yerr and s:find('"error"%s*:%s*{') then
    cur.yerr = s:match('"description"%s*:%s*"([^"]*)"') or s:match('"code"%s*:%s*"([^"]*)"') or "error"
  end
  local pos = 1
  while true do
    local a = s:find('{"contractSymbol"', pos, true)
    if not a then pos = max(pos, #s - 64); break end
    local b = s:find("}", a, true)
    if not b then pos = a; break end
    takeContract(cur, s:sub(a, b))
    pos = b + 1
  end
  cur.buf = s:sub(pos)
end

local function cookiesFrom(headers)
  if type(headers) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(headers) do
    if type(k) == "string" and k:lower() == "set-cookie" then
      for _, c in ipairs(type(v) == "table" and v or { v }) do
        local nv = tostring(c):match("^%s*([^;]+)")
        if nv and nv:find("=", 1, true) then out[#out + 1] = nv end
      end
    end
  end
  return #out > 0 and table.concat(out, "; ") or nil
end

local function feedOff(why)
  OF.cookie, OF.crumb = nil, nil
  OF.status = why
  OF.offUntil = computer.uptime() + (CONFIG.OPTION_FEED_RETRY or 600)
  for i = #httpQueue, 1, -1 do        -- drop waiting option requests
    local q = httpQueue[i]
    if q.kind == "chain" or q.kind == "crumb" or q.kind == "cookie" then
      table.remove(httpQueue, i)
      local e = q.ckey and OF.chains[q.ckey]
      if e then e.pending, e.at, e.ok, e.err = nil, now(), false, why end
    end
  end
end

-- called by finishHttp for cookie / crumb / chain / settle requests
function OF.done(cur, err)
  local k = cur.kind
  if k == "cookie" then
    local c = cookiesFrom(cur.headers)
    if c then OF.cookie = c; return end
    local step = (cur.step or 1) + 1
    if COOKIE_URLS[step] then OF.queue({ key = "#cookie", kind = "cookie", step = step }, true)
    else feedOff("no Yahoo login cookie") end
  elseif k == "crumb" then
    local body = table.concat(cur.parts or {}):gsub("^%s+", ""):gsub("%s+$", "")
    if not err and #body > 0 and #body < 64 and not body:find("[%s{<]") then
      OF.crumb = body
    else
      feedOff((tostring(err):find("429") or cur.code == 429) and "Yahoo busy (429)" or "Yahoo login refused")
    end
  elseif k == "settle" then
    local body = table.concat(cur.parts or {})
    local q = (not err) and parseQuote(body)
    local px
    if q and q.st then
      for i = 1, #q.st do if q.st[i] <= cur.exp then px = q.sp[i] end end
    end
    OF.settle[cur.skey] = px or false
  else  -- chain
    local e = OF.chains[cur.ckey] or {}
    OF.chains[cur.ckey] = e
    e.pending, e.at = nil, now()
    local yerr = cur.yerr or ""
    local authBad = cur.code == 401 or cur.code == 403 or yerr:find("Crumb") or yerr:find("Cookie")
      or yerr:find("Unauthorized") or tostring(err):find("401")
    if authBad then
      OF.cookie, OF.crumb = nil, nil
      if not OF.retried then           -- log in again once, then give up for a while
        OF.retried = true
        e.pending = true
        OF.queue({ key = "#chain:" .. cur.ckey, kind = "chain", sym = cur.sym, date = cur.date, ckey = cur.ckey }, true)
        queueAuth()
      else
        e.ok, e.err = false, "Yahoo login refused"
        feedOff(e.err)
      end
    elseif err or (cur.yerr and cur.n == 0) then
      e.ok, e.err = false, "Yahoo: " .. tostring(err or cur.yerr)
      if tostring(err):find("429") then feedOff("Yahoo busy (429)") end
    else
      OF.retried = false
      OF.status = nil
      local list = {}
      for _, c in pairs(cur.C) do list[#list + 1] = c[1] end
      for ks, c in pairs(cur.P) do if not cur.C[ks] then list[#list + 1] = c[1] end end
      table.sort(list)
      e.C, e.P, e.strikes = cur.C, cur.P, list
      e.ok = #list > 0
      e.err = (not e.ok) and "no Yahoo options that date" or nil
    end
  end
  if OF.redraw then OF.redraw() end
end

-- price of one option: Yahoo's real quote when we have it, else the formula.
-- returns mid, ask, bid, source text, volatility, volatility source
function OF.price(sym, otype, K2, exp, S)
  local e = OF.chain(sym, exp)
  local c = e and (otype == "C" and e.C or e.P)[kstr(K2)]
  local vol, vsrc = volatility(sym)
  if c then
    local bid, ask, last, iv = c[2], c[3], c[4], c[5]
    if iv >= 0.03 and iv <= 5 then vol, vsrc = iv, "Yahoo implied" end
    if ask > 0 and ask >= bid then return (ask + bid) / 2, ask, bid, "Yahoo bid/ask", vol, vsrc end
    if last > 0 then
      local a, b = askBid(last)
      return last, a, b, "Yahoo last trade", vol, vsrc
    end
  end
  local T = (exp - now()) / (365 * 86400)
  local mid = blackScholes(S, K2, T, CONFIG.OPTION_RATE or 0.04, vol, otype == "C")
  local a, b = askBid(mid)
  return mid, a, b, "formula", vol, vsrc
end

local function optionMid(sym, otype, K2, exp, S)
  return (OF.price(sym, otype, K2, exp, S))
end

-- next Friday expiries at 4:00 PM Eastern
local function expiries()
  local t = now()
  local e = toEastern(t)
  local today = daysFromCivil(e.year, e.month, e.day)
  local firstFri = today + (5 - (today + 4) % 7) % 7
  local list = {}
  local wk = 0
  while #list < 6 do
    local d = firstFri + wk * 7
    local utc = d * 86400 + 21 * 3600                 -- 4 PM EST
    if toEastern(utc).tz == "EDT" then utc = utc - 3600 end
    if utc - t > 3600 then list[#list + 1] = utc end
    wk = wk + ((#list >= 4) and 2 or 1)                -- 4 weekly, then every other week
  end
  return list
end

local function strikeStep(p)
  for _, s in ipairs({ 0.5, 1, 2.5, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 }) do
    if s >= p * 0.02 then return s end
  end
  return 10000
end

local function nearestIdx(list, v)
  local best, bd = 1, math.huge
  for i, k in ipairs(list) do local d = math.abs(k - v); if d < bd then best, bd = i, d end end
  return best
end

-- the strike the ticket points at: Yahoo's listed strikes when known, else a grid
local function currentStrike(S)
  local e = OF.chain(tk.sym, expiries()[tk.exp])
  if e then
    local list = e.strikes
    local a = nearestIdx(list, S)
    local i = max(1, min(#list, a + tk.strikeOff))
    tk.strikeOff = i - a
    return list[i]
  end
  local step = strikeStep(S)
  local atm = floor(S / step + 0.5) * step
  if atm + tk.strikeOff * step < step then tk.strikeOff = floor((step - atm) / step + 0.5) end
  return max(step, atm + tk.strikeOff * step)
end

-- ticket offset that points at strike K2
local function strikeOffFor(sym, exp, K2, S)
  local e = OF.chain(sym, exp)
  if e then return nearestIdx(e.strikes, K2) - nearestIdx(e.strikes, S) end
  local step = strikeStep(S)
  return floor((K2 - floor(S / step + 0.5) * step) / step + 0.5)
end

local function fmtExp(utc)
  local e = toEastern(utc)
  local days = (utc - now()) / 86400
  return string.format("Fri %02d/%02d (%s)", e.month, e.day, days < 1 and (floor(days * 24) .. "h") or (floor(days + 0.5) .. "d"))
end

-- settlement at expiry: pays the in-the-money value in cash ---------------------

-- the last known price at or before time t: a saved 5-minute point or the
-- latest quote, whichever was recorded closer to t
local function priceAt(sym, t)
  local bt, bp
  local h = stocks.history[sym]
  if h then
    SR.each(h, function(_, tt, p) if tt <= t and p then bt, bp = tt, p end end)
  end
  local q = quotes[sym]
  if q and q.price and q.time and q.time <= t and (not bt or q.time > bt) then return q.price end
  if bp then return bp end
  return q and q.price
end


-- settlement price at expiry for symbols that aren't on the watchlist (no saved
-- 5-minute prices): the day's closing price from Yahoo's daily chart
function OF.settlePrice(sym, exp)
  local key = sym .. "@" .. exp
  local v = OF.settle[key]
  if v then return v end
  if v == false or not inet or CONFIG.STOCK_PROVIDER == "finnhub" then return priceAt(sym, exp) end
  OF.queue({ key = "#settle:" .. key, kind = "settle", sym = sym, exp = exp, skey = key }, true)
  return nil
end


local function settleExpired()
  if not pf then return false end
  local t, changed = now(), false
  for i = #pf.options, 1, -1 do
    local o = pf.options[i]
    -- wait until Brokerage has fetched a price after the expiry time (unless the
    -- ticker isn't on the watchlist any more, then use the saved prices)
    local q = quotes[o.sym]
    if o.exp <= t then
      local S
      if OF.watched(o.sym) then
        if q and q.at and q.at > o.exp then S = priceAt(o.sym, o.exp) end
      else
        S = OF.settlePrice(o.sym, o.exp)    -- that day's close from Yahoo
      end
      if S then
        local intrinsic = (o.otype == "C") and max(0, S - o.K) or max(0, o.K - S)
        local pay = intrinsic * CONTRACT * o.qty
        if pay > 0 then
          bankTx(pay, "OPTION", string.format("Option paid out: %s %s %s", o.sym, fmtPrice(o.K), o.otype == "C" and "call" or "put"))
        end
        logTrade(string.format("EXPIRED %d %s %s %s at %s -> paid %s", o.qty, o.sym, fmtPrice(o.K),
          o.otype == "C" and "CALL" or "PUT", fmtPrice(S), money(pay)))
        table.remove(pf.options, i)
        if tk.selOpt == i then tk.selOpt = nil end
        changed = true
      end
    end
  end
  if changed then pfSave() end
  return changed
end

-- trades ---------------------------------------------------------------------
local function say(m) tk.msg = m end

local function buyStock()
  local sym, qty = tk.sym, tk.qty
  if not sym then return say("Type a ticker in the Symbol box first.") end
  if qty <= 0 then return say("Choose how many shares with the + buttons.") end
  local p, why = tradePrice(sym)
  if not p then return say(why) end
  local cost = p * qty
  if cost > pf.cash + 1e-6 then return say("Not enough savings: that costs " .. money(cost) .. ", your Bank has " .. money(pf.cash) .. ".") end
  local h = pf.stocks[sym] or { sh = 0, avg = 0 }
  h.avg = (h.sh * h.avg + qty * p) / (h.sh + qty)
  h.sh = h.sh + qty
  pf.stocks[sym] = h
  bankTx(-cost, "STOCK", string.format("Bought %s %s @ %s", commas(qty), sym, fmtPrice(p)))
  logTrade(string.format("BUY %d %s @ %s = %s", qty, sym, fmtPrice(p), money(cost)))
  pfSave()
  tk.qty = 0
  say("Bought " .. qty .. " " .. sym .. " at " .. fmtPrice(p) .. ".")
end

local function sellStock()
  local sym, qty = tk.sym, tk.qty
  local h = sym and pf.stocks[sym]
  if not h then return say("You don't own any " .. tostring(sym) .. ".") end
  if qty <= 0 then return say("Choose how many shares with the + buttons.") end
  if qty > h.sh then return say("You only own " .. h.sh .. " shares of " .. sym .. ".") end
  local p, why = tradePrice(sym)
  if not p then return say(why) end
  local got = p * qty
  local pl = (p - h.avg) * qty
  h.sh = h.sh - qty
  if h.sh <= 0 then pf.stocks[sym] = nil end
  bankTx(got, "STOCK", string.format("Sold %s %s @ %s", commas(qty), sym, fmtPrice(p)))
  logTrade(string.format("SELL %d %s @ %s = %s (P/L %s)", qty, sym, fmtPrice(p), money(got), signedMoney(pl)))
  pfSave()
  tk.qty = 0
  say("Sold " .. qty .. " " .. sym .. " at " .. fmtPrice(p) .. ". Profit/loss " .. signedMoney(pl) .. ".")
end

local function buyOption()
  local sym = tk.sym
  if not sym then return say("Type a ticker in the Symbol box first.") end
  local S, why = tradePrice(sym)
  if not S then return say(why) end
  local exp = expiries()[tk.exp]
  local K2 = currentStrike(S)
  local _, ask, _, src = OF.price(sym, tk.otype, K2, exp, S)
  if ask <= 0 then return say("No seller for that option right now (ask is 0). Try another strike.") end
  local cost = ask * CONTRACT * tk.oqty
  if cost > pf.cash + 1e-6 then return say("Not enough savings: that costs " .. money(cost) .. ".") end
  bankTx(-cost, "OPTION", string.format("Bought %d %s %s %s", tk.oqty, sym, fmtPrice(K2), tk.otype == "C" and "call" or "put"))
  local merged = false
  for _, o in ipairs(pf.options) do
    if o.sym == sym and o.otype == tk.otype and math.abs(o.K - K2) < 1e-6 and o.exp == exp then
      o.paid = (o.paid * o.qty + ask * tk.oqty) / (o.qty + tk.oqty)
      o.qty = o.qty + tk.oqty
      merged = true
    end
  end
  if not merged then
    pf.options[#pf.options + 1] = { sym = sym, otype = tk.otype, K = K2, exp = exp, qty = tk.oqty, paid = ask }
  end
  logTrade(string.format("BUY %d %s %s %s exp %s @ %s = %s [%s]", tk.oqty, sym, fmtPrice(K2),
    tk.otype == "C" and "CALL" or "PUT", fmtExp(exp):sub(5, 9), fmtPrice(ask), money(cost),
    src == "formula" and "formula" or "Yahoo"))
  pfSave()
  say("Bought " .. tk.oqty .. " contract(s) for " .. money(cost) .. ".")
end

local function sellOption()
  local o = tk.selOpt and pf.options[tk.selOpt]
  if not o then return say("Click an option in your Options list first.") end
  local S, why = tradePrice(o.sym)
  if not S then return say(why) end
  local qty = min(tk.oqty, o.qty)
  local _, _, bid, src = OF.price(o.sym, o.otype, o.K, o.exp, S)
  local got = bid * CONTRACT * qty
  local pl = (bid - o.paid) * CONTRACT * qty
  bankTx(got, "OPTION", string.format("Sold %d %s %s %s", qty, o.sym, fmtPrice(o.K), o.otype == "C" and "call" or "put"))
  o.qty = o.qty - qty
  logTrade(string.format("SELL %d %s %s %s @ %s = %s (P/L %s) [%s]", qty, o.sym, fmtPrice(o.K),
    o.otype == "C" and "CALL" or "PUT", fmtPrice(bid), money(got), signedMoney(pl),
    src == "formula" and "formula" or "Yahoo"))
  if o.qty <= 0 then table.remove(pf.options, tk.selOpt); tk.selOpt = nil end
  pfSave()
  say("Sold " .. qty .. " contract(s) for " .. money(got) .. ". Profit/loss " .. signedMoney(pl) .. ".")
end

local function totals()
  local sv, ov = 0, 0
  for s, h in pairs(pf.stocks) do
    local q = quotes[s]
    sv = sv + h.sh * ((q and q.price) or h.avg)
  end
  for _, o in ipairs(pf.options) do
    local q = quotes[o.sym]
    local mid = (q and q.price) and optionMid(o.sym, o.otype, o.K, o.exp, q.price) or o.paid
    ov = ov + mid * CONTRACT * o.qty
  end
  return sv, ov
end

------------------------------------------------------- PORTFOLIO VALUE
-- Total account value: every 5 minutes for the last week, plus one point per
-- day (the day's last value) for 5 years. About 16 KB of RAM in all.
local PV = { m5 = SR.new(300, 2016), day = SR.new(86400, 1830), im5 = SR.new(300, 2016), iday = SR.new(86400, 1830),
             at = 0, dirty = false, savedAt = 0, owner = nil }   -- i* = investments only (no savings)
local PV_RANGES = { { "1D", "m5", 1 }, { "1W", "m5", 0 }, { "1M", "day", 31 }, { "1Y", "day", 366 }, { "ALL", "day", 0 } }

local function pvPath()
  local safe = tostring(PLAYER_NAME):gsub("[^%w%-_]", "_")
  return "/home/lymanos_pfvalue_" .. safe .. ".dat"
end

local function pvSave()
  local f = io.open(pvPath(), "w")
  if not f then return end
  f:write("LSCPFVALUE 1\nM ")
  SR.write(f, PV.m5)
  f:write("\nD ")
  SR.write(f, PV.day)
  f:write("\nI ")
  SR.write(f, PV.im5)
  f:write("\nJ ")
  SR.write(f, PV.iday)
  f:write("\n")
  f:close()
  PV.dirty, PV.savedAt = false, computer.uptime()
end

local function pvLoad()
  PV.m5, PV.day = SR.new(300, 2016), SR.new(86400, 1830)
  PV.im5, PV.iday = SR.new(300, 2016), SR.new(86400, 1830)
  PV.owner = PLAYER_NAME
  local f = io.open(pvPath(), "r")
  if not f then return end
  if f:read("*l") == "LSCPFVALUE 1" then
    for line in f:lines() do
      local k, runs, hex = line:match("^(%a) (%S+) ?(%x*)")
      if k == "M" then SR.read(PV.m5, runs, hex) elseif k == "D" then SR.read(PV.day, runs, hex)
      elseif k == "I" then SR.read(PV.im5, runs, hex) elseif k == "J" then SR.read(PV.iday, runs, hex) end
    end
  end
  f:close()
end

-- record the account value (only when every holding has a fresh price)
local function pvRecord()
  if not pf then return end
  if PV.owner ~= PLAYER_NAME then pvLoad() end
  for s in pairs(pf.stocks) do
    local q = quotes[s]
    if not q or not q.price or q.err or now() - (q.at or 0) > 900 then return end
  end
  for _, o in ipairs(pf.options) do
    local q = quotes[o.sym]
    if not q or not q.price then return end
  end
  local sv, ov = totals()
  local total = pf.cash + sv + ov
  local t = now()
  local e = toEastern(t)
  if SR.put(PV.m5, t, total) then PV.dirty = true end
  if SR.put(PV.day, daysFromCivil(e.year, e.month, e.day) * 86400, total) then PV.dirty = true end
  if SR.put(PV.im5, t, sv + ov) then PV.dirty = true end
  if SR.put(PV.iday, daysFromCivil(e.year, e.month, e.day) * 86400, sv + ov) then PV.dirty = true end
end

-- drawing ----------------------------------------------------------------------
local PX1, PW1 = X0 + 1, 86            -- left column
local TX, TW1 = PX1 + PW1 + 1, 0       -- trade ticket (width set below)
TW1 = X0 + CW - TX
local PG_Y, HS_Y, OP_Y, AC_Y = TOP, TOP + 12, TOP + 22, TOP + 29   -- panels on the left
local HROWS, OROWS = 8, 5
local HCOLS = { { "SYMBOL", 8 }, { "SHARES", 9 }, { "AVG COST", 11 }, { "LAST", 11 }, { "VALUE", 13 }, { "P/L", 13 }, { "P/L %", 8 } }
local OCOLS = { { "SYM", 7 }, { "TYPE", 4 }, { "STRIKE", 9 }, { "EXPIRES", 9 }, { "QTY", 4 }, { "PAID", 8 }, { "NOW", 8 }, { "VALUE", 11 }, { "P/L", 11 } }

local function row(x, y, cols, cells, colors, b)
  local cx = x
  for i, c in ipairs(cols) do
    textW(cx, y, c[2] + 1, tostring(cells[i] or ""), colors[i] or G.text, b, i > 1 and "right" or nil)
    cx = cx + c[2] + 1
  end
  return cx
end

local function plColor(v) return (v or 0) > 0 and SK.up or ((v or 0) < 0 and SK.down or G.text) end

local function drawSummary()
  local sv, ov = totals()
  local total = pf.cash + sv + ov
  local pl = total - pf.deposits
  local x, w = TX, TW1
  D.panel(x, TOP, w, 5, "ACCOUNT · " .. pf.owner, G.accent)
  D.segs(x + 1, TOP + 1, w - 2, { { "SAVINGS ", G.dim }, { money(pf.cash), G.text } }, "STOCKS " .. money(sv))
  D.segs(x + 1, TOP + 2, w - 2, { { "OPTIONS ", G.dim }, { money(ov), G.text } },
    string.format("on %s deposited", D.shortMoney(pf.deposits)))
  D.segs(x + 1, TOP + 3, w - 2, { { "TOTAL ", G.dim }, { money(total), G.gold } },
    string.format("%s (%+.2f%%)", signedMoney(pl), pf.deposits > 0 and pl / pf.deposits * 100 or 0), G.panel, plColor(pl))
  local open = marketOpen("SPY")
  D.segs(x + 1, TOP + 4, w - 2, { { open and "● MARKET OPEN" or "○ MARKET CLOSED", open and SK.up or G.dim },
    { open and "  orders fill at the latest price" or "  9:30-4:00 ET; -USD/=X still trade", G.dim } })
end

local function drawValueGraph(reg)
  local y0 = PG_Y
  local title = V.pfInv and "INVESTMENTS ONLY ▾" or "PORTFOLIO VALUE ▾"
  D.panel(PX1, y0, PW1, 12, title, G.gold)
  if reg then region(stockRegions, PX1, y0, unicode.len(title) + 2, 1, function()
    popupMenu(PX1, y0 + 1, {
      { (V.pfInv and "  " or "● ") .. "Portfolio value (savings + investments)", function() V.pfInv, V.psel = false, nil end },
      { (V.pfInv and "● " or "  ") .. "Investments only (stocks, crypto, options)", function() V.pfInv, V.psel = true, nil end },
    })
  end) end
  D.tabs(PX1 + PW1 - 1, y0, PV_RANGES, V.pfRange, G.gold, function(i) V.pfRange, V.psel = i, nil; drawValueGraph() end, reg)
  local R = PV_RANGES[V.pfRange]
  local S = PV[(V.pfInv and "i" or "") .. R[2]]
  local n = SR.count(S)
  local i0 = 1
  local ds
  if R[2] == "m5" then i0, ds = rangeStart(S, R[3])
  elseif R[3] > 0 then i0 = max(1, n - R[3] + 1) end
  local first = n > 0 and SR.dec(S.data, i0)
  local lastV = n > 0 and SR.dec(S.data, n)
  local up = (lastV or 0) >= (first or 0)
  local info = D.chart(PX1 + 1, y0 + 2, PW1 - 2, 8, S, i0, n, {
    color = up and SK.up or SK.down, prev = (not V.pfInv) and pf.deposits or nil, stretch = false, labelW = 10, label = D.shortMoney,
    days = ds or (R[2] == "m5" and SR.dayStarts(S)) or nil, sel = V.psel, area = true })
  V.pinfo = info
  local sv, ov = totals()
  local total = (V.pfInv and 0 or pf.cash) + sv + ov
  local ch = first and (total - first) or nil
  D.segs(PX1 + 1, y0 + 1, PW1 - 2, { { "NOW ", G.dim }, { money(total) .. "   ", G.gold },
    { R[1] .. " ", G.dim },
    { ch and string.format("%s (%+.2f%%)", signedMoney(ch), first > 0 and ch / first * 100 or 0) or "--", ch and plColor(ch) or G.dim } },
    commas(n - i0 + 1) .. " points")
  if not info then
    textW(PX1 + 1, y0 + 5, PW1 - 2, (R[2] == "m5") and "The value is saved every 5 minutes while Lymanos runs."
      or "One point per day - this fills in as the days go by.", G.dim, G.panel, "center")
  end
  local c = V.psel
  if info and c and info.ct[c] then
    D.segs(PX1 + 1, y0 + 11, PW1 - 2, { { "► ", G.accent }, { fmtStamp(info.ct[c]) .. "   ", G.text },
      { money(info.last[c]), G.gold } }, V.pfInv and "" or ("vs deposits " .. signedMoney(info.last[c] - pf.deposits)), G.panel,
      V.pfInv and G.dim or plColor(info.last[c] - pf.deposits))
  else
    text(PX1 + 11, y0 + 10, dateLabels(info, S, i0, n, ds, PW1 - 12), G.dim, G.panel)
    if V.pfInv then
      D.segs(PX1 + 1, y0 + 11, PW1 - 2, { { "stocks, crypto and options only - savings not included", G.dim } }, "click to read a value")
    else
      D.segs(PX1 + 1, y0 + 11, PW1 - 2, { { "- - ", SK.prevLine }, { "money deposited (break-even)", G.dim } }, "click to read a value")
    end
  end
  if reg then region(stockRegions, PX1 + 11, y0 + 2, PW1 - 12, 8, function(px)
    if not V.pinfo then return end
    local col = px - V.pinfo.gx + 1
    for d = 0, 6 do
      if V.pinfo.ct[col - d] then col = col - d; break end
      if V.pinfo.ct[col + d] then col = col + d; break end
    end
    V.psel = (V.psel ~= col and V.pinfo.ct[col]) and col or nil
    drawValueGraph()
  end) end
end

local function holdSyms()
  local l = {}
  for s in pairs(pf.stocks) do l[#l + 1] = s end
  table.sort(l)
  return l
end

local function drawHoldings()
  local syms = holdSyms()
  V.hScroll = max(0, min(V.hScroll, #syms - HROWS))
  for i = 1, HROWS do
    local s = syms[i + V.hScroll]
    local y = HS_Y + 1 + i
    local sel = s and s == tk.selHold
    local b = sel and G.button or ((i % 2 == 0) and G.alt or G.panel)
    if s then
      local h, q = pf.stocks[s], quotes[s]
      local last = q and q.price
      local val = h.sh * (last or h.avg)
      local pl = last and (last - h.avg) * h.sh
      local cx = row(PX1 + 1, y, HCOLS,
        { (sel and "►" or " ") .. s, commas(h.sh), fmtPrice(h.avg), fmtPrice(last), money(val), signedMoney(pl),
          pl and string.format("%+.2f%%", (last / h.avg - 1) * 100) or "--" },
        { G.accent, G.text, G.dim, G.text, G.text, plColor(pl), plColor(pl) }, b)
      fill(PX1, y, 1, 1, b)
      fill(cx, y, PX1 + PW1 - cx, 1, b)
    else
      fill(PX1, y, PW1, 1, G.panel)
    end
  end
  if #syms == 0 then textW(PX1, HS_Y + 4, PW1, "No stocks yet. Use the trade ticket on the right to buy some.", G.dim, G.panel, "center") end
  if #syms > HROWS then
    textW(PX1 + PW1 - 22, HS_Y, 21, string.format("%d-%d of %d  (scroll)", V.hScroll + 1, min(#syms, V.hScroll + HROWS), #syms), G.dark, G.violet, "right")
  end
end

local function drawOptions()
  V.oScroll = max(0, min(V.oScroll, #pf.options - OROWS))
  for r = 1, OROWS do
    local i = r + V.oScroll
    local o = pf.options[i]
    local y = OP_Y + 1 + r
    local sel = (i == tk.selOpt)
    local b = sel and G.button or ((r % 2 == 0) and G.alt or G.panel)
    if o then
      local q = quotes[o.sym]
      local mid = (q and q.price) and optionMid(o.sym, o.otype, o.K, o.exp, q.price)
      local val = (mid or o.paid) * CONTRACT * o.qty
      local pl = mid and (mid - o.paid) * CONTRACT * o.qty
      local e = toEastern(o.exp)
      local cx = row(PX1 + 1, y, OCOLS,
        { (sel and "►" or " ") .. o.sym, o.otype == "C" and "CALL" or "PUT", fmtPrice(o.K), string.format("%02d/%02d", e.month, e.day), o.qty,
          fmtPrice(o.paid), mid and fmtPrice(mid) or "--", money(val), signedMoney(pl) },
        { G.accent, o.otype == "C" and SK.up or SK.down, G.text, G.dim, G.text, G.dim, G.text, G.text, plColor(pl) }, b)
      fill(PX1, y, 1, 1, b)
      fill(cx, y, PX1 + PW1 - cx, 1, b)
    else
      fill(PX1, y, PW1, 1, G.panel)
    end
  end
  if #pf.options == 0 then textW(PX1, OP_Y + 3, PW1, "No options yet. Switch the ticket to Options to buy calls or puts.", G.dim, G.panel, "center") end
  if #pf.options > OROWS then
    textW(PX1 + PW1 - 22, OP_Y, 21, string.format("%d-%d of %d  (scroll)", V.oScroll + 1, min(#pf.options, V.oScroll + OROWS), #pf.options), G.dark, G.violet, "right")
  end
end

local function drawTrades()
  for i = 1, BOT - AC_Y do
    local t = pf.trades[i] or ""
    local col = i == 1 and G.text or G.dim
    if t:find(" BUY ") then col = i == 1 and SK.up or lerp(SK.up, G.panel, 0.35)
    elseif t:find(" SELL ") then col = i == 1 and SK.down or lerp(SK.down, G.panel, 0.35)
    elseif t:find("EXPIRED") then col = G.gold
    elseif t:find("CASINO") then col = i == 1 and G.violet or lerp(G.violet, G.panel, 0.35) end
    textW(PX1 + 1, AC_Y + i, PW1 - 2, t, col, G.panel)
  end
end

local function wrapText(s, w, n)
  local out, line = {}, ""
  for word in tostring(s or ""):gmatch("%S+") do
    if unicode.len(line) + unicode.len(word) + 1 > w and line ~= "" then out[#out + 1] = line; line = word
    else line = (line == "") and word or (line .. " " .. word) end
  end
  if line ~= "" then out[#out + 1] = line end
  while #out > n do table.remove(out) end
  return out
end

-- the Symbol box in the trade ticket (type any ticker, Enter to load it)
local function drawSymField()
  local x = TX + 2
  if tk.focus then
    textW(x + 15, 19, 14, " " .. tk.input .. "_", G.dark, 0xFFFFC0)
  else
    textW(x + 15, 19, 14, " " .. (tk.sym or "click to type"), tk.sym and G.accent or G.dim, G.track)
  end
end

local function kv(x, y, w, label, value, col)
  D.segs(x, y, w, { { label, G.dim }, { value, col or G.text } })
end

local function drawTicketValues()
  local x, w = TX + 2, TW1 - 4
  local sym = tk.sym
  local q = sym and quotes[sym]
  local S = q and q.price
  drawSymField()
  if q and q.err then
    textW(x, 20, w, "! " .. q.err, SK.down, G.panel)
  elseif sym and not S then
    textW(x, 20, w, "Loading price for " .. sym .. "...", G.dim, G.panel)
  else
    local chg, pct, col = fmtChange(q)
    D.segs(x, 20, w, { { "LAST ", G.dim }, { (S and fmtPrice(S) or "--") .. "  ", G.text }, { chg .. " (" .. pct .. ")", col } },
      (sym and not OF.watched(sym)) and "off watchlist" or "")
  end
  if tk.mode == "stock" then
    local h = sym and pf.stocks[sym]
    kv(x, 21, w, "YOU OWN  ", h and (commas(h.sh) .. " sh @ " .. fmtPrice(h.avg)) or "none")
    kv(x, 23, w, "QUANTITY ", commas(tk.qty) .. " shares", G.accent)
    local cost = S and S * tk.qty
    kv(x, 28, w, "ESTIMATED ", cost and money(cost) or "--", G.gold)
    kv(x, 29, w, "SAVINGS   ", money(pf.cash), G.dim)
  else
    local exps = expiries()
    tk.exp = max(1, min(tk.exp, #exps))
    local exp = exps[tk.exp]
    textW(x + 18, 22, 22, fmtExp(exp), G.accent, G.panel, "center")
    OF.ensure(sym, exp)
    if S then
      local K2 = currentStrike(S)
      local tag = (math.abs(K2 - S) < strikeStep(S) / 2) and "at the money"
        or (((tk.otype == "C") == (K2 < S)) and "in the money" or "out of the money")
      textW(x + 18, 23, 14, fmtPrice(K2), G.accent, G.panel, "center")
      textW(x + 37, 23, w - 37, tag, G.dim, G.panel)
      local _, ask, bid, src, v, vsrc = OF.price(sym, tk.otype, K2, exp, S)
      kv(x, 24, w, "BREAKEVEN ", fmtPrice(tk.otype == "C" and K2 + ask or K2 - ask) .. " at expiry")
      kv(x, 25, w, "PRICE     ", string.format("%s/share = %s per contract", fmtPrice(ask), money(ask * CONTRACT)), G.gold)
      kv(x, 26, w, "SELL NOW  ", string.format("%s    vol %d%% (%s)", fmtPrice(bid), floor(v * 100 + 0.5), vsrc), G.dim)
      local e = OF.chains[sym .. "@" .. OF.dateOf(exp)]
      local why
      if src ~= "formula" then why = ""
      elseif CONFIG.OPTION_REAL_PRICES == false then why = " (real prices off)"
      elseif not inet then why = ""
      elseif e and e.pending then why = " - asking Yahoo..."
      elseif OF.chain(sym, exp) then why = " - no Yahoo quote here"
      elseif e and e.err then why = " - " .. e.err
      elseif OF.status then why = " - " .. OF.status end
      kv(x, 27, w, "SOURCE    ", src .. why, src == "formula" and G.dim or SK.up)
      kv(x, 30, w, "COST      ", money(ask * CONTRACT * tk.oqty) .. "   (savings " .. money(pf.cash) .. ")", G.gold)
    else
      textW(x + 18, 23, 14, "--", G.accent, G.panel, "center")
      textW(x + 37, 23, w - 37, "", G.dim, G.panel)
      for _, yy in ipairs({ 24, 25, 26, 27, 30 }) do textW(x, yy, w, yy == 25 and "Waiting for a price..." or "", G.dim, G.panel) end
    end
    kv(x, 28, w, "CONTRACTS ", tk.oqty .. "  (1 contract = " .. CONTRACT .. " shares)", G.accent)
    local o = tk.selOpt and pf.options[tk.selOpt]
    if o then
      local ee = toEastern(o.exp)
      textW(x, 31, w, string.format(" ► Selected: %d %s %s %s exp %02d/%02d", o.qty, o.sym, fmtPrice(o.K),
        o.otype == "C" and "CALL" or "PUT", ee.month, ee.day), G.text, G.button)
    else
      textW(x, 31, w, "Click an option on the left to sell it.", G.dim, G.panel)
    end
  end
  local lines = wrapText(tk.msg or (tk.focus and
    "Type any ticker (stock, ETF, BTC-USD...), then press Enter. Esc cancels." or ""), w, 6)
  for i = 1, 6 do textW(x, 35 + i, w, lines[i] or "", i == 1 and G.accent or G.text, G.panel) end
end

-- flat dark controls; a clicked one lights up for a moment so you see it landed
local function smallBtn(x, y, label, fn)
  local function paint(on) text(x, y, label, on and G.dark or G.text, on and G.accent or G.button) end
  paint(tk.flash and tk.flash.x == x and tk.flash.y == y)
  region(stockRegions, x, y, unicode.len(label), 1, function()
    tk.flash = { x = x, y = y, at = computer.uptime(), paint = paint }
    fn()
  end)
end

local function pushBtn(x, y, w, label, fn, dim, col)
  local base = dim and G.track or (col or G.button)
  local function paint(on)
    local b = on and G.accent or base
    fill(x, y, w, 3, b)
    textW(x, y + 1, w, label, on and G.dark or (dim and G.dim or G.text), b, "center")
  end
  paint(tk.flash and tk.flash.x == x and tk.flash.y == y)
  region(stockRegions, x, y, w, 3, function()
    tk.flash = { x = x, y = y, at = computer.uptime(), paint = paint }
    fn()
  end)
end

-- two-way choice: the chosen one is filled in its color with a dot
local function choice(x, y, label, on, col, fn)
  text(x, y, (on and " ● " or " ○ ") .. label .. " ", on and G.dark or G.text, on and col or G.button)
  region(stockRegions, x, y, unicode.len(label) + 4, 1, fn)
end

local function tab3(x, y, w, label, on, fn)
  fill(x, y, w, 3, on and G.accent or G.button)
  textW(x, y + 1, w, (on and "● " or "") .. label, on and G.dark or G.text, on and G.accent or G.button, "center")
  region(stockRegions, x, y, w, 3, fn)
end

local function setTicketSym(sym)
  tk.sym, tk.strikeOff, tk.qty, tk.selOpt, tk.selHold, tk.msg = sym, 0, 0, nil, nil, nil
  local q = quotes[sym]
  if not q or not q.price or q.err or now() - (q.at or 0) > 120 then
    if q and q.err then quotes[sym] = nil end
    queueFetch(sym, true, "quote")
  end
end

local function cycleSym(d)
  local list = stocks.tickers
  if #list == 0 then return end
  local idx = 0
  for i, s in ipairs(list) do if s == tk.sym then idx = i end end
  if idx == 0 then idx = (d > 0) and 0 or 1 end
  setTicketSym(list[(idx - 1 + d) % #list + 1])
end

local function act(fn) return function() fn(); drawStockWindow() end end

local function drawPortfolio(full)
  if not pf then pfLoad() end
  if PV.owner ~= PLAYER_NAME then pvLoad() end
  if not tk.sym then tk.sym = stockSel or stocks.tickers[1] end
  if full then
    fill(X0, TOP, CW, BOT - TOP + 1, G.bg)
    D.panel(PX1, HS_Y, PW1, HROWS + 2, "STOCKS", G.accent)
    local cx = PX1 + 1
    for i, c in ipairs(HCOLS) do textW(cx, HS_Y + 1, c[2] + 1, (i == 1 and " " or "") .. c[1], G.dim, G.panel, i > 1 and "right" or nil); cx = cx + c[2] + 1 end
    D.panel(PX1, OP_Y, PW1, OROWS + 2, "OPTIONS", G.violet)
    cx = PX1 + 1
    for i, c in ipairs(OCOLS) do textW(cx, OP_Y + 1, c[2] + 1, (i == 1 and " " or "") .. c[1], G.dim, G.panel, i > 1 and "right" or nil); cx = cx + c[2] + 1 end
    D.panel(PX1, AC_Y, PW1, BOT - AC_Y + 1, "RECENT ACTIVITY", G.axis)
    D.panel(TX, TOP + 5, TW1, BOT - TOP - 4, "TRADE TICKET", G.gold, tk.mode == "stock" and "stocks" or "options")
    local x = TX + 2
    tab3(x, 15, 23, "STOCKS", tk.mode == "stock", act(function() tk.mode = "stock"; tk.msg = nil end))
    tab3(x + 25, 15, TW1 - 29, "OPTIONS", tk.mode == "option", act(function() tk.mode = "option"; tk.msg = nil end))
    textW(x, 19, 15, "SYMBOL", G.dim, G.panel)
    region(stockRegions, x + 15, 19, 14, 1, function()
      tk.focus, tk.input, tk.msg = true, "", nil
      drawTicketValues()
    end)
    smallBtn(x + 30, 19, " ◄ ", act(function() cycleSym(-1) end))
    smallBtn(x + 34, 19, " ► ", act(function() cycleSym(1) end))
    textW(x + 38, 19, 11, "watchlist", G.dim, G.panel)
    if tk.mode == "stock" then
      local qx = x
      for _, d in ipairs({ -100, -10, -1, 1, 10, 100 }) do
        local lbl = string.format("%+d", d)
        smallBtn(qx, 24, " " .. lbl .. " ", act(function() tk.qty = max(0, tk.qty + d) end))
        qx = qx + unicode.len(lbl) + 3
      end
      smallBtn(x, 25, " Max buy ", act(function()
        local q = tk.sym and quotes[tk.sym]
        if q and q.price and q.price > 0 then tk.qty = floor(pf.cash / q.price) end
      end))
      smallBtn(x + 10, 25, " All shares ", act(function()
        local h = tk.sym and pf.stocks[tk.sym]
        tk.qty = h and h.sh or 0
      end))
      smallBtn(x + 23, 25, " Clear ", act(function() tk.qty = 0 end))
      pushBtn(x, 31, 23, "BUY", act(buyStock), false, 0x1F5A2E)
      pushBtn(x + 25, 31, TW1 - 29, "SELL", act(sellStock), false, 0x6A2020)
    else
      textW(x, 21, 15, "TYPE", G.dim, G.panel)
      choice(x + 15, 21, "CALL", tk.otype == "C", SK.up, act(function() tk.otype = "C" end))
      choice(x + 25, 21, "PUT", tk.otype == "P", SK.down, act(function() tk.otype = "P" end))
      textW(x, 22, 15, "EXPIRES", G.dim, G.panel)
      smallBtn(x + 15, 22, " ◄ ", act(function() tk.exp = max(1, tk.exp - 1) end))
      smallBtn(x + 41, 22, " ► ", act(function() tk.exp = tk.exp + 1 end))
      textW(x, 23, 15, "STRIKE", G.dim, G.panel)
      smallBtn(x + 15, 23, " ◄ ", act(function() tk.strikeOff = tk.strikeOff - 1 end))
      smallBtn(x + 33, 23, " ► ", act(function() tk.strikeOff = tk.strikeOff + 1 end))
      local qx = x
      for _, d in ipairs({ -10, -1, 1, 10 }) do
        local lbl = string.format("%+d", d)
        smallBtn(qx, 29, " " .. lbl .. " ", act(function() tk.oqty = max(1, tk.oqty + d) end))
        qx = qx + unicode.len(lbl) + 3
      end
      pushBtn(x, 32, 23, "BUY TO OPEN", act(buyOption), false, 0x1F5A2E)
      pushBtn(x + 25, 32, TW1 - 29, "SELL TO CLOSE", act(sellOption), not tk.selOpt, 0x6A2020)
    end
    -- list clicks (the lists can scroll)
    for i = 1, HROWS do
      region(stockRegions, PX1, HS_Y + 1 + i, PW1, 1, act(function()
        local s = holdSyms()[i + V.hScroll]
        if s then tk.selHold, tk.sym, tk.mode, tk.msg, tk.selOpt = s, s, "stock", nil, nil; tk.qty = pf.stocks[s].sh end
      end))
    end
    for r = 1, OROWS do
      region(stockRegions, PX1, OP_Y + 1 + r, PW1, 1, act(function()
        local i = r + V.oScroll
        local o = pf.options[i]
        if o then
          tk.selOpt, tk.mode, tk.sym, tk.otype, tk.oqty, tk.msg, tk.selHold = i, "option", o.sym, o.otype, o.qty, nil, nil
          for j, e in ipairs(expiries()) do if e == o.exp then tk.exp = j end end
          local S = quotes[o.sym] and quotes[o.sym].price
          if S then tk.strikeOff = strikeOffFor(o.sym, o.exp, o.K, S) end
        end
      end))
    end
    drawValueGraph(true)
  end
  drawSummary()
  drawHoldings()
  drawOptions()
  drawTrades()
  drawTicketValues()
end
OF.redraw = function()
  if activeApp == "stock" and stockView == "portfolio" and not overlay then drawPortfolio(false) end
end

-- symbols you trade or own that aren't on the watchlist (they still need prices)
OF.extras = function()
  local out, seen = {}, {}
  local function add(sym) if sym and not seen[sym] and not OF.watched(sym) then seen[sym] = true; out[#out + 1] = sym end end
  add(tk.sym)
  if pf then
    for _, z in ipairs(pf.prz or {}) do if z.st == "price" then add(z.v) end end   -- a Prize Wheel share needs a price
    for sym in pairs(pf.stocks) do add(sym) end
    for _, o in ipairs(pf.options) do add(o.sym) end
  end
  return out
end

-- typing into the ticket's Symbol box
local function tkKey(ch, code)
  if code == 28 or code == 156 then
    local sym = tk.input:upper():gsub("%s", "")
    tk.focus, tk.input = false, ""
    if sym ~= "" then setTicketSym(sym) end
    drawStockWindow()
  elseif code == 1 then tk.focus, tk.input = false, ""; drawTicketValues()
  elseif code == 14 then tk.input = tk.input:sub(1, -2); drawSymField()
  elseif ch and ch > 0 then
    local c = string.char(ch):upper()
    if c:match("[%w%.%-%^=]") and #tk.input < 12 then tk.input = tk.input .. c; drawSymField() end
  end
end

-- once per second from the main loop: expiry settlement, live values,
-- portfolio value, saving
local function pfTick()
  local up = computer.uptime()
  local shown = activeApp == "stock" and stockView == "portfolio" and not overlay
  local f = tk.flash
  if f and up - f.at >= 0.4 then          -- un-light the last clicked button
    tk.flash = nil
    if shown and f.paint then f.paint(false) end
  end
  if up - pfLastTick < 5 then return end
  pfLastTick = up
  if not pf then pfLoad() end
  if settleExpired() and shown then drawStockWindow() end
  if shown and pf then       -- keep Yahoo option quotes fresh for what's on screen
    for _, o in ipairs(pf.options) do if o.exp > now() then OF.ensure(o.sym, o.exp, true) end end
  end
  if up - PV.at >= 60 then
    PV.at = up
    pvRecord()
    if shown then drawValueGraph() end
  end
  if PV.dirty and up - PV.savedAt >= 600 then pvSave() end
  if V.dirty and up - V.savedAt >= 300 then saveStocks() end
end

local function drawStockBody()
  if stockView == "dashboard" then stockDashboard()
  elseif stockView == "portfolio" then drawPortfolio(true)
  else stockList(); stockGraph(true) end
end

-- redraw the parts that show one symbol (after a quote arrives)
local function refreshStockSym(sym)
  if activeApp ~= "stock" or overlay then return end
  if stockView == "portfolio" then drawPortfolio(false); drawStockStatus(); return end
  for i, s in ipairs(stocks.tickers) do
    if s == sym then
      if stockView == "dashboard" then stockTile(i) else stockListRow(i) end
    end
  end
  if stockView == "details" and sym == stockSel then stockGraph() end
  drawStockStatus()
end

onQuote = function(sym, q, err)
  local watched = OF.watched(sym)
  if not watched then
    local used = false
    for _, s in ipairs(OF.extras()) do if s == sym then used = true end end
    if not used then return end
  end
  if q then
    local old = quotes[sym]
    q.name = q.name or (old and old.name)
    q.at = now()
    quotes[sym] = q
    backoff = 0
    if watched then
      local merged = mergeSeries(sym, q.st, q.sp)
      if logPrice(sym, q) or merged then V.dirty = true end
    end
    q.st, q.sp = nil, nil
    stockMsg = "Updated " .. sym .. " at " .. fmtTime(now())
  else
    quotes[sym] = quotes[sym] or {}
    quotes[sym].err = err
    if tostring(err):find("429") then backoff = min(600, backoff + 60) end
    stockMsg = sym .. ": " .. tostring(err)
  end
  refreshStockSym(sym)
end

-- actions -----------------------------------------------------------------

local function addTicker()
  local sym = stockInput:upper():gsub("%s", "")
  stockInput, stockFocus = "", false
  if sym == "" then drawInput(); return end
  for _, s in ipairs(stocks.tickers) do
    if s == sym then stockMsg = sym .. " is already on the list."; stockSel = sym; drawStockWindow(); return end
  end
  if #stocks.tickers >= CONFIG.STOCK_MAX_TICKERS then
    stockMsg = "The list is full (" .. CONFIG.STOCK_MAX_TICKERS .. "). Remove one first."
    drawStockWindow(); return
  end
  stocks.tickers[#stocks.tickers + 1] = sym
  histOf(sym)
  stockSel = sym
  saveStocks()
  queueFetch(sym, true, "bars")
  stockMsg = inet and ("Added " .. sym .. " - fetching price...")
             or ("Added " .. sym .. " - no Internet Card, so prices can't load yet.")
  drawStockWindow()
end

local function removeTicker()
  if not stockSel then stockMsg = "Select a ticker first."; drawStockStatus(); return end
  local sym = stockSel
  dialog("Remove Ticker", { "Remove " .. sym .. " and its saved price history?" }, {
    { "Yes", function()
        for i, s in ipairs(stocks.tickers) do if s == sym then table.remove(stocks.tickers, i); break end end
        stocks.history[sym], quotes[sym] = nil, nil
        stockSel = stocks.tickers[1]
        saveStocks()
        stockMsg = "Removed " .. sym .. "."
      end },
    { "No" },
  })
end

local function selectTicker(i)
  local sym = stocks.tickers[i]
  if not sym then return end
  V.gsel = nil
  if stockView == "dashboard" then
    stockSel, stockView = sym, "details"
    drawStockWindow()
  else
    local old = stockSel
    stockSel = sym
    for j, s in ipairs(stocks.tickers) do if s == old or s == sym then stockListRow(j) end end
    stockGraph()
  end
end

local function stockMenu()
  popupMenu(WX + 2, WY + 3, {
    { "Add Ticker", function() stockFocus = true end },
    { "Remove Selected...", removeTicker },
    { "Refresh Now", function() refreshAll() end },
    { "-" },
    { "Close Brokerage", function() if V.dirty then saveStocks() end; if PV.dirty then pvSave() end
        stockOpen = false; activeApp = "viewer" end },
  })
end

local function stockViewMenu()
  popupMenu(WX + 13, WY + 3, {
    { "Dashboard", function() stockView = "dashboard" end },
    { "Details + Graph", function() stockView = "details" end },
    { "Portfolio", function() stockView = "portfolio" end },
  })
end

local function stockHelpMenu()
  popupMenu(WX + 19, WY + 3, { { "About Brokerage...", function()
    dialog("About Brokerage", {
      "Prices come from " .. (CONFIG.STOCK_PROVIDER == "finnhub" and "Finnhub" or "Yahoo Finance") .. " through the Internet Card.",
      "Refresh every " .. CONFIG.STOCK_REFRESH .. " s. Up to " .. commas(CONFIG.STOCK_LOG_MAX)
        .. " five-minute prices are kept per ticker (4 bytes each).",
      "Portfolio value: every 5 minutes for a week, then one point a day.",
      "Tickers use Yahoo symbols: AAPL, SPY, ^GSPC, BTC-USD, EURUSD=X.",
      "Quotes may be delayed. Paper money only - not for real trading decisions.",
    }, { { "OK" } })
  end } })
end

drawStockWindow = function()
  stockRegions = {}
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  local viewName = (stockView == "dashboard" and "Dashboard") or (stockView == "portfolio" and ("Portfolio (" .. PLAYER_NAME .. ")")) or "Details"
  titleBar(WX + 1, WY + 1, WW - 2, "▣ Brokerage - " .. viewName, true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(stockRegions, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(stockRegions, bx + 7, WY + 1, 3, 1, function() stockOpen = false; activeApp = nil; drawAll() end)

  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  text(WX + 2, WY + 2, " Brokerage ", K.black, K.face)
  text(WX + 13, WY + 2, " View ", K.black, K.face)
  text(WX + 19, WY + 2, " Help ", K.black, K.face)
  region(stockRegions, WX + 2, WY + 2, 11, 1, stockMenu)
  region(stockRegions, WX + 13, WY + 2, 6, 1, stockViewMenu)
  region(stockRegions, WX + 19, WY + 2, 6, 1, stockHelpMenu)

  -- toolbar
  fill(WX + 1, 5, WW - 2, 3, K.face)
  text(17, 6, "Ticker:", K.black, K.face)
  drawInput()
  region(stockRegions, 25, 5, 18, 3, function() stockFocus = true; drawInput() end)
  button(stockRegions, 44, 5, 9, "Add", addTicker)
  button(stockRegions, 54, 5, 12, "Remove", removeTicker)
  button(stockRegions, 67, 5, 13, "Refresh", function()
    refreshAll(); stockMsg = "Refreshing..."; drawStockStatus()
  end)
  local function viewBtn(x, w, label, key)
    button(stockRegions, x, 5, w, (stockView == key and "► " or "") .. label,
      function() stockView = key; drawStockWindow() end, stockView == key)
  end
  viewBtn(99, 18, "Dashboard", "dashboard")
  viewBtn(118, 18, "Details", "details")
  viewBtn(137, 19, "Portfolio", "portfolio")
  -- header strip
  fill(X0, WY + 6, CW, 1, G.header)
  text(X0 + 1, WY + 6, "≡ BROKERAGE · " .. viewName:upper(), G.accent, G.header)
  local open = marketOpen("SPY")
  textW(X0 + CW - 52, WY + 6, 51, (open and "● MARKET OPEN" or "○ MARKET CLOSED") .. "   " .. fmtTime(now()),
    open and G.good or G.dim, G.header, "right")

  drawStockBody()
  if stockView == "dashboard" then
    for i = 1, CONFIG.STOCK_MAX_TICKERS do
      local x, y = tileXY(i)
      region(stockRegions, x, y, TW, TH, function() selectTicker(i) end)
    end
  elseif stockView == "details" then
    for i = 1, 12 do
      region(stockRegions, X0, LIST_Y + 1 + i, CW, 1, function() selectTicker(i) end)
    end
  end
  drawStockStatus()
end

local function openStock()
  stockOpen = true
  activeApp = "stock"
end
openStockApp = openStock
stockAppOpen = function() return stockOpen end

-- typing into the ticker box
local function stockKey(ch, code)
  if code == 28 or code == 156 then addTicker()
  elseif code == 1 then stockFocus = false; drawInput()
  elseif code == 14 then stockInput = stockInput:sub(1, -2); drawInput()
  elseif ch and ch > 0 then
    local c = string.char(ch):upper()
    if c:match("[%w%.%-%^=]") and #stockInput < 15 then stockInput = stockInput .. c; drawInput() end
  end
end

-- mouse wheel over the portfolio lists
local function stockScroll(x, y, dir)
  if stockView ~= "portfolio" or not pf or x >= TX then return end
  if y > HS_Y and y < OP_Y then V.hScroll = V.hScroll - dir; drawHoldings()
  elseif y > OP_Y and y < AC_Y then V.oScroll = V.oScroll - dir; drawOptions() end
end

return {
  drawWindow = function() drawStockWindow() end,
  drawStatus = drawStockStatus,
  drawInput = function()
    drawInput()
    if activeApp == "stock" and stockView == "portfolio" and not overlay and pf then drawTicketValues() end
  end,
  load = function() loadStocks(); pfLoad(); pvLoad() end,
  reloadAccount = function()
    tk.selOpt, tk.selHold = nil, nil
    if PV.dirty then pvSave() end
    pfLoad(); pvLoad()
  end,
  tick = function() pfTick() end,
  -- the Casino uses the same account
  acct = function() if not pf then pfLoad() end return pf end,
  saveAcct = function() pfSave() end,
  logTrade = function(s) if pf then logTrade(s) end end,
  bankTx = function(a, k, d) if not pf then pfLoad() end bankTx(a, k, d) end,
  -- Prize Wheel: a share added without paying for it (cost basis = price)
  addShares = function(sym, n, price, why)
    if not pf then pfLoad() end
    local h = pf.stocks[sym] or { sh = 0, avg = 0 }
    h.avg = (h.sh * h.avg + n * price) / (h.sh + n)
    h.sh = h.sh + n
    pf.stocks[sym] = h
    logTrade(string.format("PRIZE %d %s @ %s (%s)", n, sym, fmtPrice(price), why or "prize"))
  end,
  price = function(sym) local q = quotes[sym]; return q and q.price end,
  fetch = function(sym) if inet then queueFetch(sym, false, "quote") end end,
  -- what you own (stocks, crypto, forex, options) at the latest prices, biggest first
  holdings = function()
    if not pf then pfLoad() end
    local list, tot = {}, 0
    for s, h in pairs(pf.stocks) do
      local q = quotes[s]
      local live = q and q.price
      local v = h.sh * (live or h.avg)
      list[#list + 1] = { label = s, kind = s:find("%-USD$") and "Crypto" or (s:find("=X$") and "Forex" or "Stock"),
                          qty = commas(h.sh), value = v, live = live ~= nil }
      tot = tot + v
    end
    for _, o in ipairs(pf.options) do
      local q = quotes[o.sym]
      local mid = (q and q.price) and optionMid(o.sym, o.otype, o.K, o.exp, q.price) or o.paid
      local v = mid * CONTRACT * o.qty
      list[#list + 1] = { label = o.sym .. " " .. fmtPrice(o.K) .. (o.otype == "C" and "C" or "P"), kind = "Option",
                          qty = o.qty .. " ct", value = v, live = q ~= nil and q.price ~= nil }
      tot = tot + v
    end
    table.sort(list, function(a, b) return a.value > b.value end)
    return list, tot
  end,
  refreshAll = refreshAll,
  busy = httpBusy,
  pump = pumpHttp,
  scroll = stockScroll,
  save = function() if V.dirty then saveStocks() end; if PV.dirty then pvSave() end end,
  key = function(ch, code) if tk.focus then tkKey(ch, code) else stockKey(ch, code) end end,
  hasTickers = function()
    return #stocks.tickers > 0 or (tk.sym ~= nil) or (pf ~= nil and (next(pf.stocks) ~= nil or #pf.options > 0))
  end,
  hasInternet = function() return inet ~= nil end,
  due = function() return computer.uptime() >= nextRefresh end,
  focus = function(v)
    if v ~= nil then stockFocus = v; if not v then tk.focus, tk.input = false, "" end end
    return stockFocus or tk.focus
  end,
  regions = function() return stockRegions end,
  resetRegions = function() stockRegions = {} end,
}
end)()


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

------------------------------------------------------------------ CASINO
-- Blackjack (alone, or with a friend at the same table) and Let it Ride (a
-- "crash" game). Casino money IS your Brokerage cash: same account, same file.
--
-- Money flow (nothing is ever paid or lost twice):
--   1. you bet: the money leaves your cash and is written to your account file
--      as an unfinished bet, then sent to the house server (houseview.lua)
--   2. the house confirms (BETOK) and keeps it - or refuses (BETNO) and you get
--      it straight back. The cards are only dealt once the house said yes.
--   3. the hand / ride ends: the result + payout is saved, then sent (RESULT)
--   4. the house pays (PAID): the payout lands in your cash and the bet is done
-- Anything unanswered is re-sent every few seconds (also after a restart) and
-- the house ignores repeats, so a lost wireless packet just means a short wait.
CAS = (function()
local C = {
  bg = 0x07090D, bar = 0x0F141B, bar2 = 0x19212C, line = 0x2A3544,
  felt = 0x0D5C3B, felt2 = 0x0A4A30, shade = 0x08402A,
  gold = 0xF2C14E, gold2 = 0xA8832E, text = 0xEEF1F5, dim = 0x8792A2, dark = 0x000000,
  red = 0xF0505A, green = 0x35D07F, blue = 0x4EA8FF, violet = 0xA77BFF, orange = 0xFF9F43,
  card = 0xFBFBF8, cred = 0xD0222D, cblk = 0x16181C, back = 0x8E1630, back2 = 0xC9506B,
  off = 0x1C232D, offT = 0x56606E,
}
local X0, X1 = WX + 1, WX + WW - 2
local CW = X1 - X0 + 1
local HY, FT, FB, BT, BB, SY = WY + 3, WY + 4, WY + 33, WY + 34, WY + 41, WY + WH - 2

-- M: window + UI state (one table = one local)
local M = { tab = "bj", reg = {}, open = false, msg = "Welcome! Place a bet to start.", focus = false, input = "",
            bet = 25, rbet = 10, auto = 0, mode = "solo", players = {}, hist = {}, crashes = {},
            lastFrame = 0, lastRetry = 0, lastAlive = 0, lastHello = 0, sent = false, inv = nil }
local S          -- blackjack table this computer runs (solo or as host)
local GV = nil   -- when seated at someone else's table: { id, host, hostName, view, heard }
local me = { settled = true }   -- my blackjack round: { rid, settled, waiting, guest }
local RD = { phase = "idle" }   -- Let it Ride round
local drawWindow, onBet, onPaid   -- forward
local RLT, PW                     -- Roulette, Prize Wheel (below)

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
local function dollars(n)            -- "$1,250" (or "$12.50" with cents)
  if math.abs(n - floor(n)) < 0.005 then return (n < 0 and "-$" or "$") .. commas(math.abs(n)) end
  return money(n)
end
local function shortMoney(n)
  local a = math.abs(n)
  local f
  if a >= 1e9 then f = string.format("%.2fB", a / 1e9)
  elseif a >= 1e6 then f = string.format("%.2fM", a / 1e6)
  elseif a >= 1e4 then f = string.format("%.1fK", a / 1e3)
  else return money(n) end
  return (n < 0 and "-$" or "$") .. f
end
local function signed(n) return (n > 0 and "+" or "") .. money(n) end
local function visible() return activeApp == "casino" and not overlay and not LOCK.isLocked() end
local function redraw()
  if visible() then drawWindow()
  elseif not overlay and not LOCK.isLocked() then drawTaskbar(now()) end
end
local function say(m) M.msg = m end
local function sayDraw(m) M.msg = m; redraw() end

---------------------------------------------------------------- house link
local DEF = { open = true, min = 1, max = 5000, name = "House",
  bj = { on = true, decks = 6, pays = 1.5, h17 = false, dbl = "any", das = true, hands = 4, rsa = false, pen = 0.75 },
  ride = { on = true, edge = 0.03, cap = 100, speed = 0.115 },
  rl = { on = true, wheel = "american", basket = true },
  pw = { on = true, slots = { "NVDA", 100, 0, 400, 75, "DPZ", 250, 0, 50, 500, "MU", 150, 0, 350, 125, "XOM", 300, 0, 450, 200 } } }
local HS = { addr = nil, rules = nil, heard = nil, wallet = nil }

local function num(v, d, lo, hi)
  v = tonumber(v)
  if not v or v ~= v then return d end
  return max(lo, min(hi, v))
end
local function fixRules(t)
  local b = type(t.bj) == "table" and t.bj or {}
  local r = type(t.ride) == "table" and t.ride or {}
  return { open = t.open ~= false, min = num(t.min, 1, 0.01, 1e12), max = num(t.max, 5000, 0.01, 1e12),
    name = tostring(t.name or "House"):sub(1, 24),
    bj = { on = b.on ~= false, decks = floor(num(b.decks, 6, 1, 8)), pays = num(b.pays, 1.5, 1, 2), h17 = b.h17 == true,
           dbl = (b.dbl == "9-11" or b.dbl == "10-11") and b.dbl or "any", das = b.das ~= false,
           hands = floor(num(b.hands, 4, 1, 4)), rsa = b.rsa == true, pen = num(b.pen, 0.75, 0.5, 0.9) },
    ride = { on = r.on ~= false, edge = num(r.edge, 0.03, 0, 0.5), cap = num(r.cap, 100, 1.01, 1e6),
             speed = num(r.speed, 0.115, 0.02, 1) },
    rl = { on = not (type(t.rl) == "table" and t.rl.on == false), basket = not (type(t.rl) == "table" and t.rl.basket == false),
           wheel = (type(t.rl) == "table" and t.rl.wheel == "european") and "european" or "american" },
    pw = { on = not (type(t.pw) == "table" and t.pw.on == false), slots = (function()
      local sl = type(t.pw) == "table" and t.pw.slots
      if type(sl) ~= "table" or #sl ~= 20 then return DEF.pw.slots end
      local out = {}
      for i = 1, 20 do
        local v = sl[i]
        if type(v) == "string" and v:match("^[%w%.%-=%^]+$") then out[i] = v:upper():sub(1, 12)
        else out[i] = max(0, min(1e9, tonumber(v) or 0)) end
      end
      return out
    end)() } }
end
local function R() return HS.rules or DEF end
local function online() return HS.heard ~= nil and computer.uptime() - HS.heard <= (CONFIG.HOUSE_STALE or 20) end
local function hsend(kind, a, b)
  if HS.addr then pcall(wlan.send, HS.addr, CONFIG.HOUSE_PORT, "HOUSE", kind, a, b) end
end

---------------------------------------------------------------- ledger
-- pf.cas[rid] = { g = game, p = player, n = last seq, bets = { {s, a, k, st} }, res = {p, o, d, st, tot}, void }
-- bet st: "w" = waiting for the house, "ok" = the house has it. Saved in the
-- Brokerage account file together with the cash, so both change in one write.
local function ledger()
  local pf = ST.acct()
  pf.cas = pf.cas or {}
  return pf.cas, pf
end
local function newRid(tag)
  return tag .. wlan.address:sub(1, 4) .. string.format("%x%03x", floor(now()), math.random(0, 4095))
end
local function sendBet(rid, r, b)
  hsend("BET", serialization.serialize({ r = rid, s = b.s, a = b.a, g = r.g, k = b.k, p = r.p, x = b.x }))
end
local function sendRes(rid, r)
  hsend("RESULT", serialization.serialize({ r = rid, p = r.res.p, g = r.g, o = r.res.o, d = r.res.d, pl = r.p }))
end
local function accepted(r)
  local tot, wait = 0, false
  for _, b in ipairs(r.bets) do
    if b.st == "ok" then tot = tot + b.a elseif b.st == "w" then wait = true end
  end
  return cents(tot), wait
end
-- money on its way: bets the house hasn't confirmed + bets in play + payouts not received yet
local function inPlay()
  local L = ledger()
  local n, out = 0, 0
  for _, r in pairs(L) do
    for _, b in ipairs(r.bets) do n = n + b.a end
    if r.res then out = out + r.res.p end
  end
  return n, out
end

local function placeBet(rid, game, amt, kind, maxPay)   -- maxPay: most it could win (roulette)
  local L, pf = ledger()
  amt = cents(amt or 0)
  if amt <= 0 then return nil, "Choose a bet first (click the chips)." end
  if not online() then return nil, "The house server is offline - bets can't be placed right now." end
  local rl = R()
  if kind == "main" then
    if not rl.open then return nil, "The casino is closed by the house." end
    if amt < rl.min - 1e-9 or amt > rl.max + 1e-9 then
      return nil, "Table limits are " .. dollars(rl.min) .. " to " .. dollars(rl.max) .. "."
    end
  end
  if amt > pf.cash + 1e-6 then return nil, "Not enough in your savings account: you have " .. money(pf.cash) .. "." end
  local r = L[rid]
  if not r then r = { g = game, p = PLAYER_NAME, n = 0, bets = {} }; L[rid] = r end
  r.n = r.n + 1
  local b = { s = r.n, a = amt, k = kind, st = "w", x = maxPay }
  r.bets[#r.bets + 1] = b
  ST.bankTx(-amt, "CASINO", (game == "bj" and "Blackjack" or "Let it Ride") .. (kind == "main" and " bet" or (" " .. kind)))
  pf.deposits = pf.deposits - amt
  ST.saveAcct()
  sendBet(rid, r, b)
  return b.s
end

-- bet status: "w", "ok" or nil (refused / unknown)
local function betState(rid, seq)
  local r = ledger()[rid]
  if not r then return nil end
  for _, b in ipairs(r.bets) do if b.s == seq then return b.st end end
end

local function betAnswer(rid, seq, ok, why)
  local L, pf = ledger()
  local r = L[rid]
  if not r then return end
  for i, b in ipairs(r.bets) do
    if b.s == seq then
      if b.st ~= "w" then return end              -- repeat answer: already handled
      if ok then
        b.st = "ok"
      else
        table.remove(r.bets, i)
        ST.bankTx(b.a, "CASINO", "Bet returned by the house")   -- refused: straight back
        pf.deposits = pf.deposits + b.a
        if #r.bets == 0 and not r.res then L[rid] = nil end
      end
      ST.saveAcct()
      if onBet then onBet(rid, seq, ok, why, b) end
      return
    end
  end
end

-- the round is over: record what the house owes and send it. payout "void" = all bets back
local function settle(rid, payout, outcome, detail)
  local L = ledger()
  local r = L[rid]
  if not r or r.res then return false end
  local tot, wait = accepted(r)
  if wait then r.void = r.void or outcome; ST.saveAcct(); return false end
  if tot <= 0 then L[rid] = nil; ST.saveAcct(); return false end
  if payout == "void" then payout = tot end
  r.res = { p = cents(max(0, payout)), o = tostring(outcome or ""):sub(1, 60), d = tostring(detail or ""):sub(1, 80), st = "w", tot = tot }
  r.void = nil
  ST.saveAcct()
  sendRes(rid, r)
  return true
end

local function paid(rid, amt)
  local L, pf = ledger()
  local r = L[rid]
  if not r or not r.res or r.res.st ~= "w" then return end   -- unknown or already paid
  amt = cents(tonumber(amt) or 0)
  if amt > 0 then
    ST.bankTx(amt, "CASINO", (r.g == "bj" and "Blackjack " or "Let it Ride ") .. tostring(r.res.o):lower():gsub("^%l", string.upper))
  end
  pf.deposits = pf.deposits + amt
  L[rid] = nil
  ST.logTrade(string.format("CASINO %s %s: bet %s, paid %s", r.g == "bj" and "Blackjack" or "Let it Ride",
    r.res.o, money(r.res.tot), money(amt)))
  ST.saveAcct()
  table.insert(M.hist, 1, { t = now(), g = r.g, bet = r.res.tot, pay = amt, o = r.res.o })
  while #M.hist > 14 do table.remove(M.hist) end
  if onPaid then onPaid(rid, amt, r) end
end

-- re-send everything unanswered; finish rounds that were cut short
local function retry()
  if not HS.addr then return end
  local L = ledger()
  for rid, r in pairs(L) do
    local wait = false
    for _, b in ipairs(r.bets) do
      if b.st == "w" then sendBet(rid, r, b); wait = true end
    end
    if r.res and r.res.st == "w" then sendRes(rid, r)
    elseif r.void and not wait and not r.res then settle(rid, "void", "VOID - " .. tostring(r.void), "") end
  end
  if PW then PW.retry() end
end

local function onHouse(from, kind, a, b, c)
  if CONFIG.HOUSE_ADDR and from:sub(1, #CONFIG.HOUSE_ADDR) ~= CONFIG.HOUSE_ADDR then return end
  if kind == "RULES" then
    local ok, t = pcall(serialization.unserialize, a)
    if ok and type(t) == "table" then
      local was = online()
      HS.addr, HS.heard, HS.rules, HS.wallet = from, computer.uptime(), fixRules(t), tonumber(t.wallet)
      if not was then retry(); redraw() end
    end
  elseif HS.addr and from ~= HS.addr then
    return
  elseif kind == "BETOK" then betAnswer(a, tonumber(b), true)
  elseif kind == "BETNO" then betAnswer(a, tonumber(b), false, c)
  elseif kind == "PAID" then paid(a, b); redraw()
  elseif kind == "PRIZEOK" or kind == "GRANTS" then PW.onHouse(kind, a)
  end
end

---------------------------------------------------------------- save / load
local function casPath()
  local safe = tostring(PLAYER_NAME):gsub("[^%w%-_]", "_")
  return (CONFIG.CASINO_FILE or "/home/lymanos_casino_%s.dat"):gsub("%%s", safe)
end
local function saveCas()
  local hostT = S
  writeFile(casPath(), serialization.serialize({ S = hostT, me = me, rd = RD, hist = M.hist, crashes = M.crashes,
    bet = M.bet, rbet = M.rbet, auto = M.auto, rl = RLT and RLT.state(), pw = PW and PW.state() }))
end

---------------------------------------------------------------- blackjack engine
local SUIT = { S = "♠", H = "♥", D = "♦", C = "♣" }
local RANKS = "A23456789TJQK"
local function rankOf(c) local r = c:sub(1, 1); return r == "T" and "10" or r end
local function cval(c)
  local r = c:sub(1, 1)
  if r == "A" then return 11 end
  if r == "T" or r == "J" or r == "Q" or r == "K" then return 10 end
  return tonumber(r) or 0
end
local function total(cards)
  local t, aces = 0, 0
  for _, c in ipairs(cards) do
    if c ~= "??" then
      local v = cval(c)
      t = t + v
      if v == 11 then aces = aces + 1 end
    end
  end
  while t > 21 and aces > 0 do t, aces = t - 10, aces - 1 end
  return t, aces > 0
end
local function isBJ(h) return #h.c == 2 and not h.split and (total(h.c)) == 21 end
local function newShoe(decks)
  local t = {}
  for _ = 1, decks do
    for s = 1, 4 do for r = 1, 13 do t[#t + 1] = RANKS:sub(r, r) .. ("SHDC"):sub(s, s) end end
  end
  for i = #t, 2, -1 do local j = math.random(1, i); t[i], t[j] = t[j], t[i] end
  return table.concat(t)
end
local function draw(T)
  if T.pos > #T.shoe then T.shoe, T.pos = newShoe(T.rules.decks), 1 end
  local c = T.shoe:sub(T.pos, T.pos + 1)
  T.pos = T.pos + 2
  return c
end
-- result + money back for one hand (bet included)
local function handPay(h, d, rules)
  local t, dt = total(h.c), total(d.c)
  local dbj = #d.c == 2 and dt == 21
  if t > 21 then return "BUST", 0 end
  if isBJ(h) and not dbj then return "BLACKJACK", cents(h.bet * (1 + rules.pays)) end
  if dbj then return isBJ(h) and "PUSH" or "LOSE", isBJ(h) and h.bet or 0 end
  if dt > 21 or t > dt then return "WIN", h.bet * 2 end
  if t == dt then return "PUSH", h.bet end
  return "LOSE", 0
end
local function canDouble(T, h)
  if not h or #h.c ~= 2 or h.done or h.dbl or h.aces then return false end
  if h.split and not T.rules.das then return false end
  local t = total(h.c)
  if T.rules.dbl == "9-11" then return t >= 9 and t <= 11 end
  if T.rules.dbl == "10-11" then return t == 10 or t == 11 end
  return true
end
local function canSplit(T, s, h)
  if not h or #h.c ~= 2 or h.done or h.dbl then return false end
  if cval(h.c[1]) ~= cval(h.c[2]) or #s.hands >= T.rules.hands then return false end
  if h.aces and not T.rules.rsa then return false end
  return true
end
local function snapRules()
  local b = R().bj
  return { decks = b.decks, pays = b.pays, h17 = b.h17, dbl = b.dbl, das = b.das, hands = b.hands, rsa = b.rsa, pen = b.pen }
end
local function newTable()
  local rl = snapRules()
  return { id = nil, phase = "bet", rules = rl, shoe = newShoe(rl.decks), pos = 1, round = 1, q = {}, at = 0,
           seats = { { name = PLAYER_NAME, hands = {}, ready = false, bet = 0 } }, dealer = { c = {}, hole = false } }
end
local function resetRound(T)
  local rl = snapRules()
  if rl.decks ~= T.rules.decks or T.pos > #T.shoe * T.rules.pen then
    T.shoe, T.pos, T.msg = newShoe(rl.decks), 1, "New shoe shuffled."
  else T.msg = nil end
  T.rules = rl
  T.phase, T.dealer, T.turn, T.q, T.waitSince = "bet", { c = {}, hole = false }, nil, {}, nil
  for _, s in ipairs(T.seats) do s.hands, s.ready, s.bet = {}, false, 0 end
  T.seats[1].name = PLAYER_NAME
  T.round = (T.round or 0) + 1
end
local function push(T, st) T.q[#T.q + 1] = st end
local function allHands(T, fn)
  for si, s in ipairs(T.seats) do for hi, h in ipairs(s.hands) do fn(si, hi, s, h) end end
end
local function startDeal(T)
  T.phase, T.q, T.msg = "deal", {}, nil
  local list = {}
  for i, s in ipairs(T.seats) do
    if s.ready then s.hands = { { c = {}, bet = s.bet } }; list[#list + 1] = i else s.hands = {} end
  end
  for _, i in ipairs(list) do push(T, { "c", i, 1 }) end
  push(T, { "d" })
  for _, i in ipairs(list) do push(T, { "c", i, 1 }) end
  push(T, { "h" })
  push(T, { "peek" })
  T.at = 0
end
local function exec(T, st)
  local k = st[1]
  if k == "c" then
    local s = T.seats[st[2]]
    local h = s and s.hands[st[3]]
    if h then
      local card = draw(T)
      h.c[#h.c + 1] = card
      if T.phase == "play" then
        local t = total(h.c)
        if t > 21 then h.done = true
        elseif t == 21 then h.done = true
        elseif h.dbl and #h.c >= 3 then h.done = true
        elseif h.aces and #h.c >= 2 and not (cval(card) == 11 and T.rules.rsa and #s.hands < T.rules.hands) then h.done = true end
      end
    end
  elseif k == "d" then
    T.dealer.c[#T.dealer.c + 1] = draw(T)
  elseif k == "h" then
    T.dealer.c[#T.dealer.c + 1] = draw(T)
    T.dealer.hole = true
  elseif k == "peek" then
    if total(T.dealer.c) == 21 then        -- dealer blackjack (only possible with an A or 10 showing)
      T.dealer.hole = false
      allHands(T, function(_, _, _, h) h.done = true end)
      T.msg = "Dealer has Blackjack."
      push(T, { "fin" })
    else
      allHands(T, function(_, _, _, h) if isBJ(h) then h.done = true end end)
      T.phase = "play"
      push(T, { "next" })
    end
  elseif k == "next" then
    T.turn = nil
    for si, s in ipairs(T.seats) do
      for hi, h in ipairs(s.hands) do
        if not h.done then
          if #h.c < 2 then push(T, { "c", si, hi }); push(T, { "next" }); return end
          T.turn, T.turnAt = { si, hi }, computer.uptime()
          return
        end
      end
    end
    push(T, { "rev" })
  elseif k == "rev" then
    T.dealer.hole, T.phase = false, "dealer"
    local need = false
    allHands(T, function(_, _, _, h) if total(h.c) <= 21 and not isBJ(h) then need = true end end)
    push(T, need and { "dl" } or { "fin" })
  elseif k == "dl" then
    local t, soft = total(T.dealer.c)
    if t < 17 or (t == 17 and soft and T.rules.h17) then
      T.dealer.c[#T.dealer.c + 1] = draw(T)
      push(T, { "dl" })
    else push(T, { "fin" }) end
  elseif k == "fin" then
    T.phase, T.turn = "done", nil
    allHands(T, function(_, _, _, h) h.r, h.pay = handPay(h, T.dealer, T.rules) end)
  end
end
local DELAY = { c = 0.45, d = 0.45, h = 0.45, dl = 0.7, rev = 0.6, peek = 0.15, next = 0.05, fin = 0.05 }

-- a player action on the table this computer runs. false = not allowed now
local function act(T, si, hi, a)
  if T.phase ~= "play" or not T.turn or T.turn[1] ~= si or T.turn[2] ~= hi or #T.q > 0 then return false end
  local s = T.seats[si]
  local h = s and s.hands[hi]
  if not h then return false end
  if a == "hit" then
    push(T, { "c", si, hi })
  elseif a == "stand" then
    h.done = true
  elseif a == "double" then
    if not canDouble(T, h) then return false end
    h.bet, h.dbl = h.bet * 2, true
    push(T, { "c", si, hi })
  elseif a == "split" then
    if not canSplit(T, s, h) then return false end
    local c2 = table.remove(h.c, 2)
    h.split, h.aces = true, cval(h.c[1]) == 11
    table.insert(s.hands, hi + 1, { c = { c2 }, bet = h.bet, split = true, aces = cval(c2) == 11 })
    push(T, { "c", si, hi })
    push(T, { "c", si, hi + 1 })
  else return false end
  T.turn = nil
  push(T, { "next" })
  T.at = 0
  return true
end

-- what one seat gets back: payout, money on its hands, short outcome, cards
local function seatResult(T, si)
  local s = T.seats[si]
  local pay, bets, words, cards = 0, 0, {}, {}
  for _, h in ipairs(s.hands) do
    local r, p = handPay(h, T.dealer, T.rules)
    pay, bets = pay + p, bets + h.bet
    words[#words + 1] = r .. (h.dbl and "(x2)" or "")
    local cs = {}
    for _, c in ipairs(h.c) do cs[#cs + 1] = rankOf(c) end
    cards[#cards + 1] = table.concat(cs, " ") .. "=" .. total(h.c)
  end
  local dc = {}
  for _, c in ipairs(T.dealer.c) do dc[#dc + 1] = rankOf(c) end
  return cents(pay), cents(bets), table.concat(words, ","),
         "You " .. table.concat(cards, " / ") .. "  Dealer " .. table.concat(dc, " ") .. "=" .. total(T.dealer.c)
end

-- the hand is over for me: pay what the table says (checked against what the house accepted)
local function settleMine(T, si)
  if not me.rid or me.settled then return end
  local r = ledger()[me.rid]
  me.settled = true
  if not r then saveCas(); return end
  local pay, bets, o, d = seatResult(T, si)
  local acc = accepted(r)
  if bets > acc + 0.005 then pay, o = "void", "VOID (bet mismatch)"
  elseif acc > bets + 0.005 then pay = pay + (acc - bets) end   -- a bet the table never used: back to you
  settle(me.rid, pay, o, d)
  if pay ~= "void" then
    local net = pay - acc
    M.msg = (net > 0 and ("You win " .. money(net) .. "!")) or (net < 0 and ("You lose " .. money(-net) .. ".")) or "Push - your bet comes back."
  end
  saveCas()
end

---------------------------------------------------------------- table network (port CASINO_PORT, "BJ")
local function tsend(to, kind, a, b, c) pcall(wlan.send, to, CONFIG.CASINO_PORT, "BJ", kind, a, b, c) end
local function tableView(T)
  local v = { id = T.id, phase = T.phase, rules = T.rules, turn = T.turn, msg = T.msg, round = T.round, seats = {},
              dealer = { hole = T.dealer.hole, c = {} } }
  for i, c in ipairs(T.dealer.c) do v.dealer.c[i] = (T.dealer.hole and i == 2) and "??" or c end
  for i, s in ipairs(T.seats) do
    v.seats[i] = { name = s.name, ready = s.ready, bet = s.bet, hands = s.hands }
  end
  return v
end
local function sendState()
  local g = S and S.seats[2]
  if g and g.addr then tsend(g.addr, "STATE", S.id, serialization.serialize(tableView(S))) end
end

-- after every change to the table this computer runs
local function changed()
  if S.phase == "done" and not me.guest then settleMine(S, 1) end
  saveCas()
  sendState()
  redraw()
end

local function maybeDeal(force)
  if S.phase ~= "bet" then return end
  local any, all = false, true
  for _, s in ipairs(S.seats) do if s.ready then any = true else all = false end end
  if any and (all or force) then startDeal(S); S.waitSince = nil
  elseif any then S.waitSince = S.waitSince or computer.uptime() end   -- deals by itself after 45 s
end

local function removeGuest(why)
  local g = S.seats[2]
  if not g then return end
  if S.phase == "bet" or S.phase == "done" or #g.hands == 0 then
    table.remove(S.seats, 2)
    if S.phase == "bet" then maybeDeal() end
  else
    for _, h in ipairs(g.hands) do h.done = true end   -- their hands stand; removed after the round
    g.gone = true
    if S.turn and S.turn[1] == 2 then S.turn = nil; push(S, { "next" }) end
  end
  M.msg = (g.name or "Your friend") .. " " .. (why or "left the table") .. "."
end

-- guest: the host said no to my bet (round already running) -> money back
local function onRdyNo(from, a)
  if GV and GV.id == a and from == GV.host and me.rid and not me.settled then
    me.settled = true
    settle(me.rid, "void", "VOID (not dealt in)", "")
    saveCas()
    sayDraw("The round had already started - your bet goes back to you.")
  end
end

local function onTable(from, dist, kind, a, b, c)
  local up = computer.uptime()
  if kind == "HELLO" then
    M.players[from] = { name = tostring(a or "?"), dist = dist or 0, at = up }
    tsend(from, "HERE", PLAYER_NAME)
    if visible() and M.mode == "multi" then drawWindow() end
  elseif kind == "HERE" then
    M.players[from] = { name = tostring(a or "?"), dist = dist or 0, at = up }
    if visible() then drawWindow() end
  elseif kind == "INVITE" then
    local busy = GV or (me.rid and not me.settled) or (S.seats[2] ~= nil) or S.phase ~= "bet" and S.phase ~= "done"
    if busy then tsend(from, "NOPE", a, "busy"); return end
    local name = tostring(b or "?")
    showOrQueue(function()
      dialog("Blackjack Invite", { name .. " (" .. floor((dist or 0) + 0.5) .. " blocks away) invites you to their",
        "blackjack table. You play against the same dealer; your money", "stays in your own account. Join?" }, {
        { "Join", function()
            if GV or (me.rid and not me.settled) then tsend(from, "NOPE", a, "busy"); return end
            GV = { id = a, host = from, hostName = name, view = nil, heard = computer.uptime() }
            M.mode, M.tab, M.open = "guest", "bj", true
            activeApp = "casino"
            tsend(from, "JOIN", a, PLAYER_NAME)
            M.msg = "Joined " .. name .. "'s table."
          end },
        { "No thanks", function() tsend(from, "NOPE", a, "declined") end },
      })
    end)
  elseif kind == "JOIN" then
    local inv = M.inv
    if inv and inv.id == a and inv.addr == from and not S.seats[2] then
      S.id = a
      S.seats[2] = { name = tostring(b or inv.name), addr = from, hands = {}, ready = false, bet = 0, heard = up }
      M.inv, M.mode = nil, "multi"
      M.msg = S.seats[2].name .. " joined your table."
      changed()
    end
  elseif kind == "NOPE" then
    if M.inv and M.inv.id == a then
      sayDraw((M.inv.name or "They") .. (b == "busy" and " is busy right now." or " declined."))
      M.inv = nil
    end
  elseif kind == "STATE" then
    if GV and GV.id == a and from == GV.host then
      local ok, v = pcall(serialization.unserialize, b)
      if ok and type(v) == "table" then
        GV.view, GV.heard, M.sent = v, up, false
        if v.phase == "done" and me.guest and me.rid and not me.settled then settleMine(v, 2) end
        saveCas()
        redraw()
      end
    end
  elseif kind == "RDYNO" then
    onRdyNo(from, a)
  elseif kind == "LEAVE" then
    if GV and GV.id == a and from == GV.host then
      if me.rid and not me.settled then
        me.settled = true
        settle(me.rid, "void", "VOID (host closed the table)", "")
      end
      GV, M.mode = nil, "solo"
      sayDraw("The host closed the table.")
    elseif S.seats[2] and S.seats[2].addr == from then
      removeGuest("left the table"); changed()
    end
  else
    -- guest -> host messages
    local g = S.seats[2]
    if not g or g.addr ~= from or a ~= S.id then return end
    g.heard = up
    if kind == "READY" then
      if g.ready then return end
      if S.phase == "done" then resetRound(S) end
      local amt = tonumber(b) or 0
      if S.phase ~= "bet" or amt <= 0 then tsend(from, "RDYNO", S.id); return end
      g.ready, g.bet = true, amt
      maybeDeal()
      changed()
    elseif kind == "ACT" then
      if act(S, 2, tonumber(b) or 0, c) then changed() else sendState() end
    end
  end
end

---------------------------------------------------------------- blackjack actions (buttons)
local function myView()        -- the table I'm looking at, and my seat in it
  if GV then return GV.view, 2 end
  return S, 1
end
local function inRound() return me.rid ~= nil and not me.settled end

local function deal()
  local T = myView()
  if inRound() then return sayDraw("Finish this hand first.") end
  if not R().bj.on then return sayDraw("Blackjack is closed by the house right now.") end
  if not GV then
    if S.phase == "done" then resetRound(S) end
    if S.phase ~= "bet" then return sayDraw("Wait for the current hand to finish.") end
  elseif T and T.phase ~= "bet" and T.phase ~= "done" then
    return sayDraw("Wait for the current hand to finish.")
  end
  local rid = newRid("B")
  local seq, why = placeBet(rid, "bj", M.bet, "main")
  if not seq then return sayDraw(why) end
  me = { rid = rid, settled = false, guest = GV and true or nil, waiting = { a = "main", seq = seq, amt = cents(M.bet) } }
  M.msg = "Bet " .. money(M.bet) .. " sent to the house..."
  saveCas()
  redraw()
end

local function myAction(a)
  local T, si = myView()
  if not T or not T.turn or T.turn[1] ~= si or T.phase ~= "play" or M.sent or me.waiting then return end
  local hi = T.turn[2]
  local seat = T.seats[si]
  local h = seat.hands[hi]
  if a == "double" or a == "split" then
    if (a == "double" and not canDouble(T, h)) or (a == "split" and not canSplit(T, seat, h)) then return end
    local seq, why = placeBet(me.rid, "bj", h.bet, a)
    if not seq then return sayDraw(why) end
    me.waiting = { a = a, seq = seq, hand = hi }
    M.msg = (a == "double" and "Doubling" or "Splitting") .. " - extra " .. money(h.bet) .. " sent to the house..."
    saveCas()
    return redraw()
  end
  if GV then
    tsend(GV.host, "ACT", GV.id, hi, a)
    M.sent = true
    redraw()
  elseif act(S, 1, hi, a) then changed() end
end

local function dealNow()
  if GV or S.phase ~= "bet" then return end
  maybeDeal(true)
  changed()
end

local function bjBet(rid, seq, ok, why)
  if me.rid ~= rid or not me.waiting or me.waiting.seq ~= seq then return end
  local w = me.waiting
  me.waiting = nil
  if not ok then
    if w.a == "main" then me = { settled = true } end
    M.msg = "The house refused the bet: " .. tostring(why or "no reason given")
    saveCas()
    return redraw()
  end
  if w.a == "main" then
    M.msg = "Bet accepted - good luck!"
    if GV then tsend(GV.host, "READY", GV.id, w.amt); M.sent = true
    else
      local s = S.seats[1]
      s.ready, s.bet = true, w.amt
      maybeDeal()
    end
  else
    if GV then tsend(GV.host, "ACT", GV.id, w.hand, w.a); M.sent = true
    elseif not act(S, 1, w.hand, w.a) then
      settle(me.rid, "void", "VOID", "")   -- can't happen; never keep a bet the table didn't use
    end
  end
  if GV then saveCas(); redraw() else changed() end
end

local function findPlayers()
  M.players = {}
  pcall(wlan.broadcast, CONFIG.CASINO_PORT, "BJ", "HELLO", PLAYER_NAME)
  sayDraw("Looking for players in range...")
end
local function invite(addr, p)
  if S.seats[2] or GV then return end
  local id = newRid("T")
  M.inv = { id = id, addr = addr, name = p.name }
  tsend(addr, "INVITE", id, PLAYER_NAME)
  sayDraw("Invite sent to " .. p.name .. "...")
end
local function leaveTable()
  if GV then
    if inRound() then
      local alive = computer.uptime() - (GV.heard or 0) < 60
      local v = GV.view
      local dealt = v and v.seats[2] and #v.seats[2].hands > 0 and v.phase ~= "bet"
      me.settled = true
      if alive and dealt and not me.waiting then settle(me.rid, 0, "FORFEIT (left mid-hand)", "")
      else settle(me.rid, "void", "VOID (left before the deal)", "") end
    end
    tsend(GV.host, "LEAVE", GV.id)
    GV, M.mode = nil, "solo"
    M.msg = "You left the table."
  elseif S.seats[2] then
    if S.phase ~= "bet" and S.phase ~= "done" then return sayDraw("Finish the hand before closing the table.") end
    tsend(S.seats[2].addr, "LEAVE", S.id)
    table.remove(S.seats, 2)
    M.mode = "multi"
    M.msg = "Table closed."
  end
  saveCas()
  redraw()
end
local function setMode(m)
  if GV or S.seats[2] then return sayDraw("Leave the table first.") end
  M.mode = m
  if m == "multi" then findPlayers() else M.inv = nil; redraw() end
end

---------------------------------------------------------------- let it ride
local function rideMult(t) return math.exp((RD.speed or 0.115) * max(0, t)) end
local function genCrash(edge, cap)
  local u = math.random()
  local c = floor((1 - edge) / (1 - u) * 100) / 100     -- P(reach x) = (1 - edge) / x
  if c < 1 then c = 1 end            -- 1.00x = instant bust (edge + ~1% of rounds)
  return min(c, cap)
end
local function rideBusy() return RD.phase == "betting" or RD.phase == "count" or RD.phase == "fly" end
local function launch()
  if rideBusy() then return end
  if not R().ride.on then return sayDraw("Let it Ride is closed by the house right now.") end
  local rid = newRid("R")
  local seq, why = placeBet(rid, "ride", M.rbet, "main")
  if not seq then return sayDraw(why) end
  RD = { phase = "betting", rid = rid, seq = seq, bet = cents(M.rbet), auto = (M.auto or 0) > 0 and M.auto or nil }
  M.msg = "Bet " .. money(RD.bet) .. " sent to the house..."
  saveCas()
  redraw()
end
local function rideBet(rid, seq, ok, why)
  if RD.rid ~= rid or RD.phase ~= "betting" then return end
  if not ok then
    RD = { phase = "idle" }
    M.msg = "The house refused the bet: " .. tostring(why or "no reason given")
    saveCas()
    return redraw()
  end
  local rr = R().ride
  RD.edge, RD.cap, RD.speed = rr.edge, rr.cap, rr.speed
  RD.crash = genCrash(rr.edge, rr.cap)
  RD.phase, RD.t0, RD.real0 = "count", computer.uptime() + 3, now() + 3
  M.msg = "Bet accepted - launching!"
  saveCas()
  redraw()
end
local function rideEnd()
  table.insert(M.crashes, 1, RD.crash)
  while #M.crashes > 24 do table.remove(M.crashes) end
end
local function cashOut(target)
  if RD.phase ~= "fly" or RD.out then return end
  local m = target or floor(rideMult(computer.uptime() - RD.t0) * 100) / 100
  if m > RD.crash or (not target and m >= RD.crash) then return end   -- too late
  RD.out, RD.win = m, cents(RD.bet * m)
  settle(RD.rid, RD.win, string.format("CASHED OUT %.2fx", m), string.format("crashed at %.2fx", RD.crash))
  M.msg = string.format("Cashed out at %.2fx: %s (%s)", m, money(RD.win), signed(RD.win - RD.bet))
  saveCas()
end
local function crashNow()
  RD.phase = "crashed"
  if not RD.out then
    settle(RD.rid, 0, string.format("CRASHED %.2fx", RD.crash), "no cash out")
    M.msg = string.format("Crashed at %.2fx - the house keeps %s.", RD.crash, money(RD.bet))
  end
  rideEnd()
  saveCas()
  redraw()
end
local function rideButton()
  if RD.phase == "fly" then if not RD.out then cashOut(); redraw() end
  elseif not rideBusy() then launch() end
end

---------------------------------------------------------------- big digits (5x7, for the multiplier)
local FONT = {
  ["0"] = "01110100011001110101110011000101110", ["1"] = "00100011000010000100001000010001110",
  ["2"] = "01110100010000100010001000100011111", ["3"] = "11110000010000101110000010000111110",
  ["4"] = "00010001100101010010111110001000010", ["5"] = "11111100001111000001000011000101110",
  ["6"] = "00110010001000011110100011000101110", ["7"] = "11111000010001000100010000100001000",
  ["8"] = "01110100011000101110100011000101110", ["9"] = "01110100011000101111000010001001100",
  ["x"] = "00000000001000101010001000101010001", ["."] = "00000000001111",
  ["$"] = "00100011111010001110001011111000100", ["-"] = "00000000000000011111000000000000000",
}
local function glyphW(ch) local g = FONT[ch]; return g and floor(#g / 7) or 3 end
local function bigWidth(s, sx)
  local w = 0
  for i = 1, #s do w = w + (glyphW(s:sub(i, i)) + 1) * sx end
  return w - sx
end
local function bigDraw(cv, s, x0, y0, sx, sy, col)
  local x = x0
  for i = 1, #s do
    local ch = s:sub(i, i)
    local g, gw = FONT[ch], glyphW(ch)
    if g then
      for r = 0, 6 do
        for c = 1, gw do
          if g:sub(r * gw + c, r * gw + c) == "1" then
            for yy = 0, sy - 1 do for xx = 0, sx - 1 do cset(cv, x + (c - 1) * sx + xx, y0 + r * sy + yy, col) end end
          end
        end
      end
    end
    x = x + (gw + 1) * sx
  end
end

---------------------------------------------------------------- drawing kit
local CHIPS = { { 1, 0xE6E6E6, C.dark, "1" }, { 5, 0xD8323B, C.text, "5" }, { 25, 0x2E9E5B, C.text, "25" },
                { 100, 0x2B2B2B, C.text, "100" }, { 500, 0x7B3FB5, C.text, "500" }, { 1000, 0xD9A520, C.dark, "1K" } }
local AUTO = { 0, 1.1, 1.25, 1.5, 2, 3, 5, 10, 25, 50, 100 }
local MX, MW = X0 + 46, 56               -- middle block of the bottom bar
local RX = X0 + 104                       -- right block
local RW = X1 - RX + 1

local function chipColor(v)
  local col = CHIPS[1][2]
  for _, ch in ipairs(CHIPS) do if v >= ch[1] then col = ch[2] end end
  return col
end
local function centerText(cx, y, s, f, b) text(cx - floor(unicode.len(s) / 2), y, s, f, b) end
local function bigBtn(x, y, w, label, col, fn, dis)
  local b = dis and C.off or col
  fill(x, y, w, 3, b)
  text(x, y, string.rep("▀", w), lerp(b, 0xFFFFFF, dis and 0.04 or 0.25), b)
  textW(x, y + 1, w, label, dis and C.offT or ((col == C.gold or col == C.green) and C.dark or C.text), b, "center")
  text(x, y + 2, string.rep("▄", w), lerp(b, 0x000000, 0.35), b)
  if fn and not dis then region(M.reg, x, y, w, 3, fn) end
end
local function smallBtn(x, y, s, fn, dis)
  text(x, y, s, dis and C.offT or C.text, dis and C.off or C.line)
  if fn and not dis then region(M.reg, x, y, unicode.len(s), 1, fn) end
  return x + unicode.len(s) + 1
end
local function kvRow(x, y, w, k, v, col, b)
  b = b or C.bar
  textW(x, y, w, k, C.dim, b)
  textW(x + 14, y, w - 14, v, col or C.text, b, "right")
end
local function payText(p)
  for _, it in ipairs({ { 1.5, "3 TO 2" }, { 1.2, "6 TO 5" }, { 2, "2 TO 1" }, { 1, "1 TO 1" } }) do
    if math.abs(p - it[1]) < 1e-6 then return it[2] end
  end
  return string.format("%.2f TO 1", p)
end
local function spaced(s) return (s:gsub(".", "%0 "):sub(1, -2)) end
local function betVal() return M.tab == "bj" and M.bet or M.rbet end
local function setBet(v)
  v = max(0, floor(v * 100 + 0.5) / 100)
  if M.tab == "bj" then M.bet = v else M.rbet = v end
  saveCas()
end

---------------------------------------------------------------- header + status
local function drawHeader(reg)
  fill(X0, HY, CW, 1, C.bar)
  text(X0 + 1, HY, "♠", C.text, C.bar); text(X0 + 2, HY, "♥", C.red, C.bar)
  text(X0 + 3, HY, "♣", C.text, C.bar); text(X0 + 4, HY, "♦", C.red, C.bar)
  text(X0 + 6, HY, "LYMANOS CASINO", C.gold, C.bar)
  local x = X0 + 23
  for _, t in ipairs({ { "bj", " ♠ BLACKJACK " }, { "ride", " ▲ LET IT RIDE " }, { "rl", " ◎ ROULETTE " }, { "pw", " ★ PRIZE WHEEL " } }) do
    local on = M.tab == t[1]
    text(x, HY, t[2], on and C.dark or C.dim, on and C.gold or C.bar2)
    if reg then region(M.reg, x, HY, unicode.len(t[2]), 1, function() M.tab, M.focus = t[1], false; drawWindow() end) end
    x = x + unicode.len(t[2]) + 1
  end
  local bal = " " .. money(ST.acct().cash) .. " "
  local bx = X1 - unicode.len(bal) + 1
  text(bx, HY, bal, C.dark, C.gold)
  text(bx - 9, HY, " SAVINGS ", C.gold, C.bar2)
  local hs = online() and ("● " .. R().name .. (R().open and " · OPEN" or " · CLOSED")) or "○ HOUSE OFFLINE"
  textW(bx - 36, HY, 26, hs, online() and (R().open and C.green or C.orange) or C.red, C.bar, "right")
end

local function drawStatus()
  fill(WX + 1, SY, WW - 2, 1, K.face)
  textW(WX + 2, SY, 76, M.msg or "", K.black, K.face)
  text(WX + 79, SY, "│", K.sh, K.face)
  textW(WX + 80, SY, 26, "Player: " .. tostring(PLAYER_NAME), K.black, K.face)
  text(WX + 107, SY, "│", K.sh, K.face)
  local n, out = inPlay()
  textW(WX + 108, SY, 34, (n > 0 or out > 0) and ("In play " .. money(n) .. (out > 0 and (", due " .. money(out)) or ""))
    or ("Ports " .. CONFIG.CASINO_PORT .. "/" .. CONFIG.HOUSE_PORT), K.black, K.face)
end

---------------------------------------------------------------- blackjack table
local function drawCard(x, y, c, first)
  local F = C.felt
  text(x, y, first and "▗▄▄▄▄▄▖" or "▄▄▄▄▄▄▖", C.card, F)
  if c == "??" then
    for r = 1, 5 do
      text(x, y + r, " ", C.card, C.card)
      text(x + 1, y + r, (r % 2 == 1) and "▚▞▚▞▚" or "▞▚▞▚▞", C.back2, C.back)
      text(x + 6, y + r, " ", C.card, C.card)
    end
  else
    local sc = c:sub(2, 2)
    local col = (sc == "H" or sc == "D") and C.cred or C.cblk
    local rk, su = rankOf(c), SUIT[sc] or "?"
    textW(x, y + 1, 7, rk .. su, col, C.card)
    textW(x, y + 2, 7, "", col, C.card)
    textW(x, y + 3, 7, (rk == "J" or rk == "Q" or rk == "K") and (rk .. su) or su, col, C.card, "center")
    textW(x, y + 4, 7, "", col, C.card)
    textW(x, y + 5, 7, rk .. su, col, C.card, "right")
  end
  text(x, y + 6, first and "▝▀▀▀▀▀▘" or "▀▀▀▀▀▀▘", C.card, F)
end
local function totalText(cards)
  local t, soft = total(cards)
  if soft and t < 21 then return (t - 10) .. "/" .. t end
  return tostring(t)
end
local function handW(h, step) return 7 + step * max(0, #h.c - 1) end
local function seatW(s, step)
  local w = 0
  for i, h in ipairs(s.hands) do w = w + handW(h, step) + (i > 1 and 4 or 0) end
  return w
end

local function drawSeat(T, si, ax, aw, step, mine)
  local s = T.seats[si]
  if #T.seats > 1 then
    textW(ax, FT + 14, aw, ((mine and "YOU · " or "") .. tostring(s.name or "?")):upper(), mine and C.gold or C.text, C.felt, "center")
  end
  if #s.hands == 0 then
    local t = s.ready and ("BET " .. dollars(s.bet) .. " · READY") or (T.phase == "bet" and "NO BET YET" or "SITTING OUT")
    local cx = ax + floor(aw / 2)
    for r = 0, 6 do text(cx - 4, FT + 16 + r, (r == 0 or r == 6) and "┄┄┄┄┄┄┄┄┄" or "┆       ┆", lerp(C.felt, C.text, 0.25), C.felt) end
    centerText(cx, FT + 19, s.ready and dollars(s.bet) or "BET", s.ready and C.gold or lerp(C.felt, C.text, 0.35), C.felt)
    centerText(cx, FT + 24, t, s.ready and C.green or lerp(C.felt, C.text, 0.5), C.felt)
    return
  end
  local x = ax + floor((aw - seatW(s, step)) / 2)
  for hi, h in ipairs(s.hands) do
    local hw = handW(h, step)
    local cx = x + floor(hw / 2)
    local active = T.phase == "play" and T.turn and T.turn[1] == si and T.turn[2] == hi
    local hdr = " " .. dollars(h.bet) .. (h.dbl and " x2" or "") .. "   " .. totalText(h.c)
    local hx = cx - floor((unicode.len(hdr) + 1) / 2)
    text(hx, FT + 15, "●", chipColor(h.bet), C.felt)
    text(hx + 1, FT + 15, hdr, active and C.gold or C.text, C.felt)
    for i, c in ipairs(h.c) do drawCard(x + (i - 1) * step, FT + 16, c, i == 1) end
    local t = total(h.c)
    local pill, pc
    if T.phase == "done" then
      local r, p = handPay(h, T.dealer, T.rules)
      local net = p - h.bet
      pill = " " .. r .. (math.abs(net) > 0.004 and (" " .. signed(net)) or "") .. " "
      pc = (r == "WIN" and C.green) or (r == "BLACKJACK" and C.gold) or (r == "PUSH" and C.dim) or C.red
    elseif t > 21 then pill, pc = " BUST ", C.red
    elseif isBJ(h) then pill, pc = " BLACKJACK! ", C.gold
    elseif h.done and T.phase == "play" then pill, pc = " STAND " .. t .. " ", C.line end
    if pill then centerText(cx, FT + 23, pill, pc == C.line and C.text or C.dark, pc) end
    if active then
      centerText(cx, FT + 24, mine and "▲ YOUR TURN ▲" or ("▲ " .. tostring(s.name):upper() .. " ▲"), C.gold, C.felt)
    end
    x = x + hw + 4
  end
end

local function lobby(by)
  local bx, bw, bh = X0 + 31, 80, 14
  fill(bx, by, bw, bh, C.bg)
  fill(bx, by, bw, 1, C.gold)
  text(bx, by, " ♠ PLAY WITH A FRIEND ", C.dark, C.gold)
  local y = by + 2
  local any = false
  for addr, p in pairs(M.players) do
    if y <= by + 8 then
      any = true
      textW(bx + 2, y, 50, "● " .. p.name .. "   " .. floor(p.dist + 0.5) .. " blocks away", C.text, C.bg)
      smallBtn(bx + bw - 12, y, "  INVITE  ", function() invite(addr, p) end, M.inv ~= nil)
      y = y + 2
    end
  end
  if not any then
    textW(bx + 2, y, bw - 4, "Nobody found yet. Your friend must have Lymanos open with this", C.dim, C.bg)
    textW(bx + 2, y + 1, bw - 4, "Casino version, within wireless range. Then click FIND PLAYERS.", C.dim, C.bg)
  end
  if M.inv then textW(bx + 2, by + bh - 4, bw - 4, "Invite sent to " .. M.inv.name .. " - waiting for an answer...", C.gold, C.bg) end
  textW(bx + 2, by + bh - 3, bw - 4, "Same dealer for both. Each player's money stays in their own account.", C.dim, C.bg)
  smallBtn(bx + 2, by + bh - 1, "  FIND PLAYERS  ", findPlayers)
  smallBtn(bx + 21, by + bh - 1, "  PLAY SOLO  ", function() setMode("solo") end)
end

local function feltPrompt(T, si)
  if me.waiting then return "WAITING FOR THE HOUSE TO CONFIRM YOUR BET...", C.gold end
  if not T then return "WAITING FOR THE TABLE...", C.dim end
  if T.phase == "done" and T.seats[si] and #T.seats[si].hands > 0 then
    local pay, bets = seatResult(T, si)
    local net = pay - bets
    if net > 0.004 then return "YOU WIN " .. money(net), C.green end
    if net < -0.004 then return "YOU LOSE " .. money(-net), C.red end
    return "PUSH - YOUR BET COMES BACK", C.text
  end
  if T.phase == "bet" and T.waitSince and not GV then
    return "DEALING IN " .. max(0, math.ceil(45 - (computer.uptime() - T.waitSince))) .. " S  ·  PLAYERS WITHOUT A BET SIT THIS ONE OUT", C.gold
  end
  if T.phase == "bet" and not inRound() then return "PLACE YOUR BET  ·  CLICK THE CHIPS, THEN DEAL", lerp(C.gold, C.felt, 0.2) end
  if T.msg then return tostring(T.msg):upper(), C.gold end
  return "", C.felt
end

local function drawTable()
  local T, si = myView()
  fill(X0, FT, CW, FB - FT + 1, C.felt)
  fill(X0, FB, CW, 1, C.felt2)
  text(X0, FT, string.rep("▀", CW), C.shade, C.felt)
  if not T then
    centerText(X0 + floor(CW / 2), FT + 12, "Waiting for " .. tostring(GV and GV.hostName or "the host") .. "'s table...", C.text, C.felt)
    if GV and computer.uptime() - (GV.heard or 0) > 30 then
      centerText(X0 + floor(CW / 2), FT + 14, "No signal from the host for a while - use LEAVE TABLE if they're gone.", C.orange, C.felt)
    end
    return
  end
  local rl = T.rules or snapRules()
  -- dealer
  local d = T.dealer
  local dn = #d.c
  local dw = dn > 0 and (7 + 4 * (dn - 1)) or 7
  local dx = X0 + floor((CW - dw) / 2)
  local lbl = "DEALER"
  if dn > 0 then
    local up = (d.c[1] or ""):sub(1, 1) == "A" and "an Ace" or tostring(cval(d.c[1] or "2"))
    lbl = lbl .. "  ·  " .. (d.hole and ("showing " .. up) or totalText(d.c))
  end
  textW(X0, FT + 1, CW, lbl, C.text, C.felt, "center")
  if dn == 0 then
    for r = 0, 6 do text(dx - 1, FT + 2 + r, (r == 0 or r == 6) and "┄┄┄┄┄┄┄┄┄" or "┆       ┆", lerp(C.felt, C.text, 0.2), C.felt) end
  else
    for i, c in ipairs(d.c) do drawCard(dx + (i - 1) * 4, FT + 2, (d.hole and i == 2) and "??" or c, i == 1) end
    if not d.hole and dn >= 2 then
      local t = total(d.c)
      if t > 21 then centerText(X0 + floor(CW / 2), FT + 9, " DEALER BUSTS " .. t .. " ", C.dark, C.green)
      elseif dn == 2 and t == 21 then centerText(X0 + floor(CW / 2), FT + 9, " DEALER BLACKJACK ", C.dark, C.red) end
    end
  end
  -- table print
  local line1 = spaced("BLACKJACK PAYS " .. payText(rl.pays))
  local deco = lerp(C.gold, C.felt, 0.55)
  local l1 = unicode.len(line1)
  local lx = X0 + floor((CW - l1) / 2)
  text(lx - 14, FT + 11, "━━━━━━━━━━  ", deco, C.felt)
  text(lx, FT + 11, line1, C.gold, C.felt)
  text(lx + l1, FT + 11, "  ━━━━━━━━━━", deco, C.felt)
  textW(X0, FT + 12, CW, (rl.h17 and "Dealer hits soft 17" or "Dealer must draw to 16 and stand on all 17s")
    .. "  ·  " .. (rl.dbl == "any" and "Double on any two cards" or ("Double on " .. rl.dbl))
    .. "  ·  Split to " .. rl.hands .. " hands  ·  No insurance", lerp(C.gold, C.felt, 0.35), C.felt, "center")
  -- seats
  if M.mode == "multi" and not GV and not T.seats[2] then
    drawSeat(T, 1, X0 + 1, CW - 2, 4, true)
    lobby(FT + 13)
  else
    local n = #T.seats
    local aw = n > 1 and 69 or (CW - 2)
    local step = 2
    for _, sp in ipairs({ 4, 3, 2 }) do
      local fits = true
      for _, s in ipairs(T.seats) do if seatW(s, sp) > aw then fits = false end end
      if fits then step = sp; break end
    end
    for i = 1, n do
      drawSeat(T, i, X0 + 1 + (i - 1) * 71, aw, step, i == si)
    end
    if n > 1 then for r = FT + 14, FT + 25 do text(X0 + 71, r, "┊", lerp(C.felt, C.text, 0.2), C.felt) end end
  end
  local p, pc = feltPrompt(T, si)
  textW(X0, FT + 27, CW, p, pc, C.felt, "center")
end

---------------------------------------------------------------- let it ride
local GX, GY, GW, GR = X0 + 8, FT + 1, 95, 26     -- graph canvas: x, y, width (cols), rows
local function gridVals(ymax)
  local out = {}
  for _, v in ipairs({ 1, 1.5, 2, 3, 5, 10, 20, 50, 100, 200, 500, 1000, 5000, 10000, 100000 }) do
    if v < ymax * 0.97 then out[#out + 1] = v end
  end
  while #out > 6 do table.remove(out, 2) end
  return out
end
local function multText(v) return v >= 100 and string.format("%dx", floor(v)) or string.format("%.2fx", v) end

local function drawGraph()
  local cw, ph = GW, GR * 2
  local cv = newCanvas(cw, ph, C.bg)
  local up = computer.uptime()
  local st = RD.phase
  local t, m = 0, 1
  if st == "fly" then t = max(0, up - RD.t0); m = min(rideMult(t), RD.crash)
  elseif st == "crashed" and RD.crash then m = RD.crash; t = math.log(RD.crash) / (RD.speed or 0.115) end
  local tmax = max(8, math.ceil(t * 1.2 / 4) * 4)       -- a multiple of 4: whole-second labels
  local ymax = max(2, 1 + (m - 1) * 1.35)
  local function py(v) return ph - floor((v - 1) / (ymax - 1) * (ph - 4) + 0.5) end
  local function px(tt) return 1 + floor(tt / tmax * (cw - 2) + 0.5) end
  local grid = gridVals(ymax)
  for _, v in ipairs(grid) do
    local yy = py(v)
    for xx = 1, cw, 3 do cset(cv, xx, yy, C.line) end
  end
  if st == "fly" or st == "crashed" then
    local col = (st == "crashed" and not RD.out) and C.red or (RD.out and C.green or C.gold)
    local area = lerp(col, C.bg, 0.8)
    local xe = px(t)
    local prev
    for x = 1, xe do
      local tt = (xe > 1) and ((x - 1) / (xe - 1) * t) or 0
      local yy = py(rideMult(tt))
      for y2 = yy + 1, ph do cset(cv, x, y2, area) end
      if prev and prev - yy > 1 then for y2 = yy, prev do cset(cv, x, y2, col) end end
      cset(cv, x, yy, col)
      prev = yy
    end
    if RD.out then
      local xo = px(math.log(RD.out) / (RD.speed or 0.115))
      for y2 = py(RD.out), ph, 2 do cset(cv, xo, y2, C.green) end
    end
    local hy = py(m)
    for dy = -1, 1 do for dx2 = -1, 1 do cset(cv, xe + dx2, hy + dy, st == "crashed" and C.red or 0xFFFFFF) end end
  end
  -- the big number
  local s, col
  if st == "count" then s, col = tostring(max(1, math.ceil(RD.t0 - up))), C.gold
  elseif st == "fly" then s, col = multText(floor(m * 100) / 100), RD.out and C.green or C.text
  elseif st == "crashed" then s, col = multText(RD.crash), C.red
  else s, col = "1.00x", st == "betting" and C.gold or C.line end
  local sx = #s > 6 and 2 or 3
  bigDraw(cv, s, floor((cw - bigWidth(s, sx)) / 2) + 1, 5, sx, 2, col)
  crender(cv, GX, GY)
  fill(X0, GY, 8, GR, C.bg)
  for _, v in ipairs(grid) do
    textW(X0, GY + floor((py(v) - 1) / 2), 7, v >= 10 and string.format("%dx", v) or string.format("%.1fx", v), C.dim, C.bg, "right")
  end
  local lab = {}
  for k = 0, 4 do lab[#lab + 1] = { 1 + floor(k * (cw - 1) / 4), string.format("%ds", floor(tmax * k / 4 + 0.5)) } end
  local chars = {}
  for i = 1, cw do chars[i] = " " end
  for _, it in ipairs(lab) do
    local len = #it[2]
    local lx = max(1, min(it[1] - floor(len / 2), cw - len + 1))
    for i = 1, len do chars[lx + i - 1] = it[2]:sub(i, i) end
  end
  text(GX, GY + GR, table.concat(chars), C.dim, C.bg)
  -- the line under the graph
  local info, ic = "", C.dim
  if st == "betting" then info, ic = "Sending your bet to the house...", C.gold
  elseif st == "count" then info, ic = "Launching in " .. max(1, math.ceil(RD.t0 - up)) .. "...  cash out any time after take-off", C.gold
  elseif st == "fly" and not RD.out then
    info, ic = "Bet " .. money(RD.bet) .. "  ·  worth " .. money(cents(RD.bet * floor(m * 100) / 100)) .. " now  ·  CASH OUT before it crashes!", C.text
  elseif st == "fly" then info, ic = string.format("Cashed out at %.2fx for %s - let's see where it would have crashed...", RD.out, money(RD.win)), C.green
  elseif st == "crashed" then
    if RD.out then info, ic = string.format("You cashed out at %.2fx (%s). It crashed at %.2fx.", RD.out, signed(RD.win - RD.bet), RD.crash), C.green
    else info, ic = string.format("Crashed at %.2fx%s - %s lost.", RD.crash, RD.crash <= 1 and " (instant bust)" or "", money(RD.bet)), C.red end
  else info = "Bet " .. money(M.rbet) .. ((M.auto or 0) > 0 and string.format("  ·  auto cash out at %.2fx", M.auto) or "")
    .. "  ·  press LAUNCH (or Space)" end
  textW(X0 + 1, GY + GR + 1, 101, info, ic, C.bg, "center")
end

local function drawSide()
  local x, w = RX, RW
  local rr = R().ride
  fill(x, FT, w, FB - FT + 1, C.bar)
  local function head(y, s) fill(x, y, w, 1, C.bar2); text(x, y, " " .. s .. " ", C.gold, C.bar2) end
  head(FT, "RECENT CRASHES")
  for i = 1, 24 do
    local v = M.crashes[i]
    local cx, cy = x + 1 + ((i - 1) % 3) * 12, FT + 1 + floor((i - 1) / 3)
    if v then
      local col = v < 1.5 and C.red or (v < 2 and C.orange or (v < 10 and C.green or C.gold))
      textW(cx, cy, 11, multText(v), C.dark, col, "center")
    end
  end
  if #M.crashes == 0 then textW(x + 1, FT + 2, w - 2, "No rounds yet.", C.dim, C.bar) end
  head(FT + 10, "YOUR LAST RIDES")
  local n = 0
  for _, h in ipairs(M.hist) do
    if h.g == "ride" and n < 7 then
      n = n + 1
      local net = h.pay - h.bet
      kvRow(x + 1, FT + 10 + n, w - 2, (h.o or ""):gsub("CASHED OUT ", "OUT "):sub(1, 14), signed(net), net > 0 and C.green or C.red)
    end
  end
  if n == 0 then textW(x + 1, FT + 11, w - 2, "Finished rides show up here.", C.dim, C.bar) end
  head(FT + 19, "HOUSE RULES")
  local sp = rr.speed
  kvRow(x + 1, FT + 20, w - 2, "House edge", string.format("%.1f%%  (RTP %.1f%%)", rr.edge * 100, (1 - rr.edge) * 100))
  kvRow(x + 1, FT + 21, w - 2, "Bust at 1.00x", string.format("%.1f%% of rounds", (1 - (1 - rr.edge) / 1.01) * 100))
  kvRow(x + 1, FT + 22, w - 2, "Max multiplier", multText(rr.cap))
  kvRow(x + 1, FT + 23, w - 2, "Speed", string.format("2x in %.1fs, 10x in %.0fs", math.log(2) / sp, math.log(10) / sp))
  kvRow(x + 1, FT + 24, w - 2, "Bet limits", dollars(R().min) .. " - " .. dollars(R().max))
  local tgt = (M.auto or 0) > 0 and M.auto or 2
  kvRow(x + 1, FT + 26, w - 2, string.format("Reach %.2fx", tgt), string.format("%.1f%% of rounds", min(100, (1 - rr.edge) / tgt * 100)), C.gold)
  textW(x + 1, FT + 28, w - 2, rr.on and "" or "CLOSED BY THE HOUSE", C.red, C.bar)
end

local function drawRide()
  fill(X0, FT, 104, FB - FT + 1, C.bg)
  drawGraph()
  drawSide()
end

---------------------------------------------------------------- bottom bar
local function drawBetBox()
  local x, y = X0 + 2, BT + 1
  text(x, y, "YOUR BET", C.dim, C.bar)
  if M.focus then textW(x + 10, y, 20, " $" .. M.input .. "_", C.dark, 0xFFF3C4); text(x + 32, y, "Enter", C.dim, C.bar)
  else
    textW(x + 10, y, 20, " " .. money(betVal()), C.gold, C.bar2)
    text(x + 25, y, "type ", C.offT, C.bar2)
    text(x + 32, y, "     ", C.dim, C.bar)
  end
end

local function rideLabel()
  local st = RD.phase
  if st == "fly" and not RD.out then
    local m = floor(rideMult(computer.uptime() - RD.t0) * 100) / 100
    return "CASH OUT  " .. money(cents(RD.bet * m)), C.gold, false
  elseif st == "fly" then return "CASHED OUT  " .. signed(RD.win - RD.bet), C.green, true
  elseif st == "count" then return "GET READY...", C.gold, true
  elseif st == "betting" then return "SENDING BET...", C.gold, true end
  return "LAUNCH  ·  " .. dollars(M.rbet), C.green, not online()
end
local function drawRideButton()
  local l, col, dis = rideLabel()
  bigBtn(MX, BT + 1, MW, l, col, nil, dis)
end

local function accountBlock(pf)
  local n, out = inPlay()
  kvRow(RX, BT + 1, RW - 1, "SAVINGS", money(pf.cash), C.text)
  kvRow(RX, BT + 2, RW - 1, "IN PLAY", (n > 0 or out > 0) and money(n) or "--", n > 0 and C.gold or C.dim)
  kvRow(RX, BT + 3, RW - 1, "HOUSE", online() and ("● " .. (HS.wallet and ("bank " .. shortMoney(HS.wallet)) or "online")) or "○ offline",
    online() and C.green or C.red)
  if M.tab == "bj" then
    if GV then
      textW(RX, BT + 5, RW - 1, "AT " .. tostring(GV.hostName):upper() .. "'S TABLE", C.gold, C.bar)
      smallBtn(RX, BT + 6, "  LEAVE TABLE  ", leaveTable)
    elseif S.seats[2] then
      textW(RX, BT + 5, RW - 1, "PLAYING WITH " .. tostring(S.seats[2].name):upper(), C.gold, C.bar)
      smallBtn(RX, BT + 6, "  CLOSE TABLE  ", leaveTable, S.phase ~= "bet" and S.phase ~= "done")
    else
      local busy = inRound()
      text(RX, BT + 5, M.mode == "solo" and " ● SOLO " or "   SOLO ", M.mode == "solo" and C.dark or C.text, M.mode == "solo" and C.gold or C.line)
      if not busy then region(M.reg, RX, BT + 5, 8, 1, function() setMode("solo") end) end
      text(RX + 9, BT + 5, M.mode == "multi" and " ● WITH A FRIEND " or "   WITH A FRIEND ", M.mode == "multi" and C.dark or C.text, M.mode == "multi" and C.gold or C.line)
      if not busy then region(M.reg, RX + 9, BT + 5, 17, 1, function() setMode("multi") end) end
    end
  end
  textW(RX, BT + 7, RW - 1, out > 0 and ("Payout on its way: " .. money(out)) or "", C.gold, C.bar)
end

local function drawBar()
  fill(X0, BT, CW, BB - BT + 1, C.bar)
  local pf = ST.acct()
  if M.tab == "rl" or M.tab == "pw" then
    (M.tab == "rl" and RLT or PW).bar()
    return accountBlock(pf)
  end
  -- left: bet
  drawBetBox()
  region(M.reg, X0 + 12, BT + 1, 20, 1, function() M.focus, M.input = true, ""; drawBetBox() end)
  local x = X0 + 2
  for i, ch in ipairs(CHIPS) do
    local cx = x + (i - 1) * 7
    text(cx, BT + 3, "◖", ch[2], C.bar)
    textW(cx + 1, BT + 3, 4, ch[4], ch[3], ch[2], "center")
    text(cx + 5, BT + 3, "◗", ch[2], C.bar)
    region(M.reg, cx, BT + 3, 6, 1, function() setBet(betVal() + ch[1]); drawWindow() end)
  end
  local bx = x
  bx = smallBtn(bx, BT + 5, " ½ ", function() setBet(floor(betVal() / 2)); drawWindow() end)
  bx = smallBtn(bx, BT + 5, " 2x ", function() setBet(betVal() * 2); drawWindow() end)
  bx = smallBtn(bx, BT + 5, " MIN ", function() setBet(R().min); drawWindow() end)
  bx = smallBtn(bx, BT + 5, " MAX ", function() setBet(max(0, min(R().max, floor(pf.cash)))); drawWindow() end)
  smallBtn(bx, BT + 5, " CLEAR ", function() setBet(0); drawWindow() end)
  textW(x, BT + 7, 42, "Limits " .. dollars(R().min) .. " - " .. dollars(R().max) .. "   Savings " .. money(pf.cash), C.dim, C.bar)

  -- middle: actions
  if M.tab == "bj" then
    local T, si = myView()
    local myTurn = T and T.phase == "play" and T.turn and T.turn[1] == si and not M.sent and not me.waiting and (GV or #S.q == 0)
    if myTurn then
      local seat = T.seats[si]
      local h = seat.hands[T.turn[2]]
      local bw = 13
      bigBtn(MX, BT + 1, bw, "HIT", C.blue, function() myAction("hit") end)
      bigBtn(MX + 14, BT + 1, bw, "STAND", C.red, function() myAction("stand") end)
      bigBtn(MX + 28, BT + 1, bw, "DOUBLE", C.gold, function() myAction("double") end, not canDouble(T, h))
      bigBtn(MX + 42, BT + 1, bw, "SPLIT", C.violet, function() myAction("split") end, not canSplit(T, seat, h))
      textW(MX, BT + 5, MW, "Keys: H hit · S stand · D double · P split", C.dim, C.bar, "center")
      textW(MX, BT + 6, MW, "Double / split add another " .. money(h.bet) .. " bet", C.dim, C.bar, "center")
    elseif me.waiting then
      bigBtn(MX, BT + 1, MW, "WAITING FOR THE HOUSE...", C.gold, nil, true)
      if not online() then textW(MX, BT + 5, MW, "House offline - your bet is held and re-sent until it answers.", C.orange, C.bar, "center") end
    elseif inRound() then
      local l = "PLEASE WAIT"
      if T and T.phase == "deal" then l = "DEALING..."
      elseif T and T.phase == "dealer" then l = "DEALER'S TURN"
      elseif T and T.phase == "play" and T.turn then l = (tostring(T.seats[T.turn[1]].name) .. "'S TURN"):upper()
      elseif T and T.phase == "bet" then l = "WAITING FOR OTHER PLAYERS" end
      bigBtn(MX, BT + 1, MW, l, C.gold, nil, true)
      if not GV and S.phase == "bet" and S.seats[2] and S.seats[1].ready and not S.seats[2].ready then
        bigBtn(MX, BT + 5, MW, "DEAL WITHOUT " .. tostring(S.seats[2].name):upper(), C.line, dealNow)
      end
    else
      local again = T and T.phase == "done"
      bigBtn(MX, BT + 1, MW, (again and "NEXT HAND  ·  " or "DEAL  ·  ") .. dollars(M.bet), C.green, deal,
        not online() or (T and T.phase ~= "bet" and T.phase ~= "done"))
      if not GV and S.phase == "bet" and S.seats[2] and S.seats[2].ready then
        bigBtn(MX, BT + 5, MW, "DEAL " .. tostring(S.seats[2].name):upper() .. " IN (YOU SIT OUT)", C.line, dealNow)
      else
        textW(MX, BT + 5, MW, online() and "Space = deal" or "The house server is offline - start houseview.lua", online() and C.dim or C.orange, C.bar, "center")
      end
    end
  else
    drawRideButton()
    region(M.reg, MX, BT + 1, MW, 3, function() rideButton() end)
    local busy = rideBusy()
    local a = M.auto or 0
    text(MX + 6, BT + 5, "AUTO CASH OUT", C.dim, C.bar)
    smallBtn(MX + 21, BT + 5, " ◄ ", function()
      local i = 1
      for k, v in ipairs(AUTO) do if v == a then i = k end end
      M.auto = AUTO[(i - 2) % #AUTO + 1]; saveCas(); drawWindow()
    end, busy)
    textW(MX + 25, BT + 5, 9, a > 0 and string.format("%.2fx", a) or "OFF", a > 0 and C.gold or C.dim, C.bar2, "center")
    smallBtn(MX + 35, BT + 5, " ► ", function()
      local i = 1
      for k, v in ipairs(AUTO) do if v == a then i = k end end
      M.auto = AUTO[i % #AUTO + 1]; saveCas(); drawWindow()
    end, busy)
    textW(MX, BT + 7, MW, a > 0 and ("Wins " .. money(cents(M.rbet * a)) .. " if it reaches " .. string.format("%.2fx", a)) or "Space = launch / cash out",
      C.dim, C.bar, "center")
  end

  accountBlock(pf)
end

---------------------------------------------------------------- roulette
-- American roulette (0 and 00) by default; the house can switch to a single-zero
-- wheel. Chips go on the layout; SPIN sends the total as one bet to the house,
-- the ball's pocket is picked when the house accepts and saved straight away,
-- then the wheel animation plays. Payout = sum of winning spots x (ratio + 1).
RLT = (function()
local AM = { 0, 28, 9, 26, 30, 11, 7, 20, 32, 17, 5, 22, 34, 15, 3, 24, 36, 13, 1, 37, 27, 10, 25, 29, 12, 8, 19, 31, 18, 6, 21, 33, 16, 4, 23, 35, 14, 2 }
local EU = { 0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10, 5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26 }
local RED = {}
for _, n in ipairs({ 1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36 }) do RED[n] = true end
local K2 = { red = 0xC0262D, black = 0x1B1C20, green = 0x0E7A3E, line = 0x5FA582, cloth = 0x0A4A30, win = 0xF2C14E }
local T = { phase = "idle", bets = {}, undo = {}, hist = {}, chip = 5, pos = 1 }   -- saved with the casino file
local gx, gy = X0 + 9, FT + 2              -- top-left corner of the number grid
local PX = X0 + 91                         -- right panel
local PW2 = X1 - PX + 1
local SPIN_TIME = 6

local function american() return R().rl.wheel ~= "european" end
local function wheel() return american() and AM or EU end
local function pname(n) return n == 37 and "00" or tostring(n) end
local function pcol(n) if n == 0 or n == 37 then return K2.green end return RED[n] and K2.red or K2.black end
local function numAt(c, r) return 3 * c - (r - 1) end      -- column 1..12, row 1 (top) .. 3
local function ratio(nums) return floor(36 / #nums) - 1 end   -- 35, 17, 11, 8, 6 (five), 5, 2, 1
local function range(a, b, step)
  local t = {}
  for n = a, b, step or 1 do t[#t + 1] = n end
  return t
end
local function filter(fn)
  local t = {}
  for n = 1, 36 do if fn(n) then t[#t + 1] = n end end
  return t
end
local OUT = {
  LOW = { "1 - 18", range(1, 18) }, HIGH = { "19 - 36", range(19, 36) },
  EVEN = { "EVEN", filter(function(n) return n % 2 == 0 end) }, ODD = { "ODD", filter(function(n) return n % 2 == 1 end) },
  RED = { "RED", filter(function(n) return RED[n] end) }, BLACK = { "BLACK", filter(function(n) return not RED[n] end) },
  D1 = { "1st 12", range(1, 12) }, D2 = { "2nd 12", range(13, 24) }, D3 = { "3rd 12", range(25, 36) },
  C1 = { "2 to 1", range(1, 34, 3) }, C2 = { "2 to 1", range(2, 35, 3) }, C3 = { "2 to 1", range(3, 36, 3) },
}
local function short(n)
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e4 then return floor(n / 1000) .. "K" end
  if n >= 1000 then return string.format("%.1fK", n / 1000) end
  if n == floor(n) then return tostring(floor(n)) end
  return string.format("%.2f", n)
end
local function betName(b)
  if OUT[b.key] then return OUT[b.key][1] .. (b.key:sub(1, 1) == "C" and (" (col " .. b.key:sub(2) .. ")") or "") end
  local names = {}
  for _, n in ipairs(b.n) do names[#names + 1] = pname(n) end
  local kinds = { [1] = "", [2] = "split ", [3] = "street ", [4] = "corner ", [5] = "basket ", [6] = "line " }
  return (kinds[#b.n] or "") .. table.concat(names, "-")
end
local function total()
  local t = 0
  for _, b in pairs(T.bets) do t = t + b.a end
  return cents(t)
end
-- the most this spread of chips could ever win (the house checks it can pay that)
local function maxWin(bets)
  local best = 0
  local pockets = wheel()
  for _, p in ipairs(pockets) do
    local w = 0
    for _, b in pairs(bets) do
      for _, n in ipairs(b.n) do if n == p then w = w + b.a * (ratio(b.n) + 1); break end end
    end
    if w > best then best = w end
  end
  return cents(best)
end
local function payout(bets, p)
  local w = 0
  for _, b in pairs(bets) do
    for _, n in ipairs(b.n) do if n == p then w = w + b.a * (ratio(b.n) + 1); break end end
  end
  return cents(w)
end
local function busy() return T.phase == "betting" or T.phase == "spin" end

-- which bet a click on the layout means: key, numbers, chip position
local function spotAt(x, y)
  local zero = american() and { 0, 37, 1, 2, 3 } or { 0, 1, 2, 3 }
  if x >= gx - 7 and x <= gx - 1 and y >= gy + 1 and y <= gy + 8 then
    if american() and y >= gy + 5 then return "37", { 37 }, gx - 4, gy + 7 end
    return "0", { 0 }, gx - 4, american() and gy + 3 or gy + 5
  end
  if x >= gx + 73 and x <= gx + 79 and y >= gy + 1 and y <= gy + 8 then
    local r = floor((y - gy) / 3) + 1
    local key = ({ "C3", "C2", "C1" })[r]
    return key, OUT[key][2], gx + 76, gy + (r - 1) * 3 + 2
  end
  if y >= gy + 11 and y <= gy + 12 and x >= gx + 1 and x <= gx + 71 then
    local d = min(3, floor((x - gx - 1) / 24) + 1)
    local key = "D" .. d
    return key, OUT[key][2], gx + (d - 1) * 24 + 12, gy + 12
  end
  if y >= gy + 14 and y <= gy + 15 and x >= gx + 1 and x <= gx + 71 then
    local i = min(6, floor((x - gx - 1) / 12) + 1)
    local key = ({ "LOW", "EVEN", "RED", "BLACK", "ODD", "HIGH" })[i]
    return key, OUT[key][2], gx + (i - 1) * 12 + 6, gy + 15
  end
  if x < gx or x > gx + 72 or y < gy or y > gy + 9 then return nil end
  local dx, dy = x - gx, y - gy
  local c, rx = floor(dx / 6) + 1, dx % 6
  local r, ry = floor(dy / 3) + 1, dy % 3
  local nums
  if rx > 0 and ry > 0 and c <= 12 and r <= 3 then nums = { numAt(c, r) }
  elseif rx == 0 and ry > 0 and c >= 2 and c <= 12 and r <= 3 then nums = { numAt(c - 1, r), numAt(c, r) }
  elseif rx > 0 and ry == 0 and c <= 12 and (r == 2 or r == 3) then nums = { numAt(c, r - 1), numAt(c, r) }
  elseif rx > 0 and ry == 0 and c <= 12 and r == 4 then nums = { numAt(c, 1), numAt(c, 2), numAt(c, 3) }
  elseif rx == 0 and ry == 0 and c >= 2 and c <= 12 and (r == 2 or r == 3) then
    nums = { numAt(c - 1, r - 1), numAt(c, r - 1), numAt(c - 1, r), numAt(c, r) }
  elseif rx == 0 and ry == 0 and c >= 2 and c <= 12 and r == 4 then
    nums = { numAt(c - 1, 1), numAt(c - 1, 2), numAt(c - 1, 3), numAt(c, 1), numAt(c, 2), numAt(c, 3) }
  elseif rx == 0 and ry == 0 and c == 1 and r == 4 then
    if not R().rl.basket then return nil end
    nums = zero
  else return nil end
  table.sort(nums)
  local cx, cy = x, y
  if #nums == 1 then cx, cy = gx + (c - 1) * 6 + 3, gy + (r - 1) * 3 + 2 end
  return table.concat(nums, ","), nums, cx, cy
end

local function place(x, y, remove)
  if busy() then return end
  if T.phase == "done" then T.phase, T.res = "idle", nil end
  local key, nums, cx, cy = spotAt(x, y)
  if not key then return redraw() end
  local b = T.bets[key]
  if remove then
    if b then
      b.a = cents(b.a - min(b.a, T.chip))
      if b.a <= 0 then T.bets[key] = nil end
    end
  else
    if total() + T.chip > R().max + 1e-9 then M.msg = "That would go over the table limit of " .. dollars(R().max) .. "."; return redraw() end
    if not b then b = { key = key, n = nums, a = 0, x = cx, y = cy }; T.bets[key] = b end
    b.a = cents(b.a + T.chip)
    T.undo[#T.undo + 1] = { key, T.chip }
    while #T.undo > 50 do table.remove(T.undo, 1) end
    M.msg = betName(b) .. ": " .. dollars(b.a) .. "  (pays " .. ratio(nums) .. " to 1)"
  end
  saveCas()
  redraw()
end
local function undo()
  local u = table.remove(T.undo)
  if not u or busy() then return end
  local b = T.bets[u[1]]
  if b then b.a = cents(b.a - u[2]); if b.a <= 0 then T.bets[u[1]] = nil end end
  saveCas(); redraw()
end
local function clear() if not busy() then T.bets, T.undo = {}, {}; if T.phase == "done" then T.phase = "idle" end; saveCas(); redraw() end end
local function rebet()
  if busy() or not T.last then return end
  T.bets, T.undo, T.phase = {}, {}, "idle"
  for k, b in pairs(T.last) do T.bets[k] = { key = b.key, n = b.n, a = b.a, x = b.x, y = b.y } end
  saveCas(); redraw()
end
local function double()
  if busy() then return end
  if total() * 2 > R().max + 1e-9 then M.msg = "Doubling would go over the table limit."; return redraw() end
  for _, b in pairs(T.bets) do b.a = cents(b.a * 2) end
  saveCas(); redraw()
end

local function spin()
  if busy() then return end
  if not R().rl.on then return sayDraw("Roulette is closed by the house right now.") end
  local tot = total()
  if tot <= 0 then return sayDraw("Place some chips on the table first.") end
  local rid = newRid("L")
  local seq, why = placeBet(rid, "rl", tot, "main", maxWin(T.bets))
  if not seq then return sayDraw(why) end
  T.phase, T.rid, T.seq, T.res = "betting", rid, seq, nil
  T.last = {}
  for k, b in pairs(T.bets) do T.last[k] = { key = b.key, n = b.n, a = b.a, x = b.x, y = b.y } end
  M.msg = "Bet " .. money(tot) .. " sent to the house..."
  saveCas()
  redraw()
end

local function finish()
  local p = T.res
  local pay = payout(T.bets, p)
  local tot = total()
  local what = pname(p) .. ((p == 0 or p == 37) and " green" or (RED[p] and " red" or " black"))
  settle(T.rid, pay, "SPIN " .. what:upper(), "bets " .. money(tot))
  T.phase, T.pos, T.paid = "done", T.target or T.pos, pay
  table.insert(T.hist, 1, p)
  while #T.hist > 20 do table.remove(T.hist) end
  M.msg = pay > 0 and ("The ball lands on " .. what .. " - you win " .. money(pay) .. "!") or ("The ball lands on " .. what .. ".")
  saveCas()
  redraw()
end

local function onBet(rid, seq, ok, why)
  if T.rid ~= rid or T.phase ~= "betting" then return end
  if not ok then
    T.phase = "idle"
    M.msg = "The house refused the bet: " .. tostring(why or "no reason given")
    saveCas()
    return redraw()
  end
  local wl = wheel()
  T.wheelN = #wl
  local i = math.random(1, #wl)
  T.res = wl[i]
  T.from = T.pos or 1
  T.target = i
  T.phase, T.t0 = "spin", computer.uptime()
  M.msg = "No more bets!"
  saveCas()
  redraw()
end

---------------------------------------------------------------- drawing
local function chipTag(x, y, a, bgc)
  local s = short(a)
  text(x - floor(#s / 2), y, s, chipColor(a) == CHIPS[1][2] and C.dark or C.text, chipColor(a))
end
local function cell(x, y, w, h, label, col, hot)
  local b = hot and K2.win or col
  fill(x, y, w, h, b)
  textW(x, y, w, label, hot and C.dark or C.text, b, "center")
end

local function drawLayout()
  local win = T.phase == "done" and T.res
  fill(gx - 8, gy - 1, 90, 18, C.felt)
  -- the number grid lines
  for r = 0, 3 do
    local y = gy + r * 3
    text(gx, y, r == 0 and "┌" or (r == 3 and "└" or "├"), K2.line, C.felt)
    for c = 1, 12 do
      text(gx + (c - 1) * 6 + 1, y, "─────", K2.line, C.felt)
      local j = c == 12 and (r == 0 and "┐" or (r == 3 and "┘" or "┤")) or (r == 0 and "┬" or (r == 3 and "┴" or "┼"))
      text(gx + c * 6, y, j, K2.line, C.felt)
    end
  end
  for c = 0, 12 do for r = 0, 2 do vtext(gx + c * 6, gy + r * 3 + 1, "││", K2.line, C.felt) end end
  for c = 1, 12 do
    for r = 1, 3 do
      local n = numAt(c, r)
      cell(gx + (c - 1) * 6 + 1, gy + (r - 1) * 3 + 1, 5, 2, tostring(n), pcol(n), win == n)
    end
  end
  -- zeros
  if american() then
    cell(gx - 7, gy + 1, 7, 4, "", K2.green, win == 0)
    centerText(gx - 4, gy + 2, "0", win == 0 and C.dark or C.text, win == 0 and K2.win or K2.green)
    cell(gx - 7, gy + 5, 7, 4, "", K2.green, win == 37)
    centerText(gx - 4, gy + 6, "00", win == 37 and C.dark or C.text, win == 37 and K2.win or K2.green)
  else
    cell(gx - 7, gy + 1, 7, 8, "", K2.green, win == 0)
    centerText(gx - 4, gy + 4, "0", win == 0 and C.dark or C.text, win == 0 and K2.win or K2.green)
  end
  -- 2 to 1, dozens, outside
  for r = 1, 3 do
    local key = ({ "C3", "C2", "C1" })[r]
    local hot = win and win ~= 0 and win ~= 37 and (win % 3) == ({ 0, 2, 1 })[r]
    cell(gx + 73, gy + (r - 1) * 3 + 1, 6, 2, "2:1", K2.cloth, hot)
  end
  for d = 1, 3 do
    local hot = win and win >= (d - 1) * 12 + 1 and win <= d * 12
    cell(gx + (d - 1) * 24 + 1, gy + 11, 23, 2, OUT["D" .. d][1]:upper(), K2.cloth, hot)
  end
  for i, key in ipairs({ "LOW", "EVEN", "RED", "BLACK", "ODD", "HIGH" }) do
    local hot = false
    if win then for _, n in ipairs(OUT[key][2]) do if n == win then hot = true end end end
    local col = key == "RED" and K2.red or (key == "BLACK" and K2.black or K2.cloth)
    cell(gx + (i - 1) * 12 + 1, gy + 14, 11, 2, (key == "RED" or key == "BLACK") and ("◆ " .. OUT[key][1]) or OUT[key][1], col, hot)
  end
  if R().rl.basket then
    text(gx, gy + 9, "◇", C.gold, C.felt)       -- five-number / first-four spot
  end
  -- chips
  for _, b in pairs(T.bets) do
    if #b.n == 1 or OUT[b.key] then chipTag(b.x, b.y, b.a)
    else text(b.x, b.y, "●", chipColor(b.a), C.felt) end
  end
  textW(gx - 8, gy + 17, 90, "Click a number, a line (split), a corner, or the bottom edge (street / six line).", C.dim, C.felt, "center")
end

-- the wheel strip: pockets slide under the marker
local CELLW = 5
local function drawReel(pos)
  local wl = wheel()
  local n = #wl
  local w = PW2 - 2
  local x0 = PX + 1
  local center = floor(w / 2)
  local shift = floor(pos * CELLW + 0.5)
  for row = 0, 2 do
    local runStart, runP, buf = 1, nil, {}
    local function flushRun(endc)
      if runP then
        local col = pcol(runP)
        textW(x0 + runStart - 1, FT + 3 + row, endc - runStart + 1, table.concat(buf), C.text, col)
      end
    end
    for cx = 1, w do
      local g = shift + (cx - 1 - center) + floor(CELLW / 2)
      local idx = floor(g / CELLW) % n + 1
      local p = wl[idx]
      if p ~= runP then flushRun(cx - 1); runStart, runP, buf = cx, p, {} end
      local inner = g % CELLW
      local lab = pname(p)
      local ch = " "
      if row == 1 then
        local off = floor((CELLW - #lab) / 2)
        if inner >= off and inner < off + #lab then ch = lab:sub(inner - off + 1, inner - off + 1) end
      end
      buf[#buf + 1] = ch
    end
    flushRun(w)
  end
  text(x0 + center, FT + 2, "▼", C.gold, C.bg)
  text(x0 + center, FT + 6, "▲", C.gold, C.bg)
end
local function reelPos()
  if T.phase ~= "spin" then return (T.pos or 1) - 1 end
  local n = T.wheelN or #wheel()
  local f = min(1, (computer.uptime() - T.t0) / SPIN_TIME)
  local e = 1 - (1 - f) ^ 3
  local from, to = (T.from or 1) - 1, (T.target or 1) - 1 + 4 * n
  return from + (to - from) * e
end

local function drawPanel()
  fill(PX, FT, PW2, FB - FT + 1, C.bg)
  fill(PX, FT, PW2, 1, C.bar2)
  text(PX, FT, " ◎ THE WHEEL ", C.gold, C.bar2)
  textW(PX + 14, FT, PW2 - 15, american() and "American · 0 and 00" or "European · single 0", C.dim, C.bar2, "right")
  fill(PX, FT + 2, PW2, 5, C.bg)
  drawReel(reelPos())
  -- result
  local res = (T.phase == "done") and T.res
  if res then
    local s = pname(res)
    local cv = newCanvas(24, 14, C.bg)
    bigDraw(cv, s, floor((24 - bigWidth(s, 2)) / 2) + 1, 1, 2, 2, pcol(res) == K2.black and C.text or pcol(res))
    crender(cv, PX + 2, FT + 7)
    local words = (res == 0 or res == 37) and { "GREEN" } or {
      RED[res] and "RED" or "BLACK", res % 2 == 0 and "EVEN" or "ODD", res <= 18 and "1 - 18" or "19 - 36" }
    textW(PX + 27, FT + 9, PW2 - 28, table.concat(words, " · "), pcol(res) == K2.black and C.text or pcol(res), C.bg)
    textW(PX + 27, FT + 10, PW2 - 28, (T.paid or 0) > 0 and ("You won " .. money(T.paid)) or "No win this time", (T.paid or 0) > 0 and C.green or C.dim, C.bg)
  elseif T.phase == "spin" then
    textW(PX + 2, FT + 9, PW2 - 4, "NO MORE BETS", C.gold, C.bg, "center")
  elseif T.phase == "betting" then
    textW(PX + 2, FT + 9, PW2 - 4, "Sending your bet to the house...", C.gold, C.bg, "center")
  else
    textW(PX + 2, FT + 9, PW2 - 4, "PLACE YOUR BETS", C.gold, C.bg, "center")
  end
  -- history
  fill(PX, FT + 15, PW2, 1, C.bar2)
  text(PX, FT + 15, " LAST SPINS ", C.gold, C.bar2)
  for i = 1, 20 do
    local p = T.hist[i]
    local cx, cy = PX + 1 + ((i - 1) % 10) * 5, FT + 16 + floor((i - 1) / 10)
    if p then textW(cx, cy, 4, pname(p), C.text, pcol(p), "center") end
  end
  if #T.hist == 0 then textW(PX + 1, FT + 16, PW2 - 2, "No spins yet.", C.dim, C.bg) end
  -- my bets
  fill(PX, FT + 19, PW2, 1, C.bar2)
  text(PX, FT + 19, " YOUR CHIPS ", C.gold, C.bar2)
  local list = {}
  for _, b in pairs(T.bets) do list[#list + 1] = b end
  table.sort(list, function(a, b) return a.a > b.a end)
  for i = 1, 6 do
    local b = list[i]
    if b then
      local won = T.phase == "done" and payout({ b }, T.res) > 0
      kvRow(PX + 1, FT + 19 + i, PW2 - 2, betName(b):sub(1, 22), dollars(b.a) .. "  " .. ratio(b.n) .. ":1", won and C.green or C.text, C.bg)
    end
  end
  if #list > 6 then textW(PX + 1, FT + 26, PW2 - 2, "+ " .. (#list - 6) .. " more", C.dim, C.bg) end
  if #list == 0 then textW(PX + 1, FT + 20, PW2 - 2, "Click the table to place chips.", C.dim, C.bg) end
  local tot = total()
  kvRow(PX + 1, FT + 27, PW2 - 2, "On the table", money(tot), C.gold, C.bg)
  kvRow(PX + 1, FT + 28, PW2 - 2, "Best possible win", tot > 0 and money(maxWin(T.bets)) or "--", C.text, C.bg)
  textW(PX + 1, FT + 29, PW2 - 2, american() and (R().rl.basket and "House edge 5.26% (basket 0-00-1-2-3: 7.89%)" or "House edge 5.26%")
    or "House edge 2.70%", C.dim, C.bg)
end

local function draw()
  fill(X0, FT, PX - X0, FB - FT + 1, C.felt)
  text(X0, FT, string.rep("▀", PX - X0), C.shade, C.felt)
  drawLayout()
  region(M.reg, gx - 8, gy - 1, 89, 17, function(x, y) place(x, y, M.button == 1) end)
  drawPanel()
end

-- bottom bar: chip picker + spin
local function bar()
  local x = X0 + 2
  text(x, BT + 1, "CHIP", C.dim, C.bar)
  textW(x + 10, BT + 1, 20, " " .. dollars(T.chip) .. " per click", C.gold, C.bar2)
  for i, ch in ipairs(CHIPS) do
    local cx = x + (i - 1) * 7
    local on = T.chip == ch[1]
    text(cx, BT + 3, on and "◖" or " ", ch[2], C.bar)
    textW(cx + 1, BT + 3, 4, ch[4], ch[3], ch[2], "center")
    text(cx + 5, BT + 3, on and "◗" or " ", ch[2], C.bar)
    text(cx, BT + 4, on and " ▀▀▀▀ " or "      ", C.gold, C.bar)
    region(M.reg, cx, BT + 3, 6, 1, function() T.chip = ch[1]; saveCas(); drawWindow() end)
  end
  local bx = x
  local b2 = busy()
  bx = smallBtn(bx, BT + 5, " UNDO ", undo, b2)
  bx = smallBtn(bx, BT + 5, " CLEAR ", clear, b2)
  bx = smallBtn(bx, BT + 5, " REBET ", rebet, b2 or not T.last)
  smallBtn(bx, BT + 5, " 2x ", double, b2)
  textW(x, BT + 7, 42, "Limits " .. dollars(R().min) .. " - " .. dollars(R().max) .. " per spin", C.dim, C.bar)
  local tot = total()
  local l, col, dis = "SPIN  ·  " .. dollars(tot), C.green, not online() or tot <= 0
  if T.phase == "betting" then l, dis = "SENDING BET...", true
  elseif T.phase == "spin" then l, col, dis = "NO MORE BETS", C.gold, true end
  bigBtn(MX, BT + 1, MW, l, col, spin, dis)
  textW(MX, BT + 5, MW, "Left-click adds a chip · right-click removes one", C.dim, C.bar, "center")
  textW(MX, BT + 6, MW, "Space = spin", C.dim, C.bar, "center")
end

local function pump()
  if T.phase ~= "spin" then return false end
  local up = computer.uptime()
  if up - T.t0 >= SPIN_TIME then finish(); return true end
  if up - (T.frame or 0) >= 0.06 then
    T.frame = up
    if visible() and M.tab == "rl" then drawReel(reelPos()) end
  end
  return true
end

return {
  state = function() return T end,
  setState = function(t)
    if type(t) ~= "table" then return end
    T = t
    T.bets, T.undo, T.hist, T.chip = T.bets or {}, {}, T.hist or {}, T.chip or 5
    T.phase = T.phase or "idle"
  end,
  owns = function(rid) return T.rid == rid and T.phase == "betting" end,
  rid = function() return busy() and T.rid or nil end,
  onBet = onBet, draw = draw, bar = bar, pump = pump, spin = spin, busy = busy,
  fast = function() return T.phase == "spin" end,
  -- after a restart: a spin that was decided finishes now, a bet still waiting keeps waiting
  resume = function()
    if T.phase == "spin" and T.res then finish()
    elseif T.phase == "betting" then
      local st = betState(T.rid, T.seq)
      if st ~= "w" then onBet(T.rid, T.seq, st == "ok", "refused") end
    end
  end,
}
end)()

---------------------------------------------------------------- prize wheel
-- One free spin a day (at payday, 9 PM ET) plus any the house grants. Prizes
-- are new money / new shares - they don't come out of the house wallet. The
-- spin, its result and the prize are saved in your account file in one go;
-- the house is told (PRIZE) until it confirms it has logged it (PRIZEOK).
PW = (function()
local W = { phase = "idle", pos = 1, hist = {} }        -- saved with the casino file
local CX, CY, RXE, RYE, TW = X0 + 50, FT + 14, 44, 12, 11  -- the ring of 20 tiles
local SX = X0 + 104                                      -- right panel
local SWD = X1 - SX + 1

local function slots() return R().pw.slots end
local function isStock(v) return type(v) == "string" end
local function label(v)
  if isStock(v) then return v end
  if (tonumber(v) or 0) <= 0 then return "$0" end
  return "$" .. commas(v)
end
local function prizeText(v, px)
  if isStock(v) then return "1 share of " .. v .. (px and px > 0 and (" @ " .. money(px)) or "") end
  if (tonumber(v) or 0) <= 0 then return "no prize" end
  return money(v)
end
local function tileColor(v)
  if isStock(v) then return 0x2E5FA8 end
  if v <= 0 then return 0x2A2F36 end
  return v >= 300 and 0x1F8A4C or 0x166B3A
end
local function tilePos(i)
  local a = -math.pi / 2 + (i - 1) * 2 * math.pi / 20
  return floor(CX + RXE * math.cos(a) - TW / 2 + 0.5), floor(CY + RYE * math.sin(a) - 1 + 0.5)
end
local function drawTile(i, hot)
  local v = slots()[i]
  if v == nil then return end
  local x, y = tilePos(i)
  local b = hot and C.gold or tileColor(v)
  local f = hot and C.dark or ((not isStock(v) and v <= 0) and C.offT or C.text)
  textW(x, y, TW, hot and "▼" or "", f, b, "center")
  textW(x, y + 1, TW, label(v), f, b, "center")
  textW(x, y + 2, TW, isStock(v) and "1 share" or (v > 0 and "cash" or "nothing"), hot and C.dark or lerp(f, b, 0.35), b, "center")
end

local function spinsLeft() return ST.acct().spins or 0 end
local function nextFree()
  local e = toEastern(now())
  local s = ((CONFIG.PAYDAY_HOUR or 21) * 60 + (CONFIG.PAYDAY_MINUTE or 0)) * 60 - (e.hour * 3600 + e.min * 60 + e.sec)
  if s <= 0 then s = s + 86400 end
  return s
end

---------------------------------------------------------------- prizes
local function sendPrize(z)
  hsend("PRIZE", serialization.serialize({ i = z.id, p = z.p, v = z.v, px = z.px, t = z.t }))
end
-- give the prize (only once: z.st moves from "spin"/"price" to "send")
local function award(z)
  local pf = ST.acct()
  local v = z.v
  if isStock(v) then
    local px = ST.price(v)
    if not px and z.waitFrom and computer.uptime() - z.waitFrom > 90 then px = 0 end   -- no price to be had
    if not px then
      z.st, z.waitFrom = "price", z.waitFrom or computer.uptime()
      ST.fetch(v)
      ST.saveAcct()
      return false
    end
    ST.addShares(v, 1, px, "Prize Wheel")
    pf.deposits = pf.deposits + px          -- new value, not trading profit
    z.px = px
  elseif v > 0 then
    ST.bankTx(v, "PRIZE", "Prize Wheel: " .. money(v))
    pf.deposits = pf.deposits + v
    pf.prizeTotal = (pf.prizeTotal or 0) + v
  end
  z.st, z.waitFrom = "send", nil
  ST.saveAcct()
  table.insert(W.hist, 1, { v = v, px = z.px, t = z.t })
  while #W.hist > 8 do table.remove(W.hist) end
  sendPrize(z)
  return true
end
local function pending()
  local pf = ST.acct()
  pf.prz = pf.prz or {}
  return pf.prz
end

local function spin()
  if W.phase == "spin" then return end
  if spinsLeft() < 1 then return sayDraw("No spins left - a free spin comes with every payday (" .. fmtDurLong(nextFree()) .. ").") end
  if not online() then return sayDraw("The house server is offline - the wheel needs its prize list.") end
  if not R().pw.on then return sayDraw("The Prize Wheel is closed by the house right now.") end
  local pf = ST.acct()
  local sl = slots()
  local i = math.random(1, #sl)
  local z = { id = newRid("W"), st = "spin", v = sl[i], slot = i, t = floor(now()), p = PLAYER_NAME }
  pf.spins = pf.spins - 1
  table.insert(pending(), z)
  ST.saveAcct()                               -- the spin is used and its prize decided, in one save
  W.phase, W.id, W.target = "spin", z.id, i
  W.steps, W.k, W.next = 2 * 20 + ((i - W.pos) % 20) + 20, 0, computer.uptime()
  W.result = nil
  M.msg = "Spinning..."
  saveCas()
  redraw()
end

local function finishSpin()
  local z
  for _, p in ipairs(pending()) do if p.id == W.id then z = p end end
  W.phase, W.pos = "done", W.target or W.pos
  if z and z.st == "spin" then award(z) end
  W.result = z and { v = z.v, px = z.px, st = z.st } or nil
  if z then
    M.msg = isStock(z.v) and (z.st == "send" and ("You won " .. prizeText(z.v, z.px) .. " - it's in your Brokerage portfolio!") or
      ("You won a share of " .. z.v .. "! Getting its price...")) or
      ((z.v > 0) and ("You won " .. money(z.v) .. " - deposited into your savings!") or "No prize this time. Try again tomorrow!")
  end
  saveCas()
  redraw()
end

---------------------------------------------------------------- drawing
local function drawHub()
  local hx, hy, hw, hh = CX - 20, CY - 5, 41, 11
  fill(hx, hy, hw, hh, C.bg)
  text(hx, hy, "▗" .. string.rep("▄", hw - 2) .. "▖", C.bg, C.felt)
  text(hx, hy + hh - 1, "▝" .. string.rep("▀", hw - 2) .. "▘", C.bg, C.felt)
  textW(hx + 1, hy + 1, hw - 2, "★  P R I Z E   W H E E L  ★", C.gold, C.bg, "center")
  local r = W.result
  local cv = newCanvas(hw - 4, 8, C.bg)
  local big, sub, col = tostring(spinsLeft()), spinsLeft() == 1 and "SPIN AVAILABLE" or "SPINS AVAILABLE", C.gold
  if W.phase == "spin" then big, sub, col = "", "GOOD LUCK!", C.gold
  elseif W.phase == "done" and r then
    if isStock(r.v) then big, sub, col = "", r.st == "send" and ("1 SHARE OF " .. r.v .. "!") or ("1 SHARE OF " .. r.v .. " - PRICING..."), 0x6FA8FF
    elseif r.v > 0 then big, sub, col = "$" .. commas(r.v), "ADDED TO YOUR SAVINGS", C.green
    else big, sub, col = "0", "NO PRIZE THIS TIME", C.dim end
  end
  if big ~= "" then
    local sx = bigWidth(big, 2) <= hw - 4 and 2 or 1
    bigDraw(cv, big:gsub(",", ""), floor((hw - 4 - bigWidth(big:gsub(",", ""), sx)) / 2) + 1, 1, sx, 1, col)
  end
  crender(cv, hx + 2, hy + 3)
  if big == "" and W.phase == "done" and r and isStock(r.v) then textW(hx + 1, hy + 4, hw - 2, r.v, col, C.bg, "center") end
  textW(hx + 1, hy + 8, hw - 2, sub, col, C.bg, "center")
end

local function drawSidePanel()
  local x, w = SX, SWD
  fill(x, FT, w, FB - FT + 1, C.bar)
  local function head(y, s) fill(x, y, w, 1, C.bar2); text(x, y, " " .. s .. " ", C.gold, C.bar2) end
  head(FT, "YOUR SPINS")
  kvRow(x + 1, FT + 1, w - 2, "Available", tostring(spinsLeft()), C.gold)
  kvRow(x + 1, FT + 2, w - 2, "Next free spin", "in " .. fmtDurLong(nextFree()), C.text)
  textW(x + 1, FT + 3, w - 2, "Free daily at " .. string.format("%d:%02d", ((CONFIG.PAYDAY_HOUR or 21) - 1) % 12 + 1, CONFIG.PAYDAY_MINUTE or 0)
    .. ((CONFIG.PAYDAY_HOUR or 21) >= 12 and " PM" or " AM") .. " ET (payday)", C.dim, C.bar)
  head(FT + 5, "ON THE WHEEL")
  local zeros, cash, stocks, sum, lo, hi = 0, 0, {}, 0, nil, nil
  for _, v in ipairs(slots()) do
    if isStock(v) then stocks[#stocks + 1] = v
    elseif v <= 0 then zeros = zeros + 1
    else cash, sum = cash + 1, sum + v; lo, hi = min(lo or v, v), max(hi or v, v) end
  end
  local n = #slots()
  kvRow(x + 1, FT + 6, w - 2, "Cash prizes", cash .. (lo and ("  " .. dollars(lo) .. "-" .. dollars(hi)) or ""), C.green)
  kvRow(x + 1, FT + 7, w - 2, "Stock prizes", tostring(#stocks), 0x6FA8FF)
  textW(x + 1, FT + 8, w - 2, "  " .. table.concat(stocks, " "), C.dim, C.bar)
  kvRow(x + 1, FT + 9, w - 2, "Nothing", tostring(zeros), C.dim)
  kvRow(x + 1, FT + 10, w - 2, "Average cash", money(n > 0 and sum / n or 0) .. "/spin", C.text)
  textW(x + 1, FT + 11, w - 2, "All " .. n .. " slots are equally likely.", C.dim, C.bar)
  head(FT + 13, "YOUR PRIZES")
  for i = 1, 8 do
    local h = W.hist[i]
    if h then
      local e = h.t and toEastern(h.t)
      kvRow(x + 1, FT + 13 + i, w - 2, e and string.format("%02d/%02d", e.month, e.day) or "", prizeText(h.v, h.px):sub(1, 22),
        isStock(h.v) and 0x6FA8FF or ((h.v or 0) > 0 and C.green or C.dim))
    end
  end
  if #W.hist == 0 then textW(x + 1, FT + 14, w - 2, "Nothing won yet.", C.dim, C.bar) end
  local wait, unsent = 0, 0
  for _, z in ipairs(pending()) do if z.st == "price" then wait = wait + 1 elseif z.st == "send" then unsent = unsent + 1 end end
  textW(x + 1, FT + 23, w - 2, wait > 0 and ("Waiting for a stock price (" .. wait .. ")...") or "", C.gold, C.bar)
  textW(x + 1, FT + 24, w - 2, unsent > 0 and ("Not logged by the house yet: " .. unsent) or "", C.dim, C.bar)
  textW(x + 1, FT + 26, w - 2, "Prizes are new money - they are", C.dim, C.bar)
  textW(x + 1, FT + 27, w - 2, "not taken from the house wallet.", C.dim, C.bar)
end

local function draw()
  fill(X0, FT, SX - X0, FB - FT + 1, C.felt)
  text(X0, FT, string.rep("▀", SX - X0), C.shade, C.felt)
  for i = 1, #slots() do drawTile(i, W.phase ~= "idle" and W.pos == i) end
  drawHub()
  drawSidePanel()
end

local function bar()
  local x = X0 + 2
  text(x, BT + 1, "SPINS", C.dim, C.bar)
  textW(x + 10, BT + 1, 20, " " .. spinsLeft() .. (spinsLeft() == 1 and " spin" or " spins") .. " left", C.gold, C.bar2)
  textW(x, BT + 3, 42, "Free spin every day at payday (9 PM ET).", C.dim, C.bar)
  textW(x, BT + 4, 42, "The house can also give out extra spins.", C.dim, C.bar)
  textW(x, BT + 6, 42, "Cash goes to your Bank savings, shares", C.dim, C.bar)
  textW(x, BT + 7, 42, "to your Brokerage portfolio.", C.dim, C.bar)
  local dis = W.phase == "spin" or spinsLeft() < 1 or not online()
  bigBtn(MX, BT + 1, MW, W.phase == "spin" and "SPINNING..." or (spinsLeft() < 1 and "NO SPINS LEFT" or "SPIN THE WHEEL"), C.gold, spin, dis)
  textW(MX, BT + 5, MW, spinsLeft() < 1 and ("Next free spin in " .. fmtDurLong(nextFree())) or "Space = spin", C.dim, C.bar, "center")
end

local function pump()
  if W.phase ~= "spin" then return false end
  local up = computer.uptime()
  if up < W.next then return true end
  local old = W.pos
  W.pos = W.pos % 20 + 1
  W.k = W.k + 1
  if visible() and M.tab == "pw" then drawTile(old, false); drawTile(W.pos, true) end
  if W.k >= W.steps then finishSpin(); return true end
  local f = W.k / W.steps
  W.next = up + 0.03 + 0.42 * f * f * f
  return true
end

-- every few seconds: prices that came in, prizes the house hasn't logged
local function retry()
  local pf = ST.acct()
  if not pf.prz then return end
  for _, z in ipairs(pf.prz) do
    if z.st == "price" then
      if award(z) then
        if W.result and W.id == z.id then W.result.px, W.result.st = z.px, z.st end
        M.msg = "Your share of " .. z.v .. " is in your portfolio at " .. money(z.px or 0) .. "."
        redraw()
      end
    elseif z.st == "send" then sendPrize(z) end
  end
end

local function onHouse(kind, a)
  if kind == "PRIZEOK" then
    local list = pending()
    for i, z in ipairs(list) do
      if z.id == a and z.st == "send" then table.remove(list, i); ST.saveAcct(); return end
    end
  elseif kind == "GRANTS" then
    local ok, list = pcall(serialization.unserialize, a)
    if not ok or type(list) ~= "table" then return end
    local pf = ST.acct()
    pf.gids = pf.gids or {}
    local got = 0
    for _, g in ipairs(list) do
      if type(g) == "table" and (g.p == PLAYER_NAME or g.p == "*") and tonumber(g.n) then
        local have = false
        for _, id in ipairs(pf.gids) do if id == g.id then have = true end end
        if not have then
          pf.spins = (pf.spins or 0) + floor(tonumber(g.n))
          pf.gids[#pf.gids + 1] = g.id
          while #pf.gids > 60 do table.remove(pf.gids, 1) end
          got = got + floor(tonumber(g.n))
        end
        local acked = false
        for _, nm in ipairs(g.a or {}) do if nm == PLAYER_NAME then acked = true end end
        if not acked then hsend("GRANTOK", g.id, PLAYER_NAME) end
      end
    end
    if got > 0 then
      ST.saveAcct()
      M.msg = "The house gave you " .. got .. " free Prize Wheel spin" .. (got == 1 and "" or "s") .. "!"
      redraw()
    end
  end
end

return {
  state = function() return W end,
  setState = function(t) if type(t) == "table" then W = t; W.hist = W.hist or {}; W.pos = W.pos or 1 end end,
  draw = draw, bar = bar, pump = pump, spin = spin, retry = retry, onHouse = onHouse,
  fast = function() return W.phase == "spin" end,
  busy = function() return W.phase == "spin" end,
  -- after a restart: a spin that was decided gets its prize now
  resume = function()
    for _, z in ipairs(pending()) do
      z.waitFrom = nil
      if z.st == "spin" then award(z) end
    end
    if W.phase == "spin" then W.phase = "done"; W.pos = W.target or W.pos end
  end,
  -- the free spin count shown on other screens
  redrawTiles = function() if visible() and M.tab == "pw" then drawSidePanel() end end,
}
end)()

---------------------------------------------------------------- window, menus, keys
local function howBJ()
  local rl = R().bj
  dialog("How to play Blackjack", {
    "Get closer to 21 than the dealer without going over. Cards 2-10 count their",
    "value, J/Q/K count 10, an Ace counts 1 or 11. Ace + a 10-card is Blackjack.",
    "HIT takes a card, STAND keeps your total, DOUBLE doubles the bet for exactly",
    "one more card, SPLIT turns a pair into two hands (each with its own bet).",
    "Blackjack pays " .. payText(rl.pays) .. ", a win pays 1 to 1, a tie (push) gives the bet back.",
    "The dealer " .. (rl.h17 and "hits soft 17." or "draws to 16 and stands on all 17s (soft 17 too).") .. " No insurance.",
    "With a friend: Casino > Play with a friend, find them, invite. Same dealer;",
    "each of you bets and is paid from your own account.",
  }, { { "OK" } })
end
local function howRide()
  local rr = R().ride
  dialog("How to play Let it Ride", {
    "A crash game. Bet, press LAUNCH: the multiplier starts at 1.00x and climbs",
    "faster and faster - until it crashes at a random point. CASH OUT before the",
    "crash and you win your bet times the multiplier. Wait too long: you lose it.",
    string.format("House edge %.1f%%: a target of x is reached in %.1f%% / x of rounds, and", rr.edge * 100, (1 - rr.edge) * 100),
    string.format("About %.1f%% of rounds bust at 1.00x. Max multiplier %s.", (1 - (1 - rr.edge) / 1.01) * 100, multText(rr.cap)),
    "AUTO CASH OUT cashes out for you at the target (also when the window is closed).",
  }, { { "OK" } })
end
local function howRL()
  dialog("How to play Roulette", {
    "Pick a chip value, then click the table to place chips (right-click removes one).",
    "A number pays 35:1, a line between two numbers (split) 17:1, the bottom edge of a",
    "column (street, 3 numbers) 11:1, a corner (4) 8:1, the bottom corner between two",
    "columns (six line) 5:1, the corner at 0 / 1 (" .. (R().rl.wheel == "european" and "first four" or "0-00-1-2-3 basket") .. ").",
    "Dozens and columns pay 2:1; red/black, odd/even, 1-18/19-36 pay 1:1.",
    "SPIN sends all chips as one bet; winnings (bet included) come back after the spin.",
  }, { { "OK" } })
end
local function howPW()
  dialog("About the Prize Wheel", {
    "Every day at payday (9 PM ET) you get one free spin; the house can give extra spins.",
    "The wheel has 20 slots, each equally likely: cash, a share of stock, or nothing.",
    "Cash goes straight into your Bank savings; a share goes into your Brokerage",
    "portfolio, priced at the market (or the last close when the market is shut).",
    "Prizes are new money - they don't come out of the house wallet.",
  }, { { "OK" } })
end
local function aboutCas()
  dialog("About Casino", {
    "Lymanos Casino - your casino balance is your Brokerage cash.",
    "Every bet goes to the house server (houseview.lua) on port " .. CONFIG.HOUSE_PORT .. ";",
    "it confirms each bet and pays each result. Nothing unanswered is ever lost:",
    "it is saved in your account file and re-sent until the house answers.",
    "Blackjack tables with a friend use port " .. CONFIG.CASINO_PORT .. ".",
    "House: " .. (online() and (R().name .. " (" .. tostring(HS.addr):sub(1, 8) .. ")") or "not heard from"),
  }, { { "OK" } })
end

drawWindow = function()
  M.reg = {}
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ Casino - " .. ({ bj = "Blackjack", ride = "Let it Ride", rl = "Roulette", pw = "Prize Wheel" })[M.tab], true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(M.reg, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(M.reg, bx + 7, WY + 1, 3, 1, function() M.open = false; M.focus = false; activeApp = nil; drawAll() end)
  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  text(WX + 2, WY + 2, " Casino ", K.black, K.face)
  text(WX + 10, WY + 2, " Help ", K.black, K.face)
  region(M.reg, WX + 2, WY + 2, 8, 1, function()
    popupMenu(WX + 2, WY + 3, {
      { "Blackjack", function() M.tab = "bj" end },
      { "Let it Ride", function() M.tab = "ride" end },
      { "Roulette", function() M.tab = "rl" end },
      { "Prize Wheel", function() M.tab = "pw" end },
      { "-" },
      { "Play solo", function() setMode("solo") end },
      { "Play with a friend...", function() M.tab = "bj"; setMode("multi") end },
      { "Leave / close table", leaveTable },
      { "-" },
      { "Close Casino", function() M.open = false; activeApp = nil end },
    })
  end)
  region(M.reg, WX + 10, WY + 2, 6, 1, function()
    popupMenu(WX + 10, WY + 3, { { "How to play Blackjack...", howBJ }, { "How to play Let it Ride...", howRide },
      { "How to play Roulette...", howRL }, { "About the Prize Wheel...", howPW },
      { "-" }, { "About Casino...", aboutCas } })
  end)
  drawHeader(true)
  if M.tab == "bj" then drawTable() elseif M.tab == "ride" then drawRide()
  elseif M.tab == "rl" then RLT.draw() else PW.draw() end
  drawBar()
  drawStatus()
end

local function key(ch, code)
  if code == 28 or code == 156 then
    local v = tonumber(M.input)
    M.focus, M.input = false, ""
    if v then setBet(v) end
    drawWindow()
  elseif code == 1 then M.focus, M.input = false, ""; drawWindow()
  elseif code == 14 then M.input = M.input:sub(1, -2); drawBetBox()
  elseif ch and ch > 0 then
    local c = string.char(ch)
    if c:match("[%d%.]") and #M.input < 10 then M.input = M.input .. c; drawBetBox() end
  end
end

local function hotkey(ch, code)
  local c = (ch and ch > 0 and ch < 128) and string.char(ch):lower() or ""
  if M.tab == "bj" then
    if c == "h" then myAction("hit") elseif c == "s" then myAction("stand")
    elseif c == "d" then myAction("double") elseif c == "p" then myAction("split")
    elseif (code == 57 or code == 28) and not inRound() then deal() end
  elseif M.tab == "rl" then if code == 57 or code == 28 then RLT.spin() end
  elseif M.tab == "pw" then if code == 57 or code == 28 then PW.spin() end
  elseif code == 57 or code == 28 then rideButton() end
end

---------------------------------------------------------------- engine room
local function pumpTable()
  if GV or not S or #S.q == 0 then return end
  local up = computer.uptime()
  if up < (S.at or 0) then return end
  local st = table.remove(S.q, 1)
  exec(S, st)
  S.at = up + (DELAY[st[1]] or 0.4)
  changed()
end

local function pump()
  pumpTable()
  RLT.pump()
  PW.pump()
  if RD.phase == "count" or RD.phase == "fly" then
    local up = computer.uptime()
    if RD.phase == "count" and up >= RD.t0 then RD.phase, M.lastFrame = "fly", 0 end
    if RD.phase == "fly" then
      local m = rideMult(up - RD.t0)
      if RD.auto and not RD.out and RD.auto <= RD.crash and m >= RD.auto then cashOut(RD.auto) end
      if m >= RD.crash then return crashNow() end
    end
    if up - M.lastFrame >= 0.15 then
      M.lastFrame = up
      if visible() and M.tab == "ride" then drawGraph(); drawRideButton(); drawHeader(false)
      elseif visible() then drawStatus() end
    end
  end
end

local function fast() return (not GV and S ~= nil and #S.q > 0) or RD.phase == "count" or RD.phase == "fly" or RLT.fast() or PW.fast() end

local function tick()
  local up = computer.uptime()
  if up - M.lastRetry >= 3 then M.lastRetry = up; retry() end
  if not online() and up - M.lastHello >= 10 then
    M.lastHello = up
    pcall(wlan.broadcast, CONFIG.HOUSE_PORT, "HOUSE", "HELLO")
  elseif online() and up - (M.lastHi or 0) >= 15 then   -- so the house lists this computer as online
    M.lastHi = up
    hsend("HI", PLAYER_NAME)
  end
  if not GV and S.phase == "bet" and S.waitSince and up - S.waitSince > 45 then
    maybeDeal(true); M.msg = "Dealt in the players who were ready."; changed()
  end
  local g = S.seats[2]
  if g and not GV then
    if not g.gone and up - (g.heard or up) > 75 then removeGuest("lost connection"); changed()
    elseif S.phase == "play" and S.turn and S.turn[1] == 2 and #S.q == 0 and up - (S.turnAt or up) > 45 then
      act(S, 2, S.turn[2], "stand"); M.msg = tostring(g.name) .. " took too long - their hand stands."; changed()
    elseif g.gone and (S.phase == "bet" or S.phase == "done") then table.remove(S.seats, 2); changed()
    elseif up - M.lastAlive >= 4 then M.lastAlive = up; sendState() end
  elseif GV and up - M.lastAlive >= 4 then
    M.lastAlive = up
    tsend(GV.host, "ALIVE", GV.id)
  end
  if visible() and not fast() then
    if not GV and S.waitSince and M.tab == "bj" then drawWindow() else drawHeader(false); drawStatus() end
  end
end

local function load()
  M.hist, M.crashes, M.mode, M.inv, M.sent = {}, {}, "solo", nil, false
  me, RD, GV, S = { settled = true }, { phase = "idle" }, nil, nil
  RLT.setState({ phase = "idle" })
  PW.setState({ phase = "idle" })
  local raw = readFile(casPath())
  if raw then
    local ok, t = pcall(serialization.unserialize, raw)
    if ok and type(t) == "table" then
      S = type(t.S) == "table" and t.S or nil
      if type(t.me) == "table" then me = t.me end
      if type(t.rd) == "table" and t.rd.phase then RD = t.rd end
      M.hist = type(t.hist) == "table" and t.hist or {}
      M.crashes = type(t.crashes) == "table" and t.crashes or {}
      M.bet, M.rbet, M.auto = tonumber(t.bet) or M.bet, tonumber(t.rbet) or M.rbet, tonumber(t.auto) or 0
      RLT.setState(t.rl)
      PW.setState(t.pw)
    end
  end
  if not S or type(S.seats) ~= "table" or not S.seats[1] or type(S.shoe) ~= "string" then S = newTable() end
  S.q, S.at, S.id = S.q or {}, 0, nil
  if S.seats[2] then                      -- a friend's seat can't survive a restart
    table.remove(S.seats, 2)
    for i = #S.q, 1, -1 do if S.q[i][2] == 2 then table.remove(S.q, i) end end
    if S.turn and S.turn[1] == 2 then S.turn = nil end
  end
  if (S.phase == "play" or S.phase == "deal" or S.phase == "dealer") and #S.q == 0 and not S.turn then
    if S.phase == "deal" then S.phase = "play" end
    push(S, { "next" })
  end
  S.seats[1].name = PLAYER_NAME
  S.waitSince = nil
  if S.phase == "bet" then maybeDeal() end
  local L = ledger()
  if me.rid and not me.settled then
    if me.guest then
      me.settled = true
      if L[me.rid] then settle(me.rid, "void", "VOID (restarted at a friend's table)", "") end
    elseif me.waiting then
      local st = betState(me.rid, me.waiting.seq)
      if st ~= "w" then bjBet(me.rid, me.waiting.seq, st == "ok", "refused") end
    elseif S.phase == "done" then settleMine(S, 1) end
  end
  if RD.phase == "betting" then
    local st = RD.rid and betState(RD.rid, RD.seq)
    if st ~= "w" then rideBet(RD.rid, RD.seq, st == "ok", "refused") end
  elseif RD.phase == "count" or RD.phase == "fly" then
    if not RD.out then                   -- restarted mid-ride: auto cash out counts, else it crashed
      RD.phase = "fly"
      if RD.auto and RD.auto <= RD.crash then cashOut(RD.auto)
      else settle(RD.rid, 0, string.format("CRASHED %.2fx", RD.crash), "restarted mid-ride") end
    end
    RD.phase = "crashed"
    rideEnd()
  end
  RLT.resume()
  PW.resume()
  for rid, r in pairs(L) do             -- anything else unfinished: every bet goes back
    if not r.res and not r.void and rid ~= (inRound() and me.rid) and rid ~= (rideBusy() and RD.rid) and rid ~= RLT.rid() then
      r.void = "interrupted"
    end
  end
  ST.saveAcct()
  saveCas()
end

onBet = function(rid, seq, ok, why)
  if RD.rid == rid then rideBet(rid, seq, ok, why)
  elseif RLT.owns(rid) then RLT.onBet(rid, seq, ok, why)
  else bjBet(rid, seq, ok, why) end
end
onPaid = function() redraw() end

return {
  drawWindow = function() drawWindow() end,
  regions = function() return M.reg end,
  button = function(b) M.button = b end,      -- mouse button of the click being handled (1 = right)
  isOpen = function() return M.open end,
  open = function() M.open = true; activeApp = "casino" end,
  focus = function(v)
    if v ~= nil then M.focus = v; if not v then M.input = "" end end
    return M.focus
  end,
  key = key, hotkey = hotkey,
  onHouse = onHouse, onTable = onTable,
  pump = pump, tick = tick, fast = fast,
  load = load, save = function() pcall(saveCas) end,
  houseWallet = function() return HS.wallet, online() end,
  busy = function()
    return inRound() or rideBusy() or RLT.busy() or PW.busy() or GV ~= nil or (S ~= nil and S.seats[2] ~= nil)
      or next(ledger()) ~= nil or #(ST.acct().prz or {}) > 0
  end,
  alert = function()
    local T, si = myView()
    return T ~= nil and T.phase == "play" and T.turn ~= nil and T.turn[1] == si and not visible()
  end,
}
end)()


------------------------------------------------------------------- BANK
-- Lymanos Bank: your savings account (the money every app spends from and
-- pays into), your investments (held in Brokerage, shown here), your salary,
-- and the size of the whole economy.
--   * The balance lives in your account file next to your Brokerage holdings,
--     so a trade changes both in one save. Every change goes through
--     ST.bankTx and shows up in the transaction history.
--   * Salary: CONFIG.SALARY / 365 is deposited every day at PAYDAY_HOUR
--     (Eastern). If Lymanos was off, missed paydays are paid when it's back.
--   * Economy: every Lymanos announces its owner's savings + investments on
--     BANK_PORT; the house wallet comes from houseview's broadcast.
BANK = (function()
local C = {
  green = 0x0B6B3A, green2 = 0x14874C, mint = 0x2FB36B, pale = 0xE6F4EA, page = 0xF2F6F3,
  white = 0xFFFFFF, ink = 0x17251C, dim = 0x6A7D71, line = 0xD8E6DC, red = 0xC2362B,
  gold = 0xC99A1E, blue = 0x2E78C7, violet = 0x7B52B9, teal = 0x1A9AA0,
}
local CLASS = { { "Stock", "Stocks", C.green2 }, { "Crypto", "Crypto", C.gold }, { "Option", "Options", C.violet }, { "Forex", "Forex", C.blue } }
local X0, X1 = WX + 1, WX + WW - 2
local CW = X1 - X0 + 1
local HY, TOP, BOT, SY = WY + 3, WY + 4, WY + WH - 3, WY + WH - 2
local LX, LW = X0 + 1, 70                 -- left column
local RX = LX + LW + 1                    -- right column
local RW = X1 - RX                        -- (one column of page margin on the right)
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local V = { tab = "assets", reg = {}, open = false, scroll = 0, sig = nil, lastStat = 0, lastSave = 0, lastRec = 0 }
-- economy: other players as last heard, the house wallet, and a 7-day history (15 min steps)
local E = { users = {}, house = nil, ht = {}, hv = {} }
local HIST_STEP, HIST_N = 900, 672

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
  local a = math.abs(n)
  local s
  if a >= 1e9 then s = string.format("%.2fB", a / 1e9)
  elseif a >= 1e6 then s = string.format("%.2fM", a / 1e6)
  elseif a >= 1e4 then s = string.format("%.1fK", a / 1e3)
  else return money(n) end
  return (n < 0 and "-$" or "$") .. s
end
local function pct(v) return string.format(v >= 9.95 and "%.0f%%" or "%.1f%%", v) end
local function visible() return activeApp == "bank" and not overlay and not LOCK.isLocked() end
local function realTime(t) return t and t > 1e9 end
local function dayStamp(t)
  local e = toEastern(t)
  return MONTHS[e.month] .. string.format(" %02d", e.day)
end
local function clockText(h, m)
  if SETTINGS.clock24 then return string.format("%02d:%02d", h, m) end
  local hh = h % 12
  return string.format("%d:%02d %s", hh == 0 and 12 or hh, m, h < 12 and "AM" or "PM")
end
local function acctNo()
  local n = 7
  for i = 1, #PLAYER_NAME do n = (n * 31 + PLAYER_NAME:byte(i)) % 9973 end
  for i = 1, 6 do n = (n * 17 + wlan.address:byte(i)) % 9973 end
  return string.format("%04d", n)
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
-- 5x7 pixel digits, 4 text rows tall, on a canvas of fixed width w: every cell
-- of the area is painted each time, so nothing needs clearing first (no flicker)
local function bigText(x, y, w, s, col, bgc)
  local cv = newCanvas(w, 8, bgc)
  local cx = 1
  for i = 1, #s do
    local ch = s:sub(i, i)
    local g, gw = FONT[ch], glyphW(ch)
    if g then
      for r = 0, 6 do for c = 1, gw do
        if g:sub(r * gw + c, r * gw + c) == "1" then cset(cv, cx + c - 1, r + 1, col) end
      end end
    end
    cx = cx + gw + 1
  end
  crender(cv, x, y)
end
local function bigMoney(x, y, w, n, col, bgc)
  local s = money(n)
  if bigWidth(s) > w then s = s:gsub("%.%d%d$", "") end
  if bigWidth(s) > w then s = short(n) end
  bigText(x, y, w, s, col, bgc)
end

---------------------------------------------------------------- cards
-- Full draws (opening the app, switching tabs) paint the cards; refreshes only
-- repaint the contents, cell for cell, so the screen never flashes.
local function card(x, y, w, h, title, right)
  if V.full then
    fill(x, y, w, h, C.white)
    text(x + 2, y, title, C.green, C.white)
    text(x + 2, y + 1, string.rep("─", w - 4), C.line, C.white)
  end
  local slot = w - unicode.len(title) - 6
  textW(x + w - 2 - slot, y, slot, right or "", C.dim, C.white, "right")
end
-- one table row painted left to right with no gaps: { {width, text, color, align}, ... }
local function cells(x, y, list)
  for _, c in ipairs(list) do
    textW(x, y, c[1], c[2] or "", c[3] or C.ink, C.white, c[4])
    x = x + c[1]
  end
end
local function linkBtn(x, y, s, fn)
  text(x, y, s, C.white, C.green2)
  if V.full then region(V.reg, x, y, unicode.len(s), 1, fn) end
end
-- a horizontal bar split in parts: { {value, color}, ... }
local function stackBar(x, y, w, parts, total)
  local used = 0
  for i, p in ipairs(parts) do
    local cw = (i == #parts) and (w - used) or floor(p[1] / total * w + 0.5)
    cw = max(0, min(cw, w - used))
    if cw > 0 then fill(x + used, y, cw, 1, p[2]) end
    used = used + cw
  end
  if used < w then fill(x + used, y, w - used, 1, C.line) end
end

---------------------------------------------------------------- salary
local function salaryDaily() return cents((CONFIG.SALARY or 0) / 365) end
local function payMinute() return (CONFIG.PAYDAY_HOUR or 21) * 60 + (CONFIG.PAYDAY_MINUTE or 0) end
-- the most recent payday that has already happened (as a day number), and the time now
local function lastPayday(t)
  local e = toEastern(t)
  local day = daysFromCivil(e.year, e.month, e.day)
  if e.hour * 60 + e.min >= payMinute() then return day, e end
  return day - 1, e
end
local function secondsToPayday(t)
  local e = toEastern(t)
  local s = payMinute() * 60 - (e.hour * 3600 + e.min * 60 + e.sec)
  if s <= 0 then s = s + 86400 end
  return s
end
local function paydayText(t)
  local s = secondsToPayday(t)
  local when = clockText(CONFIG.PAYDAY_HOUR or 21, CONFIG.PAYDAY_MINUTE or 0) .. " ET"
  local e = toEastern(t)
  local today = e.hour * 60 + e.min < payMinute()
  return (today and "today at " or "tomorrow at ") .. when, s
end

local announce   -- forward
local function paySalary()
  local t = now()
  if not realTime(t) then return end            -- no real clock yet: never pay on a guess
  local pf = ST.acct()
  local last = lastPayday(t)
  if not pf.lastPay then pf.lastPay = last; ST.saveAcct(); return end   -- first payday is the next one
  local n = last - pf.lastPay
  if n <= 0 then return end
  local days = min(n, CONFIG.SALARY_BACKPAY_DAYS or 30)
  local amt = salaryDaily() * days
  pf.lastPay = last
  pf.spins = (pf.spins or 0) + days * (CONFIG.DAILY_SPINS or 1)   -- the Prize Wheel's daily free spin
  if amt > 0 then
    ST.bankTx(amt, "SALARY", days == 1 and "Salary deposit" or ("Salary deposit · " .. days .. " days"))
    pf.deposits = pf.deposits + amt          -- new money, not trading profit
  end
  ST.saveAcct()
  V.sig = nil
  announce()
end

---------------------------------------------------------------- economy
local function mine()
  local pf = ST.acct()
  local _, inv = ST.holdings()
  return pf.cash, inv
end
local function houseWallet()
  local w, live = CAS.houseWallet()
  if w then E.house = { w = w, at = now() } end
  return E.house and E.house.w, live
end
-- all players (me included, live) -> list sorted by total, totals
local function economy()
  local s, p = mine()
  for _, u in pairs(E.users) do u.me = nil end
  E.users[PLAYER_NAME] = { s = s, p = p, sal = CONFIG.SALARY or 0, at = now(), me = true }
  local list, ts, tp, sal = {}, 0, 0, 0
  for name, u in pairs(E.users) do
    list[#list + 1] = { name = name, u = u }
    ts, tp, sal = ts + (u.s or 0), tp + (u.p or 0), sal + (u.sal or 0)
  end
  table.sort(list, function(a, b) return (a.u.s + a.u.p) > (b.u.s + b.u.p) end)
  local hw = houseWallet() or 0
  return ts + tp + hw, list, ts, tp, hw, sal
end

announce = function()
  local s, p = mine()
  V.lastStat = computer.uptime()
  pcall(wlan.broadcast, CONFIG.BANK_PORT, "BANK", "STAT",
    serialization.serialize({ n = PLAYER_NAME, s = cents(s), p = cents(p), sal = CONFIG.SALARY or 0 }))
end

local function onMessage(from, kind, a)
  if kind ~= "STAT" then return end
  local ok, t = pcall(serialization.unserialize, a)
  if not ok or type(t) ~= "table" or type(t.n) ~= "string" or t.n == PLAYER_NAME then return end
  E.users[t.n:sub(1, 24)] = { s = tonumber(t.s) or 0, p = tonumber(t.p) or 0, sal = tonumber(t.sal) or 0, at = now(), addr = from }
end

local function saveEcon()
  local users = {}
  for name, u in pairs(E.users) do users[name] = { s = u.s, p = u.p, sal = u.sal, at = u.at } end
  local hv = {}
  for i, v in ipairs(E.hv) do hv[i] = string.format("%.2f", v) end
  writeFile(CONFIG.ECON_FILE, serialization.serialize({ users = users, house = E.house,
    t0 = E.ht[1], hv = table.concat(hv, ",") }))
  V.lastSave = computer.uptime()
end
local function loadEcon()
  E.users, E.house, E.ht, E.hv = {}, nil, {}, {}
  local raw = readFile(CONFIG.ECON_FILE)
  if not raw then return end
  local ok, t = pcall(serialization.unserialize, raw)
  if not ok or type(t) ~= "table" then return end
  if type(t.users) == "table" then
    for name, u in pairs(t.users) do
      if type(u) == "table" then E.users[name] = { s = tonumber(u.s) or 0, p = tonumber(u.p) or 0, sal = tonumber(u.sal) or 0, at = tonumber(u.at) } end
    end
  end
  if type(t.house) == "table" and tonumber(t.house.w) then E.house = { w = tonumber(t.house.w), at = tonumber(t.house.at) } end
  local t0 = tonumber(t.t0)
  if t0 and type(t.hv) == "string" then
    local i = 0
    for v in t.hv:gmatch("[^,]+") do
      E.ht[#E.ht + 1], E.hv[#E.hv + 1] = t0 + i * HIST_STEP, tonumber(v) or 0
      i = i + 1
    end
  end
end
-- one point per 15 minutes (gaps while Lymanos was off are filled flat)
local function record()
  local t = now()
  if not realTime(t) then return end
  local slot = floor(t / HIST_STEP) * HIST_STEP
  local size = economy()
  local last = E.ht[#E.ht]
  if last and slot <= last then E.hv[#E.hv] = size; return end
  if last and slot - last > HIST_STEP then
    local lv = E.hv[#E.hv]
    for tt = last + HIST_STEP, min(slot - HIST_STEP, last + HIST_STEP * HIST_N), HIST_STEP do E.ht[#E.ht + 1], E.hv[#E.hv + 1] = tt, lv end
  end
  E.ht[#E.ht + 1], E.hv[#E.hv + 1] = slot, size
  while #E.ht > HIST_N do table.remove(E.ht, 1); table.remove(E.hv, 1) end
end

---------------------------------------------------------------- the bank page
local function header()
  fill(X0, HY, CW, 1, C.green)
  text(X0 + 1, HY, " ⌂ ", C.green, C.white)
  text(X0 + 5, HY, (CONFIG.BANK_NAME or "Lymanos Bank"):upper(), C.white, C.green)
  local x = X0 + 30
  for _, t in ipairs({ { "assets", "  Assets  " }, { "economy", "  Economy  " } }) do
    local on = V.tab == t[1]
    text(x, HY, t[2], on and C.green or C.pale, on and C.white or C.green2)
    region(V.reg, x, HY, #t[2], 1, function() V.tab, V.scroll = t[1], 0; BANK.drawWindow() end)
    x = x + #t[2] + 1
  end
  textW(X1 - 40, HY, 40, "Welcome, " .. tostring(PLAYER_NAME) .. "  ", C.pale, C.green, "right")
end

local TXROWS = BOT - TOP - 20
local TXKIND = { SALARY = C.mint, CASINO = C.violet, STOCK = C.blue, OPTION = C.teal, ADJUST = C.gold, OPEN = C.green, PRIZE = 0xD0459A }
local function txList()
  local pf = ST.acct()
  local x, y, w = LX, TOP + 16, LW
  local n = #pf.bank
  V.scroll = max(0, min(V.scroll, n - TXROWS))
  card(x, y, w, BOT - y + 1, "TRANSACTIONS", n > TXROWS
    and string.format("%d-%d of %d  ·  scroll for more", V.scroll + 1, min(n, V.scroll + TXROWS), n)
    or (n .. (n == 1 and " transaction" or " transactions")))
  if V.full then
    cells(x + 2, y + 2, { { 8, "DATE", C.dim }, { 30, "DESCRIPTION", C.dim }, { 13, "AMOUNT", C.dim, "right" }, { 1 }, { 14, "BALANCE", C.dim, "right" } })
  end
  for r = 1, TXROWS do
    local yy = y + 2 + r
    local line = pf.bank[r + V.scroll]
    if line then
      local t, kind, amt, bal, desc = line:match("^(%d+)\t(%u+)\t(%S+)\t(%S+)\t(.*)$")
      t, amt, bal = tonumber(t), tonumber(amt) or 0, tonumber(bal) or 0
      cells(x + 1, yy, { { 1 }, { 7, t and realTime(t) and dayStamp(t) or "--", C.dim }, { 2, "●", TXKIND[kind] or C.dim },
        { 29, desc or "" }, { 13, (amt > 0 and "+" or "") .. money(amt), amt > 0 and C.green2 or C.ink, "right" }, { 1 },
        { 14, money(bal), C.dim, "right" }, { 1 } })
    else
      textW(x + 1, yy, w - 2, (n == 0 and r == 2) and "  No transactions yet." or "", C.dim, C.white)
    end
  end
end

local function drawAssets()
  local pf = ST.acct()
  local t = now()
  -- savings
  card(LX, TOP + 1, LW, 8, "SAVINGS ACCOUNT  ····" .. acctNo(), "● Open")
  text(LX + LW - 8, TOP + 1, "●", C.mint, C.white)
  bigMoney(LX + 2, TOP + 3, LW - 4, pf.cash, C.green, C.white)
  local inM, outM = 0, 0
  local e = realTime(t) and toEastern(t)
  for _, line in ipairs(pf.bank) do
    local tt, kind, amt = line:match("^(%d+)\t(%u+)\t(%S+)")
    tt, amt = tonumber(tt), tonumber(amt) or 0
    if e and tt and realTime(tt) and kind ~= "OPEN" then
      local e2 = toEastern(tt)
      if e2.month == e.month and e2.year == e.year then
        if amt > 0 then inM = inM + amt else outM = outM - amt end
      end
    end
  end
  cells(LX + 2, TOP + 7, { { 22, "Available balance", C.dim }, { LW - 26, "This month  +" .. money(inM) .. "  ·  -" .. money(outM), C.dim, "right" } })
  -- salary
  card(LX, TOP + 10, LW, 5, "SALARY")
  local sal = CONFIG.SALARY or 0
  if sal > 0 then
    cells(LX + 2, TOP + 12, { { 22, money(sal) .. " / year" },
      { LW - 26, money(salaryDaily()) .. " deposited daily at " .. clockText(CONFIG.PAYDAY_HOUR or 21, CONFIG.PAYDAY_MINUTE or 0) .. " ET", C.dim, "right" } })
    V.payY = TOP + 13
  else
    textW(LX + 2, TOP + 12, LW - 4, "No salary is set on this computer.", C.dim, C.white)
    V.payY = nil
  end
  txList()
  -- investments
  local list, inv = ST.holdings()
  card(RX, TOP + 1, RW, 8, "INVESTMENTS", "held in Brokerage")
  bigMoney(RX + 2, TOP + 3, RW - 4, inv, C.ink, C.white)
  cells(RX + 2, TOP + 7, { { 20, "Portfolio value", C.dim }, { RW - 24, "Net worth " .. money(pf.cash + inv), C.green, "right" } })
  -- allocation
  card(RX, TOP + 10, RW, 9, "ALLOCATION")
  local by = {}
  for _, h in ipairs(list) do by[h.kind] = (by[h.kind] or 0) + h.value end
  local parts = {}
  for _, c in ipairs(CLASS) do if (by[c[1]] or 0) > 0 then parts[#parts + 1] = { by[c[1]], c[3], c[2] } end end
  local iw = RW - 4
  if inv > 0 then
    stackBar(RX + 2, TOP + 12, iw, parts, inv)
    for k = 0, 1 do
      local a, b = parts[k * 2 + 1], parts[k * 2 + 2]
      local function lbl(p) return p and (p[3] .. "  " .. pct(p[1] / inv * 100) .. "  " .. short(p[1])) or "" end
      cells(RX + 2, TOP + 14 + k, { { 2, a and "■" or "", a and a[2] }, { 30, lbl(a) }, { 2, b and "■" or "", b and b[2] }, { iw - 34, lbl(b) } })
    end
    -- diversity: effective number of holdings = 1 / sum(weight^2)
    local hh = 0
    for _, h in ipairs(list) do hh = hh + (h.value / inv) ^ 2 end
    local eff = hh > 0 and 1 / hh or 0
    local word = eff >= 6 and "well diversified" or (eff >= 3 and "diversified" or (eff >= 1.5 and "concentrated" or "very concentrated"))
    textW(RX + 2, TOP + 17, iw, string.format("Diversity %.1f (%s)  ·  largest %s %s", eff, word, list[1].label, pct(list[1].value / inv * 100)), C.dim, C.white)
  else
    fill(RX + 2, TOP + 12, iw, 1, C.line)
    textW(RX + 2, TOP + 14, iw, "Nothing invested yet.", C.dim, C.white)
    textW(RX + 2, TOP + 15, iw, "", C.dim, C.white)
    textW(RX + 2, TOP + 17, iw, "", C.dim, C.white)
  end
  -- holdings (its layout changes between "none" and a list: tick() redraws fully then)
  local hy = TOP + 20
  card(RX, hy, RW, BOT - hy + 1, "HOLDINGS", #list > 0 and (#list .. " position" .. (#list == 1 and "" or "s")) or nil)
  if #list == 0 then
    textW(RX + 2, hy + 3, iw, "Buy stocks, crypto or options in the Brokerage app;", C.dim, C.white)
    textW(RX + 2, hy + 4, iw, "they are listed here with their share of your portfolio.", C.dim, C.white)
    linkBtn(RX + 2, hy + 6, "  Open Brokerage  ", function() openStockApp(); drawAll() end)
    return
  end
  if V.full then
    cells(RX + 2, hy + 2, { { 20, "HOLDING", C.dim }, { 10, "QTY", C.dim, "right" }, { 1 }, { 13, "VALUE", C.dim, "right" }, { 2 }, { 19, "SHARE", C.dim } })
  end
  local stale = false
  local bw = RW - 56
  for i = 1, BOT - hy - 3 do
    local h = list[i]
    local yy = hy + 2 + i
    if h then
      local col = C.dim
      for _, c in ipairs(CLASS) do if c[1] == h.kind then col = c[3] end end
      cells(RX + 2, yy, { { 2, "■", col }, { 18, h.label .. (h.live and "" or "*") }, { 10, h.qty, C.dim, "right" }, { 1 },
        { 13, money(h.value), C.ink, "right" }, { 2 } })
      local share = inv > 0 and h.value / inv or 0
      local fw = share > 0 and max(1, floor(share * bw + 0.5)) or 0
      if fw > 0 then fill(RX + 48, yy, fw, 1, col) end
      if fw < bw then fill(RX + 48 + fw, yy, bw - fw, 1, C.pale) end
      cells(RX + 48 + bw, yy, { { 1 }, { 5, pct(share * 100), C.dim } })
      if not h.live then stale = true end
    else
      textW(RX + 2, yy, iw, "", C.ink, C.white)
    end
  end
  textW(RX + 2, BOT, iw, stale and "* no live price right now - shown at what you paid" or "", C.dim, C.white)
end

local function econChart(x, y, w, rows)
  local n = #E.hv
  local cv = newCanvas(w, rows * 2, C.white)
  if n < 2 then
    crender(cv, x, y)
    textW(x, y + floor(rows / 2), w, "The history fills in every 15 minutes while Lymanos runs.", C.dim, C.white, "center")
    textW(x, y + rows, w, "", C.dim, C.white)
    return
  end
  local lo, hi = math.huge, -math.huge
  for i = 1, n do lo, hi = min(lo, E.hv[i]), max(hi, E.hv[i]) end
  local span = max(hi - lo, math.abs(hi) * 0.02, 1)       -- at least 2%: small moves stay small
  local mid = (hi + lo) / 2
  lo, hi = mid - span / 2, mid + span / 2
  local pad = (hi - lo) * 0.12
  lo, hi = lo - pad, hi + pad
  local ph = rows * 2
  local function py(v) return ph - floor((v - lo) / (hi - lo) * (ph - 1) + 0.5) end
  local px0, py0
  for c = 1, w do
    local f = (c - 1) / (w - 1) * (n - 1) + 1
    local i = min(n, floor(f))
    local v = i < n and (E.hv[i] + (E.hv[i + 1] - E.hv[i]) * (f - i)) or E.hv[n]
    local yy = py(v)
    for y2 = yy + 1, ph do cset(cv, c, y2, C.pale) end
    if px0 then cline(cv, px0, py0, c, yy, C.green2) else cset(cv, c, yy, C.green2) end
    px0, py0 = c, yy
  end
  crender(cv, x, y)
  cells(x, y + rows, { { floor(w / 2), dayStamp(E.ht[1]), C.dim }, { w - floor(w / 2), "now", C.dim, "right" } })
end

local function drawEconomy()
  local size, list, ts, tp, hw, sal = economy()
  local t = now()
  local lw2 = 80
  local rx2, rw2 = LX + lw2 + 1, X1 - (LX + lw2 + 1)
  card(LX, TOP + 1, lw2, 8, "SIZE OF THE ECONOMY", "live")
  bigMoney(LX + 2, TOP + 3, lw2 - 4, size, C.green, C.white)
  local players = #list
  local ago
  for i = #E.ht, 1, -1 do if E.ht[i] <= t - 86400 then ago = E.hv[i]; break end end
  local ch = (ago and ago > 0) and (size - ago) or nil
  cells(LX + 2, TOP + 7, { { 58, "Savings + investments of " .. players .. " player" .. (players == 1 and "" or "s") .. " + the house wallet", C.dim },
    { 18, ch and ("24h " .. (ch >= 0 and "+" or "") .. pct(ch / ago * 100)) or "", ch and (ch >= 0 and C.green2 or C.red) or C.dim, "right" } })
  local lo, hi
  for _, v in ipairs(E.hv) do lo, hi = min(lo or v, v), max(hi or v, v) end
  card(LX, TOP + 10, lw2, 14, "ECONOMY OVER TIME", lo and ("last 7 days · " .. short(lo) .. " - " .. short(hi)) or "last 7 days")
  econChart(LX + 2, TOP + 12, lw2 - 4, 10)
  card(LX, TOP + 25, lw2, BOT - TOP - 24, "WHERE THE MONEY IS")
  local parts = { { ts, C.green2, "Savings accounts" }, { tp, C.blue, "Investments" }, { hw, C.gold, "House wallet (casino)" } }
  if size > 0 then stackBar(LX + 2, TOP + 27, lw2 - 4, parts, size) end
  for i, p in ipairs(parts) do
    cells(LX + 2, TOP + 28 + i, { { 2, "■", p[2] }, { 30, p[3] }, { 20, money(p[1]), C.ink, "right" }, { 2 },
      { 10, size > 0 and pct(p[1] / size * 100) or "--", C.dim, "right" }, { lw2 - 68 } })
  end
  local hw2, live = houseWallet()
  textW(LX + 2, TOP + 33, lw2 - 4, hw2 and (live and "House wallet is live from the house server." or
    ("House server not heard from - last known wallet " .. money(hw2) .. ".")) or "The house server hasn't been heard from yet.", C.dim, C.white)
  -- salary
  card(rx2, TOP + 1, rw2, 8, "SALARY")
  local vw = rw2 - 22
  cells(rx2 + 2, TOP + 3, { { 18, "Your salary", C.dim }, { vw, money(CONFIG.SALARY or 0) .. " / year", C.ink, "right" } })
  cells(rx2 + 2, TOP + 4, { { 18, "Paid daily", C.dim }, { vw, money(salaryDaily()) .. " at " .. clockText(CONFIG.PAYDAY_HOUR or 21, CONFIG.PAYDAY_MINUTE or 0) .. " ET", C.ink, "right" } })
  cells(rx2 + 2, TOP + 5, { { 18, "All players", C.dim }, { vw, "+" .. money(cents(sal / 365)) .. " new money / day", C.green2, "right" } })
  V.payY2 = TOP + 7
  -- players (+ the house as the last row)
  local py0 = TOP + 10
  card(rx2, py0, rw2, BOT - py0 + 1, "PLAYERS", players .. " + house")
  if V.full then
    cells(rx2 + 2, py0 + 2, { { 16, "NAME", C.dim }, { 12, "SAVINGS", C.dim, "right" }, { 1 }, { 12, "INVESTED", C.dim, "right" }, { 1 }, { 9, "SHARE", C.dim, "right" }, { 4 } })
    textW(rx2 + 2, BOT, rw2 - 4, "● online now   ○ last known values", C.dim, C.white)
  end
  local rows = BOT - py0 - 4
  local houseRow = (hw and hw ~= 0) and min(#list + 1, rows) or nil
  for i = 1, rows do
    local yy = py0 + 2 + i
    local it = list[i]
    if i == houseRow then
      cells(rx2 + 2, yy, { { 2, "◆", C.gold }, { 14, "The House" }, { 12, short(hw), C.ink, "right" }, { 1 }, { 12 }, { 1 },
        { 9, size > 0 and pct(hw / size * 100) or "--", C.dim, "right" }, { 4 } })
    elseif it then
      local u = it.u
      local fresh = u.me or (u.at and t - u.at < 60)
      cells(rx2 + 2, yy, { { 2, "●", fresh and C.mint or C.line }, { 14, it.name .. (u.me and " (you)" or "") },
        { 12, short(u.s), C.ink, "right" }, { 1 }, { 12, short(u.p), C.ink, "right" }, { 1 },
        { 9, size > 0 and pct((u.s + u.p) / size * 100) or "--", C.dim, "right" }, { 4 } })
    else
      textW(rx2 + 2, yy, rw2 - 4, "", C.ink, C.white)
    end
  end
end

-- the "next salary" line: repainted every second in place
local function drawCountdown()
  if (CONFIG.SALARY or 0) <= 0 then return end
  local t = now()
  if not realTime(t) then return end
  local when, s = paydayText(t)
  if V.tab == "assets" and V.payY then
    textW(LX + 2, V.payY, LW - 4, "Next deposit " .. money(salaryDaily()) .. " " .. when .. "  ·  in " .. fmtDurLong(s), C.green2, C.white)
  elseif V.tab == "economy" and V.payY2 then
    textW(LX + 83, V.payY2, X1 - LX - 85, "Next payday " .. when .. " · in " .. fmtDurLong(s), C.green2, C.white)
  end
end

local function drawStatus()
  fill(WX + 1, SY, WW - 2, 1, K.face)
  local _, live = houseWallet()
  textW(WX + 2, SY, 90, V.tab == "assets" and "Savings are spent by Brokerage and Casino and paid back into this account."
    or "Economy = every player's savings + investments + the house wallet.", K.black, K.face)
  text(WX + 93, SY, "│", K.sh, K.face)
  textW(WX + 94, SY, 48, "Port " .. CONFIG.BANK_PORT .. "  ·  house " .. (live and "online" or "offline"), K.black, K.face)
end

-- the layout: when it changes the page needs a full draw, otherwise a refresh is enough
local function layout()
  if V.tab ~= "assets" then return "economy" end
  local list = ST.holdings()
  return "assets" .. (#list > 0 and "+" or "-")
end
-- what's shown: when it changes the contents are repainted (no clearing)
local function signature()
  local pf = ST.acct()
  local _, inv = ST.holdings()
  local s = string.format("%.2f|%.2f|%d|%s|%d", pf.cash, inv, #pf.bank, pf.bank[1] or "", V.scroll)
  if V.tab == "economy" then
    local size, list = economy()
    local _, live = houseWallet()
    s = s .. string.format("|%.2f|%d|%d|%s", size, #list, #E.hv, tostring(live))
  end
  return s
end

local function drawWindow()
  V.reg, V.full = {}, true
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ Bank - " .. (V.tab == "assets" and "Assets" or "Economy"), true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(V.reg, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(V.reg, bx + 7, WY + 1, 3, 1, function() V.open = false; activeApp = nil; drawAll() end)
  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  text(WX + 2, WY + 2, " Bank ", K.black, K.face)
  text(WX + 8, WY + 2, " Help ", K.black, K.face)
  region(V.reg, WX + 2, WY + 2, 6, 1, function()
    popupMenu(WX + 2, WY + 3, {
      { "Assets", function() V.tab = "assets" end },
      { "Economy", function() V.tab = "economy" end },
      { "-" },
      { "Open Brokerage", function() openStockApp() end },
      { "Open Casino", function() CAS.open() end },
      { "-" },
      { "Close Bank", function() V.open = false; activeApp = nil end },
    })
  end)
  region(V.reg, WX + 8, WY + 2, 6, 1, function()
    popupMenu(WX + 8, WY + 3, { { "About the Bank...", function()
      dialog("About " .. (CONFIG.BANK_NAME or "Lymanos Bank"), {
        "Your savings account is where your money lives. Brokerage buys and Casino",
        "bets are paid from it; stock sales, option payouts and winnings go back in.",
        "Stocks, crypto and options stay in Brokerage and are shown here.",
        "Salary: " .. money(CONFIG.SALARY or 0) .. " a year, paid as " .. money(salaryDaily()) .. " every day at "
          .. clockText(CONFIG.PAYDAY_HOUR or 21, CONFIG.PAYDAY_MINUTE or 0) .. " ET.",
        "Only the owner can change it (SALARY in lymanos.lua). Missed paydays are paid",
        "when Lymanos runs again (up to " .. (CONFIG.SALARY_BACKPAY_DAYS or 30) .. " days).",
      }, { { "OK" } })
    end } })
  end)
  header()
  fill(X0, TOP, CW, BOT - TOP + 1, C.page)
  if V.tab == "assets" then drawAssets() else drawEconomy() end
  V.full = false
  drawCountdown()
  drawStatus()
  V.lay, V.sig = layout(), signature()
end

local function refresh()
  if V.tab == "assets" then drawAssets() else drawEconomy() end
  drawCountdown()
end

local function tick()
  local up = computer.uptime()
  paySalary()
  if up - V.lastStat >= 20 then announce() end
  if up - V.lastRec >= 60 then
    V.lastRec = up
    record()
    if up - V.lastSave >= 900 then saveEcon() end
  end
  if visible() then
    if layout() ~= V.lay then drawWindow()
    else
      local s = signature()
      if s ~= V.sig then V.sig = s; refresh() else drawCountdown() end
    end
  end
end

return {
  drawWindow = function() drawWindow() end,
  regions = function() return V.reg end,
  isOpen = function() return V.open end,
  open = function() V.open = true; activeApp = "bank" end,
  tick = tick, onMessage = onMessage,
  load = function() loadEcon(); V.lastRec = computer.uptime(); announce() end,   -- first point after a minute of listening
  save = function() pcall(saveEcon) end,
  scroll = function(x, y, dir)
    if V.tab == "assets" and x <= LX + LW and y > TOP + 18 then
      V.scroll = max(0, V.scroll - dir * 3)
      txList()
    end
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
  local ok = responding(t)
  if lastPacket then
    parts[#parts + 1] = "LSC " .. (ok and ((snap and snap.signalOn) and "charging" or "idle") or "offline")
  end
  local fd, _, farmOk = LG.feedState()
  if farmOk and fd.farm then parts[#parts + 1] = "Farm " .. (fd.farm.active and "running" or "idle") end
  if chessAlert then parts[#parts + 1] = "Chess: your move!" end
  if CAS.alert() then parts[#parts + 1] = "Casino: your turn!" end
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
local REFRESH = { 30, 60, 120, 300 }
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

local function casinoBusy()
  if not CAS.busy() then return false end
  dialog("Casino", { "Finish your casino round first (and wait for any payout).",
    "Casino bets belong to the account of the current name." }, { { "OK" } })
  return true
end

local function setUser(n)
  n = n:gsub("^%s+", ""):gsub("%s+$", "")
  if casinoBusy() then return end
  SETTINGS.userName = (n ~= "") and n or nil
  PLAYER_NAME = SETTINGS.userName or CONFIG.PLAYER_NAME or ("Player-" .. wlan.address:sub(1, 4))
  pcall(ST.reloadAccount)
  pcall(CAS.load)
  changed("Name saved - Brokerage now uses " .. PLAYER_NAME .. "'s account")
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
  note(L, 11, LWd - 2, "Your name is used by Chess and is your Bank account")
  note(L, 12, LWd - 2, "(Brokerage + Casino). Click a box, type, press Enter.")

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
    { "System:", tostring(SETTINGS.systemName or "Lymanos") .. "  (Lymanos 2.2)" },
    { "User:", tostring(PLAYER_NAME) },
    { "Memory:", string.format("%d K used of %d K", floor((total - free) / 1024), floor(total / 1024)) },
    { "Network card:", wlan.address:sub(1, 8) .. (wlan.isWireless() and " (wireless)" or " (wired)") },
    { "Settings file:", CONFIG.SETTINGS_FILE },
    { "Chess port:", tostring(CONFIG.CHESS_PORT) .. "    LSC port: " .. CONFIG.PORT },
    { "Casino ports:", CONFIG.CASINO_PORT .. " (tables)    " .. CONFIG.HOUSE_PORT .. " (house)" },
    { "Bank:", CONFIG.BANK_PORT .. " (economy)    salary " .. commas(CONFIG.SALARY or 0) .. "/yr" },
  }
  for i, r in ipairs(rows) do
    label(L, 25 + i, r[1])
    textW(L + FX - 18, 25 + i, LWd - FX + 16, r[2], K.black, K.face)
  end
  note(L, 33, LWd - 2, "Settings save automatically. CONFIG at the top of")
  note(L, 34, LWd - 2, "lymanos.lua holds the defaults and advanced options.")
  button(regions, L, 38, 24, "Reset to defaults", function()
    if casinoBusy() then return end
    dialog("Reset Settings", { "Put every setting back to its default?",
      "(Your name goes back to the CONFIG default too.)" }, {
      { "Yes", function()
          SETTINGS.userName, SETTINGS.systemName, SETTINGS.lockMins, SETTINGS.lockStyle = nil, "Lymanos", 30, 1
          SETTINGS.clock24, SETTINGS.desk, SETTINGS.stockRefresh, SETTINGS.optReal = false, 1, nil, nil
          SETTINGS.logsQ = { "nb", "gaps" }
          K.desk = DESK_COLORS[1][2]
          CONFIG.STOCK_REFRESH, CONFIG.OPTION_REAL_PRICES = 60, true
          PLAYER_NAME = CONFIG.PLAYER_NAME or ("Player-" .. wlan.address:sub(1, 4))
          pcall(ST.reloadAccount)
          pcall(CAS.load)
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

  -- brokerage
  groupBox(R - 2, 23, RWd + 2, 9, "Brokerage")
  label(R, 25, "Refresh prices:")
  cycler(R + FX - 18, 25, 22, "every " .. CONFIG.STOCK_REFRESH .. " s", function(d)
    local v = step(REFRESH, CONFIG.STOCK_REFRESH, d)
    CONFIG.STOCK_REFRESH, SETTINGS.stockRefresh = v, v; changed()
  end)
  label(R, 27, "Option prices:")
  cycler(R + FX - 18, 27, 22, CONFIG.OPTION_REAL_PRICES ~= false and "Yahoo + formula" or "Formula only", function()
    CONFIG.OPTION_REAL_PRICES = CONFIG.OPTION_REAL_PRICES == false
    SETTINGS.optReal = CONFIG.OPTION_REAL_PRICES; changed()
  end)
  note(R, 29, RWd - 2, "Faster refreshes use more internet requests.")

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
  listRegions = {}
  panelRegions = {}
  ST.resetRegions()
  SYS.resetRegions()
  if not keepOverlay then overlay = nil end
  drawDesktop()
  if activeApp == "viewer" then
    LG.draw(t)
    region(regions, WX + 2, WY + 2, 6, 1, fileMenu)
    region(regions, WX + 8, WY + 2, 6, 1, viewMenu)
    region(regions, WX + 14, WY + 2, 6, 1, helpMenu)
  elseif activeApp == "chess" then
    drawChessWindow()
  elseif activeApp == "stock" then
    ST.drawWindow()
  elseif activeApp == "sys" then
    SYS.drawWindow()
  elseif activeApp == "settings" then
    SET.drawWindow()
  elseif activeApp == "casino" then
    CAS.drawWindow()
  elseif activeApp == "bank" then
    BANK.drawWindow()
  end
  drawTaskbar(t)
end

------------------------------------------------------------- MAIN LOOP
local oldW, oldH = gpu.getResolution()

local function main()
  local mw, mh = gpu.maxResolution()
  if mw < W or mh < H then error("Lymanos needs a tier 3 GPU and screen (160x50).", 0) end
  gpu.setResolution(W, H)
  loadSaved()
  loadGame()
  ST.load()
  CAS.load()
  BANK.load()
  drawAll()
  requestUpdate()
  pcall(wlan.broadcast, CONFIG.HOUSE_PORT, "HOUSE", "HELLO")      -- ask the house for its rules
  if ST.hasTickers() then ST.refreshAll() end

  local lastTick = 0
  local wasResponding = nil
  while running do
    gpu.flush()                        -- show this pass's drawing in one go
    local ev = { event.pull((ST.busy() or CAS.fast()) and 0.05 or 0.5) }
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
      elseif activeApp == "chess" and hit(panelRegions, x, y) then
        -- chess side panel
      elseif activeApp == "sys" then
        if not hit(SYS.regions(), x, y) then hit(regions, x, y) end
      elseif activeApp == "bank" then
        if not hit(BANK.regions(), x, y) then hit(regions, x, y) end
      elseif activeApp == "casino" then
        CAS.button(ev[5])
        local wasFocus = CAS.focus()
        CAS.focus(false)
        if not hit(CAS.regions(), x, y) then hit(regions, x, y) end
        if wasFocus and not CAS.focus() and activeApp == "casino" and not overlay then CAS.drawWindow() end
      elseif activeApp == "stock" then
        local wasFocus = ST.focus()
        ST.focus(false)
        if not hit(ST.regions(), x, y) then hit(regions, x, y) end
        if wasFocus and not ST.focus() and activeApp == "stock" and not overlay then ST.drawInput() end
      else
        hit(regions, x, y)
      end
    elseif name == "scroll" and not overlay and activeApp == "sys" then
      SYS.scroll(ev[3], ev[4], ev[5])
    elseif name == "scroll" and not overlay and activeApp == "viewer" then
      LG.scroll(ev[3], ev[4], ev[5])
    elseif name == "scroll" and not overlay and activeApp == "stock" then
      ST.scroll(ev[3], ev[4], ev[5])
    elseif name == "modem_message" and ev[4] == CONFIG.PORT and ev[6] == "LSCSTATS" then
      local from = ev[3]
      if not CONFIG.SENDER or from:sub(1, #CONFIG.SENDER) == CONFIG.SENDER then
        local changed = receive(from, ev[5], ev[8])
        statusMsg = changed and "New cycle data received" or "Update received"
        if not overlay then
          if activeApp == "viewer" then
            if changed then drawAll() else LG.tick(now()) end
          else drawTray(now()) end
        end
      end
    elseif name == "modem_message" and ev[4] == CONFIG.FUEL_PORT and ev[6] == "LSCFUEL" then
      LG.onFuel(ev[8])
    elseif name == "modem_message" and ev[4] == CONFIG.FARM_PORT and ev[6] == "TREEFARM" then
      LG.onFarm(ev[8])
    elseif name == "modem_message" and ev[4] == CONFIG.CHESS_PORT and ev[6] == "CHESS" then
      onChessMessage(ev[3], ev[5], ev[7], ev[8], ev[9])
    elseif name == "modem_message" and ev[4] == CONFIG.BANK_PORT and ev[6] == "BANK" then
      pcall(BANK.onMessage, ev[3], ev[7], ev[8])
    elseif name == "scroll" and not overlay and activeApp == "bank" then
      BANK.scroll(ev[3], ev[4], ev[5])
    elseif name == "modem_message" and ev[4] == CONFIG.HOUSE_PORT and ev[6] == "HOUSE" then
      local ok, e = pcall(CAS.onHouse, ev[3], ev[7], ev[8], ev[9], ev[10])
      if not ok then statusMsg = "Casino error: " .. tostring(e) end
    elseif name == "modem_message" and ev[4] == CONFIG.CASINO_PORT and ev[6] == "BJ" then
      local ok, e = pcall(CAS.onTable, ev[3], ev[5], ev[7], ev[8], ev[9], ev[10])
      if not ok then statusMsg = "Casino error: " .. tostring(e) end
    elseif name == "key_down" and activeApp == "casino" and not overlay then
      if CAS.focus() then CAS.key(ev[3], ev[4]) else CAS.hotkey(ev[3], ev[4]) end
    elseif name == "key_down" and activeApp == "stock" and ST.focus() and not overlay then
      ST.key(ev[3], ev[4])
    elseif name == "key_down" and activeApp == "settings" and SET.focus() and not overlay then
      SET.key(ev[3], ev[4])
    end

    ST.pump()
    local okc, ce = pcall(CAS.pump)
    if not okc then statusMsg = "Casino error: " .. tostring(ce) end
    if ST.hasInternet() and ST.hasTickers() and not ST.busy() and ST.due() then
      ST.refreshAll()
    end

    local up = computer.uptime()
    if running and up - lastTick >= 1 then
      lastTick = up
      local t = now()
      if LOCK.isLocked() then
        LOCK.tick(t)
      elseif not overlay then
        if activeApp == "viewer" then LG.tick(t)
        elseif activeApp == "stock" then ST.drawStatus() end
        drawTray(t)
      end
      SYS.tick(activeApp == "sys" and not overlay)
      pcall(ST.tick)
      pcall(CAS.tick)
      local okb, be = pcall(BANK.tick)
      if not okb then statusMsg = "Bank error: " .. tostring(be) end
      -- lock after the idle time set in Settings (0 = never)
      local mins = SETTINGS.lockMins or 0
      if mins > 0 and not LOCK.isLocked() and LOCK.idle() >= mins * 60 then LOCK.lock() end
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
pcall(ST.save)                     -- Brokerage: price + portfolio-value history
pcall(CAS.save)                    -- Casino: table + history (money is already in the account file)
pcall(BANK.save)                   -- Bank: economy history (balances are already in the account file)
gpu.setResolution(oldW, oldH)
rgpu.setBackground(0x000000)
rgpu.setForeground(0xFFFFFF)
term.clear()
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write(tostring(err) .. "\n")
end
