--[[
  pokered.lua - Pokemon Red, natively rewritten for OpenComputers (GTNH)
  Stage 1: Gen 1 battle engine + trainer battles (Battle Mode / Gym Gauntlet)
  Stage 2: overworld - all of Kanto, NPCs, trainers, wild Pokemon, catching, items, marts, saving

  Needs: Tier 3 GPU + Tier 3 screen (160x50), keyboard, ~1 MB+ RAM.
  Data:  run pokered_convert.py on your PC against a pret/pokered checkout and
         copy its output (data.lua + gfx.pak) next to this file.

  Usage: pokered            play
         pokered sim [n]    headless AI-vs-AI test battles (prints a log)

  Controls: arrows move, Z / Enter / Space = A, X / Backspace = B, Tab or S = START (overworld)
  Works on Lua 5.2 and 5.3 architectures.
]]

local VERSION = "0.2 (stage 2: overworld)"
local args = {...}
local SIM = args[1] == "sim"

-----------------------------------------------------------------------
-- environment
-----------------------------------------------------------------------
local loadString = load   -- (the save loader below is also called "load")
local hasOC = pcall(require, "component")
local component = hasOC and require("component") or nil
local event = hasOC and require("event") or nil
local computer = hasOC and require("computer") or nil
local unicode = (hasOC and pcall(require, "unicode")) and require("unicode") or nil
local fs = (hasOC and pcall(require, "filesystem")) and require("filesystem") or nil

local function here()
  local src = debug.getinfo(1, "S").source or ""
  local dir = src:match("^@(.*/)")
  return dir or "./"
end
local ROOT = here()
for _, a in ipairs(args) do
  local r = a:match("^%-%-root=(.+)$")
  if r then ROOT = r:sub(-1) == "/" and r or (r .. "/") end
end

local function now() return computer and computer.uptime() or os.clock() end
local function sleep(t) if hasOC then os.sleep(t) end end
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local function ulen(s) return unicode and unicode.len(s) or #s:gsub("[\128-\191]", "") end
local function usub(s, i, j) if unicode then return unicode.sub(s, i, j) end return s:sub(i, j) end
local function pad(s, n) local l = ulen(s); if l >= n then return usub(s, 1, n) end return s .. string.rep(" ", n - l) end
local function rpad(s, n) s = tostring(s); local l = ulen(s); if l >= n then return s end return string.rep(" ", n - l) .. s end
local function rnd(a, b) return math.random(a, b) end
local function copy(t) local r = {}; for k, v in pairs(t) do r[k] = v end; return r end
math.randomseed(floor((os.time() or 0) + now() * 1000))

-----------------------------------------------------------------------
-- data
-----------------------------------------------------------------------
local okData, D = pcall(dofile, ROOT .. "data.lua")
if not okData then
  io.stderr:write("pokered: could not load " .. ROOT .. "data.lua\n" .. tostring(D) ..
    "\nRun pokered_convert.py on your PC and copy data.lua + gfx.pak here.\n")
  return
end
local SP, MV, TR = D.species, D.moves, D.trainers
local MOVE = {}           -- MOVE.TACKLE -> id
local NUM_MOVES = 0
for id, m in pairs(MV) do MOVE[m.const] = id; if id > NUM_MOVES then NUM_MOVES = id end end
local TRAINER = {}        -- TRAINER.BROCK -> class id
for id, t in pairs(TR) do TRAINER[t.const] = id end
local PHYSICAL = {NORMAL=1, FIGHTING=1, FLYING=1, POISON=1, GROUND=1, ROCK=1, BIRD=1, BUG=1, GHOST=1}
local HIGH_CRIT = {[MOVE.KARATE_CHOP]=1, [MOVE.RAZOR_LEAF]=1, [MOVE.CRABHAMMER]=1, [MOVE.SLASH]=1}
local STAGE_RATIO = {[-6]={25,100},[-5]={28,100},[-4]={33,100},[-3]={40,100},[-2]={50,100},[-1]={66,100},
  [0]={1,1},[1]={15,10},[2]={2,1},[3]={25,10},[4]={3,1},[5]={35,10},[6]={4,1}}
local STAT_NAME = {atk="ATTACK", def="DEFENSE", spd="SPEED", spc="SPECIAL", acc="ACCURACY", eva="EVADE"}

-----------------------------------------------------------------------
-- sprites (.pic: w, h, 2-bit packed shades)
-----------------------------------------------------------------------
local picCache, picOrder = {}, {}
local pakIndex, pakBase
local function pakRead(rel)
  if pakIndex == nil then
    pakIndex = false
    local f = io.open(ROOT .. "gfx.pak", "rb")
    if f then
      if f:read("*l") == "PAK1" then
        pakIndex = {}
        local base = 5
        while true do
          local line = f:read("*l")
          base = base + #line + 1
          if line == "" then break end
          local name, off, len = line:match("^(%S+) (%d+) (%d+)$")
          pakIndex[name] = {tonumber(off), tonumber(len)}
        end
        pakBase = base
      end
      f:close()
    end
  end
  local e = pakIndex and pakIndex[rel]
  if not e then return nil end
  local f = io.open(ROOT .. "gfx.pak", "rb")
  f:seek("set", pakBase + e[1])
  local raw = f:read(e[2])
  f:close()
  return raw
end
local function loadPic(rel)
  if picCache[rel] then return picCache[rel] end
  local raw = pakRead(rel)
  if not raw then
    local f = io.open(ROOT .. "gfx/" .. rel .. ".pic", "rb")
    if not f then return nil end
    raw = f:read("*a"); f:close()
  end
  local w, h = raw:byte(1), raw:byte(2)
  local out, n = {}, 0
  for i = 3, #raw do
    local b = raw:byte(i)
    out[#out + 1] = string.char(floor(b / 64) % 4, floor(b / 16) % 4, floor(b / 4) % 4, b % 4)
  end
  local pic = {w = w, h = h, px = table.concat(out)}
  picCache[rel] = pic
  picOrder[#picOrder + 1] = rel
  if #picOrder > 8 then picCache[table.remove(picOrder, 1)] = nil end
  return pic
end
local function shadeAt(pic, x, y) -- 0-based
  if x < 0 or y < 0 or x >= pic.w or y >= pic.h then return 0 end
  return pic.px:byte(y * pic.w + x + 1)
end

-----------------------------------------------------------------------
-- Pokemon
-----------------------------------------------------------------------
local function hpDV(dv) return (dv.atk % 2) * 8 + (dv.def % 2) * 4 + (dv.spd % 2) * 2 + (dv.spc % 2) end
local function calcStats(mon)
  local b = SP[mon.species].base
  local dv, se = mon.dvs, mon.statexp or {0, 0, 0, 0, 0}
  local function st(base, d, e, isHP)
    local v = floor(((base + d) * 2 + floor(ceil(math.sqrt(e)) / 4)) * mon.level / 100)
    return isHP and (v + mon.level + 10) or (v + 5)
  end
  mon.stats = {
    hp = st(b[1], hpDV(dv), se[1], true), atk = st(b[2], dv.atk, se[2]), def = st(b[3], dv.def, se[3]),
    spd = st(b[4], dv.spd, se[4]), spc = st(b[5], dv.spc, se[5]),
  }
end
local function defaultMoves(species, level)
  local s, mv = SP[species], {}
  local function add(m)
    for _, k in ipairs(mv) do if k == m then return end end
    mv[#mv + 1] = m
    if #mv > 4 then table.remove(mv, 1) end
  end
  for _, m in ipairs(s.lv1) do add(m) end
  for _, l in ipairs(s.learn) do if l[1] <= level then add(l[2]) end end
  return mv
end
local function newMon(species, level, dvs, moves)
  local mon = {species = species, level = level, dvs = dvs or {atk = rnd(0, 15), def = rnd(0, 15), spd = rnd(0, 15), spc = rnd(0, 15)}}
  mon.moves = moves or defaultMoves(species, level)
  calcStats(mon)
  mon.hp = mon.stats.hp
  mon.pp = {}
  for i, m in ipairs(mon.moves) do mon.pp[i] = MV[m].pp end
  return mon
end
local function healMon(mon)
  calcStats(mon)
  mon.hp, mon.status, mon.sleep = mon.stats.hp, nil, nil
  mon.pp = {}
  for i, m in ipairs(mon.moves) do mon.pp[i] = MV[m].pp end
end
local function learnable(species, level)
  local s, seen, list = SP[species], {}, {}
  for _, m in ipairs(s.lv1) do if not seen[m] then seen[m] = true; list[#list + 1] = {m, "L1"} end end
  for _, l in ipairs(s.learn) do
    if l[1] <= level and not seen[l[2]] then seen[l[2]] = true; list[#list + 1] = {l[2], "L" .. l[1]} end
  end
  for _, m in ipairs(s.tmhm) do if not seen[m] then seen[m] = true; list[#list + 1] = {m, "TM"} end end
  return list
end

-- trainer party, built the way Gen 1 does it
local GYM_ORDER = {"BROCK", "MISTY", "LT_SURGE", "ERIKA", "KOGA", "SABRINA", "BLAINE", "GIOVANNI"}
local function trainerParty(cid, partyIdx)
  local t = TR[cid]
  local p = t.parties[partyIdx]
  local party = {}
  for i, e in ipairs(p.mons) do
    party[i] = newMon(e[2], e[1], {atk = 9, def = 8, spd = 8, spc = 8})
  end
  local function setMove3(mon, move)
    mon.moves[3] = move
    for i = 1, 4 do if mon.moves[i] == nil then mon.moves[i] = nil end end
    -- compact (slot 3 may be past the end if the mon knows < 3 moves)
    local mv = {}
    for i = 1, 4 do if mon.moves[i] then mv[#mv + 1] = mon.moves[i] end end
    mon.moves = mv
    mon.pp = {}
    for i, m in ipairs(mon.moves) do mon.pp[i] = MV[m].pp end
  end
  -- gym leader signature move (LoneMoves)
  for gi, const in ipairs(GYM_ORDER) do
    if t.const == const and (const ~= "GIOVANNI" or partyIdx == 3) and D.lone[gi] then
      local mi, move = D.lone[gi][1], D.lone[gi][2]
      if party[mi] then setMove3(party[mi], move) end
    end
  end
  if D.team[cid] and party[5] then setMove3(party[5], D.team[cid]) end
  if t.const == "RIVAL3" then
    if party[1] then setMove3(party[1], MOVE.SKY_ATTACK) end
    local starterMove = ({MOVE.BLIZZARD, MOVE.MEGA_DRAIN, MOVE.FIRE_BLAST})[partyIdx]
    if party[6] and starterMove then setMove3(party[6], starterMove) end
  end
  return party
end

local RIVAL_NAME, PLAYER_NAME = "BLUE", "RED"
local function trainerName(cid)
  local t = TR[cid]
  if t.const:match("^RIVAL") then return RIVAL_NAME end
  return t.name
end

-----------------------------------------------------------------------
-- type effectiveness (Gen 1 table order matters)
-----------------------------------------------------------------------
local function typeEffect(mtype, dtypes)
  local mults, total = {}, 10
  for _, e in ipairs(D.chart) do
    if e[1] == mtype then
      for _, t in ipairs(dtypes) do
        if e[2] == t then mults[#mults + 1] = e[3]; total = total * e[3] / 10 end
      end
    end
  end
  return mults, total
end

-----------------------------------------------------------------------
-- battle engine
-----------------------------------------------------------------------
local Battle = {}
Battle.__index = Battle

local function chance(n256) return rnd(0, 255) < n256 end

function Battle.new(o)
  local b = setmetatable({}, Battle)
  b.ui = o.ui
  b.sides = {
    {party = o.party1, ctrl = o.ctrl1, name = o.name1 or PLAYER_NAME},
    {party = o.party2, ctrl = o.ctrl2, name = o.name2, trainer = o.trainer},
  }
  b.lastDamage = 0
  b.wild, b.game, b.bag, b.onCatch = o.wild, o.game, o.bag, o.onCatch
  b.runs, b.part = 0, {}
  return b
end

function Battle:msg(s) self.ui:msg(s) end
function Battle:nm(B)
  local n = SP[B.mon.species].name
  return B.side == 2 and ("Enemy " .. n) or n
end
function Battle:foe(B) return self.sides[3 - B.side].active end

function Battle:sendOut(s, idx)
  local side = self.sides[s]
  local mon = side.party[idx]
  local B = {
    side = s, mon = mon, idx = idx, species = mon.species,
    raw = {atk = mon.stats.atk, def = mon.stats.def, spd = mon.stats.spd, spc = mon.stats.spc},
    stages = {atk = 0, def = 0, spd = 0, spc = 0, acc = 0, eva = 0},
    types = copy(SP[mon.species].types), moves = copy(mon.moves), pp = mon.pp,
    turnsOut = 0, toxic = 0,
  }
  local old = side.active
  side.active = B
  -- who fought the current enemy (for EXP)
  if s == 2 then self.part = {} end
  if self.sides[1].active then self.part[self.sides[1].active.idx] = true end
  -- leaving the field ends traps involving the old mon
  local foe = self.sides[3 - s].active
  if foe and old then
    if foe.trap then foe.trap = nil end
    foe.trapped = nil
  end
  self.ui:sendOut(B, side)
end

function Battle:usable(s)
  for i, m in ipairs(self.sides[s].party) do if m.hp > 0 then return i end end
end

function Battle:stat(B, k, ignoreStages)
  local v = B.raw[k]
  if not ignoreStages then
    local r = STAGE_RATIO[B.stages[k]]
    v = floor(v * r[1] / r[2])
    if k == "atk" and B.mon.status == "BRN" then v = floor(v / 2) end
    if k == "spd" and B.mon.status == "PAR" then v = floor(v / 4) end
  end
  return max(1, min(999, v))
end

function Battle:damageMon(B, dmg, quiet)
  local mon = B.mon
  local old = mon.hp
  mon.hp = max(0, mon.hp - dmg)
  if B.bide then B.bide.dmg = B.bide.dmg + (old - mon.hp) end
  self.ui:hp(B, old, mon.hp)
  return old - mon.hp
end
function Battle:healMon(B, amt)
  local mon = B.mon
  local old = mon.hp
  mon.hp = min(mon.stats.hp, mon.hp + amt)
  self.ui:hp(B, old, mon.hp)
  return mon.hp - old
end

function Battle:setStatus(B, st, sleepTurns)
  B.mon.status = st
  if st == "SLP" then B.mon.sleep = sleepTurns or rnd(1, 7) end
  self.ui:status(B)
end

-- stat stage change; returns true if it worked
function Battle:stage(B, k, delta, byFoe)
  if byFoe and B.mist then self:msg(self:nm(B) .. "'s protected by MIST!"); return false end
  local cur = B.stages[k]
  local nv = max(-6, min(6, cur + delta))
  if nv == cur or (delta > 0 and k ~= "acc" and k ~= "eva" and B.raw[k] and self:stat(B, k) >= 999) then
    self:msg("Nothing happened!")
    return false
  end
  B.stages[k] = nv
  local word = delta > 0 and (delta > 1 and " greatly rose!" or " rose!") or (delta < -1 and " greatly fell!" or " fell!")
  self:msg(self:nm(B) .. "'s " .. STAT_NAME[k] .. word)
  return true
end

function Battle:critical(A, moveId)
  local base = SP[A.species].base[4]
  local t = floor(base / 2)
  if HIGH_CRIT[moveId] then t = min(255, base * 4)
  elseif A.focus then t = floor(base / 8) end   -- Gen 1 Focus Energy bug
  return rnd(0, 255) < t
end

function Battle:hits(A, D, move)
  if move.effect == "SWIFT_EFFECT" then return true end
  if D.invuln then return false end
  if move.effect == "DREAM_EATER_EFFECT" and D.mon.status ~= "SLP" then return false end
  local acc = floor(move.acc * 255 / 100)
  local r = STAGE_RATIO[A.stages.acc]; acc = floor(acc * r[1] / r[2])
  r = STAGE_RATIO[-D.stages.eva]; acc = floor(acc * r[1] / r[2])
  acc = max(1, min(255, acc))
  return rnd(0, 255) < acc
end

-- returns damage, crit, total effectiveness (x10)
function Battle:calcDamage(A, D, move, moveId, opt)
  opt = opt or {}
  local mtype = opt.typeless and "NONE" or move.type
  local crit = (not opt.noCrit) and self:critical(A, moveId)
  local lvl = A.mon.level * (crit and 2 or 1)
  local physical = PHYSICAL[move.type] or opt.typeless
  local a, d
  if physical then
    a, d = self:stat(A, "atk", crit), self:stat(D, "def", crit)
    if crit then a, d = A.raw.atk, D.raw.def end
    if D.reflect and not crit then d = d * 2 end
  else
    a, d = self:stat(A, "spc", crit), self:stat(D, "spc", crit)
    if crit then a, d = A.raw.spc, D.raw.spc end
    if D.lightscreen and not crit then d = d * 2 end
  end
  if move.effect == "EXPLODE_EFFECT" then d = max(1, floor(d / 2)) end
  if a > 255 or d > 255 then a = max(1, floor(a / 4)); d = max(1, floor(d / 4)) end
  local dmg = floor(floor(floor(2 * lvl / 5 + 2) * a * move.power / d) / 50)
  dmg = min(dmg, 997) + 2
  local total = 10
  if not opt.typeless then
    for _, t in ipairs(A.types) do if t == mtype then dmg = dmg + floor(dmg / 2); break end end
    local mults
    mults, total = typeEffect(mtype, D.types)
    for _, m in ipairs(mults) do dmg = floor(dmg * m / 10) end
  end
  if total == 0 then return 0, false, 0 end
  if dmg > 1 and not opt.noRandom then dmg = floor(dmg * rnd(217, 255) / 255) end
  return max(1, dmg), crit, total
end

function Battle:effMsg(total, D)
  if total > 10 then self:msg("It's super effective!")
  elseif total < 10 and total > 0 then self:msg("It's not very effective...") end
end

-- deal damage to target (respecting substitute); returns damage dealt
function Battle:applyHit(A, D, dmg)
  self.lastDamage = dmg
  if D.sub then
    D.sub = D.sub - dmg
    if D.sub <= 0 then
      D.sub = nil
      self:msg("The SUBSTITUTE broke!")
      self.ui:subChanged(D)
      return dmg, true
    end
    self:msg("The SUBSTITUTE took damage for " .. self:nm(D) .. "!")
    return dmg, true
  end
  self.ui:hitFlash(D)
  local dealt = self:damageMon(D, dmg)
  if D.rage and D.mon.hp > 0 then
    D.stages.atk = min(6, D.stages.atk + 1)
    self:msg(self:nm(D) .. "'s RAGE is building!")
  end
  return dealt, false
end

local SIDE = {
  BURN_SIDE_EFFECT1 = {"BRN", 26}, BURN_SIDE_EFFECT2 = {"BRN", 77},
  FREEZE_SIDE_EFFECT1 = {"FRZ", 26}, FREEZE_SIDE_EFFECT2 = {"FRZ", 77},
  PARALYZE_SIDE_EFFECT1 = {"PAR", 26}, PARALYZE_SIDE_EFFECT2 = {"PAR", 77},
  POISON_SIDE_EFFECT1 = {"PSN", 52}, POISON_SIDE_EFFECT2 = {"PSN", 103},
}
local STATUS_WORD = {BRN = " was burned!", FRZ = " was frozen solid!", PAR = "'s paralyzed! It may not attack!", PSN = " was poisoned!"}
local STAT_EFFECT = {
  ATTACK_UP1_EFFECT = {"atk", 1}, DEFENSE_UP1_EFFECT = {"def", 1}, SPEED_UP1_EFFECT = {"spd", 1},
  SPECIAL_UP1_EFFECT = {"spc", 1}, ACCURACY_UP1_EFFECT = {"acc", 1}, EVASION_UP1_EFFECT = {"eva", 1},
  ATTACK_UP2_EFFECT = {"atk", 2}, DEFENSE_UP2_EFFECT = {"def", 2}, SPEED_UP2_EFFECT = {"spd", 2},
  SPECIAL_UP2_EFFECT = {"spc", 2}, ACCURACY_UP2_EFFECT = {"acc", 2}, EVASION_UP2_EFFECT = {"eva", 2},
  ATTACK_DOWN1_EFFECT = {"atk", -1}, DEFENSE_DOWN1_EFFECT = {"def", -1}, SPEED_DOWN1_EFFECT = {"spd", -1},
  SPECIAL_DOWN1_EFFECT = {"spc", -1}, ACCURACY_DOWN1_EFFECT = {"acc", -1}, EVASION_DOWN1_EFFECT = {"eva", -1},
  ATTACK_DOWN2_EFFECT = {"atk", -2}, DEFENSE_DOWN2_EFFECT = {"def", -2}, SPEED_DOWN2_EFFECT = {"spd", -2},
  SPECIAL_DOWN2_EFFECT = {"spc", -2}, ACCURACY_DOWN2_EFFECT = {"acc", -2}, EVASION_DOWN2_EFFECT = {"eva", -2},
}
local STAT_SIDE = {ATTACK_DOWN_SIDE_EFFECT = "atk", DEFENSE_DOWN_SIDE_EFFECT = "def",
  SPEED_DOWN_SIDE_EFFECT = "spd", SPECIAL_DOWN_SIDE_EFFECT = "spc"}
-- effects that target the user and skip the accuracy check
local SELF_EFFECT = {HEAL_EFFECT = 1, FOCUS_ENERGY_EFFECT = 1, MIST_EFFECT = 1, REFLECT_EFFECT = 1,
  LIGHT_SCREEN_EFFECT = 1, SUBSTITUTE_EFFECT = 1, HAZE_EFFECT = 1, CONVERSION_EFFECT = 1, SPLASH_EFFECT = 1,
  METRONOME_EFFECT = 1, MIRROR_MOVE_EFFECT = 1, BIDE_EFFECT = 1, SWITCH_AND_TELEPORT_EFFECT = 1, TRANSFORM_EFFECT = 1}

local CHARGE_TEXT = {
  RAZOR_WIND = " made a whirlwind!", SOLARBEAM = " took in sunlight!", SKULL_BASH = " lowered its head!",
  SKY_ATTACK = " is glowing!", FLY = " flew up high!", DIG = " dug a hole!",
}

local function multiHits()
  local r = rnd(0, 7)
  if r < 3 then return 2 elseif r < 6 then return 3 elseif r < 7 then return 4 end
  return 5
end

function Battle:sideEffects(A, D, move, moveId, sawSub)
  if D.mon.hp <= 0 or sawSub then return end
  local e = move.effect
  local se = SIDE[e]
  if se then
    if D.mon.status == nil and chance(se[2]) then
      for _, t in ipairs(D.types) do if t == move.type then return end end
      if se[1] == "PSN" then for _, t in ipairs(D.types) do if t == "POISON" then return end end end
      self:setStatus(D, se[1])
      self:msg(self:nm(D) .. STATUS_WORD[se[1]])
    end
    return
  end
  if e == "FLINCH_SIDE_EFFECT1" or e == "FLINCH_SIDE_EFFECT2" then
    if chance(e == "FLINCH_SIDE_EFFECT1" and 26 or 77) and not D.acted then D.flinch = true end
    return
  end
  if e == "CONFUSION_SIDE_EFFECT" then
    if chance(26) and not D.confused then D.confused = rnd(2, 5); self:msg(self:nm(D) .. " became confused!") end
    return
  end
  if STAT_SIDE[e] then
    if chance(85) and not D.mist then self:stage(D, STAT_SIDE[e], -1, true) end
    return
  end
  if e == "TWINEEDLE_EFFECT" then
    if D.mon.status == nil and chance(52) then
      for _, t in ipairs(D.types) do if t == "POISON" then return end end
      self:setStatus(D, "PSN"); self:msg(self:nm(D) .. STATUS_WORD.PSN)
    end
  end
end

-- the big one: A uses moveId on D
function Battle:useMove(A, D, moveId, cont)
  local move = MV[moveId]
  local e = move.effect
  local name = self:nm(A)
  A.lastMove = moveId

  if not cont then self:msg(name .. " used " .. move.name .. "!") end

  -- moves that become other moves
  if e == "METRONOME_EFFECT" then
    local pick
    repeat pick = rnd(1, NUM_MOVES) until MV[pick] and pick ~= MOVE.METRONOME and pick ~= MOVE.STRUGGLE
    return self:useMove(A, D, pick)
  elseif e == "MIRROR_MOVE_EFFECT" then
    local lm = D.lastMove
    if not lm or lm == MOVE.MIRROR_MOVE then self:msg("But it failed!"); return end
    return self:useMove(A, D, lm)
  end

  -- two-turn moves: first turn
  if (e == "CHARGE_EFFECT" or e == "FLY_EFFECT") and not A.charging then
    A.charging = moveId
    if moveId == MOVE.FLY or moveId == MOVE.DIG then A.invuln = true end
    self:msg(name .. (CHARGE_TEXT[move.const] or " is charging up!"))
    self.ui:sprite(A, not A.invuln)
    return
  end
  if A.charging then
    A.charging, A.invuln = nil, nil
    self.ui:sprite(A, true)
  end

  -- non-damaging moves
  if move.power == 0 and e ~= "SPECIAL_DAMAGE_EFFECT" and moveId ~= MOVE.COUNTER and e ~= "OHKO_EFFECT"
      and e ~= "SUPER_FANG_EFFECT" and e ~= "BIDE_EFFECT" then
    if not SELF_EFFECT[e] and not self:hits(A, D, move) then
      self:msg(name .. "'s attack missed!")
      return
    end
    return self:statusMove(A, D, move, moveId)
  end

  -- Bide
  if e == "BIDE_EFFECT" then
    if not A.bide then
      A.bide = {turns = rnd(2, 3), dmg = 0}
      return
    end
    A.bide.turns = A.bide.turns - 1
    if A.bide.turns > 0 then self:msg(name .. " is storing energy!"); return end
    local stored = A.bide.dmg * 2
    A.bide = nil
    self:msg(name .. " unleashed energy!")
    if stored == 0 then self:msg(name .. "'s attack missed!"); return end
    self:applyHit(A, D, stored)
    return
  end

  -- accuracy
  if not self:hits(A, D, move) then
    self:msg(name .. "'s attack missed!")
    if e == "JUMP_KICK_EFFECT" then
      self:msg(name .. " kept going and crashed!")
      self:damageMon(A, 1)
    elseif e == "EXPLODE_EFFECT" then
      self:damageMon(A, A.mon.hp)
    end
    if A.thrash then A.thrash = nil end
    return
  end

  -- fixed-damage style moves
  local dmg, crit, total
  if e == "SPECIAL_DAMAGE_EFFECT" then
    local L = A.mon.level
    if moveId == MOVE.SONICBOOM then dmg = 20
    elseif moveId == MOVE.DRAGON_RAGE then dmg = 40
    elseif moveId == MOVE.PSYWAVE then dmg = rnd(1, max(1, floor(L * 3 / 2) - 1))
    else dmg = L end
    self:applyHit(A, D, dmg)
    return
  elseif e == "SUPER_FANG_EFFECT" then
    local _, t = typeEffect(move.type, D.types)
    if t == 0 then self:msg("It doesn't affect " .. self:nm(D) .. "!"); return end
    self:applyHit(A, D, max(1, floor(D.mon.hp / 2)))
    return
  elseif e == "OHKO_EFFECT" then
    local _, t = typeEffect(move.type, D.types)
    if t == 0 then self:msg("It doesn't affect " .. self:nm(D) .. "!"); return end
    if self:stat(A, "spd") < self:stat(D, "spd") then self:msg(name .. " is unaffected!"); return end
    self:applyHit(A, D, D.sub and D.sub or D.mon.hp)
    self:msg("One-hit KO!")
    return
  elseif moveId == MOVE.COUNTER then
    local lm = D.lastMove and MV[D.lastMove]
    if lm and (lm.type == "NORMAL" or lm.type == "FIGHTING") and lm.power > 0 and (self.lastDamage or 0) > 0 then
      self:applyHit(A, D, self.lastDamage * 2)
    else
      self:msg(name .. "'s attack missed!")
    end
    return
  end

  -- regular damage
  dmg, crit, total = self:calcDamage(A, D, move, moveId)
  if total == 0 then
    self:msg("It doesn't affect " .. self:nm(D) .. "!")
    if e == "EXPLODE_EFFECT" then self:damageMon(A, A.mon.hp) end
    return
  end
  if e == "DREAM_EATER_EFFECT" and D.mon.status ~= "SLP" then
    self:msg("It didn't affect " .. self:nm(D) .. "!")
    return
  end

  local hits = 1
  if e == "TWO_TO_FIVE_ATTACKS_EFFECT" then hits = multiHits()
  elseif e == "ATTACK_TWICE_EFFECT" or e == "TWINEEDLE_EFFECT" then hits = 2 end

  local dealt, sawSub, n = 0, false, 0
  for i = 1, hits do
    local d, s = self:applyHit(A, D, dmg)
    dealt, sawSub, n = dealt + d, sawSub or s, i
    if D.mon.hp <= 0 or (s and not D.sub) then break end
  end
  if crit then self:msg("Critical hit!") end
  self:effMsg(total, D)
  if hits > 1 then self:msg((A.side == 1 and "Hit the enemy " or "Hit ") .. n .. " times!") end

  -- thaw frozen target with a fire move
  if D.mon.status == "FRZ" and move.type == "FIRE" and D.mon.hp > 0 and not sawSub then
    self:setStatus(D, nil)
    self:msg(self:nm(D) .. " was defrosted!")
  end

  -- post-damage effects
  if e == "DRAIN_HP_EFFECT" or e == "DREAM_EATER_EFFECT" then
    self:healMon(A, max(1, floor(dealt / 2)))
    self:msg("Sucked health from " .. self:nm(D) .. "!")
  elseif e == "RECOIL_EFFECT" then
    local r = max(1, floor(dealt / (moveId == MOVE.STRUGGLE and 2 or 4)))
    self:damageMon(A, r)
    self:msg(name .. "'s hit with recoil!")
  elseif e == "EXPLODE_EFFECT" then
    self:damageMon(A, A.mon.hp)
  elseif e == "HYPER_BEAM_EFFECT" then
    if D.mon.hp > 0 and not (sawSub and not D.sub) then A.recharge = true end
  elseif e == "PAY_DAY_EFFECT" then
    self:msg("Coins scattered everywhere!")
  elseif e == "TRAPPING_EFFECT" then
    if not A.trap and D.mon.hp > 0 then
      A.trap = {turns = multiHits() - 1, dmg = dmg, move = moveId}
      D.trapped = true
    end
  elseif e == "THRASH_PETAL_DANCE_EFFECT" then
    if not A.thrash then A.thrash = {turns = rnd(2, 3), move = moveId} end
  elseif e == "RAGE_EFFECT" then
    A.rage = moveId
  end
  self:sideEffects(A, D, move, moveId, sawSub)
end

function Battle:statusMove(A, D, move, moveId)
  local e = move.effect
  local name = self:nm(A)
  local se = STAT_EFFECT[e]
  if se then
    if se[2] > 0 then self:stage(A, se[1], se[2], false)
    else
      if D.sub then self:msg("But it failed!"); return end
      self:stage(D, se[1], se[2], true)
    end
    return
  end
  if e == "SLEEP_EFFECT" then
    if D.mon.status == "SLP" then self:msg(self:nm(D) .. " is already asleep!"); return end
    if D.mon.status or D.sub then self:msg("But it failed!"); return end
    self:setStatus(D, "SLP")
    self:msg(self:nm(D) .. " fell asleep!")
  elseif e == "POISON_EFFECT" then
    for _, t in ipairs(D.types) do if t == "POISON" then self:msg("It didn't affect " .. self:nm(D) .. "!"); return end end
    if D.mon.status or D.sub then self:msg("But it failed!"); return end
    self:setStatus(D, "PSN")
    if moveId == MOVE.TOXIC then D.toxic = 1; self:msg(self:nm(D) .. "'s badly poisoned!")
    else self:msg(self:nm(D) .. STATUS_WORD.PSN) end
  elseif e == "PARALYZE_EFFECT" then
    local _, t = typeEffect(move.type, D.types)
    if t == 0 then self:msg("It didn't affect " .. self:nm(D) .. "!"); return end
    if D.mon.status or D.sub then self:msg("But it failed!"); return end
    self:setStatus(D, "PAR")
    self:msg(self:nm(D) .. STATUS_WORD.PAR)
  elseif e == "CONFUSION_EFFECT" then
    if D.confused or D.sub then self:msg("But it failed!"); return end
    D.confused = rnd(2, 5)
    self:msg(self:nm(D) .. " became confused!")
  elseif e == "HEAL_EFFECT" then
    if A.mon.hp >= A.mon.stats.hp then self:msg("But it failed!"); return end
    if moveId == MOVE.REST then
      self:setStatus(A, "SLP", 2)
      A.toxic = 0
      self:healMon(A, A.mon.stats.hp)
      self:msg(name .. " started sleeping!")
    else
      self:healMon(A, floor(A.mon.stats.hp / 2))
      self:msg(name .. " regained health!")
    end
  elseif e == "FOCUS_ENERGY_EFFECT" then
    if A.focus then self:msg("But it failed!"); return end
    A.focus = true; self:msg(name .. "'s getting pumped!")
  elseif e == "MIST_EFFECT" then
    if A.mist then self:msg("But it failed!"); return end
    A.mist = true; self:msg(name .. "'s shrouded in MIST!")
  elseif e == "REFLECT_EFFECT" then
    if A.reflect then self:msg("But it failed!"); return end
    A.reflect = true; self:msg(name .. " gained armor!")
  elseif e == "LIGHT_SCREEN_EFFECT" then
    if A.lightscreen then self:msg("But it failed!"); return end
    A.lightscreen = true; self:msg(name .. "'s protected against special attacks!")
  elseif e == "SUBSTITUTE_EFFECT" then
    local cost = floor(A.mon.stats.hp / 4)
    if A.sub then self:msg(name .. " has a SUBSTITUTE already!"); return end
    if A.mon.hp <= cost then self:msg("Too weak to make a SUBSTITUTE!"); return end
    self:damageMon(A, cost)
    A.sub = cost
    self.ui:subChanged(A)
    self:msg("It created a SUBSTITUTE!")
  elseif e == "HAZE_EFFECT" then
    for _, B in ipairs({A, D}) do
      for k in pairs(B.stages) do B.stages[k] = 0 end
      B.confused, B.focus, B.mist, B.reflect, B.lightscreen, B.seeded, B.disabled = nil
      B.toxic = 0
    end
    if D.mon.status then self:setStatus(D, nil) end
    self:msg("All STATUS changes are eliminated!")
  elseif e == "CONVERSION_EFFECT" then
    A.types = copy(D.types)
    self:msg("Converted type to " .. self:nm(D) .. "'s!")
  elseif e == "TRANSFORM_EFFECT" then
    A.types = copy(D.types)
    A.raw = copy(D.raw)
    A.stages = copy(D.stages)
    A.moves = copy(D.moves)
    A.pp = {}
    for i in ipairs(A.moves) do A.pp[i] = 5 end
    A.species = D.species
    self.ui:sprite(A, true)
    self:msg(name .. " transformed into " .. SP[D.species].name .. "!")
  elseif e == "LEECH_SEED_EFFECT" then
    for _, t in ipairs(D.types) do if t == "GRASS" then self:msg(name .. "'s attack missed!"); return end end
    if D.seeded then self:msg(name .. "'s attack missed!"); return end
    D.seeded = true; self:msg(self:nm(D) .. " was seeded!")
  elseif e == "DISABLE_EFFECT" then
    if D.disabled then self:msg("But it failed!"); return end
    local opts = {}
    for i, m in ipairs(D.moves) do if (D.pp[i] or 0) > 0 then opts[#opts + 1] = i end end
    if #opts == 0 then self:msg("But it failed!"); return end
    local slot = opts[rnd(1, #opts)]
    D.disabled = {slot = slot, turns = rnd(1, 8)}
    self:msg(self:nm(D) .. "'s " .. MV[D.moves[slot]].name .. " was disabled!")
  elseif e == "MIMIC_EFFECT" then
    local slot
    for i, m in ipairs(A.moves) do if m == MOVE.MIMIC then slot = i end end
    local pick = D.moves[rnd(1, #D.moves)]
    if not slot or not pick then self:msg("But it failed!"); return end
    A.moves = copy(A.moves)
    A.moves[slot] = pick
    self:msg(name .. " learned " .. MV[pick].name .. "!")
  elseif e == "SPLASH_EFFECT" then
    self:msg("No effect!")
  elseif e == "SWITCH_AND_TELEPORT_EFFECT" then
    self:msg("But it failed!")
  else
    self:msg("But nothing happened!")
  end
end

-- residual damage after a mon's own turn (Gen 1 order)
function Battle:residual(A)
  local mon = A.mon
  if mon.hp <= 0 then return end
  if mon.status == "PSN" or mon.status == "BRN" then
    local d = max(1, floor(mon.stats.hp / 16))
    if A.toxic > 0 then d = d * A.toxic; A.toxic = A.toxic + 1 end
    self:msg(self:nm(A) .. "'s hurt by " .. (mon.status == "BRN" and "the burn!" or "poison!"))
    self:damageMon(A, d)
  end
  if A.seeded and mon.hp > 0 then
    local d = max(1, floor(mon.stats.hp / 16))
    if A.toxic > 0 then d = d * A.toxic end
    local dealt = self:damageMon(A, d)
    local F = self:foe(A)
    self:msg("LEECH SEED saps " .. self:nm(A) .. "!")
    if F and F.mon.hp > 0 then self:healMon(F, dealt) end
  end
end

-- one mon's full turn, including all Gen 1 pre-move checks
function Battle:takeTurn(A, act)
  local D = self:foe(A)
  local mon = A.mon
  local name = self:nm(A)
  A.acted = true
  if mon.hp <= 0 or not D then return end
  if act.kind ~= "move" and act.kind ~= "forced" then return end

  if mon.status == "SLP" then
    mon.sleep = (mon.sleep or 1) - 1
    if mon.sleep <= 0 then self:setStatus(A, nil); self:msg(name .. " woke up!")
    else self:msg(name .. " is fast asleep!") end
    A.thrash, A.charging, A.bide, A.trap = nil
    return
  end
  if mon.status == "FRZ" then self:msg(name .. " is frozen solid!"); return end
  if A.trapped then self:msg(name .. " can't move!"); return end
  if A.flinch then A.flinch = nil; self:msg(name .. " flinched!"); A.thrash = nil; return end
  if A.recharge then A.recharge = nil; self:msg(name .. " must recharge!"); return end
  if A.disabled then
    A.disabled.turns = A.disabled.turns - 1
    if A.disabled.turns <= 0 then A.disabled = nil; self:msg(name .. "'s disabled no more!") end
  end
  if A.confused then
    A.confused = A.confused - 1
    if A.confused <= 0 then
      A.confused = nil
      self:msg(name .. "'s confused no more!")
    else
      self:msg(name .. " is confused!")
      if chance(128) then
        self:msg("It hurt itself in its confusion!")
        local fake = {power = 40, type = "NORMAL", effect = "NO_ADDITIONAL_EFFECT"}
        local dmg = self:calcDamage(A, A, fake, 0, {typeless = true, noCrit = true, noRandom = true})
        self:damageMon(A, dmg)
        A.thrash, A.charging, A.bide = nil
        return
      end
    end
  end
  if mon.status == "PAR" and chance(63) then
    self:msg(name .. "'s fully paralyzed!")
    A.thrash, A.charging, A.bide, A.trap = nil
    if A.invuln then A.invuln = nil; self.ui:sprite(A, true) end
    return
  end

  -- continuing multi-turn moves
  if A.bide then return self:useMove(A, D, MOVE.BIDE, true) end
  if A.thrash then
    A.thrash.turns = A.thrash.turns - 1
    self:msg(name .. "'s thrashing about!")
    self:useMove(A, D, A.thrash.move, true)
    if A.thrash and A.thrash.turns <= 0 then
      A.thrash = nil
      if not A.confused then A.confused = rnd(2, 5); self:msg(name .. " became confused!") end
    end
    return
  end
  if A.trap then
    if D.mon.hp > 0 then
      self:msg(name .. "'s attack continues!")
      self:applyHit(A, D, A.trap.dmg)
    end
    A.trap.turns = A.trap.turns - 1
    if A.trap.turns <= 0 or D.mon.hp <= 0 then A.trap = nil; D.trapped = nil end
    return
  end
  if A.charging then return self:useMove(A, D, A.charging, false) end

  local slot, moveId = act.slot, act.move
  if slot and A.disabled and A.disabled.slot == slot and not A.rage then
    self:msg(name .. "'s " .. MV[A.moves[slot]].name .. " is disabled!")
    return
  end
  if not moveId then
    if slot and A.moves[slot] then
      moveId = A.moves[slot]
      A.pp[slot] = max(0, (A.pp[slot] or 0) - 1)
    else
      moveId = MOVE.STRUGGLE
    end
  end
  if A.rage then moveId = A.rage end
  self:useMove(A, D, moveId)
end

function Battle:priority(B, act)
  if act.kind ~= "move" and act.kind ~= "forced" then return 10 end
  local m = act.move or (act.slot and B.moves[act.slot])
  if B.charging then m = B.charging end
  if m == MOVE.QUICK_ATTACK then return 1 end
  if m == MOVE.COUNTER then return -1 end
  return 0
end

function Battle:canChoose(B)
  return not (B.bide or B.thrash or B.trap or B.charging or B.recharge or B.rage)
end

-- usable move slots for B
function Battle:moveSlots(B)
  local slots = {}
  for i, m in ipairs(B.moves) do
    if (B.pp[i] or 0) > 0 and not (B.disabled and B.disabled.slot == i) then slots[#slots + 1] = i end
  end
  return slots
end

function Battle:getAction(s)
  local B = self.sides[s].active
  if not self:canChoose(B) then return {kind = "forced"} end
  if #self:moveSlots(B) == 0 then
    local act = self.sides[s].ctrl:choose(self, B, true)
    if act and act.kind == "switch" then return act end
    self:msg(self:nm(B) .. " has no moves left!")
    return {kind = "move", move = MOVE.STRUGGLE}
  end
  return self.sides[s].ctrl:choose(self, B, false)
end

-- returns 1 if side 1 wins, 2 if side 2 wins
function Battle:run()
  self.ui:start(self)
  for s = 1, 2 do self:sendOut(s, self:usable(s)) end
  local turns = 0
  while true do
    turns = turns + 1
    if turns > 400 then
      -- e.g. two Ghosts stuck on Struggle (Normal can't hit Ghost in Gen 1)
      self:msg("The battle dragged on too long! It's a draw.")
      return 2
    end
    local acts = {}
    for s = 1, 2 do
      local a = self:getAction(s)
      if a.kind == "quit" then return 2 end
      acts[s] = a
      if s == 1 and a.kind == "run" then
        if self:tryRun() then self:msg("Got away safely!"); return "run" end
        self:msg("Can't escape!")
      elseif s == 1 and a.kind == "item" then
        local r = self:useItem(a)
        if r then return r end
      end
    end
    -- switches happen first
    for s = 1, 2 do
      if acts[s].kind == "switch" then
        local side = self.sides[s]
        self.ui:recall(side.active, side)
        self:sendOut(s, acts[s].idx)
      end
    end
    local A1, A2 = self.sides[1].active, self.sides[2].active
    A1.acted, A2.acted = false, false
    local p1, p2 = self:priority(A1, acts[1]), self:priority(A2, acts[2])
    local first
    if p1 ~= p2 then first = p1 > p2 and 1 or 2
    else
      local s1, s2 = self:stat(A1, "spd"), self:stat(A2, "spd")
      if s1 ~= s2 then first = s1 > s2 and 1 or 2 else first = rnd(1, 2) end
    end
    for _, s in ipairs({first, 3 - first}) do
      local B = self.sides[s].active
      if B.mon.hp > 0 and self:foe(B).mon.hp > 0 then
        self:takeTurn(B, acts[s])
        if B.mon.hp > 0 and self:foe(B).mon.hp > 0 then self:residual(B) end
      end
      if A1.mon.hp <= 0 or A2.mon.hp <= 0 then break end
    end
    A1.turnsOut, A2.turnsOut = A1.turnsOut + 1, A2.turnsOut + 1
    -- faints
    for _, s in ipairs({2, 1}) do
      local B = self.sides[s].active
      if B.mon.hp <= 0 then
        local F = self:foe(B)
        if F then F.trap, F.trapped = nil, nil end
        self.ui:faint(B)
        self:msg(self:nm(B) .. " fainted!")
        if s == 2 and self.game then self:awardExp(B) end
      end
    end
    local lose1, lose2 = not self:usable(1), not self:usable(2)
    if lose1 or lose2 then return lose1 and 2 or 1 end
    for _, s in ipairs({2, 1}) do
      local B = self.sides[s].active
      if B.mon.hp <= 0 then
        local idx = self.sides[s].ctrl:replace(self, s)
        self:sendOut(s, idx)
      end
    end
  end
end

-----------------------------------------------------------------------
-- experience, levels, items, catching (adventure mode)
-----------------------------------------------------------------------
local function expFor(species, level)
  local g, n = SP[species].growth, level
  local v
  if g == "FAST" then v = floor(4 * n * n * n / 5)
  elseif g == "MEDIUM_SLOW" then v = floor(6 * n * n * n / 5) - 15 * n * n + 100 * n - 140
  elseif g == "SLOW" then v = floor(5 * n * n * n / 4)
  else v = n * n * n end
  return max(0, v)
end

-- teach `move` to mon; ask(mon, move) returns slot to replace or nil
local function learnMove(mon, move, say, ask)
  for _, m in ipairs(mon.moves) do if m == move then return end end
  local name = SP[mon.species].name
  if #mon.moves < 4 then
    mon.moves[#mon.moves + 1] = move
    mon.pp[#mon.moves] = MV[move].pp
    say(name .. " learned " .. MV[move].name .. "!")
    return true
  end
  say(name .. " is trying to learn " .. MV[move].name .. "!")
  say("But " .. name .. " can't learn more than 4 moves!")
  local slot = ask and ask(mon, move)
  if slot then
    local old = mon.moves[slot]
    mon.moves[slot] = move
    mon.pp[slot] = MV[move].pp
    say("1, 2 and... Poof! " .. name .. " forgot " .. MV[old].name .. "! And... " .. name .. " learned " .. MV[move].name .. "!")
    return true
  end
  say(name .. " did not learn " .. MV[move].name .. "!")
end

local function levelUp(mon, say, ask)
  local oldMax = mon.stats.hp
  mon.level = mon.level + 1
  calcStats(mon)
  if mon.hp > 0 then mon.hp = mon.hp + (mon.stats.hp - oldMax) end
  mon.leveled = true
  say(SP[mon.species].name .. " grew to level " .. mon.level .. "!")
  for _, l in ipairs(SP[mon.species].learn) do
    if l[1] == mon.level then learnMove(mon, l[2], say, ask) end
  end
end

local function gainExp(mon, amount, say, ask)
  mon.exp = (mon.exp or expFor(mon.species, mon.level)) + amount
  while mon.level < 100 and mon.exp >= expFor(mon.species, mon.level + 1) do levelUp(mon, say, ask) end
end

function Battle:awardExp(E)
  local sp = SP[E.mon.species]
  local total = floor(sp.exp * E.mon.level / 7)
  if not self.wild then total = floor(total * 3 / 2) end
  local parts = {}
  for idx in pairs(self.part) do
    local m = self.sides[1].party[idx]
    if m and m.hp > 0 then parts[#parts + 1] = m end
  end
  if #parts == 0 then return end
  local each = max(1, floor(total / #parts))
  local ctrl = self.sides[1].ctrl
  local say = function(t) self:msg(t) end
  local ask = ctrl.askReplace and function(mon, move) return ctrl:askReplace(mon, move) end
  for _, m in ipairs(parts) do
    m.statexp = m.statexp or {0, 0, 0, 0, 0}
    for i = 1, 5 do m.statexp[i] = min(65535, m.statexp[i] + floor(sp.base[i] / #parts)) end
    self:msg(SP[m.species].name .. " gained " .. each .. " EXP. Points!")
    local before = m.level
    gainExp(m, each, say, ask)
    local B = self.sides[1].active
    if m.level ~= before and B and B.mon == m then
      if B.species == m.species then
        B.raw = {atk = m.stats.atk, def = m.stats.def, spd = m.stats.spd, spc = m.stats.spc}
        B.moves = copy(m.moves); B.pp = m.pp
      end
      self.ui:status(B)
    end
  end
end

function Battle:tryRun()
  self.runs = self.runs + 1
  local A, E = self.sides[1].active, self.sides[2].active
  local q = floor(self:stat(E, "spd") / 4) % 256
  if q == 0 then return true end
  local odds = floor(self:stat(A, "spd") * 32 / q) + 30 * (self.runs - 1)
  return odds > 255 or rnd(0, 255) < odds
end

-- item effects shared by battle and the bag (filled in once the world data loads)
local ITEMS = {}       -- id -> {name=..., const=..., price=...}
local ITEM = {}        -- const -> id
local HEAL = {POTION = 20, SUPER_POTION = 50, HYPER_POTION = 200, MAX_POTION = 9999, FULL_RESTORE = 9999,
  FRESH_WATER = 50, SODA_POP = 60, LEMONADE = 80}
local CURE = {ANTIDOTE = "PSN", BURN_HEAL = "BRN", ICE_HEAL = "FRZ", AWAKENING = "SLP", PARLYZ_HEAL = "PAR"}
local BALL = {POKE_BALL = 255, GREAT_BALL = 200, ULTRA_BALL = 150, MASTER_BALL = 0}
local X_ITEM = {X_ATTACK = "atk", X_DEFEND = "def", X_SPEED = "spd", X_SPECIAL = "spc", X_ACCURACY = "acc"}
local function itemConst(id) return ITEMS[id] and ITEMS[id].const or "" end
local function itemName(id) return ITEMS[id] and ITEMS[id].name or ("ITEM " .. tostring(id)) end

-- does the item need a party target, and can it be used now?
local function itemKind(id, inBattle)
  local c = itemConst(id)
  if BALL[c] then return inBattle and "ball" or nil end
  if HEAL[c] or CURE[c] or c == "FULL_HEAL" or c == "REVIVE" or c == "MAX_REVIVE"
      or c == "ELIXER" or c == "MAX_ELIXER" or c == "ETHER" or c == "MAX_ETHER" then return "mon" end
  if X_ITEM[c] or c == "GUARD_SPEC" or c == "DIRE_HIT" or c == "POKE_DOLL" then return inBattle and "battle" or nil end
  if inBattle then return nil end
  if c == "RARE_CANDY" or c:match("_STONE$") or c == "HP_UP" or c == "PROTEIN" or c == "IRON"
      or c == "CARBOS" or c == "CALCIUM" or c:match("^TM_") or c:match("^HM_") then return "mon" end
  if c == "ESCAPE_ROPE" or c == "REPEL" or c == "SUPER_REPEL" or c == "MAX_REPEL" then return "field" end
  return nil
end

-- apply a "mon" item; returns true if used (and should be consumed), plus messages via say
local function useOnMon(id, mon, say, ask)
  local c = itemConst(id)
  local name = SP[mon.species].name
  local maxhp = mon.stats.hp
  if c == "REVIVE" or c == "MAX_REVIVE" then
    if mon.hp > 0 then say("It won't have any effect."); return false end
    mon.hp = c == "REVIVE" and floor(maxhp / 2) or maxhp
    mon.status = nil
    say(name .. " is revitalized!")
    return true
  end
  if mon.hp <= 0 then say("It won't have any effect."); return false end
  if HEAL[c] then
    local cure = c == "FULL_RESTORE"
    if mon.hp >= maxhp and not (cure and mon.status) then say("It won't have any effect."); return false end
    local old = mon.hp
    mon.hp = min(maxhp, mon.hp + HEAL[c])
    if cure then mon.status, mon.sleep = nil, nil end
    say(name .. " recovered by " .. (mon.hp - old) .. "!")
    return true
  end
  if CURE[c] or c == "FULL_HEAL" then
    if not mon.status or (CURE[c] and mon.status ~= CURE[c]) then say("It won't have any effect."); return false end
    mon.status, mon.sleep = nil, nil
    say(name .. " is healthy again!")
    return true
  end
  if c == "ELIXER" or c == "MAX_ELIXER" or c == "ETHER" or c == "MAX_ETHER" then
    local did = false
    for i, m in ipairs(mon.moves) do
      local full = MV[m].pp
      if (mon.pp[i] or 0) < full and (not did or c:match("ELIXER")) then
        mon.pp[i] = c:match("^MAX") and full or min(full, (mon.pp[i] or 0) + 10)
        did = true
      end
    end
    if not did then say("It won't have any effect."); return false end
    say("PP was restored.")
    return true
  end
  if c == "RARE_CANDY" then
    if mon.level >= 100 then say("It won't have any effect."); return false end
    mon.exp = expFor(mon.species, mon.level + 1)
    levelUp(mon, say, ask)
    return true
  end
  local VIT = {HP_UP = 1, PROTEIN = 2, IRON = 3, CARBOS = 4, CALCIUM = 5}
  if VIT[c] then
    mon.statexp = mon.statexp or {0, 0, 0, 0, 0}
    local i = VIT[c]
    if mon.statexp[i] >= 25600 then say("It won't have any effect."); return false end
    mon.statexp[i] = min(25600, mon.statexp[i] + 2560)
    local oldMax = maxhp
    calcStats(mon)
    mon.hp = mon.hp + (mon.stats.hp - oldMax)
    say(name .. "'s stats rose.")
    return true
  end
  if c:match("_STONE$") then
    for _, e in ipairs(SP[mon.species].evos) do
      if e.how == "ITEM" and e.item == c then
        mon.evolveTo = e.into
        return true
      end
    end
    say("It won't have any effect."); return false
  end
  if c:match("^TM_") or c:match("^HM_") then
    local move = ITEMS[id].move
    local ok = false
    for _, m in ipairs(SP[mon.species].tmhm) do if m == move then ok = true end end
    if not ok then say(name .. " is not compatible with " .. MV[move].name .. ".") return false end
    return learnMove(mon, move, say, ask) and c:match("^TM_") ~= nil
  end
  say("It won't have any effect.")
  return false
end

local function catchMon(ballConst, E)
  if ballConst == "MASTER_BALL" then return true, 3 end
  local mon = E.mon
  local r1 = rnd(0, BALL[ballConst])
  local st = (mon.status == "SLP" or mon.status == "FRZ") and 25 or (mon.status and 12 or 0)
  if r1 < st then return true, 3 end
  r1 = r1 - st
  local f = floor(mon.stats.hp * 255 / (ballConst == "GREAT_BALL" and 8 or 12)) / max(1, floor(mon.hp / 4))
  f = min(255, floor(f))
  local rate = SP[mon.species].catch
  if r1 <= rate and rnd(0, 255) <= f then return true, 3 end
  -- shakes, roughly as in Gen 1
  local w = floor(rate * 100 / BALL[ballConst])
  local x = floor(w * f / 255) + (st == 25 and 10 or (st == 12 and 5 or 0))
  return false, x < 10 and 0 or (x < 30 and 1 or (x < 70 and 2 or 3))
end

function Battle:useItem(act)
  local id = act.item
  local c = itemConst(id)
  local function use() if self.bag then self.bag[id] = (self.bag[id] or 1) - 1; if self.bag[id] <= 0 then self.bag[id] = nil end end end
  self:msg(PLAYER_NAME .. " used " .. itemName(id) .. "!")
  if BALL[c] then
    use()
    if not self.wild then
      self:msg("The trainer blocked the BALL!")
      self:msg("Don't be a thief!")
      return
    end
    local E = self.sides[2].active
    local ok, shakes = catchMon(c, E)
    if ok then
      self:msg("All right! " .. SP[E.mon.species].name .. " was caught!")
      E.mon.exp = expFor(E.mon.species, E.mon.level)
      if self.onCatch then self.onCatch(E.mon, function(t) self:msg(t) end) end
      return "caught"
    end
    self:msg(({"You missed the POKéMON!", "Darn! The POKéMON broke free!", "Aww! It appeared to be caught!",
      "Shoot! It was so close too!"})[shakes + 1])
    return
  end
  if X_ITEM[c] then
    use(); self:stage(self.sides[1].active, X_ITEM[c], 1, false); return
  end
  if c == "GUARD_SPEC" then use(); self.sides[1].active.mist = true; self:msg("Your POKéMON is shrouded in MIST!"); return end
  if c == "DIRE_HIT" then use(); self.sides[1].active.focus = true; self:msg("Your POKéMON is getting pumped!"); return end
  if c == "POKE_DOLL" then
    use()
    if self.wild then self:msg("Got away safely!"); return "run" end
    self:msg("It won't have any effect."); return
  end
  local mon = self.sides[1].party[act.target]
  local before = mon.hp
  local say = function(t) self:msg(t) end
  if useOnMon(id, mon, say) then
    use()
    local B = self.sides[1].active
    if B.mon == mon then
      if mon.hp ~= before then self.ui:hp(B, before, mon.hp) end
      if not mon.status then B.toxic = 0; if c == "FULL_RESTORE" or c == "FULL_HEAL" then B.confused = nil end end
      self.ui:status(B)
    end
  end
end

-----------------------------------------------------------------------
-- trainer AI (Gen 1 move-choice modifications 1-3)
-----------------------------------------------------------------------
local AI = {}
AI.__index = AI
function AI.new(mods) return setmetatable({mods = mods or {}}, AI) end
function AI:choose(b, B)
  local F = b:foe(B)
  local score = {}
  local slots = b:moveSlots(B)
  if #slots == 0 then return {kind = "move", move = MOVE.STRUGGLE} end
  for _, i in ipairs(slots) do score[i] = 10 end
  local has = {}
  for _, m in ipairs(self.mods) do has[m] = true end
  for _, i in ipairs(slots) do
    local mv = MV[B.moves[i]]
    if has[1] and F.mon.status and mv.power == 0 and
        (mv.effect == "SLEEP_EFFECT" or mv.effect == "POISON_EFFECT" or mv.effect == "PARALYZE_EFFECT") then
      score[i] = score[i] + 5
    end
    if has[2] and B.turnsOut == 1 then
      local e = mv.effect
      if STAT_EFFECT[e] or e == "CONVERSION_EFFECT" or e == "HAZE_EFFECT" or e == "HEAL_EFFECT"
          or e == "MIST_EFFECT" or e == "FOCUS_ENERGY_EFFECT" or e == "REFLECT_EFFECT"
          or e == "LIGHT_SCREEN_EFFECT" then
        score[i] = score[i] - 1
      end
    end
    if has[3] then
      local _, t = typeEffect(mv.type, F.types)
      if t > 10 then score[i] = score[i] - 1
      elseif t < 10 then
        for _, j in ipairs(slots) do
          local o = MV[B.moves[j]]
          if o.effect == "SUPER_FANG_EFFECT" or o.effect == "SPECIAL_DAMAGE_EFFECT" or o.effect == "FLY_EFFECT"
              or (o.type ~= mv.type and o.power > 0) then
            score[i] = score[i] + 1
            break
          end
        end
      end
    end
  end
  local best = math.huge
  for _, i in ipairs(slots) do best = min(best, score[i]) end
  local pool = {}
  for _, i in ipairs(slots) do if score[i] == best then pool[#pool + 1] = i end end
  return {kind = "move", slot = pool[rnd(1, #pool)]}
end
function AI:replace(b, s)
  return b:usable(s)
end

-----------------------------------------------------------------------
-- screen (OC GPU, optional double buffer)
-----------------------------------------------------------------------
local W, H = 160, 50
local C = {
  white = 0xFFEFFF, black = 0x181010, gray = 0x9C9CA4, light = 0xD8D0D8,
  green = 0x30C048, yellow = 0xE0B000, red = 0xD03020, blue = 0x3050C8,
}
local Gfx = {}
local gpu, buffer, curFG, curBG
local BLOCK = "\226\150\128" -- U+2580 upper half block

function Gfx.init()
  gpu = component.gpu
  local mw, mh = gpu.maxResolution()
  if mw < W or mh < H then error("pokered needs a Tier 3 GPU and Tier 3 screen (160x50)", 0) end
  gpu.setResolution(W, H)
  if gpu.maxDepth() < 8 then error("pokered needs 8-bit color (Tier 3 GPU + screen)", 0) end
  gpu.setDepth(8)
  local cols = {C.white, C.black, C.light, C.gray, C.green, C.yellow, C.red, C.blue}
  for i, c in ipairs(cols) do pcall(gpu.setPaletteColor, i - 1, c) end
  if gpu.allocateBuffer then
    local ok, b = pcall(gpu.allocateBuffer, W, H)
    if ok and b then
      buffer = b
      gpu.setActiveBuffer(buffer)
      for i, c in ipairs(cols) do pcall(gpu.setPaletteColor, i - 1, c) end
    end
  end
  curFG, curBG = nil, nil
end
function Gfx.close()
  if buffer then pcall(gpu.setActiveBuffer, 0); pcall(gpu.freeBuffer, buffer); buffer = nil end
  gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, W, H, " ")
end
function Gfx.flush()
  if buffer then gpu.bitblt(0, 1, 1, W, H, buffer, 1, 1) end
end
local function fg(c) if c ~= curFG then gpu.setForeground(c); curFG = c end end
local function bg(c) if c ~= curBG then gpu.setBackground(c); curBG = c end end
function Gfx.fill(x, y, w, h, c, ch) bg(c); if ch then fg(C.black) end; gpu.fill(x, y, w, h, ch or " ") end
function Gfx.text(x, y, s, f, b) fg(f or C.black); bg(b or C.white); gpu.set(x, y, s) end

-- draw a pic with half-blocks; scale = integer pixel size; pal = 4 colors (shade 0..3)
-- box: area (cells) the pic is centered/bottom-aligned in, in source pixels*scale
function Gfx.pic(pic, x, y, pal, scale, boxW, boxH, flip)
  scale = scale or 1
  local pw, ph = pic.w * scale, pic.h * scale
  boxW, boxH = boxW or pw, boxH or ph
  local ox = floor((boxW - pw) / 2)
  local oy = boxH - ph
  local rows = ceil(boxH / 2)
  local groups = {}
  for cy = 0, rows - 1 do
    local runStart, runKey
    local function closeRun(cx)
      if runKey then
        local g = groups[runKey]
        if not g then g = {}; groups[runKey] = g end
        g[#g + 1] = {runStart, cy, cx - runStart}
      end
    end
    for cx = 0, boxW - 1 do
      local sx = cx - ox
      if flip then sx = pw - 1 - sx end
      local ty, by = cy * 2 - oy, cy * 2 + 1 - oy
      local t = (sx >= 0 and sx < pw and ty >= 0) and shadeAt(pic, floor(sx / scale), floor(ty / scale)) or 0
      local bo = (sx >= 0 and sx < pw and by >= 0) and shadeAt(pic, floor(sx / scale), floor(by / scale)) or 0
      local key = t == bo and bo or (t * 4 + bo + 16)
      if key ~= runKey then closeRun(cx); runKey, runStart = key, cx end
    end
    closeRun(boxW)
  end
  for key, runs in pairs(groups) do
    if key < 16 then
      bg(pal[key + 1])
      for _, r in ipairs(runs) do gpu.fill(x + r[1], y + r[2], r[3], 1, " ") end
    else
      local k = key - 16
      fg(pal[floor(k / 4) + 1]); bg(pal[k % 4 + 1])
      for _, r in ipairs(runs) do gpu.set(x + r[1], y + r[2], string.rep(BLOCK, r[3])) end
    end
  end
end

function Gfx.box(x, y, w, h, title)
  Gfx.fill(x, y, w, h, C.white)
  fg(C.black); bg(C.white)
  gpu.set(x, y, "┌" .. string.rep("─", w - 2) .. "┐")
  gpu.set(x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘")
  for yy = y + 1, y + h - 2 do gpu.set(x, yy, "│"); gpu.set(x + w - 1, yy, "│") end
  if title then gpu.set(x + 2, y, " " .. title .. " ") end
end

-----------------------------------------------------------------------
-- input
-----------------------------------------------------------------------
local KEYS = {[200] = "up", [208] = "down", [203] = "left", [205] = "right", [28] = "a", [44] = "a", [57] = "a", [15] = "start",
  [14] = "b", [45] = "b", [201] = "pgup", [209] = "pgdn"}
local function key(timeout)
  while true do
    local ev, _, ch, code = event.pull(timeout, "key_down")
    if not ev then return nil end
    if KEYS[code] then return KEYS[code] end
    if ch and ch >= 65 and ch <= 122 then return string.upper(string.char(ch)) end
    if timeout then return nil end
  end
end

-----------------------------------------------------------------------
-- battle UI
-----------------------------------------------------------------------
local Settings = {textDelay = 1.2}
local UI = {}
UI.__index = UI

local BOX_Y, BOX_H = 39, 12
local EN_SPR = {x = 98, y = 2, w = 56, h = 56}     -- pixels; rows = h/2
local PL_SPR = {x = 12, y = 7, w = 64, h = 64}
local EN_HUD = {x = 4, y = 3}
local PL_HUD = {x = 90, y = 30}

local function palOf(species) return SP[species].pal end
local GRAY_PAL = {C.white, 0xB0A8B0, 0x686068, C.black}

function UI.new() return setmetatable({lines = {}, visible = {true, true}}, UI) end

function UI:start(b) self.b = b; self.lines = {}; self:redraw() end

function UI:drawSprite(B)
  local s = B.side
  local area = s == 2 and EN_SPR or PL_SPR
  Gfx.fill(area.x, area.y, area.w, floor(area.h / 2), C.white)
  if not self.visible[s] then return end
  if B.sub then
    local cx, cy = area.x + floor(area.w / 2), area.y + floor(area.h / 4)
    Gfx.box(cx - 8, cy - 3, 16, 7)
    Gfx.text(cx - 5, cy, "SUBSTITUTE")
    return
  end
  if s == 2 then
    local pic = loadPic("front/" .. B.species)
    if pic then Gfx.pic(pic, area.x, area.y, palOf(B.species), 1, area.w, area.h) end
  else
    local pic = loadPic("back/" .. B.species)
    if pic then Gfx.pic(pic, area.x, area.y, palOf(B.species), 2, area.w, area.h) end
  end
end

local STATUS_TAG = {SLP = "SLP", PSN = "PSN", BRN = "BRN", FRZ = "FRZ", PAR = "PAR"}
function UI:hpColor(hp, maxhp)
  local r = hp / maxhp
  if r > 0.5 then return C.green elseif r > 0.2 then return C.yellow end
  return C.red
end
function UI:drawBar(x, y, hp, maxhp)
  local w = 30
  local filled = hp > 0 and max(1, floor(w * hp / maxhp + 0.5)) or 0
  Gfx.text(x, y, "HP:", C.black, C.white)
  Gfx.fill(x + 3, y, w + 2, 1, C.black)
  Gfx.fill(x + 4, y, w, 1, C.light)
  if filled > 0 then Gfx.fill(x + 4, y, filled, 1, self:hpColor(hp, maxhp)) end
end
function UI:drawHUD(B, hpShown)
  local hud = B.side == 2 and EN_HUD or PL_HUD
  local mon = B.mon
  hpShown = hpShown or mon.hp
  Gfx.fill(hud.x, hud.y, 40, B.side == 2 and 4 or 5, C.white)
  Gfx.text(hud.x, hud.y, SP[mon.species].name, C.black, C.white)
  local st = mon.status and STATUS_TAG[mon.status] or ""
  Gfx.text(hud.x + 2, hud.y + 1, ":L" .. mon.level .. "  " .. st, C.black, C.white)
  self:drawBar(hud.x + 2, hud.y + 2, hpShown, mon.stats.hp)
  if B.side == 1 then
    Gfx.text(hud.x + 18, hud.y + 3, rpad(hpShown, 3) .. "/" .. rpad(mon.stats.hp, 3), C.black, C.white)
    Gfx.text(hud.x + 38, hud.y + 1, "│", C.black, C.white)
    Gfx.text(hud.x + 38, hud.y + 2, "│", C.black, C.white)
    Gfx.text(hud.x + 2, hud.y + 4, string.rep("─", 36) .. "┘", C.black, C.white)
  else
    Gfx.text(hud.x, hud.y + 3, "└" .. string.rep("─", 36), C.black, C.white)
  end
end
function UI:partyBalls(side, y, x)
  local s = ""
  for i = 1, 6 do
    local m = side.party[i]
    s = s .. (not m and "·" or (m.hp <= 0 and "x" or (m.status and "▲" or "●"))) .. " "
  end
  Gfx.text(x, y, s, C.black, C.white)
end

function UI:drawBox()
  Gfx.box(1, BOX_Y, W, BOX_H)
  for i, l in ipairs(self.lines) do Gfx.text(4, BOX_Y + 1 + i * 2 - 1, l, C.black, C.white) end
end
function UI:redraw()
  Gfx.fill(1, 1, W, BOX_Y - 1, C.white)
  local b = self.b
  for s = 1, 2 do
    local B = b.sides[s].active
    if B then self:drawSprite(B); self:drawHUD(B) end
  end
  self:drawBox()
  Gfx.flush()
end

function UI:msg(text)
  -- wrap to box width, 4 visible lines (double spaced)
  local wrapW = W - 8
  local words, line = {}, ""
  for w in text:gmatch("%S+") do
    if ulen(line) + ulen(w) + 1 > wrapW then words[#words + 1] = line; line = w
    else line = (line == "" and w or (line .. " " .. w)) end
  end
  words[#words + 1] = line
  for _, l in ipairs(words) do
    self.lines[#self.lines + 1] = l
    while #self.lines > 4 do table.remove(self.lines, 1) end
  end
  self:drawBox()
  Gfx.text(W - 4, BOX_Y + BOX_H - 2, "▼", C.black, C.white)
  Gfx.flush()
  key(Settings.textDelay or nil)
  Gfx.text(W - 4, BOX_Y + BOX_H - 2, " ", C.black, C.white)
end
function UI:clearText() self.lines = {}; self:drawBox() end

function UI:hp(B, old, new)
  if old == new then return end
  local steps = min(10, math.abs(old - new))
  for i = 1, steps do
    local v = floor(old + (new - old) * i / steps + 0.5)
    self:drawHUD(B, v)
    Gfx.flush()
    sleep(0.03)
  end
end
function UI:status(B) self:drawHUD(B); Gfx.flush() end
function UI:subChanged(B) self:drawSprite(B); Gfx.flush() end
function UI:sprite(B, show) self.visible[B.side] = show; self:drawSprite(B); Gfx.flush() end
function UI:hitFlash(B)
  for _ = 1, (buffer and 2 or 1) do -- each flash is a full sprite redraw; go easy without a GPU buffer
    self.visible[B.side] = false; self:drawSprite(B); Gfx.flush(); sleep(0.06)
    self.visible[B.side] = true; self:drawSprite(B); Gfx.flush(); sleep(0.06)
  end
end
function UI:faint(B)
  self.visible[B.side] = false
  self:drawSprite(B)
  local hud = B.side == 2 and EN_HUD or PL_HUD
  Gfx.fill(hud.x, hud.y, 40, B.side == 2 and 4 or 5, C.white)
  Gfx.flush()
end
function UI:recall(B, side)
  if B.side == 1 then self:msg(SP[B.mon.species].name .. ", come back!")
  else self:msg(side.name .. " withdrew " .. SP[B.mon.species].name .. "!") end
  self.visible[B.side] = false; self:drawSprite(B); Gfx.flush()
end
function UI:sendOut(B, side)
  self.visible[B.side] = true
  self:drawSprite(B); self:drawHUD(B); Gfx.flush()
  if B.side == 2 then
    if side.name then self:msg(side.name .. " sent out " .. SP[B.mon.species].name .. "!") end
  else
    self:msg("Go! " .. SP[B.mon.species].name .. "!")
  end
end

-- generic vertical menu inside a box; returns index or nil (B)
local function menu(x, y, items, opts)
  opts = opts or {}
  local sel = opts.sel or 1
  local n = #items
  local view = opts.view or n
  local top = 1
  while true do
    if sel < top then top = sel elseif sel >= top + view then top = sel - view + 1 end
    for i = 0, view - 1 do
      local idx = top + i
      local label = items[idx] or ""
      local w = opts.width or 30
      Gfx.text(x, y + i * (opts.spacing or 1), (idx == sel and "▶ " or "  ") .. pad(label, w - 2),
        idx == sel and (opts.selFG or C.black) or C.black, C.white)
    end
    if opts.onMove then opts.onMove(sel) end
    Gfx.flush()
    local k = key()
    if k == "up" then sel = sel > 1 and sel - 1 or n
    elseif k == "down" then sel = sel < n and sel + 1 or 1
    elseif k == "pgup" then sel = max(1, sel - view)
    elseif k == "pgdn" then sel = min(n, sel + view)
    elseif k == "a" then return sel
    elseif k == "b" and not opts.noCancel then return nil
    elseif type(k) == "string" and #k == 1 and opts.onLetter then
      local j = opts.onLetter(k, sel); if j then sel = j end
    end
  end
end

-- party screen (switching); returns index or nil
local function partyScreen(b, s, forced, title)
  local side = b.sides[s]
  local cur = side.active
  local sel = 1
  while true do
    Gfx.fill(1, 1, W, H, C.white)
    Gfx.text(4, 2, title or "Choose a POKéMON.", C.black, C.white)
    for i, m in ipairs(side.party) do
      local y = 4 + (i - 1) * 5
      local sp = SP[m.species]
      Gfx.text(6, y, (i == sel and "▶ " or "  ") .. pad(sp.name, 12) .. " :L" .. m.level ..
        "  " .. (m.status or "   "), C.black, C.white)
      local u = UI.new()
      u:drawBar(10, y + 1, m.hp, m.stats.hp)
      Gfx.text(48, y + 1, rpad(m.hp, 3) .. "/" .. rpad(m.stats.hp, 3), C.black, C.white)
      local mv = {}
      for j, id in ipairs(m.moves) do mv[#mv + 1] = MV[id].name .. " " .. (m.pp[j] or 0) .. "/" .. MV[id].pp end
      Gfx.text(60, y, table.concat(mv, "   "), C.gray, C.white)
      if cur and cur.mon == m then Gfx.text(60, y + 1, "(in battle)", C.gray, C.white) end
    end
    Gfx.flush()
    local k = key()
    if k == "up" then sel = sel > 1 and sel - 1 or #side.party
    elseif k == "down" then sel = sel < #side.party and sel + 1 or 1
    elseif k == "b" and not forced then return nil
    elseif k == "a" then
      local m = side.party[sel]
      if m.hp <= 0 then Gfx.text(4, H - 1, "There's no will to fight!                ", C.red, C.white); Gfx.flush(); key(1.5)
      elseif cur and cur.mon == m and cur.mon.hp > 0 then Gfx.text(4, H - 1, SP[m.species].name .. " is already out!        ", C.red, C.white); Gfx.flush(); key(1.5)
      else return sel end
    end
  end
end

-- player controller
local Player = {}
Player.__index = Player
function Player.new(ui, opts)
  opts = opts or {}
  return setmetatable({ui = ui, lastMain = 1, lastMove = 1, bag = opts.bag}, Player)
end
function Player:choose(b, B, noMoves)
  local ui = self.ui
  while true do
    ui:clearText()
    Gfx.text(4, BOX_Y + 2, "What will", C.black, C.white)
    Gfx.text(4, BOX_Y + 4, SP[B.mon.species].name .. " do?", C.black, C.white)
    Gfx.box(100, BOX_Y, 61, BOX_H)
    local cells = {{104, BOX_Y + 3, "FIGHT"}, {130, BOX_Y + 3, "PKMN"}, {104, BOX_Y + 7, "ITEM"}, {130, BOX_Y + 7, "RUN"}}
    local sel = self.lastMain
    local choice
    while not choice do
      for i, c in ipairs(cells) do Gfx.text(c[1], c[2], (i == sel and "▶ " or "  ") .. c[3], C.black, C.white) end
      Gfx.flush()
      local k = key()
      if k == "left" or k == "right" then sel = (sel % 2 == 1) and sel + 1 or sel - 1
      elseif k == "up" or k == "down" then sel = sel <= 2 and sel + 2 or sel - 2
      elseif k == "a" then choice = sel end
    end
    self.lastMain = 1
    if choice == 1 then
      if noMoves then return {kind = "move", move = MOVE.STRUGGLE} end
      local act = self:fightMenu(b, B)
      if act then return act end
    elseif choice == 2 then
      local idx = partyScreen(b, 1, false)
      ui:redraw()
      if idx then return {kind = "switch", idx = idx} end
    elseif choice == 3 then
      if not self.bag then
        ui:clearText(); ui:msg("No BAG in this mode! (items are part of the adventure)")
      else
        local act = self:bagMenu(b, B)
        if act then ui:redraw(); return act end
      end
    elseif choice == 4 then
      if b.wild then return {kind = "run"} end
      ui:clearText(); ui:msg("No! There's no running from a trainer battle!")
    end
    ui:redraw()
  end
end
function Player:fightMenu(b, B)
  local x, y = 40, BOX_Y
  Gfx.box(x, y, 58, BOX_H)
  local items = {}
  for i = 1, 4 do items[i] = B.moves[i] and MV[B.moves[i]].name or "-" end
  local function info(sel)
    Gfx.box(1, y - 6, 38, 7)
    local m = B.moves[sel]
    if m then
      local mv = MV[m]
      Gfx.text(3, y - 5, "TYPE/", C.black, C.white)
      Gfx.text(5, y - 4, pad(mv.type, 12), C.black, C.white)
      Gfx.text(3, y - 3, rpad(B.pp[sel] or 0, 2) .. "/" .. rpad(mv.pp, 2) ..
        (B.disabled and B.disabled.slot == sel and "  DISABLED" or "           "), C.black, C.white)
      Gfx.text(3, y - 2, "PWR " .. (mv.power > 1 and mv.power or "-") .. "  ACC " .. mv.acc .. "%  ", C.gray, C.white)
    end
  end
  while true do
    local sel = menu(x + 3, y + 2, items, {sel = self.lastMove, width = 40, spacing = 2, onMove = info})
    if not sel then self.ui:redraw(); return nil end
    self.lastMove = sel
    if B.moves[sel] then
      if (B.pp[sel] or 0) <= 0 then self.ui:msg("No PP left for this move!")
      elseif B.disabled and B.disabled.slot == sel then self.ui:msg("The move is disabled!")
      else self.ui:redraw(); return {kind = "move", slot = sel} end
      self.ui:redraw()
      Gfx.box(x, y, 58, BOX_H)
    end
  end
end
-- simple party picker (used by items); returns index or nil
local function pickMon(party, titleText, allowFainted)
  local sel = 1
  while true do
    Gfx.fill(1, 1, W, H, C.white)
    Gfx.text(4, 2, titleText or "Use on which POKéMON?", C.black, C.white)
    for i, m in ipairs(party) do
      local y = 4 + (i - 1) * 5
      Gfx.text(6, y, (i == sel and "▶ " or "  ") .. pad(SP[m.species].name, 12) .. " :L" .. m.level ..
        "  " .. (m.hp <= 0 and "FNT" or (m.status or "   ")), C.black, C.white)
      UI.new():drawBar(10, y + 1, m.hp, m.stats.hp)
      Gfx.text(48, y + 1, rpad(m.hp, 3) .. "/" .. rpad(m.stats.hp, 3), C.black, C.white)
    end
    Gfx.flush()
    local k = key()
    if k == "up" then sel = sel > 1 and sel - 1 or #party
    elseif k == "down" then sel = sel < #party and sel + 1 or 1
    elseif k == "b" then return nil
    elseif k == "a" then return sel end
  end
end

-- bag list: returns item id or nil; filter(id) decides what is shown
local function bagList(bag, titleText, filter, showPrice)
  local ids = {}
  for id, n in pairs(bag) do if n > 0 and (not filter or filter(id)) then ids[#ids + 1] = id end end
  table.sort(ids)
  local items = {}
  for i, id in ipairs(ids) do items[i] = pad(itemName(id), 16) .. " x" .. rpad(bag[id], 2) end
  items[#items + 1] = "CANCEL"
  Gfx.box(30, 4, 100, 42, titleText or "ITEM")
  local sel = menu(34, 6, items, {view = 36, width = 40})
  if not sel or sel > #ids then return nil end
  return ids[sel]
end

function Player:bagMenu(b, B)
  local id = bagList(self.bag, "ITEM", function(i) return itemKind(i, true) ~= nil end)
  if not id then return nil end
  local kind = itemKind(id, true)
  if kind == "mon" then
    local t = pickMon(b.sides[1].party)
    if not t then return nil end
    return {kind = "item", item = id, target = t}
  end
  return {kind = "item", item = id}
end

-- forget-a-move prompt; returns slot or nil
function Player:askReplace(mon, move)
  local items = {}
  for i, m in ipairs(mon.moves) do items[i] = MV[m].name end
  items[#items + 1] = "(don't learn " .. MV[move].name .. ")"
  Gfx.box(40, 20, 80, 16, "Forget which move?")
  local sel = menu(44, 23, items, {width = 60, spacing = 2})
  if self.ui and self.ui.b then self.ui:redraw() end
  if not sel or sel > #mon.moves then return nil end
  return sel
end

function Player:replace(b, s)
  local idx = partyScreen(b, 1, true, "Bring out which POKéMON?")
  self.ui:redraw()
  return idx
end

-----------------------------------------------------------------------
-- app screens
-----------------------------------------------------------------------
local OW = {}   -- overworld module (filled in below)
local SAVE = ROOT .. "save.lua"
local state = {party = {}, gauntlet = {best = 0}, textDelay = 1.2}

local function serialize(v)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  local parts = {}
  for k, x in pairs(v) do
    local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
    parts[#parts + 1] = key .. "=" .. serialize(x)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function save()
  local out = {party = {}, gauntlet = state.gauntlet, textDelay = Settings.textDelay, game = OW and OW.pack and OW.pack() or state.gameRaw}
  for i, m in ipairs(state.party) do out.party[i] = {species = m.species, level = m.level, dvs = m.dvs, moves = m.moves} end
  local f = io.open(SAVE, "w")
  if f then f:write("return " .. serialize(out)); f:close() end
end
local function load()
  local ok, s = pcall(dofile, SAVE)
  if ok and type(s) == "table" then
    state.party = {}
    for i, p in ipairs(s.party or {}) do state.party[i] = newMon(p.species, p.level, p.dvs, p.moves) end
    state.gauntlet = s.gauntlet or {best = 0}
    if s.textDelay ~= nil then Settings.textDelay = s.textDelay end
    state.gameRaw = s.game
  end
  if #state.party == 0 then
    state.party = {newMon(25, 25)} -- a Pikachu to get going
  end
end

local function title(t, sub)
  Gfx.fill(1, 1, W, H, C.white)
  Gfx.fill(1, 1, W, 3, C.red)
  Gfx.text(4, 2, t, C.white, C.red)
  if sub then Gfx.text(W - ulen(sub) - 3, 2, sub, C.white, C.red) end
end

local function speciesPicker(cur)
  local items = {}
  for i = 1, 151 do items[i] = string.format("%03d %s", i, SP[i].name) end
  local function preview(sel)
    Gfx.fill(60, 5, 100, 44, C.white)
    local s = SP[sel]
    local pic = loadPic("front/" .. sel)
    if pic then Gfx.pic(pic, 64, 6, s.pal, 1, 56, 56) end
    Gfx.text(124, 8, s.name, C.black, C.white)
    Gfx.text(124, 10, "TYPE: " .. table.concat(s.types, "/"), C.black, C.white)
    local b = s.base
    Gfx.text(124, 12, "HP  " .. b[1] .. "   ATK " .. b[2], C.black, C.white)
    Gfx.text(124, 13, "DEF " .. b[3] .. "   SPD " .. b[4], C.black, C.white)
    Gfx.text(124, 14, "SPC " .. b[5] .. "   TOTAL " .. (b[1] + b[2] + b[3] + b[4] + b[5]) .. "  ", C.black, C.white)
  end
  title("CHOOSE A POKéMON", "type a letter to jump")
  return menu(4, 5, items, {sel = cur or 1, view = 42, width = 30, onMove = preview,
    onLetter = function(ch, sel)
      for k = 1, 151 do
        local i = (sel + k - 1) % 151 + 1
        if SP[i].name:sub(1, 1) == ch then return i end
      end
    end})
end

local function movePicker(mon, slot)
  local list = learnable(mon.species, mon.level)
  local items = {}
  for i, e in ipairs(list) do
    local mv = MV[e[1]]
    items[i] = pad(mv.name, 14) .. pad(mv.type, 10) .. rpad(mv.power > 1 and mv.power or "-", 4) .. rpad(mv.acc, 5) .. "% " .. e[2]
  end
  items[#items + 1] = "(empty slot)"
  title("TEACH A MOVE - slot " .. slot, SP[mon.species].name)
  Gfx.text(6, 4, "NAME          TYPE       PWR  ACC   FROM", C.gray, C.white)
  local sel = menu(4, 5, items, {view = 42, width = 60})
  if not sel then return end
  if sel > #list then
    if #mon.moves > 1 then table.remove(mon.moves, slot) end
  else
    local m = list[sel][1]
    for i, k in ipairs(mon.moves) do if k == m and i ~= slot then return end end
    if slot > #mon.moves then mon.moves[#mon.moves + 1] = m else mon.moves[slot] = m end
  end
  healMon(mon)
end

local function editMon(i)
  local mon = state.party[i]
  while true do
    title("EDIT POKéMON #" .. i, "A select  B back")
    local s = SP[mon.species]
    local pic = loadPic("front/" .. mon.species)
    if pic then Gfx.pic(pic, 96, 6, s.pal, 1, 56, 56) end
    Gfx.text(96, 36, s.name .. "  :L" .. mon.level .. "   " .. table.concat(s.types, "/"), C.black, C.white)
    local st = mon.stats
    Gfx.text(96, 38, "HP " .. st.hp .. "  ATK " .. st.atk .. "  DEF " .. st.def .. "  SPD " .. st.spd .. "  SPC " .. st.spc .. "    ", C.black, C.white)
    Gfx.text(96, 39, "DVs  A" .. mon.dvs.atk .. " D" .. mon.dvs.def .. " S" .. mon.dvs.spd .. " C" .. mon.dvs.spc .. "     ", C.gray, C.white)
    local items = {"SPECIES: " .. s.name, "LEVEL: " .. mon.level .. "   (←/→ ±1, PgUp/PgDn ±10 on this row)"}
    for k = 1, 4 do items[#items + 1] = "MOVE " .. k .. ": " .. (mon.moves[k] and MV[mon.moves[k]].name or "-") end
    items[#items + 1] = "REROLL DVs"
    items[#items + 1] = "MAX DVs (15/15/15/15)"
    items[#items + 1] = "REMOVE FROM PARTY"
    items[#items + 1] = "DONE"
    local sel = menu(4, 6, items, {width = 80, spacing = 2})
    if not sel or sel == #items then healMon(mon); return end
    if sel == 1 then
      local sp = speciesPicker(mon.species)
      if sp then state.party[i] = newMon(sp, mon.level, mon.dvs); mon = state.party[i] end
    elseif sel == 2 then
      while true do
        Gfx.text(6, 8, "▶ LEVEL: " .. pad(tostring(mon.level), 4) .. " ←/→ ±1   ↑/↓ ±10   A done        ", C.blue, C.white)
        Gfx.flush()
        local k = key()
        if k == "left" then mon.level = max(1, mon.level - 1)
        elseif k == "right" then mon.level = min(100, mon.level + 1)
        elseif k == "down" or k == "pgdn" then mon.level = max(1, mon.level - 10)
        elseif k == "up" or k == "pgup" then mon.level = min(100, mon.level + 10)
        elseif k == "a" or k == "b" then break end
      end
      healMon(mon)
    elseif sel >= 3 and sel <= 6 then
      movePicker(mon, min(sel - 2, #mon.moves + 1))
    elseif sel == 7 then
      mon.dvs = {atk = rnd(0, 15), def = rnd(0, 15), spd = rnd(0, 15), spc = rnd(0, 15)}; healMon(mon)
    elseif sel == 8 then
      mon.dvs = {atk = 15, def = 15, spd = 15, spc = 15}; healMon(mon)
    elseif sel == 9 then
      if #state.party > 1 then table.remove(state.party, i); return end
    end
  end
end

local function partyEditor()
  while true do
    title("PARTY", "A edit  B back")
    local items = {}
    for i, m in ipairs(state.party) do
      local mv = {}
      for _, id in ipairs(m.moves) do mv[#mv + 1] = MV[id].name end
      items[i] = pad(SP[m.species].name, 12) .. " :L" .. pad(tostring(m.level), 4) .. table.concat(mv, ", ")
    end
    if #state.party < 6 then items[#items + 1] = "+ ADD POKéMON" end
    items[#items + 1] = "SET ALL LEVELS..."
    local sel = menu(4, 6, items, {width = 110, spacing = 3})
    if not sel then save(); return end
    if sel <= #state.party then editMon(sel)
    elseif items[sel] == "+ ADD POKéMON" then
      local sp = speciesPicker(1)
      if sp then state.party[#state.party + 1] = newMon(sp, state.party[1] and state.party[1].level or 50) end
    else
      local lv = state.party[1] and state.party[1].level or 50
      while true do
        title("SET ALL LEVELS", "←/→ ±1  ↑/↓ ±10  A apply  B cancel")
        Gfx.text(10, 10, "Level: " .. lv .. "   (moves reset to that level's level-up moves)   ", C.black, C.white)
        Gfx.flush()
        local k = key()
        if k == "left" then lv = max(1, lv - 1) elseif k == "right" then lv = min(100, lv + 1)
        elseif k == "down" then lv = max(1, lv - 10) elseif k == "up" then lv = min(100, lv + 10)
        elseif k == "b" then break
        elseif k == "a" then
          for i, m in ipairs(state.party) do state.party[i] = newMon(m.species, lv, m.dvs) end
          break
        end
      end
    end
    save()
  end
end

local function freshParty()
  local p = {}
  for i, m in ipairs(state.party) do healMon(m); p[i] = m end
  return p
end

local function doBattle(cid, partyIdx)
  local ui = UI.new()
  local enemy = trainerParty(cid, partyIdx)
  local tname = trainerName(cid)
  local b = Battle.new({party1 = freshParty(), party2 = enemy, ctrl1 = Player.new(ui),
    ctrl2 = AI.new(TR[cid].ai), name2 = tname, trainer = cid, ui = ui})
  -- intro: trainer pic
  Gfx.fill(1, 1, W, H, C.white)
  local tp = loadPic("trainer/" .. cid)
  if tp then Gfx.pic(tp, EN_SPR.x, EN_SPR.y, GRAY_PAL, 1, 56, 56) end
  local rp = loadPic("player/redb")
  if rp then Gfx.pic(rp, PL_SPR.x, PL_SPR.y, GRAY_PAL, 2, 64, 64) end
  ui.b = b
  ui:drawBox()
  Gfx.flush()
  ui:msg(tname .. " wants to fight!")
  ui.visible = {true, true}
  local winner = b:run()
  for _, m in ipairs(state.party) do m.status, m.sleep = nil, nil end
  if winner == 1 then
    ui:msg(PLAYER_NAME .. " defeated " .. tname .. "!")
    local last = enemy[#enemy]
    ui:msg(PLAYER_NAME .. " got ¥" .. floor(TR[cid].money / 100 * last.level) .. " for winning!")
  else
    ui:msg(PLAYER_NAME .. " is out of usable POKéMON!")
    ui:msg(PLAYER_NAME .. " blacked out!")
  end
  for _, m in ipairs(state.party) do healMon(m) end
  return winner == 1
end

local function trainerSelect()
  local ids = {}
  for id, t in pairs(TR) do if #t.parties > 0 then ids[#ids + 1] = id end end
  table.sort(ids)
  local items = {}
  for i, id in ipairs(ids) do items[i] = trainerName(id) .. "  (" .. #TR[id].parties .. ")" end
  local lastClass = 1
  while true do
    title("BATTLE A TRAINER", "A choose  B back")
    local function preview(sel)
      Gfx.fill(60, 5, 100, 44, C.white)
      local tp = loadPic("trainer/" .. ids[sel])
      if tp then Gfx.pic(tp, 100, 6, GRAY_PAL, 1, 56, 56) end
    end
    local sel = menu(4, 5, items, {sel = lastClass, view = 44, width = 40, onMove = preview})
    if not sel then return end
    lastClass = sel
    local cid = ids[sel]
    local parties = TR[cid].parties
    local pItems = {}
    for i, p in ipairs(parties) do
      local mons = {}
      for _, e in ipairs(p.mons) do mons[#mons + 1] = SP[e[2]].name .. " L" .. e[1] end
      pItems[i] = pad(p.where ~= "" and p.where or "-", 24) .. table.concat(mons, ", ")
    end
    title(trainerName(cid), "pick a team")
    local pi = menu(4, 5, pItems, {view = 44, width = 150})
    if pi then doBattle(cid, pi) end
  end
end

local function gauntlet()
  local list = {}
  for _, g in ipairs(GYM_ORDER) do list[#list + 1] = {TRAINER[g], g == "GIOVANNI" and 3 or 1} end
  for _, e in ipairs({"LORELEI", "BRUNO", "AGATHA", "LANCE"}) do list[#list + 1] = {TRAINER[e], 1} end
  list[#list + 1] = {TRAINER.RIVAL3, rnd(1, 3)}
  title("GYM GAUNTLET", "8 gyms, Elite Four, Champion")
  local y = 6
  for i, e in ipairs(list) do
    Gfx.text(8, y, string.format("%2d. %s", i, i == #list and "CHAMPION " .. RIVAL_NAME or trainerName(e[1])), C.black, C.white)
    y = y + 2
  end
  Gfx.text(8, y + 1, "Your party is fully healed between battles. Best run: " .. (state.gauntlet.best or 0) .. "/" .. #list, C.gray, C.white)
  Gfx.text(8, y + 3, "A = start   B = back", C.black, C.white)
  Gfx.flush()
  while true do
    local k = key()
    if k == "b" then return end
    if k == "a" then break end
  end
  for i, e in ipairs(list) do
    if not doBattle(e[1], e[2]) then
      state.gauntlet.best = max(state.gauntlet.best or 0, i - 1); save()
      return
    end
  end
  state.gauntlet.best = #list; save()
  title("HALL OF FAME", "")
  for i, m in ipairs(state.party) do
    local pic = loadPic("front/" .. m.species)
    if pic then Gfx.pic(pic, 4 + ((i - 1) % 3) * 52, 6 + floor((i - 1) / 3) * 22, SP[m.species].pal, 1, 56, 40) end
  end
  Gfx.text(4, H - 2, "Congratulations! You beat the Champion!  (press A)", C.black, C.white)
  Gfx.flush()
  repeat until key() == "a"
end

local function settings()
  local opts = {0.6, 1.2, 2.0, 999}
  local names = {"FAST (0.6s)", "MEDIUM (1.2s)", "SLOW (2s)", "WAIT FOR A"}
  title("OPTIONS", "")
  Gfx.text(6, 5, "Battle text speed (any key always skips):", C.black, C.white)
  local cur = 2
  for i, v in ipairs(opts) do if v == Settings.textDelay or (v == 999 and Settings.textDelay == false) then cur = i end end
  local sel = menu(6, 7, names, {sel = cur, width = 30, spacing = 2})
  if sel then
    if opts[sel] == 999 then Settings.textDelay = false else Settings.textDelay = opts[sel] end
    save()
  end
end

-----------------------------------------------------------------------
-- overworld (adventure mode)
-----------------------------------------------------------------------
;(function() -- own function scope: Lua allows only 200 locals per function
  local WD                      -- world index from gfx.pak
  local G                       -- game state (saved)
  local cur = {}                -- current map runtime
  local P = {x = 0, y = 0, dir = "DOWN", walk = false}
  local camX, camY = 0, 0
  local VIEW_W, VIEW_H = 160, 96 -- viewport in pixels (10 x 6 steps)
  local DIRS = {up = {0, -1, "UP"}, down = {0, 1, "DOWN"}, left = {-1, 0, "LEFT"}, right = {1, 0, "RIGHT"}}
  local DIRV = {UP = {0, -1}, DOWN = {0, 1}, LEFT = {-1, 0}, RIGHT = {1, 0}}
  local OPP = {UP = "DOWN", DOWN = "UP", LEFT = "RIGHT", RIGHT = "LEFT"}
  local SLOT = {51, 51, 39, 25, 25, 25, 13, 13, 11, 3}
  local BADGES = {BROCK = "BOULDER", MISTY = "CASCADE", LT_SURGE = "THUNDER", ERIKA = "RAINBOW",
    KOGA = "SOUL", SABRINA = "MARSH", BLAINE = "VOLCANO", GIOVANNI = "EARTH"}
  local SPR_SHADE = {[1] = 0, [2] = 1, [3] = 3}
  local blkCache = {}

  local function chunk(name)
    local src = pakRead(name)
    if not src then return nil end
    local f, err = loadString(src, "=" .. name)
    if not f then error(err) end
    return f()
  end

  function OW.available()
    if WD == nil then
      local ok, w = pcall(chunk, "world")
      if not ok and os.getenv("PKDEBUG") then io.stderr:write("world load failed: " .. tostring(w) .. "\n") end
      WD = ok and w or false
      if WD then for id, e in pairs(WD.items) do ITEMS[id] = e; ITEM[e.const] = id end end
    end
    return WD and true or false
  end

  local function mapName(id)
    local m = WD.maps[id]
    return m and m.const:gsub("_", " ") or "?"
  end

  local function mapBlocks(id)
    if not blkCache[id] then blkCache[id] = pakRead("blk/" .. id) end
    return blkCache[id]
  end

  -------------------------------------------------------------------
  -- map access
  -------------------------------------------------------------------
  local function getBlock(bx, by)
    local w, h = cur.w, cur.h
    if bx >= 0 and by >= 0 and bx < w and by < h then return cur.blocks:byte(by * w + bx + 1) end
    for _, c in ipairs(cur.conns) do
      local dir, mid, off = c[1], c[2], c[3]
      local m = WD.maps[mid]
      local tx, ty
      if dir == "north" and by < 0 then tx, ty = bx - off, by + m.h
      elseif dir == "south" and by >= h then tx, ty = bx - off, by - h
      elseif dir == "west" and bx < 0 then tx, ty = bx + m.w, by - off
      elseif dir == "east" and bx >= w then tx, ty = bx - w, by - off end
      if tx and tx >= 0 and ty >= 0 and tx < m.w and ty < m.h then
        local b = mapBlocks(mid)
        if b then return b:byte(ty * m.w + tx + 1) end
      end
    end
    return cur.border
  end

  local function tileAt(tx, ty)
    local b = getBlock(floor(tx / 4), floor(ty / 4))
    return cur.bst:byte(b * 16 + (ty % 4) * 4 + (tx % 4) + 1) or 0
  end

  local function inMap(x, y) return x >= 0 and y >= 0 and x < cur.w * 2 and y < cur.h * 2 end
  local function stepTile(x, y) return tileAt(2 * x, 2 * y + 1) end

  local function objAt(x, y)
    for _, o in ipairs(cur.objs) do if o.x == x and o.y == y then return o end end
  end

  local function knows(moveConst)
    local id = MOVE[moveConst]
    for _, m in ipairs(G.party) do
      for _, k in ipairs(m.moves) do if k == id then return m end end
    end
  end

  local function walkable(x, y, surfing)
    local t = stepTile(x, y)
    if surfing and t == 0x14 then return true end
    return cur.coll[t] == true
  end

  -------------------------------------------------------------------
  -- rendering
  -------------------------------------------------------------------
  local sprAt = {}
  local function sprKey(x, y) return (y + 1000) * 4096 + (x + 1000) end
  local FRAME = {DOWN = 0, UP = 1, LEFT = 2, RIGHT = 2}

  local function buildSprites()
    sprAt = {}
    for _, o in ipairs(cur.objs) do
      local pic = loadPic("spr/" .. o.sid)
      if pic then
        local frames = WD.sprites[o.sid] or 1
        sprAt[sprKey(o.x, o.y)] = {pic = pic, frame = frames >= 3 and FRAME[o.dir] or 0, flip = o.dir == "RIGHT"}
      end
    end
    local sid = P.surf and WD.spriteIds.SEEL or WD.spriteIds.RED
    local pic = loadPic("spr/" .. sid)
    if pic then
      local frames = WD.sprites[sid] or 1
      local f = frames >= 3 and FRAME[P.dir] or 0
      if P.walk and frames >= 6 and not P.surf then f = f + 3 end
      sprAt[sprKey(P.x, P.y)] = {pic = pic, frame = f, flip = P.dir == "RIGHT"}
    end
  end

  local tsPx, tsW = "", 128
  local function bgShade(px, py)
    local t = tileAt(floor(px / 8), floor(py / 8))
    local tx, ty = t % 16, floor(t / 16)
    return tsPx:byte((ty * 8 + py % 8) * tsW + tx * 8 + px % 8 + 1) or 0
  end
  local function pix(px, py)
    local e = sprAt[sprKey(floor(px / 16), floor(py / 16))]
    if e then
      local u, v = px % 16, py % 16
      if e.flip then u = 15 - u end
      local s = e.pic.px:byte((e.frame * 16 + v) * 16 + u + 1)
      if s and s > 0 then return SPR_SHADE[s] end
    end
    return bgShade(px, py)
  end

  -- draw part of the viewport; vx/vy/vw/vh in viewport pixels (vy, vh even)
  local function blitRect(vx, vy, vw, vh)
    local ox, oy = camX * 16 + vx, camY * 16 + vy
    local pal = cur.pal
    local groups = {}
    for r = 0, floor(vh / 2) - 1 do
      local runStart, runKey
      local cy = floor(vy / 2) + r + 1
      for c = 0, vw - 1 do
        local t = pix(ox + c, oy + 2 * r)
        local b = pix(ox + c, oy + 2 * r + 1)
        local key = t == b and b or (t * 4 + b + 16)
        if key ~= runKey then
          if runKey then
            local g = groups[runKey]; if not g then g = {}; groups[runKey] = g end
            g[#g + 1] = {vx + runStart + 1, cy, c - runStart}
          end
          runKey, runStart = key, c
        end
      end
      local g = groups[runKey]; if not g then g = {}; groups[runKey] = g end
      g[#g + 1] = {vx + runStart + 1, cy, vw - runStart}
    end
    for key, runs in pairs(groups) do
      if key < 16 then
        bg(pal[key + 1])
        for _, r in ipairs(runs) do gpu.fill(r[1], r[2], r[3], 1, " ") end
      else
        local k = key - 16
        fg(pal[floor(k / 4) + 1]); bg(pal[k % 4 + 1])
        for _, r in ipairs(runs) do gpu.set(r[1], r[2], string.rep(BLOCK, r[3])) end
      end
    end
  end

  local function blitStep(sx, sy)
    local vx, vy = (sx - camX) * 16, (sy - camY) * 16
    if vx >= 0 and vy >= 0 and vx < VIEW_W and vy < VIEW_H then blitRect(vx, vy, 16, 16) end
  end

  local function statusBar(text)
    Gfx.fill(1, 49, W, 2, C.black)
    Gfx.text(3, 49, mapName(cur.id), C.white, C.black)
    Gfx.text(3, 50, text or ("¥" .. G.money .. "   BADGES " .. #G.badges), C.light, C.black)
    local hint = "arrows move   Z/Enter talk   X back   Tab/S menu"
    Gfx.text(W - ulen(hint) - 2, 50, hint, C.gray, C.black)
  end

  local function setCamera() camX, camY = P.x - 4, P.y - 2 end

  local function redraw()
    setCamera()
    buildSprites()
    blitRect(0, 0, VIEW_W, VIEW_H)
    statusBar()
    Gfx.flush()
  end

  -- scroll by one step after P moved by (dx, dy)
  local function scroll(dx, dy)
    setCamera()
    buildSprites()
    if dx ~= 0 then
      gpu.copy(dx > 0 and 17 or 1, 1, VIEW_W - 16, VIEW_H / 2, -16 * dx, 0)
      blitRect(dx > 0 and VIEW_W - 16 or 0, 0, 16, VIEW_H)
    elseif dy ~= 0 then
      gpu.copy(1, dy > 0 and 9 or 1, VIEW_W, VIEW_H / 2 - 8, 0, -8 * dy)
      blitRect(0, dy > 0 and VIEW_H - 16 or 0, VIEW_W, 16)
    end
    blitStep(P.x - dx, P.y - dy)
    blitStep(P.x, P.y)
    Gfx.flush()
  end

  -------------------------------------------------------------------
  -- map loading
  -------------------------------------------------------------------
  local function mapPal(id)
    local tsName = WD.tilesets[cur.ts].name
    local name
    if tsName == "Cemetery" then name = "PAL_GRAYMON"
    elseif tsName == "Cavern" then name = "PAL_CAVE"
    else
      local ref = id < WD.firstIndoor and id or (G.lastOut or 0)
      if ref < WD.numCity then name = WD.palNames[ref + 2] else name = "PAL_ROUTE" end
    end
    local p = D.pals[name] or D.pals.PAL_ROUTE
    return {p[1], p[2], p[3], p[4]}
  end

  local function dirOf(d) return DIRV[d] and d or "DOWN" end

  local function loadMap(id)
    local info = chunk("map/" .. id)
    if not info then error("map " .. tostring(id) .. " missing from gfx.pak", 0) end
    local m = WD.maps[id]
    cur = {id = id, info = info, w = m.w, h = m.h, conns = m.conns, border = m.border, ts = m.ts}
    -- keep only this map + neighbours' blocks cached
    local keep = {[id] = true}
    for _, c in ipairs(m.conns) do keep[c[2]] = true end
    for k in pairs(blkCache) do if not keep[k] then blkCache[k] = nil end end
    cur.blocks = mapBlocks(id)
    if not cur.blocks then error("blocks for map " .. id .. " missing", 0) end
    local ts = WD.tilesets[m.ts]
    cur.coll = {}
    for _, t in ipairs(ts.coll) do cur.coll[t] = true end
    cur.counter = {}
    for _, t in ipairs(ts.counters or {}) do cur.counter[t] = true end
    cur.warpTile = {}
    for _, t in ipairs(ts.warp or {}) do cur.warpTile[t] = true end
    cur.grass = ts.grass
    cur.bst = pakRead("bst/" .. m.ts)
    local tpic = loadPic("ts/" .. m.ts)
    tsPx, tsW = tpic.px, tpic.w
    cur.pal = mapPal(id)
    cur.objs = {}
    for i, o in ipairs(info.objs) do
      local hidden = o.hide
      if o.item and G.flags["I" .. id .. "_" .. i] then hidden = true end
      if o.mon and G.flags["S" .. id .. "_" .. i] then hidden = true end
      if G.flags["H" .. id .. "_" .. i] then hidden = true end
      if not hidden then
        cur.objs[#cur.objs + 1] = {i = i, o = o, x = o.x, y = o.y, ox = o.x, oy = o.y, dir = dirOf(o.d), sid = o.s}
      end
    end
    cur.warpAt = {}
    for i, w in ipairs(info.warps) do cur.warpAt[w[1] .. "," .. w[2]] = i end
    G.map = id
  end

  -------------------------------------------------------------------
  -- text boxes & prompts
  -------------------------------------------------------------------
  local function wrap(text, width)
    local lines, line = {}, ""
    for w in text:gmatch("%S+") do
      if line ~= "" and ulen(line) + ulen(w) + 1 > width then lines[#lines + 1] = line; line = w
      else line = line == "" and w or (line .. " " .. w) end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
  end

  local function textBox(page, keepOpen)
    Gfx.box(1, 37, W, 14)
    local lines = wrap(page, W - 8)
    for i = 1, min(5, #lines) do Gfx.text(4, 37 + i * 2, lines[i], C.black, C.white) end
    if not keepOpen then Gfx.text(W - 4, 49, "▼", C.black, C.white) end
    Gfx.flush()
  end

  local function closeBox()
    blitRect(0, 72, VIEW_W, 24)
    statusBar()
    Gfx.flush()
  end

  local function say(pages)
    if type(pages) == "string" then pages = {pages} end
    for _, p in ipairs(pages or {}) do
      textBox(p)
      repeat local k = key() until k == "a" or k == "b"
    end
    closeBox()
  end

  local function yesNo(question)
    textBox(question, true)
    Gfx.box(W - 20, 29, 18, 8)
    local sel = menu(W - 17, 31, {"YES", "NO"}, {width = 10, spacing = 2})
    redraw()
    return sel == 1
  end

  local function askReplace(mon, move)
    local items = {}
    for i, m in ipairs(mon.moves) do items[i] = MV[m].name end
    items[#items + 1] = "(don't learn " .. MV[move].name .. ")"
    Gfx.box(40, 10, 80, 16, "Forget which move?")
    local sel = menu(44, 13, items, {width = 60, spacing = 2})
    if not sel or sel > #mon.moves then return nil end
    return sel
  end

  -- message sink for item use / level ups outside battle
  local function fieldSay(t) textBox(t); repeat local k = key() until k == "a" or k == "b" end

  -------------------------------------------------------------------
  -- evolution
  -------------------------------------------------------------------
  local function evolve(mon, into)
    local oldName = SP[mon.species].name
    Gfx.fill(1, 1, W, H, C.white)
    local p1 = loadPic("front/" .. mon.species)
    if p1 then Gfx.pic(p1, 52, 6, SP[mon.species].pal, 1, 56, 56) end
    textBox("What? " .. oldName .. " is evolving! (B to stop)", true)
    local k = key(3)
    if k == "b" then
      fieldSay("Huh? " .. oldName .. " stopped evolving!")
      return false
    end
    local p2 = loadPic("front/" .. into)
    Gfx.fill(1, 1, W, 36, C.white)
    if p2 then Gfx.pic(p2, 52, 6, SP[into].pal, 1, 56, 56) end
    local oldMax = mon.stats.hp
    mon.species = into
    calcStats(mon)
    mon.hp = mon.hp + (mon.stats.hp - oldMax)
    fieldSay(oldName .. " evolved into " .. SP[into].name .. "!")
    for _, l in ipairs(SP[into].learn) do
      if l[1] == mon.level then learnMove(mon, l[2], fieldSay, askReplace) end
    end
    return true
  end

  local function checkEvolutions()
    for _, m in ipairs(G.party) do
      if m.leveled and m.hp > 0 then
        for _, e in ipairs(SP[m.species].evos) do
          if e.how == "LEVEL" and m.level >= e.level then evolve(m, e.into); break end
        end
      end
      m.leveled = nil
      if m.evolveTo then local into = m.evolveTo; m.evolveTo = nil; evolve(m, into) end
    end
  end

  -------------------------------------------------------------------
  -- battles from the overworld
  -------------------------------------------------------------------
  local function healParty()
    for _, m in ipairs(G.party) do healMon(m) end
  end

  local function respawnPoint(mapId)
    local info = chunk("map/" .. mapId)
    local w = info.warps[1]
    return {map = mapId, x = w[1], y = w[2] - 1}
  end

  local function blackout()
    Gfx.fill(1, 1, W, H, C.black)
    Gfx.flush()
    sleep(0.6)
    G.money = floor(G.money / 2)
    healParty()
    local r = G.respawn
    loadMap(r.map)
    P.x, P.y, P.dir, P.surf = r.x, r.y, "UP", false
    redraw()
  end

  local function flash()
    for _ = 1, 2 do
      Gfx.fill(1, 1, W, 48, C.black); Gfx.flush(); sleep(0.08)
      blitRect(0, 0, VIEW_W, VIEW_H); Gfx.flush(); sleep(0.08)
    end
  end

  local function onCatch(mon, sayFn)
    mon.statexp = mon.statexp or {0, 0, 0, 0, 0}
    if #G.party < 6 then G.party[#G.party + 1] = mon
    else
      G.box[#G.box + 1] = mon
      sayFn(SP[mon.species].name .. " was transferred to the PC BOX!")
    end
    G.flags["C" .. mon.species] = true
  end

  -- returns "win", "lose", "run", "caught"
  local function fight(o)
    flash()
    local ui = UI.new()
    local b = Battle.new({party1 = G.party, party2 = o.party, ctrl1 = Player.new(ui, {bag = G.bag}),
      ctrl2 = AI.new(o.ai or {}), name2 = o.name, trainer = o.cid, ui = ui, wild = o.wild,
      game = true, bag = G.bag, onCatch = onCatch})
    Gfx.fill(1, 1, W, H, C.white)
    ui.b = b
    if o.wild then
      local mon = o.party[1]
      local pic = loadPic("front/" .. mon.species)
      if pic then Gfx.pic(pic, EN_SPR.x, EN_SPR.y, SP[mon.species].pal, 1, 56, 56) end
      local rp = loadPic("player/redb")
      if rp then Gfx.pic(rp, PL_SPR.x, PL_SPR.y, GRAY_PAL, 2, 64, 64) end
      ui:drawBox(); Gfx.flush()
      ui:msg("Wild " .. SP[mon.species].name .. " appeared!")
    else
      local tp = loadPic("trainer/" .. o.cid)
      if tp then Gfx.pic(tp, EN_SPR.x, EN_SPR.y, GRAY_PAL, 1, 56, 56) end
      local rp = loadPic("player/redb")
      if rp then Gfx.pic(rp, PL_SPR.x, PL_SPR.y, GRAY_PAL, 2, 64, 64) end
      ui:drawBox(); Gfx.flush()
      ui:msg(o.name .. " wants to fight!")
    end
    ui.visible = {true, true}
    local res = b:run()
    local out
    if res == 1 then
      out = "win"
      if not o.wild then
        ui:msg(PLAYER_NAME .. " defeated " .. o.name .. "!")
        for _, p in ipairs(o.endText or {}) do ui:msg(p) end
        local last = o.party[#o.party]
        local prize = floor(TR[o.cid].money / 100 * last.level)
        G.money = min(999999, G.money + prize)
        ui:msg(PLAYER_NAME .. " got ¥" .. prize .. " for winning!")
      end
    elseif res == 2 then
      out = "lose"
      ui:msg(PLAYER_NAME .. " is out of usable POKéMON!")
      ui:msg(PLAYER_NAME .. " blacked out!")
    elseif res == "caught" then out = "caught"
    else out = "run" end
    if out ~= "lose" then checkEvolutions() end
    if out == "lose" then blackout() else redraw() end
    return out
  end

  local function wildFight(dex, level)
    local mon = newMon(dex, level)
    mon.exp = expFor(dex, level)
    return fight({party = {mon}, wild = true})
  end

  local function trainerFight(ob)
    local cid, idx = ob.o.opp[1], ob.o.opp[2]
    local t = ob.o.t or {}
    local res = fight({party = trainerParty(cid, idx), cid = cid, name = trainerName(cid), ai = TR[cid].ai,
      endText = t.k == "trainer" and t.e or nil})
    if res == "win" then
      G.flags["T" .. cur.id .. "_" .. ob.i] = true
      if ob.o.story and ob.i > 0 then
        -- story trainers (e.g. Team Rocket) leave once beaten
        G.flags["H" .. cur.id .. "_" .. ob.i] = true
        for i, x in ipairs(cur.objs) do if x == ob then table.remove(cur.objs, i) break end end
        redraw()
      end
      local badge = BADGES[TR[cid].const]
      if badge and not G.flags["B" .. badge] then
        G.flags["B" .. badge] = true
        G.badges[#G.badges + 1] = badge
        say(PLAYER_NAME .. " received the " .. badge .. "BADGE!")
      end
      if TR[cid].const == "RIVAL3" then
        G.flags.champion = true
        say({"Congratulations! You are the new POKéMON LEAGUE CHAMPION!"})
      end
    end
    return res
  end

  -------------------------------------------------------------------
  -- trainers' line of sight
  -------------------------------------------------------------------
  local function bubble(o)
    local cx, cy = (o.x - camX) * 16 + 8, (o.y - camY) * 8
    if cy >= 1 then Gfx.text(cx, cy, " ! ", C.black, C.white); Gfx.flush(); sleep(0.7) end
    blitStep(o.x, o.y - 1); Gfx.flush()
  end

  local function checkSight()
    for _, ob in ipairs(cur.objs) do
      local t = ob.o.t
      if ob.o.opp and t and t.k == "trainer" and not G.flags["T" .. cur.id .. "_" .. ob.i] then
        local dv = DIRV[ob.dir]
        local dist
        if dv[1] == 0 and P.x == ob.x and (P.y - ob.y) * dv[2] > 0 then dist = math.abs(P.y - ob.y)
        elseif dv[2] == 0 and P.y == ob.y and (P.x - ob.x) * dv[1] > 0 then dist = math.abs(P.x - ob.x) end
        if dist and dist <= (t.range or 0) then
          bubble(ob)
          while math.abs(P.x - ob.x) + math.abs(P.y - ob.y) > 1 do
            local ox, oy = ob.x, ob.y
            ob.x, ob.y = ob.x + dv[1], ob.y + dv[2]
            buildSprites(); blitStep(ox, oy); blitStep(ob.x, ob.y); Gfx.flush(); sleep(0.12)
          end
          P.dir = OPP[ob.dir]
          buildSprites(); blitStep(P.x, P.y); Gfx.flush()
          say(t.b)
          trainerFight(ob)
          return true
        end
      end
    end
  end

  -------------------------------------------------------------------
  -- wild encounters
  -------------------------------------------------------------------
  local function tryEncounter()
    local wild = cur.info.wild
    if not wild then return end
    if cur.warpAt and cur.warpAt[P.x .. "," .. P.y] then return end
    local t = tileAt(2 * P.x + 1, 2 * P.y + 1)
    local rate, list
    if P.surf and t == 0x14 then rate, list = wild.wr, wild.w
    elseif t == cur.grass then rate, list = wild.gr, wild.g
    elseif cur.id >= WD.firstIndoor and WD.tilesets[cur.ts].name ~= "Forest" and not P.surf then rate, list = wild.gr, wild.g end
    if not rate or rate == 0 or not list or #list == 0 then return end
    if rnd(0, 255) >= rate then return end
    local r, acc, slot = rnd(0, 255), 0, #list
    for i, c in ipairs(SLOT) do acc = acc + c; if r < acc then slot = i; break end end
    local e = list[min(slot, #list)]
    if G.repel > 0 then
      local lead
      for _, m in ipairs(G.party) do if m.hp > 0 then lead = m; break end end
      if lead and e[1] < lead.level then return end
    end
    wildFight(e[2], e[1])
    return true
  end

  -------------------------------------------------------------------
  -- warps & movement
  -------------------------------------------------------------------
  local function indexWarps() end -- loadMap does this now

  local function doWarp(i)
    local w = cur.info.warps[i]
    local dest, idx = w[3], w[4]
    if dest == 255 then dest = G.lastOut or 0 end
    if cur.id < WD.firstIndoor then G.lastOut = cur.id end
    if not WD.maps[dest] then say("(This area isn't available.)"); return end
    loadMap(dest)
    indexWarps()
    local dw = cur.info.warps[idx] or cur.info.warps[1]
    P.x, P.y = dw[1], dw[2]
    P.surf = false
    if dest < WD.firstIndoor and walkable(P.x, P.y + 1) and not objAt(P.x, P.y + 1) then
      P.y = P.y + 1; P.dir = "DOWN"
    elseif dest >= WD.firstIndoor then
      P.dir = "UP"
    end
    redraw()
  end

  local function changeMap(nx, ny, dir)
    for _, c in ipairs(cur.conns) do
      if c[1] == dir then
        local m = WD.maps[c[2]]
        local x, y
        if dir == "north" then x, y = nx - 2 * c[3], ny + m.h * 2
        elseif dir == "south" then x, y = nx - 2 * c[3], ny - cur.h * 2
        elseif dir == "west" then x, y = nx + m.w * 2, ny - 2 * c[3]
        else x, y = nx - cur.w * 2, ny - 2 * c[3] end
        return c[2], x, y
      end
    end
  end

  local function stepTo(dx, dy, nx, ny)
    local oldPal = cur.pal
    if not inMap(nx, ny) then
      local dir = ny < 0 and "north" or (ny >= cur.h * 2 and "south" or (nx < 0 and "west" or "east"))
      local mid, x, y = changeMap(nx, ny, dir)
      if not mid then return false end
      loadMap(mid)
      indexWarps()
      nx, ny = x, y
    end
    P.x, P.y = nx, ny
    P.walk = not P.walk
    if cur.pal ~= oldPal and (cur.pal[2] ~= oldPal[2] or cur.pal[3] ~= oldPal[3]) then redraw() else scroll(dx, dy) end
    if G.repel > 0 then
      G.repel = G.repel - 1
      if G.repel == 0 then say("REPEL's effect wore off.") end
    end
    return true
  end

  local function pushBoulder(ob, dx, dy)
    if not knows("STRENGTH") then return false end
    local bx, by = ob.x + dx, ob.y + dy
    if not inMap(bx, by) or objAt(bx, by) or not walkable(bx, by) then return false end
    local ox, oy = ob.x, ob.y
    ob.x, ob.y = bx, by
    buildSprites(); blitStep(ox, oy); blitStep(bx, by); Gfx.flush()
    return true
  end

  local function tryMove(k)
    local d = DIRS[k]
    local dx, dy = d[1], d[2]
    if P.dir ~= d[3] then
      P.dir = d[3]
      buildSprites(); blitStep(P.x, P.y); Gfx.flush()
      return
    end
    local nx, ny = P.x + dx, P.y + dy
    local ob = objAt(nx, ny)
    if ob then
      if ob.sid == WD.spriteIds.BOULDER and pushBoulder(ob, dx, dy) then
        -- boulder moved; player follows next press
      end
      return
    end
    -- ledges
    local stand, target = stepTile(P.x, P.y), stepTile(nx, ny)
    for _, l in ipairs(WD.ledges) do
      if l[1] == P.dir and stand == l[2] and target == l[3] then
        local lx, ly = nx + dx, ny + dy
        if not objAt(lx, ly) and (not inMap(lx, ly) or walkable(lx, ly)) then
          stepTo(dx, dy, nx, ny)
          stepTo(dx, dy, lx, ly)
          checkSight()
        end
        return
      end
    end
    if not inMap(nx, ny) then
      local dir = ny < 0 and "north" or (ny >= cur.h * 2 and "south" or (nx < 0 and "west" or "east"))
      if not changeMap(nx, ny, dir) then return end
    end
    if not walkable(nx, ny, P.surf) then
      if not P.surf and stepTile(nx, ny) == 0x14 then
        local m = knows("SURF")
        if m and yesNo("The water is calm. Would you like to SURF?") then
          say(SP[m.species].name .. " used SURF!")
          P.surf = true
          stepTo(dx, dy, nx, ny)
        end
      end
      return
    end
    if P.surf and stepTile(nx, ny) ~= 0x14 then P.surf = false end
    if not stepTo(dx, dy, nx, ny) then return end
    local wi = cur.warpAt[P.x .. "," .. P.y]
    if wi then doWarp(wi); return end
    if checkSight() then return end
    tryEncounter()
  end

  -- wandering NPCs
  local lastTick = 0
  local function npcTick()
    local t = now()
    if t - lastTick < 0.4 then return end
    lastTick = t
    local moved = false
    for _, ob in ipairs(cur.objs) do
      if ob.o.m == "WALK" and rnd(1, 4) == 1 then
        local choices = {"UP", "DOWN", "LEFT", "RIGHT"}
        if ob.o.d == "UP_DOWN" then choices = {"UP", "DOWN"} elseif ob.o.d == "LEFT_RIGHT" then choices = {"LEFT", "RIGHT"} end
        local d = choices[rnd(1, #choices)]
        local v = DIRV[d]
        local nx, ny = ob.x + v[1], ob.y + v[2]
        ob.dir = d
        if inMap(nx, ny) and math.abs(nx - ob.ox) <= 3 and math.abs(ny - ob.oy) <= 3 and walkable(nx, ny)
            and not objAt(nx, ny) and not (nx == P.x and ny == P.y) and not cur.warpAt[nx .. "," .. ny] then
          local ox, oy = ob.x, ob.y
          ob.x, ob.y = nx, ny
          buildSprites(); blitStep(ox, oy)
        else
          buildSprites()
        end
        blitStep(ob.x, ob.y)
        moved = true
      end
    end
    if moved then Gfx.flush() end
  end

  -------------------------------------------------------------------
  -- shops, nurse, PC
  -------------------------------------------------------------------
  local function bagAdd(id, n) G.bag[id] = (G.bag[id] or 0) + n end

  local function qtyPrompt(maxQ, unit)
    local q = 1
    while true do
      Gfx.box(90, 30, 60, 6, "How many?")
      Gfx.text(94, 32, "x" .. rpad(q, 2) .. (unit and ("   ¥" .. (unit * q)) or "") .. "        ", C.black, C.white)
      Gfx.text(94, 34, "↑/↓ amount   A ok   B cancel", C.gray, C.white)
      Gfx.flush()
      local k = key()
      if k == "up" then q = q < maxQ and q + 1 or 1
      elseif k == "down" then q = q > 1 and q - 1 or maxQ
      elseif k == "right" then q = min(maxQ, q + 10)
      elseif k == "left" then q = max(1, q - 10)
      elseif k == "a" then return q
      elseif k == "b" then return nil end
    end
  end

  local function mart(items)
    say("Hi there! May I help you?")
    while true do
      Gfx.box(1, 1, 40, 10, "¥" .. G.money)
      local sel = menu(4, 3, {"BUY", "SELL", "QUIT"}, {width = 20, spacing = 2})
      if sel == 1 then
        local list = {}
        for i, id in ipairs(items) do list[i] = pad(itemName(id), 16) .. rpad("¥" .. (ITEMS[id].price or 0), 8) end
        list[#list + 1] = "CANCEL"
        Gfx.box(42, 1, 60, #list * 2 + 4, "BUY")
        local s2 = menu(45, 3, list, {width = 40, spacing = 2})
        if s2 and s2 <= #items then
          local id = items[s2]
          local price = ITEMS[id].price or 0
          local maxQ = price > 0 and min(99, floor(G.money / price)) or 99
          if maxQ < 1 then say("You don't have enough money.")
          else
            local q = qtyPrompt(maxQ, price)
            if q then
              G.money = G.money - price * q
              bagAdd(id, q)
              say("Here you are! Thank you!")
            end
          end
        end
        redraw()
      elseif sel == 2 then
        local id = bagList(G.bag, "SELL", function(i) return (ITEMS[i] and (ITEMS[i].price or 0) > 0) end)
        if id then
          local unit = floor((ITEMS[id].price or 0) / 2)
          local q = qtyPrompt(G.bag[id], unit)
          if q then
            G.bag[id] = G.bag[id] - q
            if G.bag[id] <= 0 then G.bag[id] = nil end
            G.money = min(999999, G.money + unit * q)
          end
        end
        redraw()
      else
        redraw()
        say("Thank you!")
        return
      end
    end
  end

  local function nurse()
    say({"Welcome to our POKéMON CENTER!", "We heal your POKéMON back to perfect health!"})
    if yesNo("Shall we heal your POKéMON?") then
      say("OK. We'll need your POKéMON.")
      healParty()
      G.respawn = respawnPoint(cur.id)
      say({"Thank you! Your POKéMON are fighting fit!", "We hope to see you again!"})
    else
      say("We hope to see you again!")
    end
  end

  local function monLine(m)
    return pad(SP[m.species].name, 12) .. " :L" .. pad(tostring(m.level), 4) .. rpad(m.hp, 3) .. "/" .. rpad(m.stats.hp, 3) ..
      "  " .. (m.hp <= 0 and "FNT" or (m.status or ""))
  end

  local function pcBox()
    while true do
      title("BILL's PC", #G.box .. " in BOX")
      local sel = menu(6, 6, {"WITHDRAW POKéMON", "DEPOSIT POKéMON", "LOG OFF"}, {width = 30, spacing = 2})
      if sel == 1 then
        if #G.box == 0 then title("BILL's PC", ""); Gfx.text(6, 6, "There are no POKéMON in the BOX!", C.black, C.white); Gfx.flush(); key()
        elseif #G.party >= 6 then title("BILL's PC", ""); Gfx.text(6, 6, "Your party is full!", C.black, C.white); Gfx.flush(); key()
        else
          local items = {}
          for i, m in ipairs(G.box) do items[i] = monLine(m) end
          title("WITHDRAW", "")
          local s2 = menu(6, 5, items, {width = 60, view = 40})
          if s2 then G.party[#G.party + 1] = table.remove(G.box, s2) end
        end
      elseif sel == 2 then
        if #G.party <= 1 then title("BILL's PC", ""); Gfx.text(6, 6, "You can't deposit your last POKéMON!", C.black, C.white); Gfx.flush(); key()
        else
          local items = {}
          for i, m in ipairs(G.party) do items[i] = monLine(m) end
          title("DEPOSIT", "")
          local s2 = menu(6, 5, items, {width = 60, spacing = 2})
          if s2 then G.box[#G.box + 1] = table.remove(G.party, s2) end
        end
      else
        redraw(); return
      end
    end
  end

  -------------------------------------------------------------------
  -- talking
  -------------------------------------------------------------------
  local function interact()
    local v = DIRV[P.dir]
    local fx, fy = P.x + v[1], P.y + v[2]
    local ob = objAt(fx, fy)
    if not ob and cur.counter[stepTile(fx, fy)] then fx, fy = fx + v[1], fy + v[2]; ob = objAt(fx, fy) end
    if ob then
      local o = ob.o
      if ob.sid ~= WD.spriteIds.POKE_BALL and ob.sid ~= WD.spriteIds.BOULDER and (WD.sprites[ob.sid] or 1) >= 3 then
        ob.dir = OPP[P.dir]
      end
      buildSprites(); blitStep(ob.x, ob.y); Gfx.flush()
      local t = o.t or {}
      if o.item then
        bagAdd(o.item, 1)
        G.flags["I" .. cur.id .. "_" .. ob.i] = true
        for i, x in ipairs(cur.objs) do if x == ob then table.remove(cur.objs, i) break end end
        buildSprites(); blitStep(ob.x, ob.y); Gfx.flush()
        say(PLAYER_NAME .. " found " .. itemName(o.item) .. "!")
        return
      end
      if o.mon then
        if t.p then say(t.p) end
        local res = wildFight(o.mon[1], o.mon[2])
        if res ~= "run" and res ~= "lose" then
          G.flags["S" .. cur.id .. "_" .. ob.i] = true
          for i, x in ipairs(cur.objs) do if x == ob then table.remove(cur.objs, i) break end end
          redraw()
        end
        return
      end
      if o.opp then
        local beaten = G.flags["T" .. cur.id .. "_" .. ob.i]
        if t.k == "trainer" then
          if beaten then say(t.a) else say(t.b); trainerFight(ob) end
        else
          if beaten then say(t.p or "...") else
            if t.p then say(t.p) end
            trainerFight(ob)
          end
        end
        return
      end
      local mapConst = WD.maps[cur.id].const
      if ob.sid == WD.spriteIds.FOSSIL and mapConst == "MT_MOON_B2F" then
        -- take one fossil; the SUPER NERD grabs the other (both vanish, as in the game)
        local item = ob.i == 6 and ITEM.DOME_FOSSIL or ITEM.HELIX_FOSSIL
        if yesNo("You want the " .. itemName(item) .. "?") then
          bagAdd(item, 1)
          for _, k in ipairs({6, 7}) do G.flags["H" .. cur.id .. "_" .. k] = true end
          for i = #cur.objs, 1, -1 do if cur.objs[i].sid == WD.spriteIds.FOSSIL then table.remove(cur.objs, i) end end
          redraw()
          say(PLAYER_NAME .. " got the " .. itemName(item) .. "! The SUPER NERD took the other one.")
        end
        return
      end
      if mapConst == "CHAMPIONS_ROOM" and ob.sid == WD.spriteIds.BLUE and not G.flags.champion then
        say({"BLUE: Hey! I was looking forward to seeing you, RED!", "I'm the most powerful trainer in the world!"})
        local ob2 = {i = 0, o = {opp = {TRAINER.RIVAL3, G.rivalParty or 1}, t = {}}}
        trainerFight(ob2)
        return
      end
      if t.k == "nurse" then nurse(); return end
      if t.k == "mart" then mart(t.items); return end
      -- HMs are story gifts in the original; hand them out here
      local hm = ({SS_ANNE_CAPTAINS_ROOM = "HM_CUT", ROUTE_16_FLY_HOUSE = "HM_FLY", SAFARI_ZONE_SECRET_HOUSE = "HM_SURF",
        WARDENS_HOUSE = "HM_STRENGTH", ROUTE_2_GATE = "HM_FLASH"})[mapConst]
      if hm and ITEM[hm] and not G.flags["G" .. hm] then
        if t.p then say(t.p) end
        G.flags["G" .. hm] = true
        bagAdd(ITEM[hm], 1)
        say(PLAYER_NAME .. " received " .. itemName(ITEM[hm]) .. "! It contains " .. MV[ITEMS[ITEM[hm]].move].name .. ".")
        return
      end
      if o.story then
        -- free-roam rule: story NPCs who block the way step aside once you've talked to them
        if t.p then say(t.p) end
        G.flags["H" .. cur.id .. "_" .. ob.i] = true
        for i, x in ipairs(cur.objs) do if x == ob then table.remove(cur.objs, i) break end end
        redraw()
        say("(They stepped aside.)")
        return
      end
      if t.k == "text" then
        say(t.p)
        if mapConst == "REDS_HOUSE_1F" and ob.sid == WD.spriteIds.MOM then
          healParty()
          say("MOM: You should take a quick rest. ... Oh good! You and your POKéMON are looking great! Take care now!")
        end
        return
      end
      say("...")
      return
    end
    for _, s in ipairs(cur.info.signs) do
      if s.x == fx and s.y == fy then
        if s.t and s.t.p then say(s.t.p) end
        return
      end
    end
    -- CUT
    local tile = stepTile(fx, fy)
    if (tile == 0x3D and WD.tilesets[cur.ts].name == "Overworld") or (tile == 0x50 and WD.tilesets[cur.ts].name == "Gym") then
      local m = knows("CUT")
      if m then
        if yesNo("This tree can be CUT! Use CUT?") then
          local bx, by = floor(fx / 2), floor(fy / 2)
          local b = getBlock(bx, by)
          for _, pr in ipairs(WD.cut) do
            if pr[1] == b then
              local pos = by * cur.w + bx + 1
              cur.blocks = cur.blocks:sub(1, pos - 1) .. string.char(pr[2]) .. cur.blocks:sub(pos + 1)
              blkCache[cur.id] = cur.blocks
              break
            end
          end
          say(SP[m.species].name .. " hacked away with CUT!")
          redraw()
        end
      else
        say("This tree looks like it can be CUT!")
      end
    end
  end

  -------------------------------------------------------------------
  -- menus
  -------------------------------------------------------------------
  local function summary(m)
    title(SP[m.species].name .. "  :L" .. m.level, "B back")
    local s = SP[m.species]
    local pic = loadPic("front/" .. m.species)
    if pic then Gfx.pic(pic, 4, 5, s.pal, 1, 56, 56) end
    local y = 6
    local function line(t) Gfx.text(66, y, t, C.black, C.white); y = y + 2 end
    line("TYPE: " .. table.concat(s.types, "/"))
    line("HP " .. m.hp .. "/" .. m.stats.hp .. "   STATUS: " .. (m.status or "OK"))
    line("ATTACK " .. m.stats.atk .. "   DEFENSE " .. m.stats.def)
    line("SPEED " .. m.stats.spd .. "   SPECIAL " .. m.stats.spc)
    line("EXP " .. (m.exp or 0) .. "   to next level: " .. (m.level < 100 and (expFor(m.species, m.level + 1) - (m.exp or 0)) or 0))
    y = y + 1
    for i, id in ipairs(m.moves) do line(pad(MV[id].name, 14) .. pad(MV[id].type, 10) .. "PP " .. (m.pp[i] or 0) .. "/" .. MV[id].pp) end
    Gfx.flush()
    repeat local k = key() until k == "a" or k == "b"
  end

  local function partyMenu()
    while true do
      local i = pickMon(G.party, "POKéMON  (A select, B back)")
      if not i then return end
      Gfx.box(100, 4 + (i - 1) * 5, 24, 8)
      local sel = menu(103, 5 + (i - 1) * 5, {"STATS", "SWITCH", "CANCEL"}, {width = 18, spacing = 2})
      if sel == 1 then summary(G.party[i])
      elseif sel == 2 then
        local j = pickMon(G.party, "Move " .. SP[G.party[i].species].name .. " to where?")
        if j then G.party[i], G.party[j] = G.party[j], G.party[i] end
      end
    end
  end

  local function bagMenu()
    while true do
      title("ITEM", "B back")
      local id = bagList(G.bag, "ITEM")
      if not id then return end
      local kind = itemKind(id, false)
      if kind == "mon" then
        local t = pickMon(G.party, "Use " .. itemName(id) .. " on which POKéMON?")
        if t then
          title("ITEM", "")
          local mon = G.party[t]
          local box = function(text) textBox(text); repeat local k = key() until k == "a" or k == "b" end
          if useOnMon(id, mon, box, askReplace) then
            G.bag[id] = G.bag[id] - 1
            if G.bag[id] <= 0 then G.bag[id] = nil end
            if mon.evolveTo then local into = mon.evolveTo; mon.evolveTo = nil; evolve(mon, into) end
            if mon.leveled then mon.leveled = nil
              for _, e in ipairs(SP[mon.species].evos) do
                if e.how == "LEVEL" and mon.level >= e.level then evolve(mon, e.into); break end
              end
            end
          end
        end
      elseif kind == "field" then
        local c = itemConst(id)
        if c == "ESCAPE_ROPE" then
          if cur.id >= WD.firstIndoor then
            G.bag[id] = G.bag[id] - 1; if G.bag[id] <= 0 then G.bag[id] = nil end
            local r = G.respawn
            loadMap(r.map); indexWarps(); P.x, P.y = r.x, r.y
            return "moved"
          end
          title("ITEM", ""); fieldSay("This isn't the time to use that!")
        else
          G.repel = ({REPEL = 100, SUPER_REPEL = 200, MAX_REPEL = 250})[c]
          G.bag[id] = G.bag[id] - 1; if G.bag[id] <= 0 then G.bag[id] = nil end
          title("ITEM", ""); fieldSay("REPEL's effect lingers...")
        end
      else
        title("ITEM", ""); fieldSay("OAK: " .. PLAYER_NAME .. "! This isn't the time to use that!")
      end
    end
  end

  local function trainerCard()
    title("TRAINER CARD", "B back")
    Gfx.text(8, 6, "NAME: " .. PLAYER_NAME, C.black, C.white)
    Gfx.text(8, 8, "MONEY: ¥" .. G.money, C.black, C.white)
    Gfx.text(8, 10, "BADGES: " .. (#G.badges > 0 and table.concat(G.badges, " ") or "none yet"), C.black, C.white)
    Gfx.text(8, 12, "POKéMON in BOX: " .. #G.box, C.black, C.white)
    if G.flags.champion then Gfx.text(8, 14, "POKéMON LEAGUE CHAMPION!", C.red, C.white) end
    local rp = loadPic("player/red")
    if rp then Gfx.pic(rp, 100, 6, GRAY_PAL, 1, 56, 56) end
    Gfx.flush()
    repeat local k = key() until k == "a" or k == "b"
  end

  -- returns "exit" to leave to the title screen
  local function startMenu()
    local items = {"POKéMON", "ITEM", PLAYER_NAME, "SAVE", "OPTION", "EXIT"}
    local isCenter = WD.tilesets[cur.ts].name == "Pokecenter"
    if isCenter then table.insert(items, 3, "PC BOX") end
    while true do
      Gfx.box(W - 30, 1, 30, #items * 2 + 3)
      local sel = menu(W - 27, 3, items, {width = 24, spacing = 2})
      local choice = items[sel or 0]
      if not sel then redraw(); return end
      if choice == "POKéMON" then partyMenu()
      elseif choice == "ITEM" then bagMenu()
      elseif choice == "PC BOX" then pcBox()
      elseif choice == PLAYER_NAME then trainerCard()
      elseif choice == "SAVE" then
        OW.saveFn()
        redraw(); say(PLAYER_NAME .. " saved the game!")
        return
      elseif choice == "OPTION" then settings()
      elseif choice == "EXIT" then
        redraw()
        if yesNo("Return to the title screen? (Unsaved progress is lost.)") then return "exit" end
      end
      redraw()
    end
  end

  -------------------------------------------------------------------
  -- save data
  -------------------------------------------------------------------
  local function packMon(m)
    return {species = m.species, level = m.level, dvs = m.dvs, moves = m.moves, pp = m.pp, hp = m.hp,
      status = m.status, sleep = m.sleep, exp = m.exp, statexp = m.statexp}
  end
  local function unpackMon(p)
    local m = {species = p.species, level = p.level, dvs = p.dvs, moves = p.moves, pp = p.pp or {}, hp = p.hp,
      status = p.status, sleep = p.sleep, exp = p.exp or expFor(p.species, p.level), statexp = p.statexp or {0, 0, 0, 0, 0}}
    calcStats(m)
    if m.hp == nil then m.hp = m.stats.hp end
    for i, id in ipairs(m.moves) do if not m.pp[i] then m.pp[i] = MV[id].pp end end
    return m
  end

  function OW.pack()
    if not G then return nil end
    local out = {}
    for k, v in pairs(G) do out[k] = v end
    out.party, out.box = {}, {}
    for i, m in ipairs(G.party) do out.party[i] = packMon(m) end
    for i, m in ipairs(G.box) do out.box[i] = packMon(m) end
    out.x, out.y, out.dir, out.surf = P.x, P.y, P.dir, P.surf
    return out
  end
  function OW.unpack(s)
    if type(s) ~= "table" then return end
    G = s
    local party, box = {}, {}
    for i, p in ipairs(s.party or {}) do party[i] = unpackMon(p) end
    for i, p in ipairs(s.box or {}) do box[i] = unpackMon(p) end
    G.party, G.box = party, box
    G.bag = G.bag or {}; G.flags = G.flags or {}; G.badges = G.badges or {}; G.repel = G.repel or 0
  end
  function OW.hasGame() return G ~= nil end

  -------------------------------------------------------------------
  -- new game / play loop
  -------------------------------------------------------------------
  local function chooseStarter()
    local starters = {1, 4, 7}
    local sel = 2
    while true do
      title("PROF. OAK: Choose your POKéMON!", "←/→ choose   A confirm")
      for i, dex in ipairs(starters) do
        local pic = loadPic("front/" .. dex)
        if pic then Gfx.pic(pic, 6 + (i - 1) * 52, 10, SP[dex].pal, 1, 56, 56) end
        Gfx.text(18 + (i - 1) * 52, 40, (i == sel and "▶ " or "  ") .. SP[dex].name, i == sel and C.red or C.black, C.white)
      end
      Gfx.flush()
      local k = key()
      if k == "left" then sel = sel > 1 and sel - 1 or 3
      elseif k == "right" then sel = sel < 3 and sel + 1 or 1
      elseif k == "a" then return starters[sel], sel end
    end
  end

  function OW.newGame()
    if not OW.available() then return false end
    local dex, which = chooseStarter()
    local mon = newMon(dex, 5)
    mon.exp = expFor(dex, 5)
    mon.statexp = {0, 0, 0, 0, 0}
    -- the rival picks the starter that beats yours (Rival3 party 1 = Blastoise, 2 = Venusaur, 3 = Charizard)
    local rivalParty = ({3, 1, 2})[which]
    G = {party = {mon}, box = {}, bag = {}, money = 3000, flags = {}, badges = {}, repel = 0,
      lastOut = WD.mapIds.PALLET_TOWN, rivalParty = rivalParty}
    G.bag[ITEM.POTION] = 1
    G.bag[ITEM.POKE_BALL] = 5
    G.respawn = respawnPoint(WD.mapIds.REDS_HOUSE_1F)
    loadMap(WD.mapIds.REDS_HOUSE_2F)
    indexWarps()
    P.x, P.y, P.dir, P.surf = 3, 6, "UP", false
    return true
  end

  function OW.play()
    if not OW.available() then return end
    if not cur.id or cur.id ~= G.map then
      loadMap(G.map or WD.mapIds.REDS_HOUSE_2F)
      indexWarps()
      if G.x then P.x, P.y, P.dir, P.surf = G.x, G.y, G.dir or "DOWN", G.surf end
    end
    redraw()
    if cur.id == WD.mapIds.REDS_HOUSE_2F and not G.flags.intro then
      G.flags.intro = true
      say({"OAK: Hello there! Welcome to the world of POKéMON!",
        "Your very own POKéMON legend is about to unfold!",
        "(Stage 2: Kanto is open to explore. Story scripts aren't in yet, so roads are unlocked and some events won't happen.)"})
    end
    while true do
      local k = key(0.4)
      if not k then npcTick()
      elseif DIRS[k] then tryMove(k)
      elseif k == "a" then interact()
      elseif k == "start" or k == "S" or k == "M" then
        local r = startMenu()
        if r == "exit" then return end
      end
    end
  end

  -- for the headless test: walk every warp/connection and render
  function OW._test()
    return {loadMap = loadMap, indexWarps = indexWarps, P = P, cur = function() return cur end, redraw = redraw,
      tryMove = tryMove, interact = interact, G = function() return G end, setG = function(g) G = g end,
      wildFight = wildFight, WD = function() return WD end, doWarp = doWarp, walkable = walkable,
      changeMap = changeMap, inMap = inMap, stepTile = stepTile, objAt = objAt, checkSight = checkSight,
      tryEncounter = tryEncounter, startMenu = startMenu, setCam = function(x, y) P.x, P.y = x, y end,
      healParty = healParty}
  end
end)()

local function mainMenu()
  while true do
    Gfx.fill(1, 1, W, H, C.white)
    local rp = loadPic("player/red")
    if rp then Gfx.pic(rp, 100, 10, GRAY_PAL, 1, 56, 56) end
    local pk = loadPic("front/25")
    if pk then Gfx.pic(pk, 58, 22, SP[25].pal, 1, 40, 30) end
    Gfx.fill(1, 2, W, 5, C.red)
    Gfx.text(6, 3, "P O K é M O N   R E D", C.white, C.red)
    Gfx.text(6, 5, "OpenComputers edition  v" .. VERSION, C.light, C.red)
    local items, acts = {}, {}
    local function add(label, fn) items[#items + 1] = label; acts[#items] = fn end
    if OW.available() then
      if state.gameRaw or OW.hasGame() then
        add("CONTINUE", function()
          if not OW.hasGame() then OW.unpack(state.gameRaw) end
          OW.play()
        end)
      end
      add("NEW GAME", function()
        if state.gameRaw or OW.hasGame() then
          Gfx.box(40, 20, 80, 8, "NEW GAME")
          Gfx.text(44, 22, "This replaces your saved adventure when you SAVE.", C.black, C.white)
          Gfx.text(44, 24, "A = start a new game   B = cancel", C.gray, C.white)
          Gfx.flush()
          local k
          repeat k = key() until k == "a" or k == "b"
          if k == "b" then return end
        end
        if OW.newGame() then OW.play() end
      end)
    end
    add("BATTLE A TRAINER", trainerSelect)
    add("GYM GAUNTLET", gauntlet)
    add("EDIT PARTY", partyEditor)
    add("OPTIONS", settings)
    add("QUIT", false)
    local sel = menu(8, 12, items, {width = 30, spacing = 3, noCancel = true})
    if not acts[sel] then return end
    acts[sel]()
  end
end

-----------------------------------------------------------------------
-- headless simulation (pokered sim [n])
-----------------------------------------------------------------------
local function simulate(n)
  local logUI = {}
  function logUI:msg(s) print("  " .. s) end
  for _, f in ipairs({"start", "hp", "status", "subChanged", "sprite", "hitFlash", "faint", "recall"}) do
    logUI[f] = function() end
  end
  function logUI:sendOut(B, side) print(("  [%d] sends out %s L%d (%d HP)"):format(B.side, SP[B.mon.species].name, B.mon.level, B.mon.hp)) end
  local wins = {0, 0}
  local cids = {}
  for id, t in pairs(TR) do if #t.parties > 0 then cids[#cids + 1] = id end end
  local fuzz = args[3] == "fuzz"
  if args[4] then math.randomseed(tonumber(args[4])) end
  local function randomParty()
    local p = {}
    for i = 1, rnd(1, 6) do
      local mv = {}
      for j = 1, 4 do mv[j] = rnd(1, NUM_MOVES) end
      p[i] = newMon(rnd(1, 151), rnd(5, 100), nil, mv)
    end
    return p
  end
  for i = 1, n do
    local c1, c2 = cids[rnd(1, #cids)], cids[rnd(1, #cids)]
    local p1, p2 = rnd(1, #TR[c1].parties), rnd(1, #TR[c2].parties)
    print(("== battle %d: %s #%d vs %s #%d"):format(i, trainerName(c1), p1, trainerName(c2), p2))
    local b = Battle.new({party1 = fuzz and randomParty() or trainerParty(c1, p1),
      party2 = fuzz and randomParty() or trainerParty(c2, p2),
      ctrl1 = AI.new({1, 2, 3}), ctrl2 = AI.new(TR[c2].ai), name1 = trainerName(c1), name2 = trainerName(c2), ui = logUI})
    local w = b:run()
    wins[w] = wins[w] + 1
    print("  winner: side " .. w)
  end
  print(("done: %d battles, side1 %d / side2 %d"):format(n, wins[1], wins[2]))
end

-----------------------------------------------------------------------
-- main
-----------------------------------------------------------------------
if SIM then
  simulate(tonumber(args[2]) or 5)
  return
end
if not hasOC then print("pokered must run inside OpenComputers (or use: pokered sim)") return end
Gfx.init()
load()
OW.saveFn = save
local ok, err = xpcall(mainMenu, debug.traceback)
save()
Gfx.close()
if not ok then io.stderr:write(tostring(err) .. "\n") end
