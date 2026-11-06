--[[
  lscview.lua  -  LSC Cycle Viewer (Windows 98 style)

  Runs on a second computer anywhere within wireless range of the
  lscstats computer. Receives copies of the charging-cycle log over a
  Wireless Network Card, stores them, and shows them in a retro
  desktop: a cycle list, a Nitrobenzene-per-cycle chart, live status
  and totals.

  Files written on this computer:
    /home/lscstats_copy.dat     latest copy exactly as received
    /home/lscview_archive.dat   long-term archive (keeps more than 8 cycles)

  Also includes a two-player Chess game: two computers running lscview
  can find each other and play over the same wireless card (port 4041),
  and Stock Track: a stock watchlist with a dashboard and price graphs
  (needs an Internet Card in this computer).

  Needs: tier 3 GPU + tier 3 screen (160x50) and a Wireless Network
  Card (tier 2 recommended). Mouse only. Exit: X button, Start >
  Shut Down, or Ctrl+C.
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  PORT = 4040,                 -- must match WIRELESS_PORT in lscstats.lua
  SENDER = nil,                -- nil = accept any lscstats computer, or put its card address
  ARCHIVE_MAX = 100,           -- cycles kept in the local archive
  GRAPH_CYCLES = 8,            -- cycles shown in the chart
  STALE_SECONDS = 75,          -- no packet for this long = "Not Responding"
  COPY_FILE = "/home/lscstats_copy.dat",
  ARCHIVE_FILE = "/home/lscview_archive.dat",

  -- Chess
  PLAYER_NAME = nil,           -- your name shown to your opponent, e.g. "Cam" (nil = auto)
  CHESS_PORT = 4041,           -- must be the same on both computers
  CHESS_FILE = "/home/lscview_chess.dat",   -- saved game (resumes after restart)

  -- Stock Track (needs an Internet Card)
  STOCK_PROVIDER = "yahoo",    -- "yahoo" (no key needed) or "finnhub" (free key from finnhub.io)
  FINNHUB_KEY = nil,           -- e.g. "abc123..." when STOCK_PROVIDER = "finnhub"
  STOCK_REFRESH = 60,          -- seconds between price refreshes
  STOCK_LOG_EVERY = 300,       -- seconds between saved history points (graph)
  STOCK_LOG_MAX = 390,         -- price points kept per ticker (5-min bars: about 5 trading days)
  STOCK_MAX_TICKERS = 12,
  STOCK_FILE = "/home/lscview_stocks.dat",
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

--------------------------------------------------------- 98 PALETTE
local K = {
  desk   = 0x008080,   -- teal desktop
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
local PLAYER_NAME = CONFIG.PLAYER_NAME or ("Player-" .. wlan.address:sub(1, 4))

local function requestUpdate()
  pcall(wlan.broadcast, CONFIG.PORT, "LSCSTATS_REQ")
end

------------------------------------------------------- REAL-WORLD TIME
local TIME_PATHS = { "/tmp/.lscview_clock", "/home/.lscview_clock" }
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
           min = floor(secs % 3600 / 60), sec = secs % 60, tz = dst and "EDT" or "EST" }
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
  saveArchive()
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

local function crender(cv, sx, sy)
  for r = 1, ceil(cv.h / 2) do
    local top, bot = cv.g[r * 2 - 1], cv.g[r * 2] or cv.g[r * 2 - 1]
    local x = 1
    while x <= cv.w do
      local t, b = top[x], bot[x]
      local x2 = x + 1
      while x2 <= cv.w and top[x2] == t and bot[x2] == b do x2 = x2 + 1 end
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

-- Window geometry
local WX, WY, WW, WH = 14, 2, 144, 44
local LIST = { x = 58, y = 9, w = 98, h = 14 }
local LIST_ROWS = LIST.h - 3
local COLS = {
  { "#", 6 }, { "Started", 20 }, { "Stopped", 20 },
  { "Duration", 10 }, { "Rate L/s", 10 }, { "Nitrobenzene L", 16 },
}

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

local function drawDesktop()
  fill(1, 1, W, 46, K.desk)
  drawIcon(3, 2, "pc", "My Computer")
  drawIcon(3, 8, "doc", "LSC Log")
  drawIcon(3, 14, "bin", "Recycle Bin")
  local cv = newCanvas(8, 8, K.desk)
  pieceOnCanvas(cv, "n", K.white, K.black)
  crender(cv, 4, 20)
  textW(1, 24, 12, "Chess", K.white, K.desk, "center")
  region(regions, 1, 8, 12, 5, function() activeApp = "viewer"; drawAll() end)
  region(regions, 1, 20, 12, 5, function() openChess(); drawAll() end)
  -- Stock Track icon: a little rising chart
  fill(4, 26, 8, 3, K.white)
  text(4, 26, "    ▗▞▀", 0x007A00, K.white)
  text(4, 27, "▁▗▄▞   ", 0x007A00, K.white)
  text(4, 28, "▔▔▔▔▔▔▔▔", K.sh, K.white)
  textW(1, 29, 12, "Stock Track", K.white, K.desk, "center")
  region(regions, 1, 26, 12, 4, function() openStockApp(); drawAll() end)
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
  taskButton(11, 30, " ▣ LSC Cycle Viewer", "viewer")
  local tx = 42
  if chessOpen then
    taskButton(tx, 30, chessAlert and " ▣ Chess - YOUR MOVE!" or " ▣ Chess", "chess")
    tx = tx + 31
  end
  if stockAppOpen and stockAppOpen() then taskButton(tx, 30, " ▣ Stock Track", "stock") end
  drawTray(t)
end

------------------------------------------------------------ WINDOW PARTS
local function drawTitle(t)
  local title = "LSC Cycle Viewer - " .. CONFIG.COPY_FILE:match("[^/]+$")
  if lastPacket and not responding(t) then title = title .. " (Not Responding)" end
  titleBar(WX + 1, WY + 1, WW - 2, "▣ " .. title, true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
end

local function selectedCycle()
  if not selected then return nil end
  for _, c in ipairs(archive) do if c.start == selected then return c end end
end

local function drawStatusBar(t)
  local y = WY + WH - 2
  local x = WX + 1
  local w = WW - 2
  fill(x, y, w, 1, K.face)
  local parts = {
    { statusMsg, 60 },
    { #archive .. " cycles in archive", 24 },
    { "Port " .. CONFIG.PORT .. (wlan.isWireless() and " (wireless)" or " (wired)"), 24 },
    { lastPacket and ("Updated " .. fmtTime(lastPacket)) or "No data yet", w - 60 - 24 - 24 - 4 },
  }
  local cx = x
  for i, p in ipairs(parts) do
    if i > 1 then text(cx, y, "│", K.sh, K.face) end
    textW(cx + 1, y, p[2], p[1], K.black, K.face)
    cx = cx + p[2] + 1
  end
end

local function kv(x, y, label, value, color)
  textW(x, y, 15, label, K.black, K.face)
  textW(x + 15, y, 22, value, color or K.black, K.face)
end

-- per-second values only overwrite text (no blanking = no flicker)
local function drawLive(t)
  local x, y = 18, 9
  local ok = responding(t)
  if not lastPacket then
    kv(x, y + 2, "Connection:", "Waiting for data...", K.sh)
  else
    kv(x, y + 2, "Connection:", ok and "Online" or "Not responding", ok and K.green or K.red)
  end
  kv(x, y + 3, "Sender:", lastFrom and lastFrom:sub(1, 8) or "--")
  kv(x, y + 4, "Distance:", lastDist and (string.format("%d", floor(lastDist + 0.5)) .. " blocks") or "--")
  kv(x, y + 5, "Last packet:", lastPacket and fmtTime(lastPacket) or "--")
  kv(x, y + 6, "Packet age:", lastPacket and (fmtDurLong(t - lastPacket) .. " ago") or "--")

  local cur = snap and snap.signalOn and snap.current or nil
  if snap then
    kv(x, y + 8, "Fuel signal:", snap.signalOn and "CHARGING" or "IDLE", snap.signalOn and K.green or K.sh)
  else
    kv(x, y + 8, "Fuel signal:", "--")
  end
  if cur then
    local el = floor(t - cur.start)
    kv(x, y + 9, "Current cycle:", "#" .. tostring(cur.id))
    kv(x, y + 10, "Started:", fmtStamp(cur.start))
    kv(x, y + 11, "Elapsed:", fmtDur(el), K.navy)
    kv(x, y + 12, "NB so far:", commas(el * (snap.rate or 0)) .. " L")
  else
    kv(x, y + 9, "Current cycle:", "none")
    kv(x, y + 10, "Started:", "--")
    kv(x, y + 11, "Elapsed:", "--")
    kv(x, y + 12, "NB so far:", "--")
  end
  kv(x, y + 13, "Burn rate:", snap and (commas(snap.rate or 0) .. " L/s") or "--")
end

local function drawTotals()
  local x, y, w, h = 16, 26, 40, 17
  groupBox(x, y, w, h, "Archive Totals")
  local n = #archive
  local tot, totDur, longest = 0, 0, 0
  for _, c in ipairs(archive) do
    tot, totDur = tot + (c.used or 0), totDur + (c.dur or 0)
    longest = max(longest, c.dur or 0)
  end
  kv(x + 2, y + 2, "Cycles stored:", n .. " / " .. CONFIG.ARCHIVE_MAX)
  kv(x + 2, y + 3, "Avg duration:", n > 0 and fmtDurLong(totDur / n) or "--")
  kv(x + 2, y + 4, "Longest:", n > 0 and fmtDurLong(longest) or "--")
  kv(x + 2, y + 5, "Avg NB/cycle:", n > 0 and (commas(tot / n) .. " L") or "--")
  kv(x + 2, y + 6, "Total NB:", commas(tot) .. " L", K.navy)
  kv(x + 2, y + 8, "Copy file:", CONFIG.COPY_FILE:match("[^/]+$"))
  kv(x + 2, y + 9, "Archive file:", CONFIG.ARCHIVE_FILE:match("[^/]+$"))

  local c = selectedCycle()
  text(x + 2, y + 11, string.rep("─", w - 4), K.sh, K.face)
  if c then
    kv(x + 2, y + 12, "Selected:", "Cycle #" .. tostring(c.id), K.navy)
    kv(x + 2, y + 13, "Duration:", fmtDurLong(c.dur) .. " (" .. commas(c.dur) .. " s)")
    kv(x + 2, y + 14, "Nitrobenzene:", commas(c.used) .. " L")
  else
    kv(x + 2, y + 12, "Selected:", "(click a row)", K.sh)
  end
end

local function drawList()
  local L = LIST
  listRegions = {}
  bevel(L.x, L.y, L.w, L.h, "sunken", K.face, K.white)
  -- header (raised column buttons)
  local cx = L.x + 1
  for _, col in ipairs(COLS) do
    textW(cx, L.y + 1, col[2], " " .. col[1], K.black, K.face)
    text(cx + col[2], L.y + 1, "│", K.sh, K.face)
    cx = cx + col[2] + 1
  end
  fill(cx, L.y + 1, L.x + L.w - 2 - cx, 1, K.face)

  -- rows, newest first
  local n = #archive
  local maxScroll = max(0, n - LIST_ROWS)
  scroll = max(0, min(scroll, maxScroll))
  for r = 1, LIST_ROWS do
    local idx = n - scroll - r + 1
    local y = L.y + 1 + r
    local c = archive[idx]
    if c then
      local sel = (c.start == selected)
      local b, f = sel and K.navy or K.white, sel and K.white or K.black
      local cells = { "#" .. tostring(c.id), fmtStamp(c.start), fmtStamp(c.stop),
                      fmtDur(c.dur), commas(c.rate or 0), commas(c.used or 0) }
      cx = L.x + 1
      for i, col in ipairs(COLS) do
        textW(cx, y, col[2] + 1, " " .. cells[i], f, b, i >= 4 and "right" or nil)
        cx = cx + col[2] + 1
      end
      fill(cx, y, L.x + L.w - 2 - cx, 1, b)
      region(listRegions, L.x + 1, y, L.w - 3, 1, function()
        selected = (selected == c.start) and nil or c.start
        drawList(); drawTotals()
      end)
    else
      fill(L.x + 1, y, L.w - 3, 1, K.white)
    end
  end
  if n == 0 then
    textW(L.x + 1, L.y + 4, L.w - 3, "No cycles received yet. Use File > Request Update.", K.sh, K.white, "center")
  end

  -- scrollbar
  local sx, sy, sh = L.x + L.w - 2, L.y + 1, L.h - 2
  text(sx, sy, "▲", K.black, K.face)
  text(sx, sy + sh - 1, "▼", K.black, K.face)
  vtext(sx, sy + 1, string.rep("░", sh - 2), K.face, K.track)
  if maxScroll > 0 then
    local thumb = sy + 1 + floor((sh - 3) * (scroll / maxScroll) + 0.5)
    text(sx, thumb, "█", K.face, K.track)
  end
  region(listRegions, sx, sy, 1, 1, function() scroll = scroll - 1; drawList() end)
  region(listRegions, sx, sy + sh - 1, 1, 1, function() scroll = scroll + 1; drawList() end)
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
  local x, y, w, h = 58, 24, 98, 19
  groupBox(x, y, w, h, "Nitrobenzene Used per Cycle (last " .. CONFIG.GRAPH_CYCLES .. ")")
  bevel(x + 2, y + 1, w - 4, h - 2, "sunken", K.face, K.white)

  local labelW = 9
  local gx, gy = x + 3 + labelW + 1, y + 2
  local cw, rows = w - 6 - labelW - 2, 12
  local ph = rows * 2

  local pts, list = {}, {}
  for i = max(1, #archive - CONFIG.GRAPH_CYCLES + 1), #archive do list[#list + 1] = archive[i] end
  local n = #list
  local ymax = 1
  for _, c in ipairs(list) do ymax = max(ymax, c.used or 0) end
  ymax = niceMax(ymax * 1.05)
  local function py(v) return ph - floor(v / ymax * (ph - 2) + 0.5) end

  local cv = newCanvas(cw, ph, K.white)
  for k = 0, 4 do
    local yy = py(ymax * k / 4)
    for xx = 1, cw, 2 do cset(cv, xx, yy, K.grid) end
    if n > 0 then
      textW(x + 3, gy + floor((yy - 1) / 2), labelW, shortL(ymax * k / 4), K.black, K.white, "right")
    end
  end
  for yy = 1, ph do cset(cv, 1, yy, K.black) end
  for xx = 1, cw do cset(cv, xx, ph, K.black) end

  if n == 0 then
    crender(cv, gx, gy)
    textW(gx, gy + 5, cw, "(no data)", K.sh, K.white, "center")
    return
  end
  for i in ipairs(list) do
    local px = (n == 1) and floor(cw / 2) or (5 + floor((i - 1) * (cw - 10) / (n - 1) + 0.5))
    pts[i] = { px, py(list[i].used or 0) }
  end
  for i = 2, n do cline(cv, pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2], K.line) end
  for i, p in ipairs(pts) do
    local col = (list[i].start == selected) and K.red or (i == n and K.green or K.mark)
    for dx = -1, 1 do for dy = -1, 1 do cset(cv, p[1] + dx, p[2] + dy, col) end end
  end
  crender(cv, gx, gy)
  for i, c in ipairs(list) do
    local cx = gx + pts[i][1] - 1
    local function lab(row, s, col)
      local lw = unicode.len(s)
      text(max(gx, min(cx - floor(lw / 2), gx + cw - lw)), gy + rows + row, s, col, K.white)
    end
    lab(0, "#" .. tostring(c.id), K.black)
    lab(1, shortL(c.used or 0) .. " L", K.navy)
    lab(2, fmtDur(c.dur), K.sh)
  end
end

local about, confirmClear   -- defined with the dialogs below

local function drawWindow(t)
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  drawTitle(t)
  region(regions, WX + WW - 12, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(regions, WX + WW - 5, WY + 1, 3, 1, function() running = false end)

  -- menu bar
  local menuY = WY + 2
  fill(WX + 1, menuY, WW - 2, 1, K.face)
  text(WX + 2, menuY, " File ", K.black, K.face)
  text(WX + 8, menuY, " View ", K.black, K.face)
  text(WX + 14, menuY, " Help ", K.black, K.face)

  -- toolbar
  local ty = WY + 3
  button(regions, 16, ty, 20, "Request Update", function()
    requestUpdate(); statusMsg = "Update requested..."; drawStatusBar(now())
  end)
  button(regions, 37, ty, 18, "Clear Archive", function() confirmClear() end)
  button(regions, 56, ty, 11, "About", function() about() end)
  text(WX + 1, ty + 3, string.rep("─", WW - 2), K.sh, K.face)

  groupBox(16, 9, 40, 16, "Live Status")
  drawLive(t)
  drawTotals()
  drawList()
  drawGraph()
  drawStatusBar(t)
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
    local word = "LSC98"
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
  local w = max(50, #buttons * 14 + 6)
  for _, l in ipairs(lines) do w = max(w, unicode.len(l) + 10) end
  local h = #lines + 8
  local x, y = floor((W - w) / 2), floor((46 - h) / 2)
  overlay = { regions = {}, modal = true }
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
  dialog("About LSC Cycle Viewer", {
    "LSC Cycle Viewer  version 1.0",
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
  dialog("Shut Down", { "Are you sure you want to close LSC Cycle Viewer?" },
    { { "Yes", function() running = false end }, { "No" } })
end


local function fileMenu()
  popupMenu(WX + 2, WY + 3, {
    { "Request Update", function() requestUpdate(); statusMsg = "Update requested..." end },
    { "Clear Archive...", confirmClear },
    { "-" },
    { "Exit", function() running = false end },
  })
end

local function viewMenu()
  popupMenu(WX + 8, WY + 3, {
    { "Scroll to Newest", function() scroll = 0 end },
    { "Clear Selection", function() selected = nil end },
  })
end

local function helpMenu()
  popupMenu(WX + 14, WY + 3, { { "About LSC Viewer...", about } })
end

openStartMenu = function()
  popupMenu(1, 47, {
    { "LSC Cycle Viewer", function() activeApp = "viewer" end },
    { "Chess", function() openChess() end },
    { "Stock Track", function() openStockApp() end },
    { "-" },
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
      textW(PX + 2, 21, 63, "(The other computer must be running lscview.)", K.sh, K.face)
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
  activeApp = "viewer"
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
      "1. Both computers run lscview (in wireless range).",
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

----------------------------------------------------------- STOCK TRACK
-- Lives in its own function so it gets its own local-variable budget
-- (Lua allows only 200 locals in the main part of a file).
local ST = (function()
local inet = nil
do
  local a = component.list("internet")()
  if a then inet = component.proxy(a) end
end

local SK = {
  up = 0x007A00, down = 0xC00000, flat = 0x404040,
  prevLine = 0xA8A8A8, grid = 0xD8D8D8,
}
local stocks = { tickers = {}, history = {} }   -- saved
local quotes = {}           -- live: sym -> { price, prev, high, low, time, name, currency, err }
local stockSel = nil        -- selected ticker
local stockView = "dashboard"   -- "dashboard" | "details"
local stockInput, stockFocus = "", false
local stockMsg = inet and "Ready." or "No Internet Card found - install one to get prices."
local stockOpen = false
local nextRefresh = 0       -- computer.uptime() of the next refresh
local stockRegions = {}     -- rebuilt by drawStockWindow
local backoff = 0           -- extra delay after errors (rate limiting)

local function saveStocks() writeFile(CONFIG.STOCK_FILE, serialization.serialize(stocks)) end

local function loadStocks()
  local raw = readFile(CONFIG.STOCK_FILE)
  if not raw then return end
  local ok, t = pcall(serialization.unserialize, raw)
  if ok and type(t) == "table" then
    stocks.tickers = t.tickers or {}
    stocks.history = t.history or {}
    stockSel = stocks.tickers[1]
    if #stocks.tickers > 0 then stockOpen = true end
  end
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

local function quoteURL(sym)
  if CONFIG.STOCK_PROVIDER == "finnhub" then
    return "https://finnhub.io/api/v1/quote?symbol=" .. urlEncode(sym) .. "&token=" .. tostring(CONFIG.FINNHUB_KEY)
  end
  return "https://query1.finance.yahoo.com/v8/finance/chart/" .. urlEncode(sym) .. "?interval=5m&range=1d"
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
  local series = {}
  local ts, cl = body:match('"timestamp"%s*:%s*%[(.-)%]'), body:match('"close"%s*:%s*%[(.-)%]')
  if ts and cl then
    local tlist, clist = {}, {}
    for v in ts:gmatch("[^,]+") do tlist[#tlist + 1] = tonumber(v) end
    for v in cl:gmatch("[^,]+") do clist[#clist + 1] = tonumber(v) end
    for i = 1, min(#tlist, #clist) do
      if tlist[i] and clist[i] then series[#series + 1] = { t = tlist[i], p = clist[i], mt = tlist[i] } end
    end
  end
  return { price = price, prev = jnum(body, "chartPreviousClose") or jnum(body, "previousClose"),
           high = jnum(body, "regularMarketDayHigh"), low = jnum(body, "regularMarketDayLow"),
           time = jnum(body, "regularMarketTime"), currency = jstr(body, "currency"),
           name = jstr(body, "shortName") or jstr(body, "longName"), series = series }
end

local onQuote   -- forward: called when a fetch finishes

local function queueFetch(sym, front)
  for _, q in ipairs(httpQueue) do if q == sym then return end end
  if httpCur and httpCur.sym == sym then return end
  if front then table.insert(httpQueue, 1, sym) else httpQueue[#httpQueue + 1] = sym end
end

local function refreshAll()
  for _, sym in ipairs(stocks.tickers) do queueFetch(sym) end
  nextRefresh = computer.uptime() + CONFIG.STOCK_REFRESH + backoff
end

local function finishHttp(err)
  local cur = httpCur
  httpCur = nil
  pcall(cur.h.close)
  if err then
    onQuote(cur.sym, nil, err)
    return
  end
  local q, perr = parseQuote(cur.body)
  onQuote(cur.sym, q, perr)
end

-- call often from the main loop; does a little work and returns
local function pumpHttp()
  if not inet then return end
  if not httpCur then
    local sym = table.remove(httpQueue, 1)
    if not sym then return end
    if CONFIG.STOCK_PROVIDER == "finnhub" and not CONFIG.FINNHUB_KEY then
      onQuote(sym, nil, "Set FINNHUB_KEY in the config")
      return
    end
    local ok, h = pcall(inet.request, quoteURL(sym), nil,
      { ["User-Agent"] = "Mozilla/5.0 (compatible; OpenComputers lscview)", ["Accept"] = "application/json" })
    if not ok or not h then onQuote(sym, nil, "Request failed: " .. tostring(h)); return end
    httpCur = { sym = sym, h = h, body = "", started = computer.uptime() }
  end
  local cur = httpCur
  local ok, done = pcall(cur.h.finishConnect)
  if not ok then finishHttp(tostring(done)); return end
  if done then
    for _ = 1, 16 do
      local okr, chunk = pcall(cur.h.read, 8192)
      if not okr then finishHttp(tostring(chunk)); return end
      if chunk == nil then
        local okc, code = pcall(cur.h.response)
        if okc and code and code ~= 200 and #cur.body == 0 then finishHttp("HTTP " .. tostring(code)); return end
        if okc and code == 429 then finishHttp("HTTP 429 (too many requests)"); return end
        finishHttp(nil)
        return
      elseif chunk == "" then
        break
      else
        cur.body = cur.body .. chunk
      end
    end
  end
  if computer.uptime() - cur.started > 15 then finishHttp("Timed out") end
end

local function httpBusy() return inet ~= nil and (httpCur ~= nil or #httpQueue > 0) end

-- history -----------------------------------------------------------------
local function mergeSeries(sym, series)
  if not series or #series == 0 then return false end
  local hist = stocks.history[sym] or {}
  stocks.history[sym] = hist
  local seen = {}
  for _, h in ipairs(hist) do if h.mt then seen[h.mt] = true end end
  local added = false
  for _, pnt in ipairs(series) do
    if not seen[pnt.mt] then hist[#hist + 1] = pnt; seen[pnt.mt] = true; added = true end
  end
  if added then
    table.sort(hist, function(a, b) return (a.mt or a.t) < (b.mt or b.t) end)
    while #hist > CONFIG.STOCK_LOG_MAX do table.remove(hist, 1) end
  end
  return added
end

local function logPrice(sym, q)
  local hist = stocks.history[sym] or {}
  stocks.history[sym] = hist
  local last = hist[#hist]
  local t = q.time or now()
  -- one point per STOCK_LOG_EVERY of market time, and only when the market time moved
  if last and (t - (last.mt or last.t) < CONFIG.STOCK_LOG_EVERY) then return false end
  hist[#hist + 1] = { t = t, p = q.price, mt = q.time }
  while #hist > CONFIG.STOCK_LOG_MAX do table.remove(hist, 1) end
  return true
end

-- drawing -----------------------------------------------------------------
local SX, SY, SW = 16, 9, 140           -- content area
local SCOLS = {
  { "Symbol", 10 }, { "Name", 22 }, { "Price", 12 }, { "Change", 11 }, { "Change %", 9 },
  { "Day Low", 11 }, { "Day High", 11 }, { "Prev Close", 11 }, { "Market Time", 20 },
}
local LIST_Y, LIST_H = 9, 15            -- details list (12 rows)
local GRAPH_Y, GRAPH_H = 25, 18

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
  if not sym then fill(SX + 1, y, SW - 2, 1, K.white); return end
  local q = quotes[sym]
  local sel = (sym == stockSel)
  local b = sel and K.navy or K.white
  local base = sel and K.white or K.black
  local chg, pct, col = fmtChange(q)
  if sel then col = K.white end
  local cells = {
    { sym, base },
    { q and (q.err and ("! " .. q.err) or q.name) or "loading...", (q and q.err) and (sel and K.white or K.down) or base },
    { q and fmtPrice(q.price) or "--", base },
    { chg, col }, { pct, col },
    { q and fmtPrice(q.low) or "--", base }, { q and fmtPrice(q.high) or "--", base },
    { q and fmtPrice(q.prev) or "--", base }, { q and fmtMarketTime(q.time) or "--", base },
  }
  local cx = SX + 1
  for c, col2 in ipairs(SCOLS) do
    textW(cx, y, col2[2] + 1, " " .. cells[c][1], cells[c][2], b, (c >= 3 and c <= 8) and "right" or nil)
    cx = cx + col2[2] + 1
  end
  fill(cx, y, SX + SW - 1 - cx, 1, b)
end

local function stockList()
  bevel(SX, LIST_Y, SW, LIST_H, "sunken", K.face, K.white)
  local cx = SX + 1
  for _, col in ipairs(SCOLS) do
    textW(cx, LIST_Y + 1, col[2], " " .. col[1], K.black, K.face)
    text(cx + col[2], LIST_Y + 1, "│", K.sh, K.face)
    cx = cx + col[2] + 1
  end
  fill(cx, LIST_Y + 1, SX + SW - 1 - cx, 1, K.face)
  for i = 1, LIST_H - 3 do stockListRow(i) end
  if #stocks.tickers == 0 then
    textW(SX + 1, LIST_Y + 4, SW - 2, "Type a ticker (e.g. AAPL, MSFT, SPY, BTC-USD) and click Add.", K.sh, K.white, "center")
  end
end

-- price history line (+ current price) for a symbol
local function seriesFor(sym)
  local pts = {}
  for _, h in ipairs(stocks.history[sym] or {}) do pts[#pts + 1] = h end
  local q = quotes[sym]
  if q and q.price and not q.err then
    local last = pts[#pts]
    if not last or (q.time and (last.mt or last.t) < q.time) then
      pts[#pts + 1] = { t = q.time or q.at or 0, p = q.price, mt = q.time }
    end
  end
  return pts
end

local function plotSeries(cv, pts, prev, lineCol)
  local lo, hi = math.huge, -math.huge
  for _, p in ipairs(pts) do lo, hi = min(lo, p.p), max(hi, p.p) end
  if prev then lo, hi = min(lo, prev), max(hi, prev) end
  if hi - lo < 1e-9 then hi, lo = hi + 0.5, lo - 0.5 end
  local pad = (hi - lo) * 0.08
  lo, hi = lo - pad, hi + pad
  local function py(v) return cv.h - floor((v - lo) / (hi - lo) * (cv.h - 1) + 0.5) end
  if prev then
    local yy = py(prev)
    for xx = 1, cv.w, 3 do cset(cv, xx, yy, SK.prevLine) end
  end
  local n = #pts
  local lx, ly
  for i, p in ipairs(pts) do
    local x = (n == 1) and floor(cv.w / 2) or (1 + floor((i - 1) * (cv.w - 1) / (n - 1) + 0.5))
    local y = py(p.p)
    if lx then cline(cv, lx, ly, x, y, lineCol) else cset(cv, x, y, lineCol) end
    lx, ly = x, y
  end
  return lo, hi, py
end

local function stockGraph()
  groupBox(SX, GRAPH_Y, SW, GRAPH_H, stockSel and ("Price History - " .. stockSel) or "Price History")
  bevel(SX + 2, GRAPH_Y + 1, SW - 4, GRAPH_H - 2, "sunken", K.face, K.white)
  local labelW = 10
  local gx, gy = SX + 3 + labelW + 1, GRAPH_Y + 2
  local cw, rows = SX + SW - 4 - gx, 11
  local cv = newCanvas(cw, rows * 2, K.white)
  if not stockSel then
    crender(cv, gx, gy)
    textW(gx, gy + 5, cw, "Select a ticker to see its graph.", K.sh, K.white, "center")
    return
  end
  local pts = seriesFor(stockSel)
  local q = quotes[stockSel]
  if #pts < 2 then
    crender(cv, gx, gy)
    textW(gx, gy + 4, cw, "Not enough price data yet for a graph.", K.sh, K.white, "center")
    textW(gx, gy + 6, cw, CONFIG.STOCK_PROVIDER == "finnhub"
      and ("Finnhub has no free intraday history: a point is saved every " .. floor(CONFIG.STOCK_LOG_EVERY / 60) .. " min while the market is open.")
      or "Waiting for today's price data from Yahoo...", K.sh, K.white, "center")
  else
    for k = 0, 3 do for xx = 1, cw, 2 do cset(cv, xx, 1 + floor(k * (rows * 2 - 1) / 3), SK.grid) end end
    local up = pts[#pts].p >= pts[1].p
    local lo, hi = plotSeries(cv, pts, q and q.prev, up and SK.up or SK.down)
    crender(cv, gx, gy)
    for k = 0, 3 do
      local v = hi - (hi - lo) * k / 3
      textW(SX + 3, gy + floor(k * (rows - 1) / 3), labelW, fmtPrice(v), K.black, K.white, "right")
    end
    textW(gx, gy + rows, 30, fmtStamp(pts[1].t), K.sh, K.white)
    textW(gx + cw - 30, gy + rows, 30, fmtStamp(pts[#pts].t), K.sh, K.white, "right")
  end
  -- stats line
  local lo2, hi2 = math.huge, -math.huge
  for _, p in ipairs(pts) do lo2, hi2 = min(lo2, p.p), max(hi2, p.p) end
  local chg, pct = fmtChange(q)
  local line = stockSel .. "   Last " .. (q and fmtPrice(q.price) or "--") .. " " .. ((q and q.currency) or "")
    .. "   Today " .. chg .. " (" .. pct .. ")   Prev close " .. (q and fmtPrice(q.prev) or "--")
    .. "   Logged range " .. (#pts > 0 and (fmtPrice(lo2) .. " - " .. fmtPrice(hi2)) or "--")
    .. "   Points " .. #(stocks.history[stockSel] or {})
  textW(SX + 4, gy + rows + 1, SW - 8, line, K.black, K.white)
  text(SX + 4, gy + rows + 2, "- - -", SK.prevLine, K.white)
  textW(SX + 10, gy + rows + 2, 40, "previous close", K.sh, K.white)
end

-- dashboard tiles
local TW, TH, TCOLS = 34, 10, 4
local function tileXY(i)
  local c, r = (i - 1) % TCOLS, floor((i - 1) / TCOLS)
  return SX + c * (TW + 1), SY + r * (TH + 1)
end

local function stockTile(i)
  local x, y = tileXY(i)
  local sym = stocks.tickers[i]
  if not sym then
    fill(x, y, TW, TH, K.face)
    if i == #stocks.tickers + 1 then
      bevel(x, y, TW, TH, "sunken", K.face, K.face)
      textW(x + 1, y + 4, TW - 2, "+ add a ticker above", K.sh, K.face, "center")
    end
    return
  end
  local q = quotes[sym]
  local sel = sym == stockSel
  bevel(x, y, TW, TH, "raised", K.face, sel and 0xD8D8F0 or K.face)
  local bgc = sel and 0xD8D8F0 or K.face
  textW(x + 2, y + 1, 10, sym, K.navy, bgc)
  textW(x + 12, y + 1, TW - 14, q and (q.err and "error" or (q.name or "")) or "loading...",
    (q and q.err) and K.down or K.sh, bgc, "right")
  textW(x + 2, y + 2, TW - 4, q and (q.err and q.err or fmtPrice(q.price) .. " " .. (q.currency or "")) or "--",
    (q and q.err) and K.down or K.black, bgc)
  local chg, pct, col = fmtChange(q)
  textW(x + 2, y + 3, TW - 4, chg .. "  (" .. pct .. ")", col, bgc)
  -- sparkline
  local cv = newCanvas(TW - 4, 8, K.white)
  local pts = seriesFor(sym)
  if #pts >= 2 then
    plotSeries(cv, pts, q and q.prev, (pts[#pts].p >= pts[1].p) and SK.up or SK.down)
  end
  crender(cv, x + 2, y + 4)
  if #pts < 2 then textW(x + 2, y + 5, TW - 4, "waiting for price data...", K.sh, K.white, "center") end
  textW(x + 2, y + 8, TW - 4, q and fmtMarketTime(q.time) or "", K.sh, bgc)
end

local function stockDashboard()
  fill(SX, SY, SW, 34, K.face)
  for i = 1, CONFIG.STOCK_MAX_TICKERS do stockTile(i) end
end

local function drawStockBody()
  if stockView == "dashboard" then stockDashboard() else stockList(); stockGraph() end
end

-- redraw the parts that show one symbol (after a quote arrives)
local function refreshStockSym(sym)
  if activeApp ~= "stock" or overlay then return end
  for i, s in ipairs(stocks.tickers) do
    if s == sym then
      if stockView == "dashboard" then stockTile(i) else stockListRow(i) end
    end
  end
  if stockView == "details" and sym == stockSel then stockGraph() end
  drawStockStatus()
end

onQuote = function(sym, q, err)
  local known = false
  for _, s in ipairs(stocks.tickers) do if s == sym then known = true end end
  if not known then return end
  if q then
    local old = quotes[sym]
    q.name = q.name or (old and old.name)
    q.at = now()
    quotes[sym] = q
    backoff = 0
    local merged = mergeSeries(sym, q.series)
    q.series = nil
    if logPrice(sym, q) or merged then saveStocks() end
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
local drawStockWindow   -- forward

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
  stocks.history[sym] = stocks.history[sym] or {}
  stockSel = sym
  saveStocks()
  queueFetch(sym, true)
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
    { "Close Stock Track", function() stockOpen = false; activeApp = "viewer" end },
  })
end

local function stockViewMenu()
  popupMenu(WX + 10, WY + 3, {
    { "Dashboard", function() stockView = "dashboard" end },
    { "Details + Graph", function() stockView = "details" end },
  })
end

local function stockHelpMenu()
  popupMenu(WX + 16, WY + 3, { { "About Stock Track...", function()
    dialog("About Stock Track", {
      "Prices come from " .. (CONFIG.STOCK_PROVIDER == "finnhub" and "Finnhub" or "Yahoo Finance") .. " through the Internet Card.",
      "Refresh every " .. CONFIG.STOCK_REFRESH .. " s; a history point is saved every "
        .. floor(CONFIG.STOCK_LOG_EVERY / 60) .. " min (" .. CONFIG.STOCK_LOG_MAX .. " kept).",
      "Tickers use Yahoo symbols: AAPL, SPY, ^GSPC, BTC-USD, EURUSD=X.",
      "Quotes may be delayed. Not for real trading decisions.",
    }, { { "OK" } })
  end } })
end

drawStockWindow = function()
  stockRegions = {}
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▣ Stock Track - " .. (stockView == "dashboard" and "Dashboard" or "Details"), true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(stockRegions, bx, WY + 1, 3, 1, function() activeApp = nil; drawAll() end)
  region(stockRegions, bx + 7, WY + 1, 3, 1, function() stockOpen = false; activeApp = "viewer"; drawAll() end)

  fill(WX + 1, WY + 2, WW - 2, 1, K.face)
  text(WX + 2, WY + 2, " Stocks ", K.black, K.face)
  text(WX + 10, WY + 2, " View ", K.black, K.face)
  text(WX + 16, WY + 2, " Help ", K.black, K.face)
  region(stockRegions, WX + 2, WY + 2, 8, 1, stockMenu)
  region(stockRegions, WX + 10, WY + 2, 6, 1, stockViewMenu)
  region(stockRegions, WX + 16, WY + 2, 6, 1, stockHelpMenu)

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
  button(stockRegions, 117, 5, 19, "Dashboard", function() stockView = "dashboard"; drawStockWindow() end,
    stockView == "dashboard")
  button(stockRegions, 137, 5, 19, "Details", function() stockView = "details"; drawStockWindow() end,
    stockView == "details")
  text(WX + 1, 8, string.rep("─", WW - 2), K.sh, K.face)

  drawStockBody()
  if stockView == "dashboard" then
    for i = 1, CONFIG.STOCK_MAX_TICKERS do
      local x, y = tileXY(i)
      region(stockRegions, x, y, TW, TH, function() selectTicker(i) end)
    end
  else
    for i = 1, LIST_H - 3 do
      region(stockRegions, SX + 1, LIST_Y + 1 + i, SW - 2, 1, function() selectTicker(i) end)
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


return {
  drawWindow = function() drawStockWindow() end,
  drawStatus = drawStockStatus,
  drawInput = drawInput,
  load = loadStocks,
  refreshAll = refreshAll,
  busy = httpBusy,
  pump = pumpHttp,
  key = stockKey,
  hasTickers = function() return #stocks.tickers > 0 end,
  hasInternet = function() return inet ~= nil end,
  due = function() return computer.uptime() >= nextRefresh end,
  focus = function(v) if v ~= nil then stockFocus = v end return stockFocus end,
  regions = function() return stockRegions end,
  resetRegions = function() stockRegions = {} end,
}
end)()

drawAll = function(keepOverlay)
  local t = now()
  regions = {}
  listRegions = {}
  panelRegions = {}
  ST.resetRegions()
  if not keepOverlay then overlay = nil end
  drawDesktop()
  if activeApp == "viewer" then
    drawWindow(t)
    region(regions, WX + 2, WY + 2, 6, 1, fileMenu)
    region(regions, WX + 8, WY + 2, 6, 1, viewMenu)
    region(regions, WX + 14, WY + 2, 6, 1, helpMenu)
  elseif activeApp == "chess" then
    drawChessWindow()
  elseif activeApp == "stock" then
    ST.drawWindow()
  end
  drawTaskbar(t)
end

------------------------------------------------------------- MAIN LOOP
local oldW, oldH = gpu.getResolution()

local function main()
  local mw, mh = gpu.maxResolution()
  if mw < W or mh < H then error("LSC Cycle Viewer needs a tier 3 GPU and screen (160x50).", 0) end
  gpu.setResolution(W, H)
  loadSaved()
  loadGame()
  ST.load()
  drawAll()
  requestUpdate()
  if ST.hasTickers() then ST.refreshAll() end

  local lastTick = 0
  local wasResponding = nil
  while running do
    local ev = { event.pull(ST.busy() and 0.05 or 0.5) }
    local name = ev[1]
    if name == "interrupted" then
      running = false
    elseif name == "touch" then
      local x, y = ev[3], ev[4]
      if overlay then
        if not hit(overlay.regions, x, y) and not overlay.modal then closeOverlay() end
      elseif hit(taskRegions, x, y) then
        -- taskbar
      elseif activeApp == "viewer" and hit(listRegions, x, y) then
        -- cycle list
      elseif activeApp == "chess" and hit(panelRegions, x, y) then
        -- chess side panel
      elseif activeApp == "stock" then
        local wasFocus = ST.focus()
        ST.focus(false)
        if not hit(ST.regions(), x, y) then hit(regions, x, y) end
        if wasFocus and not ST.focus() and activeApp == "stock" and not overlay then ST.drawInput() end
      else
        hit(regions, x, y)
      end
    elseif name == "scroll" and not overlay and activeApp == "viewer" then
      local x, y, dir = ev[3], ev[4], ev[5]
      if x >= LIST.x and x < LIST.x + LIST.w and y >= LIST.y and y < LIST.y + LIST.h then
        scroll = scroll - dir
        drawList()
      end
    elseif name == "modem_message" and ev[4] == CONFIG.PORT and ev[6] == "LSCSTATS" then
      local from = ev[3]
      if not CONFIG.SENDER or from:sub(1, #CONFIG.SENDER) == CONFIG.SENDER then
        local changed = receive(from, ev[5], ev[8])
        statusMsg = changed and "New cycle data received" or "Update received"
        if not overlay then
          if changed and activeApp == "viewer" then drawAll() elseif changed then drawTray(now()) else
            local t = now()
            if activeApp == "viewer" then drawLive(t); drawStatusBar(t) end
          end
        end
      end
    elseif name == "modem_message" and ev[4] == CONFIG.CHESS_PORT and ev[6] == "CHESS" then
      onChessMessage(ev[3], ev[5], ev[7], ev[8], ev[9])
    elseif name == "key_down" and activeApp == "stock" and ST.focus() and not overlay then
      ST.key(ev[3], ev[4])
    end

    ST.pump()
    if ST.hasInternet() and ST.hasTickers() and not ST.busy() and ST.due() then
      ST.refreshAll()
    end

    local up = computer.uptime()
    if running and up - lastTick >= 1 and not overlay then
      lastTick = up
      local t = now()
      local r = responding(t) and true or false
      if activeApp == "viewer" then
        drawLive(t)
        if r ~= wasResponding then drawTitle(t); drawStatusBar(t) end
      elseif activeApp == "stock" then
        ST.drawStatus()
      end
      drawTray(t)
      wasResponding = r
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
