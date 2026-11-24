--[[
  pokered.lua - Pokemon Red, natively rewritten for OpenComputers (GTNH)
  Stage 1: Gen 1 battle engine + trainer battles (Battle Mode / Gym Gauntlet)

  Needs: Tier 3 GPU + Tier 3 screen (160x50), keyboard, ~1 MB+ RAM.
  Data:  run pokered_convert.py on your PC against a pret/pokered checkout and
         copy its output (data.lua + gfx.pak) next to this file.

  Usage: pokered            play
         pokered sim [n]    headless AI-vs-AI test battles (prints a log)

  Controls: arrows move, Z / Enter / Space = A, X / Backspace = B
  Works on Lua 5.2 and 5.3 architectures.
]]

local VERSION = "0.1 (stage 1: battles)"
local args = {...}
local SIM = args[1] == "sim"

-----------------------------------------------------------------------
-- environment
-----------------------------------------------------------------------
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
  if act.kind == "switch" then return end

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
  if act.kind == "switch" then return 10 end
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
local KEYS = {[200] = "up", [208] = "down", [203] = "left", [205] = "right", [28] = "a", [44] = "a", [57] = "a",
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
function Player.new(ui) return setmetatable({ui = ui, lastMain = 1, lastMove = 1}, Player) end
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
      ui:clearText(); ui:msg("The BAG is empty! (items come in a later stage)")
    elseif choice == 4 then
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
function Player:replace(b, s)
  local idx = partyScreen(b, 1, true, "Bring out which POKéMON?")
  self.ui:redraw()
  return idx
end

-----------------------------------------------------------------------
-- app screens
-----------------------------------------------------------------------
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
  local out = {party = {}, gauntlet = state.gauntlet, textDelay = Settings.textDelay}
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
    local items = {"BATTLE A TRAINER", "GYM GAUNTLET", "EDIT PARTY", "OPTIONS", "QUIT"}
    local sel = menu(8, 12, items, {width = 30, spacing = 3, noCancel = true})
    if sel == 1 then trainerSelect()
    elseif sel == 2 then gauntlet()
    elseif sel == 3 then partyEditor()
    elseif sel == 4 then settings()
    else return end
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
local ok, err = xpcall(mainMenu, debug.traceback)
save()
Gfx.close()
if not ok then io.stderr:write(tostring(err) .. "\n") end
