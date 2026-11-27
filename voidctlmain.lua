--[[
  voidctlmain.lua  -  Void Miner control, MAIN SCREEN (runs on Earth)

  Everything voidctl.lua does for the miners on its own linked card(s), plus:
  it listens over a wireless network card for every other voidctl.lua on
  Earth and shows their miners too. Click a miner in the "Miners" box and the
  production rules list switches to that miner - with the same START / STOP /
  AUTO buttons and rule editing.

    planet 1  voidminer --linked card-->  voidctlmain (this, big screen)
    planet 2  voidminer --linked card-->  voidctl --wireless-->  voidctlmain

  Rules of a remote miner are kept on ITS voidctl computer: it keeps the miner
  running by itself, and this screen sends it your changes. Rules of the
  local miner(s) are kept here, as in voidctl.lua.

  Hardware:
    - Server (or computer case) with tier 3 GPU, tier 3 screen (160x50),
      keyboard, CPU, memory, HDD with OpenOS
    - Adapter touching an ME Interface (or the ME Controller) - read only
    - the Linked Card(s) of the local miner(s)
    - Wireless Network Card (tier 2 recommended: 400 block range; a tier 1
      card only reaches 16 blocks). Every voidctl needs one as well.

  Numbers accept k / m / g (e.g. 64k, 1.5m).
  Files: /home/voidctlmain.dat (local rules, last known whitelists, chosen miner)
  Exit: Ctrl+C (every miner keeps its last request; remote ones keep running).
]]

---------------------------------------------------------------- CONFIG
local CONFIG = {
  DATA_FILE = "/home/voidctlmain.dat",
  AE_POLL = 5,           -- seconds between ME level reads
  SEND_EVERY = 10,       -- the request is sent again this often (and at once on a change)
  OFFLINE_AFTER = 45,    -- seconds without a report = miner / station offline
  AE_ADDRESS = nil,      -- nil = first me_interface / me_controller; or the start of an address
  LOG_MAX = 40,
  NET_PORT = 4050,       -- must be the same in every voidctl.lua
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
local rgpu = component.isAvailable("gpu") and component.gpu or nil
if rgpu then
  local ok, scr = pcall(rgpu.getScreen)
  if not ok or not scr then rgpu = nil end
end
local HEADLESS = rgpu == nil      -- no GPU / screen: control + wireless only
local gpu
if HEADLESS then
  gpu = setmetatable({}, { __index = function() return function() end end })
else
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
  S.pubDirty = true                           -- tell the main screen soon
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
  S.pubDirty = true
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


local function setMode(r, mode)
  r.mode = mode
  if mode == "auto" then
    local a = amount[r.id]
    r.latch = type(a) == "number" and a < r.low or false
  end
  save(); evaluate(); sendAll(false)
end

------------------------------------------------------------ REMOTE STATIONS
-- stations[address of the voidctl's wireless card] = { snap, last, name }
-- snap = { name, ae, aeErr, miners = { { link, name, online, age, hold, machine, foreign, err,
--          entries = { { id, label, inBus, problem } } } }, rules = { { id, link, ore, oreLabel,
--          trigger, low, high, mode, amount, st, det } } }
local wnet
local stations, parts = {}, {}

local function findWireless()
  wnet = nil
  for addr in component.list("modem") do
    local m = component.proxy(addr)
    if m.isWireless() then wnet = m; break end
  end
  if wnet then pcall(wnet.open, CONFIG.NET_PORT) end
end

local function stationLive(addr)
  local s = stations[addr]
  return s and computer.uptime() - s.last <= CONFIG.OFFLINE_AFTER
end

local function remoteMiner(addr, link)
  local s = stations[addr]
  if not s then return nil end
  for _, m in ipairs(s.snap.miners or {}) do if m.link == link then return m end end
end

local function sendCmd(addr, c)
  if not wnet then flash("No wireless network card in this computer"); return false end
  if not stationLive(addr) then flash("That station is not answering - command not sent"); return false end
  pcall(wnet.send, addr, CONFIG.NET_PORT, "VC_CMD", serialization.serialize(c))
  return true
end

local function helloAll()
  if wnet then pcall(wnet.broadcast, CONFIG.NET_PORT, "VC_CMD", serialization.serialize({ op = "hello" })) end
end

------------------------------------------------------------ VIEW
-- S.view = { kind = "local", link } or { kind = "remote", st = station address, link }
-- S.selId = id of the selected rule in that view (nil = new rule)

local function sameView(a, b)
  return a and b and a.kind == b.kind and a.link == b.link and a.st == b.st
end

-- every miner, local ones first: { kind, st, link, name, online, s, where }
local function minerList()
  local out = {}
  for _, link in ipairs(links()) do
    out[#out + 1] = { kind = "local", link = link, name = minerName(link), online = online(link),
                      s = L[link], where = "linked card here" }
  end
  local addrs = {}
  for a in pairs(stations) do addrs[#addrs + 1] = a end
  table.sort(addrs)
  for _, a in ipairs(addrs) do
    local st = stations[a]
    local live = stationLive(a)
    for _, m in ipairs(st.snap.miners or {}) do
      out[#out + 1] = { kind = "remote", st = a, link = m.link, name = m.name, online = live and m.online,
                        s = m, where = "via " .. st.name, live = live }
    end
  end
  return out
end

local function viewName()
  local v = S.view
  if not v then return "no miner" end
  if v.kind == "local" then return minerName(v.link) .. "  (linked card here)" end
  local m = remoteMiner(v.st, v.link)
  local s = stations[v.st]
  return (m and m.name or "remote miner") .. "  (via " .. (s and s.name or "a station not heard yet") .. ")"
end

local function stateColor(st)
  if st == "PRODUCING" then return C.green end
  if st == "STARTING" or st == "STOPPING" or st == "MINER HOLD" then return C.amber end
  if st == "IDLE" then return C.dim end
  return C.red
end

-- the rules of the miner on screen, in one shape for local and remote
local function viewRows()
  local v, rows = S.view, {}
  if not v then return rows end
  if v.kind == "local" then
    for _, r in ipairs(D.rules) do
      if r.link == v.link then
        local st, col, det = ruleState(r)
        rows[#rows + 1] = { id = r.id, r = r, ore = oreLabel(r), oreId = r.ore, trigger = r.trigger.label,
                            amount = amount[r.id], low = r.low, high = r.high, mode = r.mode, st = st, col = col, det = det }
      end
    end
  else
    local s = stations[v.st]
    if s then
      local live = stationLive(v.st)
      for _, x in ipairs(s.snap.rules or {}) do
        if x.link == v.link then
          local st, det = x.st, x.det
          if not live then st, det = "NO SIGNAL", s.name .. " last heard " .. ago(s.last) end
          rows[#rows + 1] = { id = x.id, x = x, ore = x.oreLabel, oreId = x.ore, trigger = x.trigger, amount = x.amount,
                              low = x.low, high = x.high, mode = x.mode, st = st, col = stateColor(st), det = det }
        end
      end
    end
  end
  return rows
end

local function rowById(id)
  if not id then return nil end
  for _, row in ipairs(viewRows()) do if row.id == id then return row end end
end

-- ores of the miner on screen: { { id, label } }
local function viewOres()
  local v = S.view
  if not v then return {} end
  local entries
  if v.kind == "local" then entries = L[v.link] and L[v.link].entries
  else local m = remoteMiner(v.st, v.link); entries = m and m.entries end
  local out = {}
  for _, e in ipairs(entries or {}) do out[#out + 1] = { id = e.id, label = e.label } end
  return out
end

local function viewOreLabel(id)
  for _, o in ipairs(viewOres()) do if o.id == id then return o.label end end
  return id and ("ore #" .. tostring(id)) or "?"
end

------------------------------------------------------------ EDIT FORM
local function loadForm(row)
  if row then
    E.ore = row.oreId
    E.trigger, E.low, E.high, E.mode = row.trigger, tostring(row.low), tostring(row.high), row.mode
  else
    local ores, rows = viewOres(), viewRows()
    E.ore = nil
    for _, o in ipairs(ores) do                  -- first ore that has no rule yet
      local used = false
      for _, x in ipairs(rows) do if x.oreId == o.id then used = true end end
      if not used then E.ore = o.id; break end
    end
    if not E.ore and ores[1] then E.ore = ores[1].id end
    E.trigger = E.ore and viewOreLabel(E.ore) or ""
    E.low, E.high, E.mode = "", "", "auto"
  end
  E.focus = nil
  S.delAt = nil
end

local function setView(m)
  S.view = { kind = m.kind, st = m.st, link = m.link }
  S.selId, S.scroll = nil, 0
  D.view = S.view
  save()
  loadForm(nil)
end

local function saveForm()
  local v = S.view
  if not v then flash("Pick a miner in the Miners box first"); return end
  if not E.ore then flash("This miner has no ores on its whitelist yet"); return end
  local trig = E.trigger:gsub("^%s+", ""):gsub("%s+$", "")
  if trig == "" then trig = viewOreLabel(E.ore) end
  local low, high = parseNum(E.low), parseNum(E.high)
  if E.mode == "auto" or E.low ~= "" or E.high ~= "" then
    if not low or not high then flash("Start below and Stop at need numbers (64k, 1.5m ...)"); return end
    if high <= low then flash("Stop at must be higher than Start below"); return end
  end
  if v.kind == "remote" then
    if sendCmd(v.st, { op = "save", rule = S.selId, link = v.link, ore = E.ore, trigger = trig,
                       low = low, high = high, mode = E.mode }) then
      flash("Sent to " .. stations[v.st].name .. "...")
      if not S.selId then S.newPending = true end
    end
    E.focus = nil
    return
  end
  local row = rowById(S.selId)
  local r = row and row.r
  if not r then
    r = { id = D.nextId, latch = false }
    D.nextId = D.nextId + 1
    D.rules[#D.rules + 1] = r
    S.selId = r.id
  end
  r.link, r.ore = v.link, E.ore
  r.oreLabel = oreLabel({ link = r.link, ore = r.ore })
  if not r.trigger or r.trigger.label ~= trig then r.trigger = { label = trig }; amount[r.id] = nil end
  r.low, r.high, r.mode = low or r.low or 0, high or r.high or 0, E.mode
  save()
  S.lastAE = -99                              -- read the level now
  flash("Saved: " .. r.oreLabel .. " <- " .. trig)
  E.focus = nil
end

local function doMode(row, mode)
  if row.r then
    setMode(row.r, mode)
  elseif S.view and S.view.kind == "remote" then
    if sendCmd(S.view.st, { op = "mode", rule = row.id, mode = mode }) then row.x.mode = mode end
  end
  if row.id == S.selId then E.mode = mode end
end

local function doDelete(row)
  if row.r then
    for i, r in ipairs(D.rules) do if r == row.r then table.remove(D.rules, i); break end end
    save(); evaluate(); sendAll(false)
    flash("Rule deleted")
  elseif S.view and S.view.kind == "remote" then
    sendCmd(S.view.st, { op = "delete", rule = row.id })
  end
  S.selId = nil
  loadForm(nil)
end

------------------------------------------------------------ NETWORK IN
local function onNet(from, port, kind, a, b, c, d)
  if port ~= CONFIG.NET_PORT then return end
  if kind == "VC_PART" then
    local seq, i, n, chunk = a, b, c, d
    if type(i) ~= "number" or type(n) ~= "number" or type(chunk) ~= "string" then return end
    local p = parts[from]
    if not p or p.seq ~= seq then p = { seq = seq, n = n, got = {}, count = 0 }; parts[from] = p end
    if not p.got[i] then p.got[i] = chunk; p.count = p.count + 1 end
    if p.count < p.n then return end
    parts[from] = nil
    local ok, snap = pcall(serialization.unserialize, table.concat(p.got))
    if not ok or type(snap) ~= "table" then return end
    local was = stationLive(from)
    local name = tostring(snap.name or ("Station " .. from:sub(1, 4)))
    stations[from] = { snap = snap, last = computer.uptime(), name = name }
    if not was then logLine(name .. " connected (" .. #(snap.miners or {}) .. " miner(s))") end
    -- a rule just made on this screen: select it when it shows up
    if S.newPending and S.view and S.view.st == from then
      local best
      for _, x in ipairs(snap.rules or {}) do if x.link == S.view.link and (not best or x.id > best) then best = x.id end end
      if best then S.selId, S.newPending = best, nil end
    end
  elseif kind == "VC_ACK" then
    local s = stations[from]
    flash((s and s.name or "Station") .. ": " .. tostring(a))
  end
end

------------------------------------------------------------ DRAWING
local ROWS = 22
local TX = { num = 3, ore = 7, trig = 43, me = 79, low = 93, high = 105, mode = 117, state = 124, b = 138 }

local function drawTop()
  fill(1, 1, W, 1, C.accent)
  textW(2, 1, 32, "Void Miner Control - Main", C.white, C.accent)
  local x = 34
  for _, m in ipairs(minerList()) do
    local s = "● " .. m.name .. "  "
    if x + unicode.len(s) > W - 46 then break end
    text(x, 1, s, m.online and 0xB0FFB0 or 0xFFB0B0, C.accent)
    x = x + unicode.len(s)
  end
  local n = 0
  for a in pairs(stations) do if stationLive(a) then n = n + 1 end end
  textW(W - 46, 1, 24, wnet and ("● Wireless: " .. n .. " station(s)") or "● no wireless card",
    wnet and 0xB0FFB0 or 0xFFB0B0, C.accent, "right")
  textW(W - 21, 1, 20, ae and "● ME connected" or "● ME not found", ae and 0xB0FFB0 or 0xFFB0B0, C.accent, "right")

  fill(1, 2, W, 1, C.bg)
  local bx = 2
  bx = btn(bx, 2, "New rule", C.gray, function() S.selId = nil; loadForm(nil) end)
  bx = btn(bx, 2, "All AUTO", C.gray, function()
    for _, row in ipairs(viewRows()) do doMode(row, "auto") end
    flash("Every rule of this miner is on AUTO")
  end)
  bx = btn(bx, 2, "All STOP", C.red, function()
    for _, row in ipairs(viewRows()) do doMode(row, "off") end
    flash("Every rule of this miner is on STOP")
  end)
  btn(bx, 2, "Ask everyone", C.gray, function()
    for _, link in ipairs(links()) do pcall(component.invoke, link, "send", "VM_HELLO") end
    helloAll()
    sendAll(true); flash("Asked every miner and station for its status")
  end)
  if S.aeErr then textW(80, 2, 79, S.aeErr, C.red, C.bg, "right") end
end

local function drawTable()
  panel(2, 4, W - 2, ROWS + 3, "Production rules - " .. viewName())
  local y = 5
  fill(2, y, W - 2, 1, C.alt)
  textW(TX.num, y, 3, "#", C.dim, C.alt)
  textW(TX.ore, y, 35, "Produces", C.dim, C.alt)
  textW(TX.trig, y, 35, "Trigger item (ME)", C.dim, C.alt)
  textW(TX.me, y, 13, "In ME", C.dim, C.alt, "right")
  textW(TX.low, y, 11, "Start below", C.dim, C.alt, "right")
  textW(TX.high, y, 11, "Stop at", C.dim, C.alt, "right")
  textW(TX.mode, y, 6, "Mode", C.dim, C.alt)
  textW(TX.state, y, 13, "State", C.dim, C.alt)
  textW(TX.b, y, 20, "Control", C.dim, C.alt)
  local rows = viewRows()
  S.scroll = max(0, min(S.scroll, #rows - ROWS))
  for k = 1, ROWS do
    local i = S.scroll + k
    local row = rows[i]
    local yy = y + k
    local b = (row and row.id == S.selId) and C.sel or (k % 2 == 0 and C.alt or C.panel)
    fill(2, yy, W - 2, 1, b)
    if row then
      region(2, yy, TX.b - 3, 1, function() S.selId = row.id; loadForm(row) end)
      local a = row.amount
      textW(TX.num, yy, 3, tostring(i), C.dim, b)
      textW(TX.ore, yy, 35, row.ore, C.text, b)
      textW(TX.trig, yy, 35, row.trigger, (row.trigger == row.ore) and C.dim or C.text, b)
      local ac = C.text
      if type(a) == "number" and row.mode == "auto" then ac = a < row.low and C.red or (a >= row.high and C.green or C.amber) end
      textW(TX.me, yy, 13, type(a) == "number" and short(a) or "?", ac, b, "right")
      textW(TX.low, yy, 11, short(row.low), C.dim, b, "right")
      textW(TX.high, yy, 11, short(row.high), C.dim, b, "right")
      local mc = row.mode == "on" and C.green or (row.mode == "off" and C.red or C.text)
      textW(TX.mode, yy, 6, row.mode == "on" and "START" or (row.mode == "off" and "STOP" or "AUTO"), mc, b)
      textW(TX.state, yy, 13, row.st, row.col, b)
      local bx = TX.b
      bx = btn(bx, yy, "START", row.mode == "on" and C.green or C.gray, function() doMode(row, "on") end)
      bx = btn(bx, yy, "STOP", row.mode == "off" and C.red or C.gray, function() doMode(row, "off") end)
      btn(bx, yy, "AUTO", row.mode == "auto" and C.accent or C.gray, function() doMode(row, "auto") end)
    elseif i == 1 then
      local v = S.view
      local msg = "No rules for this miner yet - press New rule, pick an ore, set the levels and Save."
      if not v then msg = "No miner yet - install a linked card here, or start voidctl on another computer with a wireless card."
      elseif v.kind == "remote" and not stations[v.st] then msg = "Waiting for this station to report over wireless..." end
      textW(TX.ore, yy, 120, msg, C.dim, b)
    end
  end
  local row = rowById(S.selId)
  local yy = y + ROWS + 1
  fill(2, yy, W - 2, 1, C.panel)
  if row then
    textW(TX.num, yy, W - 6, "Rule: " .. row.st .. " - " .. tostring(row.det or ""), row.col, C.panel)
  elseif #rows > ROWS then
    textW(TX.num, yy, W - 6, "Scroll for more rules (" .. #rows .. " in total)", C.dim, C.panel)
  end
end

local function field(id, x, y, w, value)
  local f = E.focus == id
  textW(x, y, w, " " .. value .. (f and "_" or ""), f and C.white or C.text, f and C.focus or C.field)
  region(x, y, w, 1, function() E.focus = id end)
end

local function drawForm()
  local x, y, w = 2, 31, 86
  local row = rowById(S.selId)
  panel(x, y, w, 15, (row and "Edit rule" or "New rule") .. " - " .. viewName())
  local lx, fx = x + 2, x + 22
  textW(lx, y + 2, 20, "Ore to produce:", C.text, C.panel)
  local ores = viewOres()
  local cur = 0
  for i, o in ipairs(ores) do if o.id == E.ore then cur = i end end
  local oreText = E.ore and viewOreLabel(E.ore) or (#ores == 0 and "(this miner has no ores yet)" or "(pick one)")
  local function step(d)
    if #ores == 0 then return end
    local o = ores[(cur - 1 + d) % #ores + 1]
    local oldLabel = E.ore and viewOreLabel(E.ore)
    E.ore = o.id
    if E.trigger == "" or E.trigger == oldLabel then E.trigger = o.label end   -- trigger follows the ore
  end
  text(fx, y + 2, " ◄ ", C.white, C.gray); region(fx, y + 2, 3, 1, function() step(-1) end)
  textW(fx + 3, y + 2, 54, " " .. oreText, C.white, C.field)
  text(fx + 57, y + 2, " ► ", C.white, C.gray); region(fx + 57, y + 2, 3, 1, function() step(1) end)

  textW(lx, y + 4, 20, "Trigger item:", C.text, C.panel)
  field("trigger", fx, y + 4, 46, E.trigger)
  btn(fx + 48, y + 4, "Same as ore", C.gray, function() if E.ore then E.trigger = viewOreLabel(E.ore) end end)
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
  if S.view and S.view.kind == "remote" then
    textW(lx, y + 11, w - 4, "This rule is kept on " .. (stations[S.view.st] and stations[S.view.st].name or "its station") ..
      " - Save sends it there.", C.dim, C.panel)
  end

  local bx = lx
  bx = btn(bx, y + 13, "  Save  ", C.green, saveForm)
  bx = btn(bx, y + 13, "Clear form", C.gray, function() S.selId = nil; loadForm(nil) end)
  if row then
    local armed = S.delAt and computer.uptime() - S.delAt < 5
    btn(bx, y + 13, armed and "Click again to delete" or "Delete rule", C.red, function()
      if armed then doDelete(row) else S.delAt = computer.uptime() end
    end)
  end
end

local function minerInfo(m)
  local s = m.s
  if m.kind == "remote" and not m.live then
    return "no signal from the station (" .. ago(stations[m.st].last) .. ")", C.red
  end
  if not s or (m.kind == "local" and not s.last) or (m.kind == "remote" and not s.age) then
    return "no report yet - is voidminer running?", C.red
  end
  if not m.online then
    local t = m.kind == "local" and ago(s.last) or (floor(s.age / 60) .. "m ago")
    return "miner offline - last report " .. t, C.red
  end
  if s.err then return tostring(s.err), C.red end
  local nIn, nProb = 0, 0
  for _, e in ipairs(s.entries or {}) do
    if e.inBus then nIn = nIn + 1 end
    if e.problem then nProb = nProb + 1 end
  end
  return #(s.entries or {}) .. " ores, " .. nIn .. " mining" .. (nProb > 0 and (", " .. nProb .. " problem(s)") or "") ..
    (s.hold and ", HOLD" or "") .. " | " .. tostring(s.machine), nProb > 0 and C.amber or C.text
end

local function drawMiners()
  local x, y, w, h = 90, 31, 69, 10
  panel(x, y, w, h, "Miners - click one to show its rules")
  local list = minerList()
  for k = 1, h - 1 do
    local m = list[k]
    local yy = y + k
    if m then
      local sel = sameView(m, S.view)
      local b = sel and C.sel or C.panel
      fill(x, yy, w, 1, b)
      textW(x + 1, yy, 18, "● " .. m.name, m.online and C.green or C.red, b)
      local info, col = minerInfo(m)
      textW(x + 20, yy, 18, m.where, C.dim, b)
      textW(x + 39, yy, w - 40, info, col, b)
      region(x, yy, w, 1, function() setView(m) end)
    elseif k == 1 then
      textW(x + 1, yy, w - 2, "No miners - add a linked card here or start voidctl elsewhere.", C.red, C.panel)
    end
  end
end

local function drawLog()
  local x, y, w, h = 90, 42, 69, 4
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
    textW(2, H, W - 2, "Click a miner to show its rules, a rule to edit it.  Tab = next field, Enter = Save, " ..
      "Esc = leave field.  Mouse wheel scrolls.  Ctrl+C quits (every miner keeps running).", C.dim, C.head)
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

-- no miner chosen yet (or it vanished): the first one in the list
local function ensureView()
  if S.view then
    if S.view.kind == "local" then
      for _, l in ipairs(links()) do if l == S.view.link then return end end
    else
      return                                   -- a station may simply not have reported yet
    end
  end
  local m = minerList()[1]
  if m then setView(m) else S.view = nil end
end

local oldW, oldH
if not HEADLESS then oldW, oldH = rgpu.getResolution() end

local function main()
  if HEADLESS then error("voidctlmain needs a tier 3 GPU and screen (160x50).", 0) end
  local mw, mh = rgpu.maxResolution()
  if mw < W or mh < H then error("voidctlmain needs a tier 3 GPU and screen (160x50).", 0) end
  gpu.setResolution(W, H)
  load()
  S.view = D.view
  findAE()
  findWireless()
  for _, link in ipairs(links()) do pcall(component.invoke, link, "send", "VM_HELLO") end
  helloAll()
  ensureView()
  loadForm(nil)
  readAE(); evaluate(); sendAll(true)
  local lastDraw, lastEnsure = 0, 0
  while true do
    local ev = { event.pull(0.5) }
    local name = ev[1]
    if name == "interrupted" then break
    elseif name == "modem_message" then
      if wnet and ev[2] == wnet.address then onNet(ev[3], ev[4], ev[6], ev[7], ev[8], ev[9], ev[10])
      else onMessage(table.unpack(ev, 2)) end
    elseif name == "touch" then
      E.focus = nil              -- a click on a field puts the focus back on it
      hit(ev[3], ev[4])
    elseif name == "scroll" then
      if ev[3] < 90 or ev[4] < 31 then S.scroll = S.scroll - ev[5] end
    elseif name == "key_down" then onKey(ev[3], ev[4])
    elseif name == "component_added" or name == "component_removed" then
      findAE()
      if ev[3] == "modem" then findWireless() end
      if ev[3] == "tunnel" and name == "component_added" then pcall(component.invoke, ev[2], "send", "VM_HELLO") end
    end
    local up = computer.uptime()
    if up - S.lastAE >= CONFIG.AE_POLL then
      local ok, e = pcall(readAE)
      if not ok then S.aeErr = "Program error: " .. tostring(e) end
      evaluate()
    end
    sendAll(false)
    if up - lastEnsure >= 2 then
      lastEnsure = up
      local had = S.view
      ensureView()
      if not had and S.view then loadForm(nil) end
    end
    if name or up - lastDraw >= 1 then
      lastDraw = up
      drawAll()
      gpu.flush()
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
save()
if not HEADLESS then
  gpu.setResolution(oldW, oldH)
  rgpu.setBackground(0x000000)
  rgpu.setForeground(0xFFFFFF)
  term.clear()
end
if not ok and not tostring(err):find("interrupted") then io.stderr:write(tostring(err) .. "\n") end
