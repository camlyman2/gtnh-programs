--[[
  voidctl.lua  -  Void Miner control (runs on Earth)

  Watches item levels in your ME system and tells the void miners on other
  planets (voidminer.lua, over linked cards) which ores to mine.

  A RULE ties one ore on one miner to one ME item (the trigger):
    AUTO   mine when the trigger falls below "Start below",
           stop when it reaches "Stop at" (hysteresis)
    START  always mine (manual)
    STOP   never mine (manual)
  The trigger can be the ore itself or any other item (e.g. mine Magnetite
  Ore when Iron Dust runs low). Several rules can use the same ore: it is
  mined while ANY of them asks for it.

  Hardware:
    - Server (or computer case) with tier 3 GPU, tier 3 screen (160x50),
      keyboard, CPU, memory, HDD with OpenOS
    - Adapter touching an ME Interface (or the ME Controller) - read only,
      this program never changes anything in AE
    - one Linked Card per planet, each crafted as a pair with the card in
      that planet's void miner computer (a server rack / tier 3 case has
      room for several)

  Editing a rule: click its row, change the fields at the bottom, Save.
  Numbers accept k / m / g (e.g. 64k, 1.5m).

  Files: /home/voidctl.dat (rules, last known miner whitelists)
  Exit: Ctrl+C (the miners keep their last request).
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  DATA_FILE = "/home/voidctl.dat",
  AE_POLL = 5,           -- seconds between ME level reads
  SEND_EVERY = 10,       -- the request is sent again this often (and at once on a change)
  OFFLINE_AFTER = 45,    -- seconds without a report = miner offline
  AE_ADDRESS = nil,      -- nil = first me_interface / me_controller; or the start of an address
  LOG_MAX = 40,
}

--------------------------------------------------------------- MODULES
local component     = require("component")
local computer      = require("computer")
local event         = require("event")
local serialization = require("serialization")
local unicode       = require("unicode")
local term          = require("term")
local floor, max, min = math.floor, math.max, math.min

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
local W, H = 160, 50
local C = {
  bg = 0x1B1F24, panel = 0x232930, alt = 0x20252B, head = 0x313945, text = 0xE6E6E6,
  dim = 0x8A96A3, accent = 0x2A7FA8, green = 0x2E9E4F, red = 0xC23B3B, amber = 0xD08A1E,
  sel = 0x2C4A63, field = 0x0F1215, focus = 0x3A3A10, white = 0xFFFFFF, gray = 0x4A5562,
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
local function btn(x, y, label, b, fn, f)
  local w = unicode.len(label) + 2
  text(x, y, " " .. label .. " ", f or C.white, b)
  if fn then region(x, y, w, 1, fn) end
  return x + w + 1
end
local function panel(x, y, w, h, title)
  fill(x, y, w, h, C.panel)
  fill(x, y, w, 1, C.head)
  textW(x + 1, y, w - 2, title, C.white, C.head)
end

local function commas(n)
  local s = string.format("%d", floor(n + 0.5))
  local k
  repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
  return s
end
local function short(n)
  if n >= 1e12 then return string.format("%.2fT", n / 1e12) end
  if n >= 1e9 then return string.format("%.2fG", n / 1e9) end
  if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
  if n >= 1e4 then return string.format("%.1fk", n / 1e3) end
  return commas(n)
end
local function parseNum(s)
  s = tostring(s):lower():gsub("[,%s_]", "")
  local n, suf = s:match("^(%d+%.?%d*)([kmgt]?)$")
  if not n then return nil end
  return floor(tonumber(n) * ({ [""] = 1, k = 1e3, m = 1e6, g = 1e9, t = 1e12 })[suf] + 0.5)
end
local function ago(t)
  if not t then return "never" end
  local s = floor(computer.uptime() - t)
  if s < 60 then return s .. "s ago" end
  if s < 3600 then return floor(s / 60) .. "m ago" end
  return floor(s / 3600) .. "h ago"
end

------------------------------------------------------------------ DATA
-- rules[i] = { id, link, ore, oreLabel, trigger = { label, name, damage }, low, high, mode, latch }
--   link = address of the linked card that reaches the miner, ore = id on that miner
-- cache[link] = { name, entries } - last report of each miner (kept while it is offline)
local D = { rules = {}, nextId = 1, cache = {} }
local L = {}            -- live reports: L[link] = { name, hold, entries, machine, foreign, err, last }
local amount = {}       -- amount[rule.id] = number in ME, or nil (cannot read)
local want = {}         -- want[rule.id] = true / false
local sent = {}         -- sent[link] = { sig, t, set }
local log = {}
local S = { sel = nil, scroll = 0, lastAE = -99, aeErr = nil, msg = nil, msgAt = 0, delAt = nil }
local E = { ore = nil, trigger = "", low = "", high = "", mode = "auto", focus = nil }   -- edit form

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
  if type(D.rules) ~= "table" then D.rules = {} end
  if type(D.cache) ~= "table" then D.cache = {} end
  D.nextId = tonumber(D.nextId) or 1
  for link, c in pairs(D.cache) do
    L[link] = { name = c.name, entries = c.entries or {}, last = nil }
  end
end

local function logLine(s, bad)
  log[#log + 1] = { t = computer.uptime(), s = s, bad = bad }
  while #log > CONFIG.LOG_MAX do table.remove(log, 1) end
end
local function flash(m) S.msg, S.msgAt = m, computer.uptime() end

------------------------------------------------------------ MINERS
local function links()
  local out = {}
  for addr in component.list("tunnel") do out[#out + 1] = addr end
  table.sort(out)
  return out
end

local function minerName(link)
  local s = L[link]
  return (s and s.name) or ("link " .. link:sub(1, 6))
end

local function online(link)
  local s = L[link]
  return s and s.last and computer.uptime() - s.last <= CONFIG.OFFLINE_AFTER
end

local function entryOf(link, id)
  local s = L[link]
  if s and s.entries then
    for _, e in ipairs(s.entries) do if e.id == id then return e end end
  end
end

local function oreLabel(r)
  local e = entryOf(r.link, r.ore)
  return (e and e.label) or r.oreLabel or ("ore #" .. tostring(r.ore))
end

-- every ore on every known miner: { link, id, label }
local function allOres()
  local out = {}
  local ls = {}
  for link in pairs(L) do ls[#ls + 1] = link end
  table.sort(ls)
  for _, link in ipairs(ls) do
    for _, e in ipairs(L[link].entries or {}) do out[#out + 1] = { link = link, id = e.id, label = e.label } end
  end
  return out
end

local function onMessage(localAddr, _, _, _, kind, payload)
  if kind ~= "VM_STATE" then return end
  local okT, t = pcall(component.type, localAddr)
  if not okT or t ~= "tunnel" then return end
  local ok, st = pcall(serialization.unserialize, payload)
  if not ok or type(st) ~= "table" then return end
  local was = online(localAddr)
  st.last = computer.uptime()
  st.entries = st.entries or {}
  L[localAddr] = st
  if not was then logLine(minerName(localAddr) .. " is online") end
  -- keep the whitelist for offline editing; save only when it changed
  local parts = { tostring(st.name) }
  for _, e in ipairs(st.entries) do parts[#parts + 1] = e.id .. "=" .. tostring(e.label) end
  local sig = table.concat(parts, "|")
  local c = D.cache[localAddr]
  if not c or c.sig ~= sig then
    local entries = {}
    for i, e in ipairs(st.entries) do entries[i] = { id = e.id, label = e.label } end
    D.cache[localAddr] = { name = st.name, entries = entries, sig = sig }
    for _, r in ipairs(D.rules) do
      if r.link == localAddr then local e = entryOf(r.link, r.ore); if e then r.oreLabel = e.label end end
    end
    save()
  end
end

------------------------------------------------------------ AE
local ae

local function findAE()
  ae = nil
  if CONFIG.AE_ADDRESS then
    local ok, a = pcall(component.get, CONFIG.AE_ADDRESS)
    if ok and a then ae = component.proxy(a); return end
  end
  for _, t in ipairs({ "me_interface", "me_controller" }) do
    local a = component.list(t)()
    if a then ae = component.proxy(a); return end
  end
end

-- how many of the trigger item are in ME (nil = cannot read)
local function aeCount(tr, cache)
  if not ae then return nil end
  local ck = tr.label
  if cache[ck] ~= nil then return cache[ck] or nil end
  local filter = tr.name and { name = tr.name, damage = tr.damage } or { label = tr.label }
  local ok, list = pcall(ae.getItemsInNetwork, filter)
  if not ok or type(list) ~= "table" then cache[ck] = false; return nil end
  local n = 0
  for _, it in ipairs(list) do
    if type(it) == "table" and it.label == tr.label then
      n = n + (tonumber(it.size) or 0)
      if not tr.name then tr.name, tr.damage = it.name, it.damage; S.saveSoon = true end
    end
  end
  cache[ck] = n
  return n
end

local function readAE()
  S.lastAE = computer.uptime()
  if not ae then findAE() end
  if not ae then S.aeErr = "No ME Interface / ME Controller found (Adapter next to one)."; return end
  S.aeErr = nil
  local cache = {}
  for _, r in ipairs(D.rules) do amount[r.id] = aeCount(r.trigger, cache) end
  if S.saveSoon then S.saveSoon = nil; save() end
end

------------------------------------------------------------ LOGIC
local function evaluate()
  local changed = false
  for _, r in ipairs(D.rules) do
    if r.mode == "on" then want[r.id] = true
    elseif r.mode == "off" then want[r.id] = false
    else
      local a = amount[r.id]
      local old = r.latch
      if type(a) == "number" then
        if a < r.low then r.latch = true elseif a >= r.high then r.latch = false end
      end
      if r.latch ~= old then changed = true end
      want[r.id] = r.latch and true or false
    end
  end
  if changed then save() end
end

-- is this ore on this miner asked for by any rule?
local function oreWanted(link, id)
  for _, r in ipairs(D.rules) do
    if r.link == link and r.ore == id and want[r.id] then return true end
  end
  return false
end

local function sendAll(force)
  local up = computer.uptime()
  for _, link in ipairs(links()) do
    local ids, set = {}, {}
    for _, r in ipairs(D.rules) do
      if r.link == link and want[r.id] and not set[r.ore] then set[r.ore] = true; ids[#ids + 1] = r.ore end
    end
    table.sort(ids)
    local sig = table.concat(ids, ",")
    local s = sent[link]
    if force or not s or s.sig ~= sig or up - s.t >= CONFIG.SEND_EVERY then
      pcall(component.invoke, link, "send", "VM_WANT", serialization.serialize(ids))
      if s and s.sig ~= sig then
        for id in pairs(set) do
          if not s.set[id] then logLine("Requested " .. (oreLabel({ link = link, ore = id })) .. " on " .. minerName(link)) end
        end
        for id in pairs(s.set) do
          if not set[id] then logLine("Stopped " .. (oreLabel({ link = link, ore = id })) .. " on " .. minerName(link)) end
        end
      end
      sent[link] = { sig = sig, t = up, set = set }
    end
  end
end

-- name, color, detail
local function ruleState(r)
  if not L[r.link] then return "NO MINER", C.red, "this linked card has never reported - is voidminer running?" end
  if not online(r.link) then return "OFFLINE", C.red, minerName(r.link) .. " last reported " .. ago(L[r.link].last) end
  local st = L[r.link]
  local e = entryOf(r.link, r.ore)
  if not e then return "NOT ON MINER", C.red, "this ore is no longer on " .. minerName(r.link) .. "'s whitelist" end
  if st.hold then return "MINER HOLD", C.amber, minerName(r.link) .. " is on hold (button on its own screen)" end
  if e.problem then return "PROBLEM", C.red, e.problem end
  local w = oreWanted(r.link, r.ore)
  if e.inBus and w then
    return "PRODUCING", C.green, want[r.id] and "in the input bus" or "in the input bus - kept on by another rule for this ore"
  end
  if e.inBus then return "STOPPING", C.amber, "waiting for the miner to take the ore out" end
  if w then return "STARTING", C.amber, "waiting for the miner to put the ore in" end
  return "IDLE", C.dim, "ore is in its chest slot"
end

------------------------------------------------------------ EDIT FORM
local function loadForm(r)
  if r then
    E.ore = { link = r.link, id = r.ore }
    E.trigger, E.low, E.high, E.mode = r.trigger.label, tostring(r.low), tostring(r.high), r.mode
  else
    local ores = allOres()
    E.ore = nil
    for _, o in ipairs(ores) do                -- first ore that has no rule yet
      local used = false
      for _, x in ipairs(D.rules) do if x.link == o.link and x.ore == o.id then used = true end end
      if not used then E.ore = { link = o.link, id = o.id }; break end
    end
    if not E.ore and ores[1] then E.ore = { link = ores[1].link, id = ores[1].id } end
    E.trigger = E.ore and oreLabel({ link = E.ore.link, ore = E.ore.id }) or ""
    E.low, E.high, E.mode = "", "", "auto"
  end
  E.focus = nil
  S.delAt = nil
end

local function saveForm()
  if not E.ore then flash("Pick an ore first (no miner has reported yet?)"); return end
  local trig = E.trigger:gsub("^%s+", ""):gsub("%s+$", "")
  if trig == "" then trig = oreLabel({ link = E.ore.link, ore = E.ore.id }) end
  local low, high = parseNum(E.low), parseNum(E.high)
  if E.mode == "auto" or E.low ~= "" or E.high ~= "" then
    if not low or not high then flash("Start below and Stop at need numbers (64k, 1.5m ...)"); return end
    if high <= low then flash("Stop at must be higher than Start below"); return end
  end
  local r = S.sel and D.rules[S.sel]
  if not r then
    r = { id = D.nextId, latch = false }
    D.nextId = D.nextId + 1
    D.rules[#D.rules + 1] = r
    S.sel = #D.rules
  end
  r.link, r.ore = E.ore.link, E.ore.id
  r.oreLabel = oreLabel({ link = r.link, ore = r.ore })
  if not r.trigger or r.trigger.label ~= trig then r.trigger = { label = trig }; amount[r.id] = nil end
  r.low, r.high, r.mode = low or r.low or 0, high or r.high or 0, E.mode
  save()
  S.lastAE = -99                              -- read the level now
  flash("Saved: " .. r.oreLabel .. " <- " .. trig)
  E.focus = nil
end

local function setMode(r, mode)
  r.mode = mode
  if mode == "auto" then
    local a = amount[r.id]
    r.latch = type(a) == "number" and a < r.low or false
  end
  if S.sel and D.rules[S.sel] == r then E.mode = mode end
  save(); evaluate(); sendAll(false)
end

------------------------------------------------------------ DRAWING
local ROWS = 22
local TX = { num = 3, miner = 7, ore = 23, trig = 51, me = 79, low = 93, high = 105, mode = 117, state = 124, b = 138 }

local function drawTop()
  fill(1, 1, W, 1, C.accent)
  textW(2, 1, 40, "Void Miner Control - Earth", C.white, C.accent)
  local x = 44
  local ls = links()
  if #ls == 0 then textW(x, 1, 60, "● no linked card installed", 0xFFB0B0, C.accent) end
  for _, link in ipairs(ls) do
    local on = online(link)
    local s = "● " .. minerName(link) .. "  "
    text(x, 1, s, on and 0xB0FFB0 or 0xFFB0B0, C.accent)
    x = x + unicode.len(s)
  end
  textW(W - 30, 1, 29, ae and "● ME connected" or "● ME not found", ae and 0xB0FFB0 or 0xFFB0B0, C.accent, "right")

  fill(1, 2, W, 1, C.bg)
  local bx = 2
  bx = btn(bx, 2, "New rule", C.gray, function() S.sel = nil; loadForm(nil) end)
  bx = btn(bx, 2, "All AUTO", C.gray, function() for _, r in ipairs(D.rules) do setMode(r, "auto") end; flash("Every rule is on AUTO") end)
  bx = btn(bx, 2, "All STOP", C.red, function() for _, r in ipairs(D.rules) do setMode(r, "off") end; flash("Every rule is on STOP") end)
  btn(bx, 2, "Ask miners", C.gray, function()
    for _, link in ipairs(links()) do pcall(component.invoke, link, "send", "VM_HELLO") end
    sendAll(true); flash("Asked every miner for its status")
  end)
  if S.aeErr then textW(80, 2, 79, S.aeErr, C.red, C.bg, "right") end
end

local function drawTable()
  panel(2, 4, W - 2, ROWS + 3, "Production rules")
  local y = 5
  fill(2, y, W - 2, 1, C.alt)
  textW(TX.num, y, 3, "#", C.dim, C.alt)
  textW(TX.miner, y, 15, "Miner", C.dim, C.alt)
  textW(TX.ore, y, 27, "Produces", C.dim, C.alt)
  textW(TX.trig, y, 27, "Trigger item (ME)", C.dim, C.alt)
  textW(TX.me, y, 13, "In ME", C.dim, C.alt, "right")
  textW(TX.low, y, 11, "Start below", C.dim, C.alt, "right")
  textW(TX.high, y, 11, "Stop at", C.dim, C.alt, "right")
  textW(TX.mode, y, 6, "Mode", C.dim, C.alt)
  textW(TX.state, y, 13, "State", C.dim, C.alt)
  textW(TX.b, y, 20, "Control", C.dim, C.alt)
  S.scroll = max(0, min(S.scroll, #D.rules - ROWS))
  for row = 1, ROWS do
    local i = S.scroll + row
    local r = D.rules[i]
    local yy = y + row
    local b = (r and i == S.sel) and C.sel or (row % 2 == 0 and C.alt or C.panel)
    fill(2, yy, W - 2, 1, b)
    if r then
      region(2, yy, TX.b - 3, 1, function() S.sel = i; loadForm(r) end)
      local a = amount[r.id]
      local name, col = ruleState(r)
      textW(TX.num, yy, 3, tostring(i), C.dim, b)
      textW(TX.miner, yy, 15, minerName(r.link), C.text, b)
      textW(TX.ore, yy, 27, oreLabel(r), C.text, b)
      textW(TX.trig, yy, 27, r.trigger.label, (r.trigger.label == oreLabel(r)) and C.dim or C.text, b)
      local ac = C.text
      if type(a) == "number" and r.mode == "auto" then ac = a < r.low and C.red or (a >= r.high and C.green or C.amber) end
      textW(TX.me, yy, 13, type(a) == "number" and short(a) or "?", ac, b, "right")
      textW(TX.low, yy, 11, short(r.low), C.dim, b, "right")
      textW(TX.high, yy, 11, short(r.high), C.dim, b, "right")
      local mc = r.mode == "on" and C.green or (r.mode == "off" and C.red or C.text)
      textW(TX.mode, yy, 6, r.mode == "on" and "START" or (r.mode == "off" and "STOP" or "AUTO"), mc, b)
      textW(TX.state, yy, 13, name, col, b)
      local bx = TX.b
      bx = btn(bx, yy, "START", r.mode == "on" and C.green or C.gray, function() setMode(r, "on") end)
      bx = btn(bx, yy, "STOP", r.mode == "off" and C.red or C.gray, function() setMode(r, "off") end)
      btn(bx, yy, "AUTO", r.mode == "auto" and C.accent or C.gray, function() setMode(r, "auto") end)
    elseif i == 1 then
      textW(TX.ore, yy, 100, "No rules yet - press New rule, pick an ore, set the levels and Save.", C.dim, b)
    end
  end
  local r = S.sel and D.rules[S.sel]
  local yy = y + ROWS + 1
  fill(2, yy, W - 2, 1, C.panel)
  if r then
    local name, col, detail = ruleState(r)
    textW(TX.num, yy, W - 6, "Rule " .. S.sel .. ": " .. name .. " - " .. tostring(detail), col, C.panel)
  elseif #D.rules > ROWS then
    textW(TX.num, yy, W - 6, "Scroll for more rules (" .. #D.rules .. " in total)", C.dim, C.panel)
  end
end

local function field(id, x, y, w, value)
  local f = E.focus == id
  textW(x, y, w, " " .. value .. (f and "_" or ""), f and C.white or C.text, f and C.focus or C.field)
  region(x, y, w, 1, function() E.focus = id end)
end

local function drawForm()
  local x, y, w = 2, 31, 86
  local r = S.sel and D.rules[S.sel]
  panel(x, y, w, 15, r and ("Edit rule " .. S.sel) or "New rule")
  local lx, fx = x + 2, x + 22
  textW(lx, y + 2, 20, "Ore to produce:", C.text, C.panel)
  local ores = allOres()
  local cur = 0
  for i, o in ipairs(ores) do if E.ore and o.link == E.ore.link and o.id == E.ore.id then cur = i end end
  local oreText = E.ore and (minerName(E.ore.link) .. ":  " .. oreLabel({ link = E.ore.link, ore = E.ore.id }))
    or (#ores == 0 and "(no miner has reported yet)" or "(pick one)")
  local function step(d)
    if #ores == 0 then return end
    local n = (cur - 1 + d) % #ores + 1
    local o = ores[n]
    local oldLabel = E.ore and oreLabel({ link = E.ore.link, ore = E.ore.id })
    E.ore = { link = o.link, id = o.id }
    if E.trigger == "" or E.trigger == oldLabel then E.trigger = o.label end   -- trigger follows the ore
  end
  text(fx, y + 2, " ◄ ", C.white, C.gray); region(fx, y + 2, 3, 1, function() step(-1) end)
  textW(fx + 3, y + 2, 54, " " .. oreText, C.white, C.field)
  text(fx + 57, y + 2, " ► ", C.white, C.gray); region(fx + 57, y + 2, 3, 1, function() step(1) end)

  textW(lx, y + 4, 20, "Trigger item:", C.text, C.panel)
  field("trigger", fx, y + 4, 46, E.trigger)
  btn(fx + 48, y + 4, "Same as ore", C.gray, function()
    if E.ore then E.trigger = oreLabel({ link = E.ore.link, ore = E.ore.id }) end
  end)
  textW(lx, y + 5, w - 4, "Exact item name as AE shows it, e.g. Magnetite Ore, Iron Dust, Copper Ingot.", C.dim, C.panel)

  textW(lx, y + 7, 20, "Start below:", C.text, C.panel)
  field("low", fx, y + 7, 16, E.low)
  textW(fx + 20, y + 7, 12, "Stop at:", C.text, C.panel)
  field("high", fx + 32, y + 7, 16, E.high)
  textW(lx, y + 8, w - 4, "AUTO mines while the trigger is below Start, until it reaches Stop.", C.dim, C.panel)

  textW(lx, y + 10, 20, "Mode:", C.text, C.panel)
  local mx = fx
  mx = btn(mx, y + 10, "AUTO", E.mode == "auto" and C.accent or C.gray, function() E.mode = "auto" end)
  mx = btn(mx, y + 10, "START", E.mode == "on" and C.green or C.gray, function() E.mode = "on" end)
  btn(mx, y + 10, "STOP", E.mode == "off" and C.red or C.gray, function() E.mode = "off" end)

  local bx = lx
  bx = btn(bx, y + 13, "  Save  ", C.green, saveForm)
  bx = btn(bx, y + 13, "Clear form", C.gray, function() S.sel = nil; loadForm(nil) end)
  if r then
    local armed = S.delAt and computer.uptime() - S.delAt < 5
    btn(bx, y + 13, armed and "Click again to delete" or "Delete rule", C.red, function()
      if armed then
        table.remove(D.rules, S.sel)
        S.sel = nil; loadForm(nil); save(); evaluate(); sendAll(false)
        flash("Rule deleted")
      else
        S.delAt = computer.uptime()
      end
    end)
  end
end

local function drawMiners()
  local x, y, w = 90, 31, 69
  panel(x, y, w, 7, "Miners")
  local ls = links()
  local row = 0
  for _, link in ipairs(ls) do
    if row >= 5 then break end
    row = row + 1
    local s = L[link]
    local on = online(link)
    local yy = y + row
    local nIn, nProb = 0, 0
    for _, e in ipairs((s and s.entries) or {}) do
      if e.inBus then nIn = nIn + 1 end
      if e.problem then nProb = nProb + 1 end
    end
    textW(x + 1, yy, 18, "● " .. minerName(link), on and C.green or C.red, C.panel)
    local info
    if not s then info = "never reported"
    elseif not on then info = "offline - last report " .. ago(s.last)
    else
      info = #(s.entries or {}) .. " ores, " .. nIn .. " mining" ..
        (nProb > 0 and (", " .. nProb .. " problem(s)") or "") ..
        (s.hold and ", HOLD" or "") .. (s.foreign and s.foreign > 0 and (", " .. s.foreign .. " other item(s) in bus") or "") ..
        " | " .. tostring(s.machine)
      if s.err then info = tostring(s.err) end
    end
    textW(x + 20, yy, w - 21, info, (s and s.err) and C.red or C.text, C.panel)
  end
  if #ls == 0 then textW(x + 1, y + 1, w - 2, "Install a linked card (one per planet).", C.red, C.panel) end
end

local function drawLog()
  local x, y, w, h = 90, 39, 69, 7
  panel(x, y, w, h, "Activity")
  for i = 1, h - 1 do
    local e = log[#log - i + 1]
    if e then
      textW(x + 1, y + i, 9, ago(e.t), C.dim, C.panel)
      textW(x + 10, y + i, w - 11, e.s, e.bad and C.red or C.text, C.panel)
    end
  end
end

local function drawAll()
  regions = {}
  fill(1, 1, W, H, C.bg)
  drawTop()
  drawTable()
  drawForm()
  drawMiners()
  drawLog()
  fill(1, H, W, 1, C.head)
  if S.msg and computer.uptime() - S.msgAt < 8 then textW(2, H, W - 2, S.msg, C.white, C.head)
  else
    textW(2, H, W - 2, "Click a rule to edit it.  Tab = next field, Enter = Save, Esc = leave field.  " ..
      "Mouse wheel scrolls the rules.  Ctrl+C quits (miners keep their last request).", C.dim, C.head)
  end
end

------------------------------------------------------------- MAIN
local FIELDS = { "trigger", "low", "high" }

local function onKey(ch, code)
  if not E.focus then
    if code == 28 or code == 156 then saveForm() end
    return
  end
  local v = E[E.focus]
  if code == 28 or code == 156 then saveForm()
  elseif code == 1 then E.focus = nil
  elseif code == 15 then
    for i, f in ipairs(FIELDS) do if f == E.focus then E.focus = FIELDS[i % #FIELDS + 1]; break end end
  elseif code == 14 then E[E.focus] = unicode.sub(v, 1, -2)
  elseif ch and ch >= 32 and ch < 127 and unicode.len(v) < 44 then E[E.focus] = v .. string.char(ch) end
end

local oldW, oldH = rgpu.getResolution()

local function main()
  local mw, mh = rgpu.maxResolution()
  if mw < W or mh < H then error("voidctl needs a tier 3 GPU and screen (160x50).", 0) end
  gpu.setResolution(W, H)
  load()
  findAE()
  for _, link in ipairs(links()) do pcall(component.invoke, link, "send", "VM_HELLO") end
  loadForm(nil)
  readAE(); evaluate(); sendAll(true)
  local lastDraw = 0
  while true do
    local ev = { event.pull(0.5) }
    local name = ev[1]
    if name == "interrupted" then break
    elseif name == "modem_message" then onMessage(table.unpack(ev, 2))
    elseif name == "touch" then
      E.focus = nil              -- a click on a field puts the focus back on it
      hit(ev[3], ev[4])
    elseif name == "scroll" then S.scroll = S.scroll - ev[5]
    elseif name == "key_down" then onKey(ev[3], ev[4])
    elseif name == "component_added" or name == "component_removed" then
      findAE()
      if ev[3] == "tunnel" and name == "component_added" then pcall(component.invoke, ev[2], "send", "VM_HELLO") end
    end
    local up = computer.uptime()
    if up - S.lastAE >= CONFIG.AE_POLL then
      local ok, e = pcall(readAE)
      if not ok then S.aeErr = "Program error: " .. tostring(e) end
      evaluate()
    end
    sendAll(false)
    if name or up - lastDraw >= 1 then
      lastDraw = up
      drawAll()
      gpu.flush()
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
save()
gpu.setResolution(oldW, oldH)
rgpu.setBackground(0x000000)
rgpu.setForeground(0xFFFFFF)
term.clear()
if not ok and not tostring(err):find("interrupted") then io.stderr:write(tostring(err) .. "\n") end
