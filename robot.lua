--[[
  robot.lua  -  Lymanos Robot Control: the program that runs ON the robot

  Keep the master copy of this file on the CONTROLLER at /home/robot.lua.
  The robot's boot.lua downloads it over the Linked Card, so you never edit
  it on the robot itself. Change it on the controller, then press
  "Update Robot" in the Robot Control app.

  The robot does nothing on its own. It waits for commands from the
  controller, carries them out one step at a time, and after every step
  reports back: where it is, which way it faces, energy, tool, inventory,
  and what is in front of / above / below it (detect + geolyzer analyze).

  Robot hardware this expects:
    Linked Card (required), Geolyzer, Inventory Controller Upgrade,
    Inventory Upgrades, Hover Upgrade, Chunkloader Upgrade, Battery Upgrade.
    A pickaxe in the tool slot.

  Position: the robot can't see its own coordinates. It counts its moves
  from a position you give it once ("Set Pos..." on the controller) and
  saves it to /home/robot_pos.dat after every move, so it survives restarts.
]]

local ARGS = ...
local VERSION = "1.0"

local CONFIG = {
  POS_FILE = "/home/robot_pos.dat",
  HEARTBEAT = 10,          -- seconds between status messages while idle
  MAX_SWINGS = 16,         -- swings at one block before giving up (falling gravel/sand)
  SCAN_MAX_R = 6,          -- largest scan radius allowed
  -- items thrown away when the inventory is nearly full (item names, lower case).
  -- Tunnelling through stone fills the robot with cobblestone otherwise.
  JUNK = { "minecraft:cobblestone", "minecraft:dirt", "minecraft:gravel", "minecraft:sand",
           "minecraft:stone", "minecraft:netherrack", "gt.blockgranite", "gt.blockstones",
           "minecraft:flint", "chisel:" },
  JUNK_WHEN_FREE = 3,      -- throw junk away when this many slots or fewer are free
  -- never dig blocks whose name contains one of these (lower case)
  PROTECT = { "opencomputers", "chest", "charger", "enderstorage", "appliedenergistics",
              "gt.blockmachines", "bedrock", "computer", "ironchest", "storagedrawers" },
  -- a block is "ore" when its name contains one of these...
  ORE = { "ore" },
  -- ...unless it also contains one of these
  NOT_ORE = { "core", "store", "orechid" },
}

local component     = require("component")
local computer      = require("computer")
local event         = require("event")
local sides         = require("sides")
local serialization = require("serialization")
local robot         = require("robot")

local floor, max, min = math.floor, math.max, math.min

local tunnel = component.isAvailable("tunnel") and component.tunnel or nil
if not tunnel then error("robot.lua needs a Linked Card", 0) end
local rc    = component.robot
local geo   = component.isAvailable("geolyzer") and component.geolyzer or nil
local ic    = component.isAvailable("inventory_controller") and component.inventory_controller or nil
local chunk = component.isAvailable("chunkloader") and component.chunkloader or nil

local SUM = type(ARGS) == "table" and ARGS.sum or 0
local BOOT = type(ARGS) == "table" and ARGS.boot or "?"

local function send(kind, ...) pcall(tunnel.send, "RC", kind, ...) end
local function ser(t) return serialization.serialize(t) end

------------------------------------------------------------- POSITION
-- facing: 0 = north (-Z), 1 = east (+X), 2 = south (+Z), 3 = west (-X)
local P = { x = 0, y = 64, z = 0, f = 0, set = false }
do
  local f = io.open(CONFIG.POS_FILE, "r")
  if f then
    local ok, t = pcall(serialization.unserialize, f:read("*a"))
    f:close()
    if ok and type(t) == "table" and t.x then P = t end
  end
end
local function savePos()
  local f = io.open(CONFIG.POS_FILE, "w")
  if f then f:write(ser(P)); f:close() end
end
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = -1, 0, 1, 0 }

-- the block on a side (front/back/up/down), in world coordinates
local function neighbor(side)
  if side == sides.up then return P.x, P.y + 1, P.z end
  if side == sides.down then return P.x, P.y - 1, P.z end
  if side == sides.back then return P.x - DX[P.f], P.y, P.z - DZ[P.f] end
  return P.x + DX[P.f], P.y, P.z + DZ[P.f]
end

------------------------------------------------------------- HELPERS
local function has(name, list)
  name = tostring(name or ""):lower()
  for _, p in ipairs(list) do if name:find(p, 1, true) then return true end end
  return false
end
local function isOre(name) return has(name, CONFIG.ORE) and not has(name, CONFIG.NOT_ORE) end

local function analyze(side)
  if not geo then return nil end
  local ok, info = pcall(geo.analyze, side)
  if ok and type(info) == "table" then return info end
  return nil
end

local function counts()
  local c = {}
  for i = 1, robot.inventorySize() do c[i] = robot.count(i) end
  return c
end

local invCache = { used = 0, n = 0 }
local function invInfo()
  local n, used = robot.inventorySize(), 0
  for i = 1, n do if robot.count(i) > 0 then used = used + 1 end end
  invCache.used, invCache.n = used, n
  return used, n
end

local function state(fullInv)
  if fullInv then invInfo() end
  local okd, dur = pcall(robot.durability)
  return {
    x = P.x, y = P.y, z = P.z, f = P.f, set = P.set,
    e = floor(computer.energy()), me = floor(computer.maxEnergy()),
    dur = (okd and type(dur) == "number") and floor(dur * 1000) / 1000 or nil,
    inv = invCache.used, invn = invCache.n,
    ver = VERSION, sum = SUM, boot = BOOT,
    geo = geo ~= nil, ic = ic ~= nil, ck = chunk ~= nil,
  }
end

-- what's in front, above and below: { x, y, z, desc, name, meta, hardness }
local function look(side)
  local x, y, z = neighbor(side)
  local _, desc = rc.detect(side)
  local e = { x, y, z, desc or "?" }
  if desc ~= "air" then
    local info = analyze(side)
    if info then e[5], e[6], e[7] = info.name, info.metadata, info.hardness end
  end
  return e
end
local function senseAll()
  return { look(sides.front), look(sides.up), look(sides.down) }
end

------------------------------------------------------------- ACTIONS
local function move(side)
  local ok, why = rc.move(side)
  if ok then
    if side == sides.up then P.y = P.y + 1
    elseif side == sides.down then P.y = P.y - 1
    elseif side == sides.back then P.x, P.z = P.x - DX[P.f], P.z - DZ[P.f]
    else P.x, P.z = P.x + DX[P.f], P.z + DZ[P.f] end
    savePos()
  end
  return ok, why
end

local function turnTo(f)
  local d = (f - P.f) % 4
  if d == 1 then robot.turnRight() elseif d == 2 then robot.turnAround() elseif d == 3 then robot.turnLeft() end
  P.f = f % 4
  savePos()
  return true
end

-- drop junk stacks (cobblestone etc.) on the ground; returns how many items
local function dumpJunk()
  if not ic then return nil end
  local n = 0
  for i = 1, robot.inventorySize() do
    if robot.count(i) > 0 then
      local okS, st = pcall(ic.getStackInInternalSlot, i)
      if okS and type(st) == "table" and has(st.name, CONFIG.JUNK) then
        robot.select(i)
        local c = robot.count(i)
        rc.drop(sides.down)
        n = n + c - robot.count(i)
      end
    end
  end
  robot.select(1)
  invInfo()
  return n > 0 and n or nil
end

-- dig whatever is on that side (if anything), then move into it.
-- match: nil = dig anything not protected; "ore" = only if it is an ore;
--        any other text = only if "name#meta" equals it.
local function digMove(side, match)
  local blocked, desc = rc.detect(side)
  local oreDig, before = false, nil
  if blocked and desc ~= "entity" then
    local info = analyze(side)
    local name = info and tostring(info.name or "") or ""
    if name ~= "" and has(name, CONFIG.PROTECT) then return false, "protected: " .. name end
    if match then
      local k = name .. "#" .. tostring(info and info.metadata or 0)
      if (match == "ore" and not isOre(name)) or (match ~= "ore" and k ~= match) then
        return false, "nomatch: " .. (name ~= "" and name or "unknown block")
      end
    end
    oreDig = isOre(name)
    if oreDig and ic then before = counts() end
  elseif match and not blocked then
    return false, "nomatch: " .. tostring(desc)      -- the ore isn't there any more
  end
  for _ = 1, CONFIG.MAX_SWINGS do
    blocked, desc = rc.detect(side)
    if not blocked then break end
    local ok, why = rc.swing(side)
    if not ok and desc ~= "entity" then return false, "can't break: " .. tostring(why) end
  end
  blocked, desc = rc.detect(side)
  if blocked and desc ~= "entity" then return false, "still blocked" end
  local moved, why
  for _ = 1, 5 do
    moved, why = move(side)
    if moved then break end
    if why == "entity" then rc.swing(side) else break end
  end
  if not moved then return false, why or "can't move" end
  -- which items did that ore drop? (labels, for the controller's tally)
  local drops
  if before then
    local now = counts()
    for i, c in ipairs(now) do
      if c > (before[i] or 0) then
        local okS, st = pcall(ic.getStackInInternalSlot, i)
        if okS and type(st) == "table" then
          drops = drops or {}
          drops[#drops + 1] = { st.label or st.name or "?", c - (before[i] or 0) }
        end
      end
    end
  end
  local junk
  if ic then
    local used, n = invInfo()
    if n - used <= CONFIG.JUNK_WHEN_FREE then junk = dumpJunk() end
  end
  if drops or junk then return true, nil, { drops = drops, junk = junk } end
  return true
end

local function scan(r, ylo, yhi)
  if not geo then return false, "no geolyzer" end
  r = max(1, min(CONFIG.SCAN_MAX_R, floor(tonumber(r) or 4)))
  ylo, yhi = floor(tonumber(ylo) or -r), floor(tonumber(yhi) or r)
  local w = 2 * r + 1
  local cx, cy, cz = P.x, P.y, P.z
  for dy = ylo, yhi do
    local rows = {}
    for dz = -r, r do
      -- one row along X: offsets are world-aligned, not turned with the robot
      local ok, vals = pcall(geo.scan, -r, dz, dy, w, 1, 1)
      if not ok or type(vals) ~= "table" then return false, "scan failed: " .. tostring(vals) end
      local row = {}
      for i = 1, w do row[i] = string.format("%.1f", tonumber(vals[i]) or 0) end
      rows[#rows + 1] = table.concat(row, ",")
    end
    send("SCAN", cx, cy, cz, r, dy, table.concat(rows, ";"))
  end
  return true
end

local SIDENAME = { down = sides.down, up = sides.up, front = sides.front }
local function unload(sideName)
  local s = SIDENAME[sideName or "down"] or sides.down
  local moved, left = 0, 0
  for i = 1, robot.inventorySize() do
    if robot.count(i) > 0 then
      robot.select(i)
      local c = robot.count(i)
      rc.drop(s)
      if robot.count(i) > 0 then left = left + 1 end
      moved = moved + (c - robot.count(i))
    end
  end
  robot.select(1)
  invInfo()
  if left > 0 then return false, "container full: " .. left .. " stack(s) left", { moved = moved } end
  return true, nil, { moved = moved }
end

local OPS = {
  f = function() return move(sides.front) end,
  b = function() return move(sides.back) end,
  u = function() return move(sides.up) end,
  d = function() return move(sides.down) end,
  l = function() robot.turnLeft(); P.f = (P.f + 3) % 4; savePos(); return true end,
  r = function() robot.turnRight(); P.f = (P.f + 1) % 4; savePos(); return true end,
  a = function() robot.turnAround(); P.f = (P.f + 2) % 4; savePos(); return true end,
  face = function(s) return turnTo(tonumber(s[2]) or 0) end,
  tf = function(s) return digMove(sides.front, s.m) end,
  tu = function(s) return digMove(sides.up, s.m) end,
  td = function(s) return digMove(sides.down, s.m) end,
  dig  = function() return rc.swing(sides.front) end,
  digu = function() return rc.swing(sides.up) end,
  digd = function() return rc.swing(sides.down) end,
  scan = function(s) return scan(s[2], s[3], s[4]) end,
  unload = function(s) return unload(s[2]) end,
  setpos = function(s)
    P.x, P.y, P.z, P.f = floor(tonumber(s[2]) or 0), floor(tonumber(s[3]) or 64), floor(tonumber(s[4]) or 0), floor(tonumber(s[5]) or 0) % 4
    P.set = true
    savePos()
    return true
  end,
  state = function() invInfo(); return true end,
  chunk = function(s)
    if not chunk then return false, "no chunkloader upgrade" end
    chunk.setActive(s[2] and true or false)
    return true
  end,
}

------------------------------------------------------------- MAIN LOOP
local queue = {}
local lastBeat = 0
invInfo()
send("READY", ser(state(false)))

while true do
  local ev = { event.pull(#queue > 0 and 0 or 1, "modem_message") }
  if ev[1] and ev[2] == tunnel.address and ev[6] == "RC" then
    local kind = ev[7]
    if kind == "CMD" then
      local id = ev[8]
      local okU, list = pcall(serialization.unserialize, ev[9])
      if okU and type(list) == "table" then
        for i, st in ipairs(list) do queue[#queue + 1] = { id = id, i = i, n = #list, s = st } end
      end
    elseif kind == "STOP" then
      local n = #queue
      queue = {}
      send("STOPPED", n, ser(state(false)))
    elseif kind == "PING" then
      send("PONG", ser(state(true)))
    elseif kind == "UPDATE" then
      send("BYE", "update")
      return "update"
    elseif kind == "EXIT" then
      send("BYE", "exit")
      return "exit"
    elseif kind == "REBOOT" then
      send("BYE", "reboot")
      computer.shutdown(true)
    end
  end

  if #queue > 0 then
    local q = table.remove(queue, 1)
    local fn = type(q.s) == "table" and OPS[q.s[1]] or nil
    local ok, why, extra
    if not fn then
      ok, why = false, "unknown command " .. tostring(type(q.s) == "table" and q.s[1] or q.s)
    else
      local okc, a, b, c = pcall(fn, q.s)
      if okc then ok, why, extra = a, b, c else ok, why = false, "error: " .. tostring(a) end
    end
    if not ok then                       -- a failed step cancels the rest of its batch
      local keep = {}
      for _, r in ipairs(queue) do if r.id ~= q.id then keep[#keep + 1] = r end end
      queue = keep
    end
    -- (a network message holds at most 8 values, so the report is one table)
    send("RES", q.id, q.i, q.n, ok and true or false, why and tostring(why) or "",
      ser({ st = state(false), se = senseAll(), x = extra }))
    lastBeat = computer.uptime()
  elseif computer.uptime() - lastBeat >= CONFIG.HEARTBEAT then
    send("BEAT", ser(state(true)))
    lastBeat = computer.uptime()
  end
end
