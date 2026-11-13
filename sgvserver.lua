--[[
  sgvserver.lua  -  Stargate Valley storage server

  Keeps every Stargate Valley farm for every Lymanos player. The game on a
  Lymanos computer loads a farm from here when you play it and sends it back
  when you sleep or press Save Game. Chests are separate small files that are
  only read when a chest is opened.

  Files (CFG.ROOT, one folder per Lymanos player name):
    <root>/<player>/index.dat          the player's farm list (name, day, gold...)
    <root>/<player>/f<id>.sav          one farm (about 3-6 KB)
    <root>/<player>/f<id>_c<tile>.dat  one chest (about 0.1-1 KB)
    <root>/<player>/f<id>_c<tile>.new  chest changes not saved yet: they become
                                       .dat when the farm is saved, and are thrown
                                       away when the farm is loaded again without
                                       saving (so nothing gets duplicated or lost)

  Needs: a network card (wireless for wireless Lymanos computers), any screen
  (optional - without one it just runs). Port must match SGV_PORT in lymanos.lua.
  Exit: Ctrl+C.
]]

local CFG = {
  PORT = 4047,
  ROOT = "/home/sgv",        -- put it on a RAID or a big drive if you like, e.g. "/mnt/1a2/sgv"
  MAX_FARMS = 6,             -- farms per player
  MAX_SAVE = 60000,          -- largest farm accepted (bytes)
  MAX_CHEST = 6000,          -- largest chest accepted (bytes)
  NAME = "Stargate Storage",
  LOG_MAX = 60,
}

local component     = require("component")
local computer      = require("computer")
local event         = require("event")
local filesystem    = require("filesystem")
local serialization = require("serialization")
local unicode       = require("unicode")

local floor, max, min = math.floor, math.max, math.min

local modem
for addr in component.list("modem") do
  local m = component.proxy(addr)
  if m.isWireless() then modem = m; break end
end
if not modem then
  local a = component.list("modem")()
  if a then modem = component.proxy(a) end
end
if not modem then io.stderr:write("sgvserver: no network card found.\n"); return end
modem.open(CFG.PORT)
pcall(modem.setStrength, 400)

filesystem.makeDirectory(CFG.ROOT)

---------------------------------------------------------------- files
local function readFile(p)
  local f = io.open(p, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end
local function writeFile(p, s)            -- write a copy first, then swap it in
  local tmp = p .. ".tmp"
  local f, why = io.open(tmp, "w")
  if not f then return false, tostring(why) end
  f:write(s)
  f:close()
  if filesystem.exists(p) then filesystem.remove(p) end
  return filesystem.rename(tmp, p)
end
local function safeName(user)
  local s = tostring(user or ""):lower():gsub("[^%w%-_]", "_"):sub(1, 24)
  if s == "" then s = "_nobody" end
  return s
end
local function dirOf(user)
  local d = CFG.ROOT .. "/" .. safeName(user)
  if not filesystem.exists(d) then filesystem.makeDirectory(d) end
  return d
end
local function loadIndex(user)
  local raw = readFile(dirOf(user) .. "/index.dat")
  local ok, t = pcall(serialization.unserialize, raw or "")
  if not ok or type(t) ~= "table" then t = {} end
  t.next = tonumber(t.next) or 1
  t.farms = type(t.farms) == "table" and t.farms or {}
  t.who = t.who or tostring(user)
  return t
end
local function saveIndex(user, t) return writeFile(dirOf(user) .. "/index.dat", serialization.serialize(t)) end
local function findFarm(t, id)
  for i, f in ipairs(t.farms) do if f.id == id then return f, i end end
end
local function farmFile(user, id) return dirOf(user) .. "/f" .. id .. ".sav" end
local function chestFile(user, id, idx, ext) return dirOf(user) .. "/f" .. id .. "_c" .. idx .. ext end
-- the chest files of one farm: { [tile] = { dat = true, new = true } }
local function chestFiles(user, id)
  local out = {}
  local d = dirOf(user)
  for name in filesystem.list(d) do
    local idx, ext = name:match("^f" .. id .. "_c(%d+)%.(%a+)$")
    if idx and (ext == "dat" or ext == "new") then
      idx = tonumber(idx)
      out[idx] = out[idx] or {}
      out[idx][ext] = true
    end
  end
  return out
end

---------------------------------------------------------------- log + screen
local LOG = {}
local dirty = true
local stats = { saves = 0, loads = 0, bytesIn = 0, bytesOut = 0 }
local function stamp()
  local s = floor(computer.uptime())
  return string.format("%02d:%02d:%02d", floor(s / 3600) % 100, floor(s % 3600 / 60), s % 60)
end
local function log(s)
  LOG[#LOG + 1] = stamp() .. "  " .. s
  while #LOG > CFG.LOG_MAX do table.remove(LOG, 1) end
  dirty = true
end

local gpu = component.isAvailable("gpu") and component.gpu or nil
local SW, SH = 80, 25
if gpu then
  local mw, mh = gpu.maxResolution()
  SW, SH = min(mw, 120), min(mh, 40)
  pcall(gpu.setResolution, SW, SH)
end
local C = { bg = 0x10140C, bar = 0x5B2B10, bar2 = 0xB8682C, text = 0xF8D59A, dim = 0x9A8A6A, ok = 0x6CD04A, head = 0xFFE6A0 }

local function put(x, y, s, f, b)
  if b then gpu.setBackground(b) end
  if f then gpu.setForeground(f) end
  gpu.set(x, y, s)
end
local function fit(s, w)
  s = tostring(s)
  if unicode.len(s) > w then return unicode.sub(s, 1, w) end
  return s .. string.rep(" ", w - unicode.len(s))
end
local function human(n)
  if not n then return "?" end
  if n >= 1048576 then return string.format("%.2f MB", n / 1048576) end
  if n >= 1024 then return string.format("%.1f KB", n / 1024) end
  return floor(n) .. " B"
end

local function allFarms()
  local rows = {}
  for name in filesystem.list(CFG.ROOT) do
    if name:sub(-1) == "/" then
      local raw = readFile(CFG.ROOT .. "/" .. name .. "index.dat")
      local ok, t = pcall(serialization.unserialize, raw or "")
      if ok and type(t) == "table" and type(t.farms) == "table" then
        for _, f in ipairs(t.farms) do rows[#rows + 1] = { who = t.who or name:sub(1, -2), f = f } end
      end
    end
  end
  return rows
end

local SEASON = { "Spr", "Sum", "Fall", "Win" }
local function draw()
  if not gpu then return end
  dirty = false
  gpu.setBackground(C.bg); gpu.fill(1, 1, SW, SH, " ")
  put(1, 1, fit("  ♣ " .. CFG.NAME .. "  -  Stargate Valley save server", SW), C.head, C.bar)
  local fsp = filesystem.get(CFG.ROOT)
  local used, total = fsp and fsp.spaceUsed(), fsp and fsp.spaceTotal()
  put(2, 3, fit(string.format("Port %d   Uptime %s   Disk %s / %s   Saves %d  Loads %d   In %s  Out %s",
    CFG.PORT, stamp(), human(used), human(total), stats.saves, stats.loads, human(stats.bytesIn), human(stats.bytesOut)), SW - 2), C.text, C.bg)
  put(2, 5, fit(string.format("%-14s %-16s %-12s %-14s %10s %8s %8s", "Player", "Farm", "Farmer", "Date", "Gold", "Played", "Size"), SW - 2), C.head, C.bg)
  local rows = allFarms()
  local y = 6
  local listMax = max(3, SH - 16)
  for i, r in ipairs(rows) do
    if i > listMax then put(2, y, fit("... " .. (#rows - listMax) .. " more", SW - 2), C.dim, C.bg); y = y + 1; break end
    local f = r.f
    local pl = tonumber(f.played) or 0
    put(2, y, fit(string.format("%-14s %-16s %-12s %-14s %10s %8s %8s", tostring(r.who):sub(1, 14), tostring(f.name):sub(1, 16),
      tostring(f.farmer):sub(1, 12), (SEASON[tonumber(f.season) or 1] or "?") .. " " .. tostring(f.day) .. " Y" .. tostring(f.year),
      tostring(f.gold) .. "g", string.format("%dh%02dm", floor(pl / 3600), floor(pl % 3600 / 60)), human(f.size)), SW - 2), C.text, C.bg)
    y = y + 1
  end
  if #rows == 0 then put(2, y, "No farms yet. Start Stargate Valley on a Lymanos computer.", C.dim, C.bg); y = y + 1 end
  put(1, y + 1, fit("  Activity", SW), C.head, C.bar)
  local n = SH - (y + 2)
  for i = 1, n do
    local l = LOG[#LOG - n + i]
    if l then put(2, y + 1 + i, fit(l, SW - 2), C.dim, C.bg) end
  end
end

---------------------------------------------------------------- requests
local last = {}          -- per computer: the last request id and its answer
local xfer = {}          -- uploads in progress: [player/id] = { n, parts, meta, t }

local H = {}

H.FIND = function(user) return true, CFG.NAME end

H.LIST = function(user)
  local t = loadIndex(user)
  local list = {}
  for _, f in ipairs(t.farms) do
    list[#list + 1] = { id = f.id, name = f.name, farmer = f.farmer, day = f.day, season = f.season,
                        year = f.year, gold = f.gold, played = f.played, saved = f.saved }
  end
  return true, serialization.serialize(list)
end

H.NEW = function(user, name, farmer)
  name = tostring(name or ""):gsub("[%c]", ""):sub(1, 24)
  farmer = tostring(farmer or ""):gsub("[%c]", ""):sub(1, 24)
  if name == "" then return false, "The farm needs a name." end
  local t = loadIndex(user)
  if #t.farms >= CFG.MAX_FARMS then return false, "You already have " .. CFG.MAX_FARMS .. " farms - delete one first." end
  local id = t.next
  t.next = id + 1
  t.who = tostring(user)
  t.farms[#t.farms + 1] = { id = id, name = name, farmer = farmer, day = 1, season = 1, year = 1, gold = 500, played = 0, size = 0 }
  local ok, why = saveIndex(user, t)
  if not ok then return false, "Disk error: " .. tostring(why) end
  log(tostring(user) .. " created farm '" .. name .. "' (#" .. id .. ")")
  return true, id
end

H.DEL = function(user, id)
  id = tonumber(id)
  local t = loadIndex(user)
  local f, i = findFarm(t, id)
  if not f then return false, "No such farm." end
  filesystem.remove(farmFile(user, id))
  for idx, e in pairs(chestFiles(user, id)) do
    if e.dat then filesystem.remove(chestFile(user, id, idx, ".dat")) end
    if e.new then filesystem.remove(chestFile(user, id, idx, ".new")) end
  end
  table.remove(t.farms, i)
  local ok, why = saveIndex(user, t)
  if not ok then return false, "Disk error: " .. tostring(why) end
  log(tostring(user) .. " deleted farm '" .. tostring(f.name) .. "'")
  return true
end

local PART = 3600
H.LOAD = function(user, id)
  id = tonumber(id)
  local t = loadIndex(user)
  local f = findFarm(t, id)
  if not f then return false, "No such farm." end
  local s = readFile(farmFile(user, id))
  if not s or s == "" then return false, "This farm has no save data (it was never saved)." end
  -- unsaved chest changes from last time are thrown away, like the rest of the unsaved game
  for idx, e in pairs(chestFiles(user, id)) do
    if e.new then filesystem.remove(chestFile(user, id, idx, ".new")) end
  end
  stats.loads = stats.loads + 1
  stats.bytesOut = stats.bytesOut + #s
  log(tostring(user) .. " loaded '" .. tostring(f.name) .. "' (" .. human(#s) .. ")")
  return true, s:sub(1, PART), math.max(1, math.ceil(#s / PART))
end

H.LPART = function(user, id, i)
  local s = readFile(farmFile(user, tonumber(id)))
  i = tonumber(i)
  if not s or not i then return false, "No save data." end
  return true, s:sub((i - 1) * PART + 1, i * PART)
end

H.SBEG = function(user, id, n, meta)
  id, n = tonumber(id), tonumber(n)
  local t = loadIndex(user)
  if not findFarm(t, id) then return false, "No such farm (was it deleted?)." end
  if not n or n < 1 or n * PART > CFG.MAX_SAVE + PART then return false, "Save too big." end
  xfer[safeName(user) .. "/" .. id] = { n = n, parts = {}, meta = meta, t = computer.uptime() }
  return true
end

H.SPART = function(user, id, i, data)
  local x = xfer[safeName(user) .. "/" .. tostring(tonumber(id))]
  i = tonumber(i)
  if not x then return false, "Upload not started." end
  if not i or i < 1 or i > x.n or type(data) ~= "string" then return false, "Bad part." end
  x.parts[i] = data
  x.t = computer.uptime()
  return true
end

H.SEND = function(user, id)
  id = tonumber(id)
  local key = safeName(user) .. "/" .. tostring(id)
  local x = xfer[key]
  if not x then return false, "Upload not started." end
  for i = 1, x.n do if not x.parts[i] then return false, "Part " .. i .. " is missing." end end
  local blob = table.concat(x.parts)
  if #blob > CFG.MAX_SAVE then return false, "Save too big." end
  local t = loadIndex(user)
  local f = findFarm(t, id)
  if not f then return false, "No such farm." end
  local ok, why = writeFile(farmFile(user, id), blob)
  if not ok then return false, "Disk error: " .. tostring(why) end
  local okm, meta = pcall(serialization.unserialize, x.meta or "")
  meta = (okm and type(meta) == "table") and meta or {}
  for _, k in ipairs({ "name", "farmer", "day", "season", "year", "gold", "played", "saved" }) do
    if meta[k] ~= nil then f[k] = meta[k] end
  end
  f.size = #blob
  -- chests: staged changes become real, chests that are gone are deleted
  local keep = {}
  for _, idx in ipairs(type(meta.chests) == "table" and meta.chests or {}) do keep[tonumber(idx) or -1] = true end
  for idx, e in pairs(chestFiles(user, id)) do
    if not keep[idx] then
      if e.dat then filesystem.remove(chestFile(user, id, idx, ".dat")) end
      if e.new then filesystem.remove(chestFile(user, id, idx, ".new")) end
    elseif e.new then
      local d = chestFile(user, id, idx, ".dat")
      if filesystem.exists(d) then filesystem.remove(d) end
      filesystem.rename(chestFile(user, id, idx, ".new"), d)
    end
  end
  local oki, whyi = saveIndex(user, t)
  if not oki then return false, "Disk error: " .. tostring(whyi) end
  xfer[key] = nil
  stats.saves = stats.saves + 1
  stats.bytesIn = stats.bytesIn + #blob
  log(tostring(user) .. " saved '" .. tostring(f.name) .. "'  " .. (SEASON[tonumber(f.season) or 1] or "") .. " " ..
    tostring(f.day) .. "  " .. tostring(f.gold) .. "g  (" .. human(#blob) .. ")")
  return true
end

H.CGET = function(user, id, idx)
  id, idx = tonumber(id), tonumber(idx)
  if not id or not idx then return false, "Bad chest." end
  local s = readFile(chestFile(user, id, idx, ".new")) or readFile(chestFile(user, id, idx, ".dat")) or ""
  stats.bytesOut = stats.bytesOut + #s
  return true, s
end

H.CPUT = function(user, id, idx, data)
  id, idx = tonumber(id), tonumber(idx)
  if not id or not idx or type(data) ~= "string" then return false, "Bad chest." end
  if #data > CFG.MAX_CHEST then return false, "Chest data too big." end
  if not findFarm(loadIndex(user), id) then return false, "No such farm." end
  local ok, why = writeFile(chestFile(user, id, idx, ".new"), data)
  if not ok then return false, "Disk error: " .. tostring(why) end
  stats.bytesIn = stats.bytesIn + #data
  return true
end

local function handle(from, op, rid, user, a, b, c)
  local L = last[from]
  if L and L.rid == rid then                    -- a repeat (our answer got lost): same answer again
    modem.send(from, CFG.PORT, "SGV", "R", rid, L.ok, L.p, L.x)
    return
  end
  local fn = H[op]
  local ok, p, x
  if not fn then ok, p = false, "Unknown request " .. tostring(op)
  else
    local okc, r1, r2, r3 = pcall(fn, user, a, b, c)
    if okc then ok, p, x = r1, r2, r3 else ok, p = false, "Server error: " .. tostring(r1); log("ERROR " .. tostring(r1)) end
  end
  last[from] = { rid = rid, ok = ok, p = p, x = x }
  modem.send(from, CFG.PORT, "SGV", "R", rid, ok, p, x)
  if op ~= "SPART" and op ~= "LPART" and op ~= "FIND" then dirty = true end
end

---------------------------------------------------------------- main loop
log("Started on port " .. CFG.PORT .. ", files in " .. CFG.ROOT)
local lastDraw = 0
while true do
  local ev = { event.pull(1) }
  if ev[1] == "interrupted" then break end
  if ev[1] == "modem_message" and ev[4] == CFG.PORT and ev[6] == "SGV" then
    local ok, e = pcall(handle, ev[3], ev[7], ev[8], ev[9], ev[10], ev[11], ev[12])
    if not ok then log("ERROR " .. tostring(e)) end
  end
  local up = computer.uptime()
  for k, x in pairs(xfer) do if up - x.t > 120 then xfer[k] = nil end end
  if dirty or up - lastDraw >= 10 then lastDraw = up; pcall(draw) end
end
if gpu then
  gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, SW, SH, " ")
end
print("Stargate Valley storage server stopped.")
