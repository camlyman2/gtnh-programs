--[[
  voidminer.lua  -  Void Miner controller (runs on the planet with the miner)

  Keeps a whitelist of ores. Each ore sits in its own slot of the ORE CHEST.
  Earth (voidctl.lua) says, over the linked card, which ores it wants mined.
  This program moves exactly those ores from their chest slot into the Void
  Miner's input bus, and puts every other one back into ITS OWN chest slot.

  The void miner must be in WHITELIST mode (screwdriver on the controller),
  so the ores in the input bus are the ores it produces.

  Hardware:
    - Computer case (tier 2 is enough) with CPU, 2x memory (tier 2), HDD with
      OpenOS, Lua BIOS EEPROM, tier 2 GPU, tier 2 screen, keyboard
    - Linked Card - crafted as a pair with the one in the Earth computer
    - Transposer touching BOTH the ore chest and the void miner's input bus,
      connected to the computer with OC cable
    - optional: Adapter touching the void miner controller (shows working /
      idle, and pauses the miner while nothing is requested - CONFIG below)

  Use:
    1. Put each ore you want to control in its own slot of the ore chest.
    2. "Add all" adds every ore in the chest with its slot, or "Add slot"
       adds one slot. The slot number is remembered for each ore.
    3. Give the miner a name with "Rename" (Earth shows this name).
    4. On Earth, make rules for the ores in voidctl.lua.

  Files: /home/voidminer.dat (whitelist, name, last request from Earth)
  Exit: Ctrl+C (ores stay where they are).
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  DATA_FILE = "/home/voidminer.dat",
  POLL = 2,                 -- seconds between checks of chest / bus
  REPORT_EVERY = 10,        -- seconds between status reports to Earth
  LINK_TIMEOUT = 120,       -- seconds without any message from Earth = "lost"
  LINK_LOST_ACTION = "keep",-- "keep" = keep mining what was last asked
                            -- "stop" = put every ore back while Earth is silent
  CONTROL_MACHINE = true,   -- with an Adapter on the controller: pause the miner
                            -- when no ore is in the input bus (an empty
                            -- whitelist must not mine everything)
  BUS_SIDE = nil,           -- nil = detect; else 0..5 (transposer side of the input bus)
  CHEST_SIDE = nil,         -- nil = detect; else 0..5 (transposer side of the ore chest)
  LOG_MAX = 8,
}

--------------------------------------------------------------- MODULES
local component     = require("component")
local computer      = require("computer")
local event         = require("event")
local serialization = require("serialization")
local unicode       = require("unicode")
local term          = require("term")
local floor, max, min = math.floor, math.max, math.min

local SIDE = { [0] = "bottom", "top", "north", "south", "west", "east" }

------------------------------------------------------------- SCREEN BUFFER
-- Everything is drawn into memory; flush() sends only changed cells (no flicker).
local rgpu = component.gpu
local gpu
do
  local SW, SH = rgpu.getResolution()
  local P = 16777216
  local wc, wk, hc, hk, lo, hi = {}, {}, {}, {}, {}, {}
  local cf, cb, rf, rb = 0xFFFFFF, 0x000000, nil, nil
  local CH = "[\0-\127\194-\244][\128-\191]*"
  local function touch(y, a, b)
    if not lo[y] or a < lo[y] then lo[y] = a end
    if not hi[y] or b > hi[y] then hi[y] = b end
  end
  gpu = setmetatable({}, { __index = rgpu })
  function gpu.setForeground(c) cf = c end
  function gpu.setBackground(c) cb = c end
  function gpu.set(x, y, s)
    if y < 1 or y > SH then return end
    local k, i, base, first = cf * P + cb, 0, (y - 1) * SW, nil
    for ch in s:gmatch(CH) do
      local xx = x + i
      if xx >= 1 and xx <= SW then wc[base + xx], wk[base + xx] = ch, k; first = first or xx end
      i = i + 1
    end
    if first then touch(y, first, min(SW, x + i - 1)) end
  end
  function gpu.fill(x, y, w, h, ch)
    local x1, x2, y1, y2 = max(1, x), min(SW, x + w - 1), max(1, y), min(SH, y + h - 1)
    if x1 > x2 or y1 > y2 then return end
    local k = cf * P + cb
    for yy = y1, y2 do
      local base = (yy - 1) * SW
      for xx = x1, x2 do wc[base + xx], wk[base + xx] = ch or " ", k end
      touch(yy, x1, x2)
    end
  end
  function gpu.setResolution(w, h)
    local ok = rgpu.setResolution(w, h)
    SW, SH = w, h
    wc, wk, hc, hk, lo, hi, rf, rb = {}, {}, {}, {}, {}, {}, nil, nil
    return ok
  end
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
          if c ~= nil and (c ~= hc[i] or k ~= hk[i]) then
            local parts = { c }
            hc[i], hk[i] = c, k
            local x2 = x + 1
            while x2 <= b do
              local j = base + x2
              if wk[j] ~= k or wc[j] == nil then break end
              parts[#parts + 1] = wc[j]
              hc[j], hk[j] = wc[j], k
              x2 = x2 + 1
            end
            local bgc = k % P
            local fgc = (k - bgc) / P
            if bgc ~= rb then rgpu.setBackground(bgc); rb = bgc end
            if fgc ~= rf then rgpu.setForeground(fgc); rf = fgc end
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

------------------------------------------------------------- DRAW HELPERS
local W, H = 80, 25
local C = {
  bg = 0x1E1E1E, panel = 0x2D2D2D, head = 0x3C3C3C, text = 0xE0E0E0, dim = 0x878787,
  accent = 0x336699, green = 0x339933, red = 0xCC3333, amber = 0xCC9933, sel = 0x336699,
  field = 0x000000, white = 0xFFFFFF,
}

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
local function text(x, y, s, f, b) gpu.setBackground(b); gpu.setForeground(f); gpu.set(x, y, s) end
local function textW(x, y, w, s, f, b, align) text(x, y, fit(s, w, align), f, b) end
local function fill(x, y, w, h, b) gpu.setBackground(b); gpu.fill(x, y, w, h, " ") end

local regions = {}
local function region(x, y, w, h, fn) regions[#regions + 1] = { x = x, y = y, w = w, h = h, fn = fn } end
local function hit(x, y)
  for i = #regions, 1, -1 do
    local r = regions[i]
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then r.fn(x, y); return true end
  end
end
local function btn(x, y, label, b, fn)
  local w = unicode.len(label) + 2
  text(x, y, " " .. label .. " ", C.white, b)
  region(x, y, w, 1, fn)
  return x + w + 1
end

------------------------------------------------------------------ DATA
-- list[i] = { id, slot, name, damage, label, key }   (key = name@damage)
local D = { name = nil, list = {}, nextId = 1, want = {}, hold = false }
local S = {
  err = nil, foreign = {}, busSize = 0, chestSize = 0, lastEarth = nil, lastReport = -99,
  lastPoll = -99, log = {}, sel = 1, scroll = 0, prompt = nil, msg = nil, msgAt = 0,
  machine = nil, machText = "no adapter on the controller", lost = false,
}

local function save()
  local ok, s = pcall(serialization.serialize, D)
  if not ok then return end
  local f = io.open(CONFIG.DATA_FILE, "w")
  if f then f:write(s); f:close() end
end

local function load()
  local f = io.open(CONFIG.DATA_FILE, "r")
  if f then
    local raw = f:read("*a"); f:close()
    local ok, t = pcall(serialization.unserialize, raw)
    if ok and type(t) == "table" then for k, v in pairs(t) do D[k] = v end end
  end
  if type(D.list) ~= "table" then D.list = {} end
  if type(D.want) ~= "table" then D.want = {} end
  D.nextId = tonumber(D.nextId) or 1
  if not D.name then D.name = "Void Miner " .. computer.address():sub(1, 4) end
end

local function logLine(s, bad)
  S.log[#S.log + 1] = { t = computer.uptime(), s = s, bad = bad }
  while #S.log > CONFIG.LOG_MAX do table.remove(S.log, 1) end
end
local function flash(m) S.msg, S.msgAt = m, computer.uptime() end

------------------------------------------------------------ COMPONENTS
local tp, tunnel

local function findComponents()
  local a = component.list("transposer")()
  tp = a and component.proxy(a) or nil
  a = component.list("tunnel")()
  tunnel = a and component.proxy(a) or nil
  S.machine = nil
  for addr in component.list("gt_machine") do S.machine = component.proxy(addr); break end
end

local function looksGT(name)
  name = tostring(name):lower()
  return name:find("blockmachines", 1, true) or name:find("gregtech", 1, true) or name:find("^gt%.")
    or name:find("hatch", 1, true) or name:find("bus", 1, true)
end

-- the side of the input bus (a GregTech block) and of the ore chest (anything else)
local function detectSides()
  D.busSide, D.chestSide = CONFIG.BUS_SIDE, CONFIG.CHEST_SIDE
  if not tp then return end
  local gt, other = {}, {}
  for side = 0, 5 do
    local ok, n = pcall(tp.getInventorySize, side)
    if ok and type(n) == "number" and n > 0 then
      local okn, name = pcall(tp.getInventoryName, side)
      if okn and looksGT(name) then gt[#gt + 1] = side else other[#other + 1] = side end
    end
  end
  if D.busSide == nil then D.busSide = gt[1] end
  if D.chestSide == nil then
    for _, sd in ipairs(other) do if sd ~= D.busSide then D.chestSide = sd; break end end
  end
  if D.busSide == nil then          -- name not recognised: the two inventories, in side order
    for _, sd in ipairs(other) do if sd ~= D.chestSide then D.busSide = sd; break end end
  end
  save()
end

-- { stacks = {...}, bySlot = {...}, size = n }   each stack: slot, name, damage, label, size, key
local function readInv(side)
  if side == nil then return nil, "side not found" end
  local okn, n = pcall(tp.getInventorySize, side)
  if not okn or type(n) ~= "number" then return nil, "nothing on the " .. SIDE[side] .. " side" end
  local out = { stacks = {}, bySlot = {}, size = n }
  local function add(i, s)
    if type(s) == "table" and s.name and s.name ~= "minecraft:air" and (tonumber(s.size) or 0) > 0 then
      local st = { slot = i, name = s.name, damage = floor(tonumber(s.damage) or 0),
                   label = tostring(s.label or s.name), size = floor(s.size) }
      st.key = st.name .. "@" .. st.damage
      out.stacks[#out.stacks + 1] = st
      out.bySlot[i] = st
    end
  end
  local ok, it = pcall(tp.getAllStacks, side)
  if ok and it then
    for i = 1, min(n, 512) do
      local ok2, s = pcall(it)
      if not ok2 then break end
      add(i, s)
    end
  else                                 -- getAllStacks off in this pack's config
    for i = 1, min(n, 512) do
      local ok2, s = pcall(tp.getStackInSlot, side, i)
      if ok2 then add(i, s) end
    end
  end
  return out
end

local function moved(ok, n)
  if not ok then return 0 end
  if n == true then return 1 end
  return floor(tonumber(n) or 0)
end

local function entryById(id) for _, e in ipairs(D.list) do if e.id == id then return e end end end
local function entryByKey(key) for _, e in ipairs(D.list) do if e.key == key then return e end end end

----------------------------------------------------------- RECONCILE
-- Puts every wanted ore into the input bus and every other ore back into its slot.
local function reconcile()
  if not tp then S.err = "No transposer connected."; return end
  if D.busSide == nil or D.chestSide == nil then detectSides() end
  if D.busSide == nil or D.chestSide == nil then
    S.err = "The transposer must touch the ore chest AND the input bus."
    return
  end
  local bus, why = readInv(D.busSide)
  if not bus then S.err = "Cannot read the input bus: " .. tostring(why); return end
  local chest, why2 = readInv(D.chestSide)
  if not chest then S.err = "Cannot read the ore chest: " .. tostring(why2); return end
  S.err, S.busSize, S.chestSize = nil, bus.size, chest.size

  local inBus = {}
  for _, st in ipairs(bus.stacks) do if not inBus[st.key] then inBus[st.key] = st end end

  local stopAll = D.hold or (S.lost and CONFIG.LINK_LOST_ACTION == "stop")
  for _, e in ipairs(D.list) do
    local want = D.want[e.id] and not stopAll
    local b = inBus[e.key]
    local cs = chest.bySlot[e.slot]
    e.problem = nil
    if want and not b then
      if cs and cs.key == e.key then
        local n = moved(pcall(tp.transferItem, D.chestSide, D.busSide, cs.size, e.slot))
        if n > 0 then b = true; logLine("Started " .. e.label)
        else e.problem = "the input bus is full" end
      elseif cs then
        e.problem = "chest slot " .. e.slot .. " holds " .. cs.label
      else
        e.problem = "not in chest slot " .. e.slot
      end
    elseif not want and b then
      if cs and cs.key ~= e.key then
        e.problem = "cannot return: chest slot " .. e.slot .. " holds " .. cs.label
      else
        local n = moved(pcall(tp.transferItem, D.busSide, D.chestSide, b.size, b.slot, e.slot))
        if n > 0 then b = nil; cs = true; logLine("Stopped " .. e.label)
        else e.problem = "cannot return it to chest slot " .. e.slot end
      end
    end
    if b then e.where = "BUS"
    elseif cs and (cs == true or cs.key == e.key) then e.where = "CHEST"
    else e.where = "MISSING" end
  end

  -- items in the bus that are not on the whitelist are left alone, but shown
  S.foreign = {}
  for _, st in ipairs(bus.stacks) do
    if not entryByKey(st.key) then S.foreign[#S.foreign + 1] = st.label end
  end

  -- the controller: pause while no ore is in the bus
  local m = S.machine
  if m then
    local any = false
    for _, e in ipairs(D.list) do if e.where == "BUS" then any = true end end
    any = any or #S.foreign > 0
    if CONFIG.CONTROL_MACHINE then
      local ok, allowed = pcall(m.isWorkAllowed)
      if ok and allowed ~= any then pcall(m.setWorkAllowed, any) end
    end
    local ok, act = pcall(m.isMachineActive)
    if not ok then S.machine = nil; S.machText = "adapter lost"
    elseif act then S.machText = "working"
    elseif CONFIG.CONTROL_MACHINE and not any then S.machText = "paused (nothing requested)"
    else S.machText = "idle (check power / drilling fluid)" end
  else
    S.machText = "no adapter on the controller"
  end
end

------------------------------------------------------------- LINK
local function report()
  if not tunnel then return end
  S.lastReport = computer.uptime()
  local entries = {}
  for i, e in ipairs(D.list) do
    if i > 40 then break end           -- keeps the message under the linked card's size limit
    entries[i] = { id = e.id, label = unicode.sub(e.label, 1, 40), slot = e.slot, inBus = e.where == "BUS",
                   where = e.where, problem = e.problem and unicode.sub(e.problem, 1, 60) or nil }
  end
  local st = { name = D.name, hold = D.hold, entries = entries, machine = S.machText,
               foreign = #S.foreign, err = S.err }
  local ok, s = pcall(serialization.serialize, st)
  if ok then pcall(tunnel.send, "VM_STATE", s) end
end

local function onMessage(localAddr, _, _, _, kind, payload)
  if not tunnel or localAddr ~= tunnel.address then return end
  S.lastEarth, S.lost = computer.uptime(), false
  if kind == "VM_WANT" then
    local ok, ids = pcall(serialization.unserialize, payload)
    if not ok or type(ids) ~= "table" then return end
    local want, changed = {}, false
    for _, id in ipairs(ids) do want[id] = true end
    for id in pairs(want) do if not D.want[id] then changed = true end end
    for id in pairs(D.want) do if not want[id] then changed = true end end
    if changed then
      D.want = want
      save()
      reconcile()
    end
    report()
  elseif kind == "VM_HELLO" then
    report()
  end
end

------------------------------------------------------------- ACTIONS
local function addSlot(slot, chest)
  chest = chest or readInv(D.chestSide)
  if not chest then return false, "cannot read the ore chest" end
  local st = chest.bySlot[slot]
  if not st then return false, "chest slot " .. slot .. " is empty" end
  for _, e in ipairs(D.list) do
    if e.slot == slot then return false, "slot " .. slot .. " is already used by " .. e.label end
    if e.key == st.key then return false, st.label .. " is already on the list (slot " .. e.slot .. ")" end
  end
  D.list[#D.list + 1] = { id = D.nextId, slot = slot, name = st.name, damage = st.damage,
                          label = st.label, key = st.key, where = "CHEST" }
  D.nextId = D.nextId + 1
  return true, st.label
end

local function ask(label, onEnter, value)
  S.prompt = { label = label, value = value or "", onEnter = onEnter }
end

local function selected() return D.list[S.sel] end

------------------------------------------------------------- DRAWING
local ROWS = 14

local function ago(t)
  if not t then return "never" end
  local s = floor(computer.uptime() - t)
  if s < 60 then return s .. "s ago" end
  if s < 3600 then return floor(s / 60) .. "m ago" end
  return floor(s / 3600) .. "h ago"
end

local function drawAll()
  regions = {}
  fill(1, 1, W, H, C.bg)

  -- title
  fill(1, 1, W, 1, C.accent)
  textW(2, 1, 50, "Void Miner - " .. D.name, C.white, C.accent)
  local link = not tunnel and "no linked card" or (S.lastEarth and ("Earth " .. ago(S.lastEarth)) or "waiting for Earth")
  local lc = (not tunnel or S.lost) and C.red or (S.lastEarth and C.white or C.amber)
  textW(52, 1, 28, "● " .. link .. " ", lc, C.accent, "right")

  -- status
  textW(2, 2, 40, "Miner: " .. S.machText, C.text, C.bg)
  if D.hold then textW(44, 2, 36, "HOLD - Earth requests ignored", C.amber, C.bg, "right")
  elseif S.lost then textW(44, 2, 36, "Earth silent - " .. (CONFIG.LINK_LOST_ACTION == "stop" and "all stopped" or "keeping last request"), C.amber, C.bg, "right")
  end
  if S.err then textW(2, 3, 78, "! " .. S.err, C.red, C.bg) end

  -- table
  fill(1, 4, W, 1, C.head)
  textW(2, 4, 3, "#", C.dim, C.head)
  textW(5, 4, 30, "Ore", C.dim, C.head)
  textW(36, 4, 5, "Slot", C.dim, C.head, "right")
  textW(43, 4, 8, "Where", C.dim, C.head)
  textW(52, 4, 6, "Earth", C.dim, C.head)
  textW(59, 4, 21, "Note", C.dim, C.head)
  S.scroll = max(0, min(S.scroll, #D.list - ROWS))
  S.sel = max(1, min(S.sel, max(1, #D.list)))
  for r = 1, ROWS do
    local i = S.scroll + r
    local e = D.list[i]
    local y = 4 + r
    local b = (i == S.sel and e) and C.sel or (r % 2 == 0 and C.panel or C.bg)
    fill(1, y, W, 1, b)
    if e then
      local wc = e.where == "BUS" and C.green or (e.where == "MISSING" and C.red or C.dim)
      textW(2, y, 3, tostring(i), C.dim, b)
      textW(5, y, 30, e.label, C.text, b)
      textW(36, y, 5, tostring(e.slot), C.text, b, "right")
      textW(43, y, 8, e.where == "BUS" and "MINING" or (e.where or "?"), wc, b)
      textW(52, y, 6, D.want[e.id] and "wants" or "-", D.want[e.id] and C.green or C.dim, b)
      textW(59, y, 21, e.problem or "", C.red, b)
      region(1, y, W, 1, function() S.sel = i end)
    elseif i == 1 then
      textW(5, y, 70, "(empty - put ores in the chest, then press Add all or Add slot)", C.dim, b)
    end
  end

  -- buttons
  local y = 20
  fill(1, y, W, 1, C.bg)
  local x = 2
  x = btn(x, y, "Add slot", C.head, function()
    ask("Chest slot of the new ore:", function(v)
      local n = tonumber(v)
      if not n then flash("Type a slot number"); return end
      local ok, m = addSlot(floor(n))
      if ok then save(); flash("Added " .. m .. " (slot " .. floor(n) .. ")"); reconcile(); report()
      else flash(m) end
    end)
  end)
  x = btn(x, y, "Add all", C.head, function()
    local chest = readInv(D.chestSide)
    if not chest then flash("Cannot read the ore chest"); return end
    local n = 0
    for _, st in ipairs(chest.stacks) do if addSlot(st.slot, chest) then n = n + 1 end end
    save(); flash(n .. " ore(s) added"); reconcile(); report()
  end)
  x = btn(x, y, "Slot", C.head, function()
    local e = selected()
    if not e then flash("Select an ore first"); return end
    ask("New chest slot for " .. e.label .. ":", function(v)
      local n = tonumber(v)
      if not n then flash("Type a slot number"); return end
      for _, o in ipairs(D.list) do
        if o ~= e and o.slot == floor(n) then flash("Slot " .. floor(n) .. " is used by " .. o.label); return end
      end
      e.slot = floor(n); save(); flash(e.label .. " now uses slot " .. e.slot); reconcile(); report()
    end)
  end)
  x = btn(x, y, "Remove", C.red, function()
    local e = selected()
    if not e then flash("Select an ore first"); return end
    if e.where == "BUS" then
      D.want[e.id] = nil
      reconcile()
      if e.where == "BUS" then flash("Cannot put " .. e.label .. " back - " .. tostring(e.problem)); return end
    end
    for i, o in ipairs(D.list) do if o == e then table.remove(D.list, i); break end end
    D.want[e.id] = nil
    save(); flash("Removed " .. e.label); report()
  end)
  x = btn(x, y, "Rename", C.head, function()
    ask("Name of this miner (shown on Earth):", function(v)
      v = v:gsub("^%s+", ""):gsub("%s+$", "")
      if v ~= "" then D.name = v; save(); report(); flash("Renamed") end
    end, D.name)
  end)
  x = btn(x, y, D.hold and "Resume" or "Hold", D.hold and C.green or C.amber, function()
    D.hold = not D.hold
    save(); reconcile(); report()
    flash(D.hold and "Hold: every ore is back in the chest" or "Following Earth again")
  end)
  btn(x, y, "Detect", C.head, function()
    findComponents(); detectSides(); reconcile(); report()
    flash("Bus: " .. (D.busSide and SIDE[D.busSide] or "?") .. ", chest: " .. (D.chestSide and SIDE[D.chestSide] or "?"))
  end)

  -- prompt / message
  fill(1, 22, W, 1, C.bg)
  if S.prompt then
    local lw = unicode.len(S.prompt.label) + 1
    textW(2, 22, lw, S.prompt.label, C.text, C.bg)
    textW(2 + lw, 22, W - 3 - lw, " " .. S.prompt.value .. "_", C.white, C.field)
  elseif S.msg and computer.uptime() - S.msgAt < 8 then
    textW(2, 22, W - 2, S.msg, C.amber, C.bg)
  end

  -- footer
  textW(2, 23, W - 2, "Input bus: " .. (D.busSide and SIDE[D.busSide] or "?") .. " (" .. S.busSize .. " slots)   " ..
    "Ore chest: " .. (D.chestSide and SIDE[D.chestSide] or "?") .. " (" .. S.chestSize .. " slots)   " ..
    (#S.foreign > 0 and ("Other items in bus: " .. #S.foreign) or ""), C.dim, C.bg)
  local last = S.log[#S.log]
  textW(2, 24, W - 2, last and ("Last: " .. last.s .. "  (" .. ago(last.t) .. ")") or "", C.dim, C.bg)
  textW(2, 25, W - 2, "Click a row to select it.  Enter = OK, Esc = cancel.  Ctrl+C = quit.", C.dim, C.bg)
end

------------------------------------------------------------- MAIN
local function onKey(ch, code)
  local p = S.prompt
  if not p then return end
  if code == 28 or code == 156 then S.prompt = nil; p.onEnter(p.value)
  elseif code == 1 then S.prompt = nil
  elseif code == 14 then p.value = unicode.sub(p.value, 1, -2)
  elseif ch and ch >= 32 and ch < 127 and #p.value < 40 then p.value = p.value .. string.char(ch) end
end

local oldW, oldH = rgpu.getResolution()

local function main()
  local mw, mh = rgpu.maxResolution()
  if mw < W or mh < H then error("voidminer needs a tier 2 GPU and screen (80x25).", 0) end
  gpu.setResolution(W, H)
  load()
  findComponents()
  if D.busSide == nil or D.chestSide == nil or CONFIG.BUS_SIDE or CONFIG.CHEST_SIDE then detectSides() end
  reconcile()
  report()
  while true do
    drawAll()
    gpu.flush()
    local ev = { event.pull(0.5) }
    local name = ev[1]
    if name == "interrupted" then break
    elseif name == "modem_message" then onMessage(table.unpack(ev, 2))
    elseif name == "touch" then hit(ev[3], ev[4])
    elseif name == "scroll" then S.scroll = S.scroll - ev[5]
    elseif name == "key_down" then onKey(ev[3], ev[4])
    elseif name == "component_added" or name == "component_removed" then findComponents()
    end
    local up = computer.uptime()
    if S.lastEarth and up - S.lastEarth > CONFIG.LINK_TIMEOUT and not S.lost then
      S.lost = true
      logLine("Earth is silent", true)
    end
    if up - S.lastPoll >= CONFIG.POLL then
      S.lastPoll = up
      local ok, e = pcall(reconcile)
      if not ok then S.err = "Program error: " .. tostring(e) end
    end
    if up - S.lastReport >= CONFIG.REPORT_EVERY then report() end
  end
end

local ok, err = xpcall(main, debug.traceback)
save()
gpu.setResolution(oldW, oldH)
rgpu.setBackground(0x000000)
rgpu.setForeground(0xFFFFFF)
term.clear()
if not ok and not tostring(err):find("interrupted") then io.stderr:write(tostring(err) .. "\n") end
