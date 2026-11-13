--[[
  stargate.lua  -  Stargate Valley (a farming game for Lymanos)

  Started by Lymanos (desktop icon or Start > Stargate Valley). It is only
  loaded while it is open, and every farm lives on the storage server
  (sgvserver.lua): this computer keeps nothing on disk but this file.

  Controls
    W A S D / arrows   walk                 E or I     inventory
    left click         use the tool         Esc        menu (save, quit)
    right click        interact / harvest   1-9 0 - =  toolbar slot
    C or Space         use tool (facing)    wheel      next / previous slot
    X or F             interact (facing)

  A game day (6:00 am - 2:00 am) lasts as long as a Minecraft day:
  CONFIG.SGV_DAY_SECONDS in lymanos.lua (default 1200 s = 20 minutes).
  Time stops while a menu is open or the game is minimized.
]]

local ctx = ...
if type(ctx) ~= "table" or not ctx.gpu then
  error("Stargate Valley is started from Lymanos (desktop icon or Start menu).", 0)
end

local gpu, wlan, CONFIG = ctx.gpu, ctx.wlan, ctx.CONFIG
local computer, unicode, serialization = ctx.computer, ctx.unicode, ctx.serialization
local fgc, bgc = ctx.fg, ctx.bg            -- Lymanos' color setters (keeps its color cache right)
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local byte, char, srep, ssub = string.byte, string.char, string.rep, string.sub
local concat = table.concat

local W, H = 160, 50
local TS = 6                                 -- tile = 6 x 6 pixels = 6 columns x 3 rows
local MW, MH = 60, 34                        -- farm size in tiles (60 x 34 = 2040, fits a 2048-slot Lua table)
local PORT = CONFIG.SGV_PORT or 4047
local DAY_SECONDS = CONFIG.SGV_DAY_SECONDS or 1200
local HALF = unicode.char(0x2580)
local VERSION = "0.1"

---------------------------------------------------------------- PALETTE
-- one character per color; sprites are strings of these ('.' = see-through)
local PAL = {}
for tok in ([[
g6CB33C G5AA032 h84C84C H3E7E28 n2F7A38 N1D5629 m46A04A M123F1E
dE9B55E DD49B45 eF4CC80 t9A6438 T7A4A28 w5E3A20 W45281A
b3B7FD4 B2C62B0 c8FC2F2 oC8813E O8A4E24 pE6A85A P5C3418
rCC4A2C R8C2B1A sE8744A k9C9C9C K6C6C6C lCACACA L4A4A4A
u7E4C26 U4E2E16 x2B1A10 yFFFFFF YF4E4BC v7FB6E8 V4C86C6
fF5C9A2 a6A3A1A z3A6FC0 j2F3D5C q86D84E Q4AA82E iF0E2A8 IC49A5C
CF7F5E6 F5BAA36 EEE4466 J4A78EE Z2E8E5C AF2C14E XD02020 S3C8C3C
1E9B868 2D9A04E 3F2C67A 4D8A458 59A5A2A 66E3A1A 7101010 8B84A2A
9E08850 0606060 #202030 @F07A2A %FFD23A +3A6ABA *E6E6E6 &9A2E2A
=F08A30
]]):gmatch("%S+") do
  PAL[byte(tok)] = tonumber(ssub(tok, 2), 16)
end
local VOID = 0x101010
local CURSOR = 0xE02424

-- hair and shirt colors you can pick (they replace 'a' and 'z')
local HAIRS = { { "Brown", 0x6A3A1A }, { "Black", 0x24201E }, { "Blond", 0xE8C060 },
                { "Red", 0xB0401E }, { "Teal", 0x2AA8A0 }, { "Lilac", 0xB08AD8 } }
local SHIRTS = { { "Blue", 0x3A6FC0 }, { "Red", 0xC03A3A }, { "Green", 0x3A9A4A },
                 { "Black", 0x2A2A30 }, { "Purple", 0x7A4AB0 }, { "Orange", 0xE07A2A } }

---------------------------------------------------------------- SPRITES
local SP = {}                -- 6x6 sprites (36-character strings)
local BIG = {}               -- bigger pictures { w, h, s }

-- a cheap repeatable "random" number for a position
local function hash(a, b)
  local v = (a * 73856093 + b * 19349663 + 7919) % 1000003
  return (v * 2654435761) % 4294967296
end

do   -- (the painting helpers are only needed while the art is made)

local function S6(...)
  local s = concat({ ... })
  if #s ~= 36 then error("Stargate Valley: bad 6x6 sprite (" .. #s .. ")", 0) end
  return s
end

-- big sprites: { w, h, s } (s = w*h characters)
local function art(w, ...)
  local s = concat({ ... })
  if #s % w ~= 0 then error("Stargate Valley: bad sprite width", 0) end
  return { w = w, h = #s / w, s = s }
end

-- painting big sprites in code: a canvas of character codes
local function cvNew(w, h)
  local c = { w = w, h = h }
  for i = 1, w * h do c[i] = 46 end
  return c
end
local function cvSet(c, x, y, ch)
  x, y = floor(x), floor(y)
  if x >= 0 and y >= 0 and x < c.w and y < c.h then c[y * c.w + x + 1] = byte(ch) end
end
local function cvGet(c, x, y)
  if x < 0 or y < 0 or x >= c.w or y >= c.h then return 46 end
  return c[y * c.w + x + 1]
end
local function cvRect(c, x, y, w, h, ch)
  for yy = y, y + h - 1 do for xx = x, x + w - 1 do cvSet(c, xx, yy, ch) end end
end
-- dark edge around everything that is drawn
local function cvOutline(c, ch)
  local edge = {}
  for y = 0, c.h - 1 do
    for x = 0, c.w - 1 do
      if cvGet(c, x, y) ~= 46 and (cvGet(c, x - 1, y) == 46 or cvGet(c, x + 1, y) == 46
          or cvGet(c, x, y - 1) == 46 or cvGet(c, x, y + 1) == 46) then
        edge[#edge + 1] = y * c.w + x + 1
      end
    end
  end
  local b = byte(ch)
  for _, i in ipairs(edge) do c[i] = b end
end
local function cvPack(c)
  local t = {}
  for i = 1, c.w * c.h do t[i] = char(c[i]) end
  return { w = c.w, h = c.h, s = concat(t) }
end


-- ground variants (made from a base color with a few speckles)
local function speckle(base, dots, seed, n)
  local t = {}
  for i = 1, 36 do
    local r = hash(i, seed) % n
    t[i] = dots[r + 1] or base
  end
  return concat(t)
end

SP.grass = {
  speckle("g", { "h", "G" }, 1, 11), speckle("g", { "G", "h", "G" }, 2, 13),
  speckle("g", { "h" }, 3, 9), S6("gggggg", "gHgggg", "gHggGg", "ggggGg", "gggggg", "gggHgg"),
}
SP.sand = { speckle("d", { "e", "D" }, 4, 12), speckle("d", { "D" }, 5, 10), speckle("d", { "e" }, 6, 14) }
SP.water = { S6("bbbbbb", "bcbbbb", "bbbBbb", "bbbbcb", "Bbbbbb", "bbbbbb"),
             S6("bbbbbb", "bbbbBb", "bcbbbb", "bbbbbb", "bbbcbb", "Bbbbbb") }
SP.shore = S6("dddddd", "deddDd", "bbbbbb", "bcbbbb", "bbbBbb", "bbbbbb")
SP.cobble = { S6("lkkKlk", "kkKkkk", "KlkkKl", "kkkKkk", "lkKkkl", "KkkkKk"),
              S6("kKlkkK", "lkkKlk", "kkKkkk", "KklkkK", "kkKlkk", "lkkkKl") }
SP.forest = { S6("NnnNMN", "nmmnNn", "nmnnNM", "NnNMnn", "MNnmmn", "NnnnNN"),
              S6("nNMNnn", "NnnmmN", "MNnnnN", "nnNNmm", "NmmnNn", "nnNMNN") }
SP.tilled = S6("tttttt", "TTTTTT", "tttttt", "tttttt", "TTTTTT", "tttttt")
SP.wet = S6("wwwwww", "WWWWWW", "wwwwww", "wwwwww", "WWWWWW", "wwwwww")
SP.floor = { S6("334333", "334333", "334333", "444444", "333433", "333433"),
             S6("343333", "343333", "343333", "444444", "333343", "333343") }
SP.wall = S6("121111", "121111", "121111", "121111", "121111", "121111")
SP.walltop = S6("666666", "555555", "121111", "121111", "121111", "121111")
SP.wallbot = S6("121111", "121111", "121111", "121111", "666666", "PPPPPP")
SP.void = S6("777777", "777777", "777777", "777777", "777777", "777777")
SP.trim = S6("777777", "777777", "OOOOOO", "pppppp", "oooooo", "777777")

-- things on a tile
SP.weed = S6("......", ".Q..Q.", "QqQ.qQ", ".QqQq.", "QQqqQQ", ".QQQQ.")
SP.stone = S6("......", "..lk..", ".lkkk.", "lkkkKk", "kkKKKK", ".KKKK.")
SP.twig = S6("......", "....u.", "..uu..", ".uUuu.", "u....U", "......")
SP.stump = S6("......", ".uuuu.", "uppppu", "uppopu", "UuuuuU", ".UUUU.")
SP.chest = S6(".OOOO.", "OppppO", "OOAAOO", "OooooO", "OooooO", "OOOOOO")
SP.fence = S6("......", ".u..u.", "pppppp", ".u..u.", "pppppp", ".U..U.")
SP.wpath = S6("pppppo", "oooooo", "ppopPp", "oooooo", "poppPp", "oooooo")
SP.gpath = S6("kllkkl", "lkKlkk", "kklkll", "lkkKkk", "kllkkl", "Kkklkk")
SP.gift = S6("......", ".=+==.", "++++++", ".=+==.", ".=+==.", ".OOOO.")
SP.dead = S6("......", ".u..u.", "..uU..", ".UuU..", "..UU..", "......")

-- crop stages
SP.c_seed = S6("......", "......", "..u.u.", "......", ".u..u.", "......")
SP.c_sprout = S6("......", "......", "..q...", "..Qq..", "..Q...", "......")
SP.c_small = S6("......", ".q..q.", "..qQ..", ".qQQq.", "..QQ..", "......")
SP.c_big = S6(".q..q.", "qQ.qQq", ".QqQQ.", "qQQQq.", "..QQ..", "......")
SP.c_trellis = S6(".uFFu.", ".uFQu.", ".FuFu.", ".uFFu.", ".FuQu.", ".u..u.")
SP.r_parsnip = S6(".q.q..", "..qQ..", ".qQq..", ".iiii.", "..ii..", "...i..")
SP.r_potato = S6("q.q.q.", "QqQqQ.", ".QQQ..", "IQIQI.", ".I.I..", "......")
SP.r_cauli = S6(".Q..Q.", "QCCCCQ", "CCyCCC", "QCCCCQ", ".QQQQ.", "..QQ..")
SP.r_kale = S6("Z.Z.Z.", "ZZqZZ.", "ZZZZZZ", ".ZqZZ.", "..ZZ..", "..Q...")
SP.r_bean = S6(".uFqu.", ".qFQu.", ".FqFu.", ".uFqu.", ".qFQu.", ".u..u.")
SP.r_tulip = S6("..E...", ".EEE..", ".EEE..", "..Q.q.", ".qQQ..", "..Q...")
SP.r_jazz = S6(".J.J..", "JJJJJ.", ".JyJ..", "..Q...", ".QQq..", "..Q...")

-- item icons
SP.i_hoe = S6("kkk...", "..ku..", "...u..", "....u.", ".....u", "......")
SP.i_axe = S6(".kk...", "kkku..", ".kk.u.", "....u.", ".....u", "......")
SP.i_pick = S6(".kkkk.", "k.u..k", "..u...", "...u..", "....u.", "......")
SP.i_can = S6("......", ".BBB.b", "BbbbBb", "BbbbB.", "BBBBB.", "......")
SP.i_scythe = S6("lkk...", "...kk.", "....u.", "...u..", "..u...", "......")
SP.i_wood = S6("......", ".OOOO.", "pOooOo", "pooooO", ".OOOO.", "......")
SP.i_fiber = S6("..Q...", ".QqQ..", "QqQqQ.", ".QqQ..", "..Qq..", "...Q..")
SP.i_sap = S6("......", "..A...", ".AAA..", ".AAO..", "..A...", "......")
SP.i_bean = S6("......", "..q...", ".qQ.q.", ".Q.qQ.", "..qQ..", "...Q..")
SP.i_dial_day = S6("..A...", "A.A.A.", ".AAA..", "AAAAA.", ".AAA..", "A.A.A.")
SP.i_dial_night = S6("..yy..", ".yy...", "yy....", "yy....", ".yy...", "..yy..")
SP.i_rain = S6(".kkk..", "kllkk.", "kkkkkk", "..b...", ".b..b.", "b..b..")
SP.i_trash = S6(".kkkk.", "kkkkkk", ".lklk.", ".lklk.", ".lklk.", ".kkkk.")

local function seedIcon(c)
  return S6("..PP..", ".p" .. c .. c .. "p.", "p" .. srep(c, 4) .. "p", "pp" .. c .. c .. "pp", ".pppp.", "u..u.u")
end

-- the farmer: 6x12, four directions, two walking frames
local BODY = { "zzzzzz", "zzzzzz", "fzzzzf", ".zzzz.", ".jjjj.", ".jjjj." }
local function farmer(head, legs)
  local t = {}
  for i = 1, 4 do t[#t + 1] = head[i] end
  for i = 1, 6 do t[#t + 1] = BODY[i] end
  t[#t + 1] = legs[1]; t[#t + 1] = legs[2]
  return concat(t)
end
local function mirror(s)
  local t = {}
  for r = 0, 11 do t[#t + 1] = ssub(s, r * 6 + 1, r * 6 + 6):reverse() end
  return concat(t)
end
local LEGS0, LEGS1 = { ".j..j.", ".U..U." }, { "..jj..", "..UU.." }
SP.p_down = { farmer({ ".aaaa.", "aaaaaa", "afxfxa", ".ffff." }, LEGS0),
              farmer({ ".aaaa.", "aaaaaa", "afxfxa", ".ffff." }, LEGS1) }
SP.p_up = { farmer({ ".aaaa.", "aaaaaa", "aaaaaa", ".aaaa." }, LEGS0),
            farmer({ ".aaaa.", "aaaaaa", "aaaaaa", ".aaaa." }, LEGS1) }
SP.p_left = { farmer({ ".aaaa.", "aaaaa.", "fxfaa.", ".ffa.." }, LEGS0),
              farmer({ ".aaaa.", "aaaaa.", "fxfaa.", ".ffa.." }, LEGS1) }
SP.p_right = { mirror(SP.p_left[1]), mirror(SP.p_left[2]) }

---------------------------------------------------------------- BIG ART

-- the farmhouse: 9 x 7 tiles (54 x 42 px), porch along the bottom
do
  local c = cvNew(54, 42)
  -- annex (woodshed) on the left: small red roof over a stack of logs
  cvRect(c, 0, 13, 13, 7, "r")
  for y = 13, 19, 2 do cvRect(c, 0, y, 13, 1, "R") end
  for y = 20, 35 do
    for x = 0, 11 do
      local lx, ly = x % 4, (y - 20) % 4
      cvSet(c, x, y, (lx >= 1 and lx <= 2 and ly >= 1 and ly <= 2) and "p" or ((lx == 0 or ly == 0) and "U" or "u"))
    end
  end
  cvRect(c, 11, 20, 1, 16, "P")
  -- main roof: a tall gable
  for y = 0, 19 do
    local hw = 3 + y * 1.2
    for x = 10, 49 do
      local dx = x - 31
      if abs(dx) <= hw then
        local ch = ((y + floor((x + (y % 2) * 2) / 4)) % 3 == 0) and "R" or "r"
        if abs(dx) > hw - 1.2 then ch = "R" end
        if y % 3 == 2 then ch = "R" end
        if dx < 0 and abs(dx) > hw - 3 and y % 3 ~= 2 then ch = "s" end
        cvSet(c, x, y, ch)
      end
    end
  end
  -- wooden gable with a round window
  for y = 5, 19 do
    local hw = (y - 5) * 0.85
    for x = 10, 52 do
      local dx = x - 31
      if abs(dx) <= hw then cvSet(c, x, y, (x % 3 == 0) and "o" or "p") end
    end
  end
  for y = 7, 15 do
    for x = 27, 35 do
      local d = ((x - 31) ^ 2 + ((y - 11) * 1.0) ^ 2) ^ 0.5
      if d <= 2.3 then cvSet(c, x, y, (x < 31 and y < 11) and "c" or "v")
      elseif d <= 3.2 then cvSet(c, x, y, "O") end
    end
  end
  -- chimney
  for y = 0, 13 do
    for x = 41, 46 do
      local ch = ((x + floor(y / 2) * 3) % 4 == 0 or y % 2 == 0) and "K" or ((x + y) % 3 == 0 and "l" or "k")
      cvSet(c, x, y, ch)
    end
  end
  cvRect(c, 40, 0, 8, 1, "L")
  -- front wall
  for y = 19, 35 do
    for x = 12, 49 do cvSet(c, x, y, (x % 3 == 0) and "o" or "p") end
  end
  cvRect(c, 12, 19, 38, 1, "O")
  cvRect(c, 12, 35, 38, 1, "O")
  cvRect(c, 12, 19, 1, 17, "O")
  -- window with green shutters
  cvRect(c, 17, 23, 8, 7, "O")
  cvRect(c, 18, 24, 6, 5, "v")
  cvRect(c, 18, 24, 2, 2, "c")
  cvRect(c, 20, 24, 1, 5, "O"); cvRect(c, 18, 26, 6, 1, "O")
  cvRect(c, 15, 23, 2, 7, "S"); cvRect(c, 25, 23, 2, 7, "S")
  for y = 24, 29, 2 do cvSet(c, 15, y, "H"); cvSet(c, 26, y, "H") end
  -- door
  cvRect(c, 29, 21, 9, 15, "P")
  cvRect(c, 30, 22, 7, 13, "O")
  cvRect(c, 31, 23, 5, 3, "v")
  cvRect(c, 31, 27, 2, 3, "o"); cvRect(c, 34, 27, 2, 3, "o")
  cvRect(c, 31, 31, 2, 3, "o"); cvRect(c, 34, 31, 2, 3, "o")
  cvSet(c, 35, 29, "A")
  -- brick pillar on the right
  for y = 14, 41 do
    for x = 49, 53 do
      local joint = (y % 3 == 0) or ((x + (floor(y / 3) % 2) * 2) % 4 == 0)
      cvSet(c, x, y, joint and "6" or "5")
    end
  end
  -- porch (deck), steps and a red mat
  for y = 36, 41 do
    for x = 0, 48 do
      local ch = "o"
      if y == 36 then ch = "p" elseif y == 39 or (x % 9 == 0 and y ~= 41) then ch = "O" end
      if y == 41 then ch = "P" end
      cvSet(c, x, y, ch)
    end
  end
  for y = 38, 41 do
    for x = 27, 39 do cvSet(c, x, y, (y == 39 or y == 41) and "O" or "p") end
  end
  cvRect(c, 29, 36, 9, 2, "X")
  BIG.house = cvPack(c)
end

-- pine tree: 18 x 30 (3 tiles wide, 5 tall)
do
  local c = cvNew(18, 30)
  for y = 0, 24 do
    local tier = floor(y / 6)
    local within = y - tier * 6
    local hw = min(8.5, 1 + within * 0.95 + tier * 1.4)
    for x = 0, 17 do
      local dx = x - 8.5
      if abs(dx) <= hw then
        local ch = "n"
        if within >= 5 then ch = "N"
        elseif dx < -hw + 2 then ch = "m"
        elseif dx > hw - 2 then ch = "N" end
        cvSet(c, x, y, ch)
      end
    end
  end
  cvRect(c, 7, 23, 4, 7, "u")
  cvRect(c, 7, 23, 1, 7, "U"); cvRect(c, 10, 25, 1, 5, "U")
  cvOutline(c, "M")
  BIG.pine = cvPack(c)
end

-- round leafy tree: 18 x 26
do
  local c = cvNew(18, 26)
  for y = 0, 17 do
    for x = 0, 17 do
      local dx, dy = (x - 8.5) / 8.8, (y - 8.5) / 8.4
      local d = dx * dx + dy * dy
      if d <= 1 then
        local ch = "n"
        if dx + dy < -0.55 then ch = "m"
        elseif dx + dy > 0.6 then ch = "N" end
        if hash(x, y) % 9 == 0 then ch = "h" end
        cvSet(c, x, y, ch)
      end
    end
  end
  cvRect(c, 7, 17, 4, 9, "u")
  cvRect(c, 7, 17, 1, 9, "U"); cvRect(c, 6, 25, 6, 1, "U")
  cvOutline(c, "M")
  BIG.oak = cvPack(c)
end

BIG.bin = art(12,
  ".OOOOOOOOOO.",
  "OppppppppppO",
  "OOOOOOOOOOOO",
  "OooOooOooOoO",
  "OooOooOooOoO",
  "OOOOOOOOOOOO",
  "OooOooOooOoO",
  "OooOooOooOoO",
  "OOOOOOOOOOOO",
  ".PPPPPPPPPP.")
BIG.mailbox = art(6,
  ".kkkX.",
  "kllkX.",
  "kkkkk.",
  "KKKKK.",
  "..u...",
  "..u...",
  "..u...",
  "..u...",
  "..U...",
  ".UUU..")
-- seed stall (stands in for the town shop): 18 x 18
BIG.stall = art(18,
  "XXXyyyXXXyyyXXXyyy",
  "XXXyyyXXXyyyXXXyyy",
  "XXXyyyXXXyyyXXXyyy",
  ".X.y.X.y.X.y.X.y.X",
  "..................",
  ".u..............u.",
  ".u..............u.",
  ".u..............u.",
  ".u..............u.",
  ".u..............u.",
  "OOOOOOOOOOOOOOOOOO",
  "OEiqJqAqiqEqJqiqAO",
  "OppppppppppppppppO",
  "OooOooOooOooOooOoO",
  "OooOooOooOooOooOoO",
  "OooOooOooOooOooOoO",
  "OOOOOOOOOOOOOOOOOO",
  ".PPPPPPPPPPPPPPPP.")

-- inside the farmhouse
BIG.tv = art(12,
  "...000000...",
  "..00000000..",
  "000########0",
  "00#v######00",
  "00#v######00",
  "00########00",
  "000000000XX0",
  ".0000000000.",
  "OOOOOOOOOOOO",
  "OppppppppppO",
  "OooooooooooO",
  "OoooooAAoooO",
  "OooooooooooO",
  ".PP......PP.")
BIG.chair = art(6,
  ".OOOO.",
  ".OppO.",
  ".OpoO.",
  ".OpoO.",
  ".OppO.",
  ".OOOO.",
  "oooooo",
  "OppppO",
  "OOOOOO",
  ".O..O.",
  ".O..O.",
  ".P..P.")
BIG.table = art(12,
  "OOOOOOOOOOOO",
  "OpppppppppPO",
  "OppppppppppO",
  "OpppYYYppppO",
  "OppYyyyYpppO",
  "OppYyyyYpppO",
  "OpppYYAAoppO",
  "OppppppppppO",
  "OOOOOOOOOOOO",
  ".O........O.",
  ".O........O.",
  ".O........O.",
  ".P........P.",
  "............")
do
  local c = cvNew(18, 24)
  for y = 0, 23 do
    local x1, x2 = 0, 17
    if y < 9 then x1, x2 = 5, 12 end
    for x = x1, x2 do
      local joint = (y % 2 == 0) or ((x + (floor(y / 2) % 2) * 2) % 4 == 0)
      cvSet(c, x, y, joint and "6" or "5")
    end
  end
  cvRect(c, 0, 9, 18, 2, "6")
  cvRect(c, 3, 13, 12, 11, "7")
  for x = 4, 13 do
    cvSet(c, x, 22, "U"); cvSet(c, x, 23, "U")
    if x % 2 == 0 then cvSet(c, x, 20, "@"); cvSet(c, x + 1, 21, "%") else cvSet(c, x, 19, "@") end
  end
  cvRect(c, 1, 14, 1, 9, "K")
  BIG.fireplace = cvPack(c)
end
BIG.window = art(6,
  ".pppp.",
  "pyyyyp",
  "pyYyYp",
  "pyyyyp",
  "pppppp",
  "pyyyyp",
  "pYyYyp",
  "pyyyyp",
  ".pppp.",
  "......")
BIG.picture = art(6,
  "OOOOOO",
  "OvvvvO",
  "OvnvvO",
  "OnNnvO",
  "OgggGO",
  "OOOOOO")
BIG.bed = art(12,
  "&&&&&&&&&&&&",
  "&PPPPPPPPPP&",
  "&**********&",
  "&*yyyyyyyy*&",
  "&**********&",
  "&YYYYYYYYYY&",
  "&YpYYYYYYpY&",
  "&YYYYYYYYYY&",
  "&YYYYpYYYYY&",
  "&YYYYYYYYYY&",
  "&YpYYYYYYpY&",
  "&YYYYYYYYYY&",
  "&YYYYYYYYYY&",
  "&&&&&&&&&&&&",
  "&PPPPPPPPPP&",
  "&&........&&",
  "&&........&&",
  "............")
BIG.plant = art(6,
  "m...m.",
  ".m.mn.",
  "nmmnm.",
  ".nmnN.",
  "..nN..",
  ".OOOO.",
  ".OooO.",
  ".OooO.",
  "..OO..",
  "......")
BIG.rug = art(12,
  ".9999999999.",
  "988888888889",
  "989999999989",
  "989888888989",
  "989899998989",
  "989888888989",
  "989999999989",
  "988888888889",
  ".9999999999.")

SP.seedIcon = seedIcon
end

-- title-screen letters (5 x 7)
local GLYPH = {
  S = "01111100001000001110000010000111110", T = "11111001000010000100001000010000100",
  A = "01110100011000111111100011000110001", R = "11110100011000111110101001001010001",
  G = "01111100001000010011100011000101111", E = "11111100001000011110100001000011111",
  V = "10001100011000110001100010101000100", L = "10000100001000010000100001000011111",
  Y = "10001100010101000100001000010000100",
}

---------------------------------------------------------------- ITEMS
-- k: tool | seed | crop | res | place.  sell = shipping price.  eat = energy.
local IT = {
  hoe    = { n = "Hoe", k = "tool", ic = SP.i_hoe, d = "Tills the soil so seeds can be planted." },
  can    = { n = "Watering Can", k = "tool", ic = SP.i_can, d = "Waters crops. Refill it at the pond." },
  axe    = { n = "Axe", k = "tool", ic = SP.i_axe, d = "Chops twigs, trees and stumps." },
  pick   = { n = "Pickaxe", k = "tool", ic = SP.i_pick, d = "Breaks stones; un-tills soil." },
  scythe = { n = "Scythe", k = "tool", ic = SP.i_scythe, d = "Cuts weeds. Uses no energy." },
  wood   = { n = "Wood", k = "res", sell = 2, ic = SP.i_wood, d = "A sturdy building material." },
  stone  = { n = "Stone", k = "res", sell = 2, ic = SP.stone, d = "A common building material." },
  fiber  = { n = "Fiber", k = "res", sell = 1, ic = SP.i_fiber, d = "Raw material sourced from plants." },
  sap    = { n = "Sap", k = "res", sell = 2, ic = SP.i_sap, d = "A fluid that comes from trees." },
  chest  = { n = "Chest", k = "place", obj = 7, ic = SP.chest, d = "Stores up to 36 stacks of items." },
  fence  = { n = "Wood Fence", k = "place", obj = 8, sell = 1, ic = SP.fence, d = "Keeps things in or out." },
  wpath  = { n = "Wood Path", k = "place", obj = 9, sell = 1, ic = SP.wpath, d = "Place it on the ground to make a path." },
  gpath  = { n = "Gravel Path", k = "place", obj = 10, sell = 1, ic = SP.gpath, d = "Place it on the ground to make a path." },
}
local TOOLS = { "hoe", "axe", "can", "pick", "scythe" }

-- crops (spring). days = days of watering to ripen, regrow = days between harvests
local CROPS = {
  parsnip = { n = "Parsnip", days = 4, buy = 20, sell = 35, eat = 25, ripe = SP.r_parsnip, col = "i" },
  potato  = { n = "Potato", days = 6, buy = 50, sell = 80, eat = 26, ripe = SP.r_potato, col = "I", extra = 0.2 },
  cauli   = { n = "Cauliflower", days = 12, buy = 80, sell = 175, eat = 75, ripe = SP.r_cauli, col = "C" },
  bean    = { n = "Green Bean", days = 10, buy = 60, sell = 40, eat = 25, ripe = SP.r_bean, col = "F", regrow = 3, trellis = true, icon = SP.i_bean },
  kale    = { n = "Kale", days = 6, buy = 70, sell = 110, eat = 50, ripe = SP.r_kale, col = "Z" },
  tulip   = { n = "Tulip", days = 6, buy = 20, sell = 30, eat = 45, ripe = SP.r_tulip, col = "E" },
  jazz    = { n = "Blue Jazz", days = 7, buy = 30, sell = 50, eat = 45, ripe = SP.r_jazz, col = "J" },
}
local CROPLIST = { "parsnip", "potato", "cauli", "bean", "kale", "tulip", "jazz" }
local CROPNUM = {}
for i, k in ipairs(CROPLIST) do
  local c = CROPS[k]
  CROPNUM[k] = i
  c.key = k
  IT[k] = { n = c.n, k = "crop", sell = c.sell, eat = c.eat, ic = c.icon or c.ripe, d = "Fresh from the farm." }
  IT[k .. "_s"] = { n = c.n .. (k == "bean" and " Starter" or (k == "tulip" and " Bulb" or " Seeds")), k = "seed",
    crop = k, buy = c.buy, sell = floor(c.buy / 2), ic = SP.seedIcon(c.col),
    d = "Plant in tilled soil. Ripe in " .. c.days .. " days" .. (c.regrow and (", then every " .. c.regrow) or "") .. "." }
end
local SHOPLIST = { "parsnip_s", "potato_s", "cauli_s", "bean_s", "kale_s", "tulip_s", "jazz_s" }

local RECIPES = {
  { id = "chest", n = 1, need = { { "wood", 50 } } },
  { id = "fence", n = 1, need = { { "wood", 2 } } },
  { id = "wpath", n = 1, need = { { "wood", 1 } } },
  { id = "gpath", n = 1, need = { { "stone", 1 } } },
}

local function itemName(id) return IT[id] and IT[id].n or tostring(id) end
local function kindName(id)
  local k = IT[id] and IT[id].k
  return ({ tool = "Tool", seed = "Seed", crop = "Crop", res = "Resource", place = "Crafting" })[k] or ""
end
local function maxStack(id) return (IT[id] and IT[id].k == "tool") and 1 or 999 end

---------------------------------------------------------------- OBJECTS
local OB = { NONE = 0, WEED = 1, STONE = 2, TWIG = 3, PINE = 4, OAK = 5, STUMP = 6, CHEST = 7,
             FENCE = 8, WPATH = 9, GPATH = 10, CROP = 11 }
local OBJSPR = { [OB.WEED] = SP.weed, [OB.STONE] = SP.stone, [OB.TWIG] = SP.twig, [OB.STUMP] = SP.stump,
                 [OB.CHEST] = SP.chest, [OB.FENCE] = SP.fence, [OB.WPATH] = SP.wpath, [OB.GPATH] = SP.gpath }
local OBJSOLID = { [OB.WEED] = true, [OB.STONE] = true, [OB.TWIG] = true, [OB.PINE] = true, [OB.OAK] = true,
                   [OB.STUMP] = true, [OB.CHEST] = true, [OB.FENCE] = true }

---------------------------------------------------------------- GAME STATE
-- G = the farm that is being played (nil on the title screen)
local G
local LOC                       -- current location: FARM or HOUSE
local P = { x = 0, y = 0, face = "down", step = 1, sx = 0, sy = 0, base = 0, spr = SP.p_down[1] }
local camX, camY = 0, 0         -- world pixel at the top-left screen corner (camY even)

---------------------------------------------------------------- LOCATIONS
local GR = { GRASS = 0, SAND = 1, WATER = 2, COBBLE = 3, FOREST = 4, FLOOR = 10, WALL = 11, VOID = 12 }

local function place(L, spr, tx, ty, base, solidRect, act)
  -- spr anchored so its bottom edge sits on tile row 'base', left edge at tile tx
  local s = { x = tx * TS, y = (base + 1) * TS - spr.h, w = spr.w, h = spr.h, s = spr.s, base = base }
  L.statics[#L.statics + 1] = s
  if solidRect then
    for y = solidRect[2], solidRect[4] do
      for x = solidRect[1], solidRect[3] do
        local i = y * L.w + x + 1
        L.solid[i] = true
        if act then L.act[i] = act end
      end
    end
  end
  return s
end

-- Ground is kept as a string, one character per tile (much smaller than a
-- table): L.code. The character picks the ground type (L.gt) and the picture (L.gsp).
local function groundCode(L, list)
  local idx, chars, sprs, gts = {}, {}, {}, {}
  for i = 1, L.w * L.h do
    local e = list[i]
    local k = idx[e[2]]
    if not k then
      k = #sprs + 1
      idx[e[2]], sprs[k], gts[k] = k, e[2], e[1]
    end
    chars[i] = char(k)
  end
  L.code, L.gsp, L.gt = concat(chars), sprs, gts
end
local function gAt(L, i) return L.gt[byte(L.code, i)] end

local FARM = { w = MW, h = MH, solid = {}, act = {}, statics = {}, cover = {}, void = 0x1D5629 }
do
  local L = FARM
  local ground, list = {}, {}
  for y = 0, MH - 1 do
    for x = 0, MW - 1 do
      local i = y * MW + x + 1
      local g = GR.GRASS
      local px, py = (x - 9) / 4.6, (y - 26) / 3.0
      if x <= 2 or x >= MW - 3 or y <= 1 or y >= MH - 2 then g = GR.FOREST
      elseif px * px + py * py <= 1 then g = GR.WATER
      elseif y >= 11 and y <= 13 and x >= 13 and x <= 34 then g = GR.SAND
      elseif y >= 14 and y <= 15 and x >= 29 and x <= 56 then g = GR.SAND
      elseif x >= 30 and x <= 31 and y >= 14 and y <= 19 then g = GR.SAND
      elseif x >= 36 and x <= 39 and y >= 2 and y <= 6 then g = GR.COBBLE
      end
      ground[i] = g
    end
  end
  for y = 0, MH - 1 do
    for x = 0, MW - 1 do
      local i = y * MW + x + 1
      local g = ground[i]
      local h = hash(x, y)
      local s
      if g == GR.GRASS then s = SP.grass[h % 4 + 1]
      elseif g == GR.SAND then s = SP.sand[h % 3 + 1]
      elseif g == GR.WATER then
        s = (y > 0 and ground[i - MW] ~= GR.WATER) and SP.shore or SP.water[h % 2 + 1]
      elseif g == GR.COBBLE then s = SP.cobble[h % 2 + 1]
      else s = SP.forest[h % 2 + 1] end
      list[i] = { g, s }
      if g == GR.WATER or g == GR.FOREST then L.solid[i] = true end
      if g == GR.WATER then L.act[i] = "water" end
    end
  end
  groundCode(L, list)
  place(L, BIG.house, 16, 4, 10, { 16, 4, 24, 9 }, nil)
  L.act[9 * MW + 21 + 1] = "door"
  place(L, BIG.bin, 27, 9, 9, { 27, 9, 28, 9 }, "bin")
  place(L, BIG.mailbox, 25, 10, 10, { 25, 10, 25, 10 }, "mail")
  place(L, BIG.stall, 52, 11, 13, { 52, 12, 54, 13 }, "shop")
  for i = 0, 2 do L.act[11 * MW + 52 + i + 1] = "shop" end
  -- tall pines standing in the forest around the farm (they can't be cut)
  for x = 1, MW - 2, 3 do
    if hash(x, 99) % 3 ~= 0 then place(L, BIG.pine, x - 1, 0, 1) end
    if hash(x, 98) % 3 ~= 0 then place(L, BIG.pine, x - 1, 0, MH - 1) end
  end
  for y = 4, MH - 3, 3 do
    if hash(97, y) % 3 ~= 0 then place(L, BIG.pine, 0, 0, y) end
    if hash(96, y) % 3 ~= 0 and (y < 12 or y > 17) then place(L, BIG.pine, MW - 3, 0, y) end
  end
end

-- tiles behind big pictures get no weeds or stones (you couldn't see them)
FARM.deco = {}
for _, sp in ipairs(FARM.statics) do
  for ty = max(0, floor(sp.y / TS)), min(MH - 1, floor((sp.y + sp.h - 1) / TS)) do
    for tx = max(0, floor(sp.x / TS)), min(MW - 1, floor((sp.x + sp.w - 1) / TS)) do FARM.deco[ty * MW + tx + 1] = true end
  end
end

-- inside the farmhouse (13 x 11 tiles)
local HOUSE = { w = 13, h = 11, solid = {}, act = {}, statics = {}, cover = {}, void = VOID }
do
  local L = HOUSE
  local list = {}
  for y = 0, L.h - 1 do
    for x = 0, L.w - 1 do
      local i = y * L.w + x + 1
      local g, s = GR.VOID, SP.void
      if y <= 2 then g = GR.WALL; s = (y == 0) and SP.walltop or (y == 2 and SP.wallbot or SP.wall)
      elseif y <= 9 or x == 3 then g = GR.FLOOR; s = SP.floor[x % 2 + 1] end
      if y == 10 and x ~= 3 then s = SP.trim end
      list[i] = { g, s }
      if g ~= GR.FLOOR then L.solid[i] = true end
    end
  end
  groundCode(L, list)
  place(L, BIG.window, 2, 0, 1)
  place(L, BIG.picture, 6, 0, 0).y = 3
  place(L, BIG.fireplace, 9, 0, 3, { 9, 3, 11, 3 }, "fire")
  place(L, BIG.tv, 0, 0, 4, { 0, 3, 1, 4 }, "tv")
  place(L, BIG.chair, 3, 0, 3, { 3, 3, 3, 3 }, nil)
  place(L, BIG.table, 4, 0, 4, { 4, 3, 5, 4 }, nil)
  place(L, BIG.plant, 0, 0, 9, { 0, 9, 0, 9 }, nil)
  place(L, BIG.bed, 11, 0, 9, { 11, 7, 12, 9 }, "bed")
  place(L, BIG.rug, 7, 0, 8).base = -100       -- always under everything
  L.act[6 * L.w + 3 + 1] = "gift"
end
local HOUSE_DOOR = { 3, 10 }                     -- inside: step down from here to go out
local FARM_DOOR = { 21, 10 }                     -- outside: in front of the door
local BED_SPOT = { 10, 8 }

local function rebuildCover(L)
  local cover = {}
  local function add(s)
    for ty = max(0, floor(s.y / TS)), min(L.h - 1, floor((s.y + s.h - 1) / TS)) do
      for tx = max(0, floor(s.x / TS)), min(L.w - 1, floor((s.x + s.w - 1) / TS)) do
        local i = ty * L.w + tx + 1
        local list = cover[i]
        if not list then list = {}; cover[i] = list end
        list[#list + 1] = s
      end
    end
  end
  for _, s in ipairs(L.statics) do add(s) end
  if L == FARM and G then
    for i = 1, MW * MH do
      local o = G.obj[i]
      if o == OB.PINE or o == OB.OAK then
        local tx, ty = (i - 1) % MW, floor((i - 1) / MW)
        local b = (o == OB.PINE) and BIG.pine or BIG.oak
        add({ x = tx * TS - 6, y = (ty + 1) * TS - b.h, w = b.w, h = b.h, s = b.s, base = ty })
      end
    end
  end
  L.cover = cover
end

---------------------------------------------------------------- NEW FARM
local function newFarm(name, farmerName, hair, shirt, seed)
  local g = {
    v = 1, name = name, farmer = farmerName, hair = hair or 1, shirt = shirt or 1, seed = seed,
    day = 1, season = 1, year = 1, mins = 360, gold = 500, earned = 0, energy = 270, maxE = 270,
    water = 40, loc = "house", x = BED_SPOT[1], y = BED_SPOT[2], face = "down",
    weather = "sun", tom = "sun", gift = true, mail = true, played = 0,
    inv = {}, bin = {}, soil = {}, obj = {}, crops = {}, hp = {}, chests = {},
  }
  for i = 1, 36 do g.inv[i] = false end
  for i, id in ipairs(TOOLS) do g.inv[i] = { id = id, n = 1 } end
  local rnd = seed
  local function r(n) rnd = (rnd * 1103515245 + 12345) % 2147483648; return rnd % n end
  for y = 0, MH - 1 do
    for x = 0, MW - 1 do
      local i = y * MW + x + 1
      g.soil[i] = 0
      local o = OB.NONE
      if gAt(FARM, i) == GR.GRASS and not FARM.solid[i] and not FARM.deco[i] then
        local near = (y >= 2 and y <= 16 and x >= 11 and x <= 36) or (x >= 48 and y >= 9 and y <= 17)
        local v = r(1000)
        if near then
          if v < 25 then o = OB.WEED end
        elseif y >= 16 or x <= 12 or x >= 40 or y <= 9 then
          if v < 115 then o = OB.WEED
          elseif v < 175 then o = OB.STONE
          elseif v < 235 then o = OB.TWIG
          elseif v < 262 and x >= 4 and x <= MW - 5 and y >= 4 then o = (r(3) == 0) and OB.OAK or OB.PINE end
        end
      end
      g.obj[i] = o
    end
  end
  -- trees need room around their trunks
  for i = 1, MW * MH do
    local o = g.obj[i]
    if o == OB.PINE or o == OB.OAK then
      local tx, ty = (i - 1) % MW, floor((i - 1) / MW)
      for dy = -2, 1 do
        for dx = -1, 1 do
          local j = (ty + dy) * MW + tx + dx + 1
          if (dx ~= 0 or dy ~= 0) and j >= 1 and j <= MW * MH and (g.obj[j] == OB.PINE or g.obj[j] == OB.OAK) then g.obj[j] = OB.NONE end
        end
      end
    end
  end
  -- the old fence behind the house
  for x = 9, 33 do
    if x < 16 or x > 24 then g.obj[3 * MW + x + 1] = OB.FENCE end
  end
  return g
end

---------------------------------------------------------------- SAVE FORMAT
-- The farm is sent to the storage server as one serialized table. The two
-- 2400-tile layers are run-length encoded (mostly empty, so ~1-2 KB each).
local function rle(arr, n)
  local out, i = {}, 1
  while i <= n do
    local v = arr[i] or 0
    local j = i
    while j < n and (arr[j + 1] or 0) == v do j = j + 1 end
    out[#out + 1] = char(65 + v) .. ((j > i) and tostring(j - i + 1) or "")
    i = j + 1
  end
  return concat(out)
end
local function unrle(s, n)
  local arr, i = {}, 0
  for c, num in tostring(s or ""):gmatch("(%u)(%d*)") do
    local v = byte(c) - 65
    for _ = 1, (tonumber(num) or 1) do
      if i < n then i = i + 1; arr[i] = v end
    end
  end
  for j = i + 1, n do arr[j] = 0 end
  return arr
end
local function packStacks(list, n)
  local t = {}
  for i = 1, n do
    local s = list[i]
    t[i] = s and (s.id .. "*" .. s.n) or ""
  end
  return concat(t, "|")
end
local function unpackStacks(str, n)
  local list, i = {}, 0
  for part in (tostring(str or "") .. "|"):gmatch("([^|]*)|") do
    i = i + 1
    if i > n then break end
    local id, cnt = part:match("^([%w_]+)%*(%d+)$")
    list[i] = (id and IT[id] and tonumber(cnt) > 0) and { id = id, n = tonumber(cnt) } or false
  end
  for j = i + 1, n do list[j] = false end
  return list
end

local function encodeFarm(g)
  local crops, hp, chests = {}, {}, {}
  for i, c in pairs(g.crops) do
    crops[#crops + 1] = i .. ":" .. (CROPNUM[c.k] or 1) .. ":" .. floor(c.d) .. ":" .. (c.dead and 1 or 0)
  end
  for i, v in pairs(g.hp) do hp[#hp + 1] = i .. ":" .. v end
  for i, v in pairs(g.chests) do chests[#chests + 1] = i .. ":" .. v end
  local bin = {}
  for _, s in ipairs(g.bin) do bin[#bin + 1] = s.id .. "*" .. s.n end
  return serialization.serialize({
    v = 1, name = g.name, farmer = g.farmer, hair = g.hair, shirt = g.shirt, seed = g.seed,
    day = g.day, season = g.season, year = g.year, mins = floor(g.mins), gold = g.gold, earned = g.earned,
    energy = g.energy, maxE = g.maxE, water = g.water, loc = g.loc, x = g.x, y = g.y, face = g.face,
    weather = g.weather, tom = g.tom, gift = g.gift, mail = g.mail, played = floor(g.played),
    inv = packStacks(g.inv, 36), bin = concat(bin, "|"),
    soil = rle(g.soil, MW * MH), obj = rle(g.obj, MW * MH),
    crops = concat(crops, ";"), hp = concat(hp, ";"), chests = concat(chests, ";"),
  })
end

local function decodeFarm(s)
  local ok, t = pcall(serialization.unserialize, s)
  if not ok or type(t) ~= "table" or not t.name then return nil, "the save data is damaged" end
  local function n(v, d) v = tonumber(v); return v or d end
  local g = {
    v = 1, name = tostring(t.name), farmer = tostring(t.farmer or "Farmer"), hair = n(t.hair, 1), shirt = n(t.shirt, 1),
    seed = n(t.seed, 1), day = n(t.day, 1), season = n(t.season, 1), year = n(t.year, 1), mins = n(t.mins, 360),
    gold = n(t.gold, 0), earned = n(t.earned, 0), energy = n(t.energy, 270), maxE = n(t.maxE, 270),
    water = n(t.water, 40), loc = (t.loc == "farm") and "farm" or "house", x = n(t.x, BED_SPOT[1]), y = n(t.y, BED_SPOT[2]),
    face = tostring(t.face or "down"), weather = (t.weather == "rain") and "rain" or "sun", tom = (t.tom == "rain") and "rain" or "sun",
    gift = t.gift ~= false, mail = t.mail ~= false, played = n(t.played, 0),
    inv = unpackStacks(t.inv, 36), bin = {}, soil = unrle(t.soil, MW * MH), obj = unrle(t.obj, MW * MH),
    crops = {}, hp = {}, chests = {},
  }
  if not SP["p_" .. g.face] then g.face = "down" end
  for part in tostring(t.bin or ""):gmatch("[^|]+") do
    local id, cnt = part:match("^([%w_]+)%*(%d+)$")
    if id and IT[id] then g.bin[#g.bin + 1] = { id = id, n = tonumber(cnt) } end
  end
  for i, k, d, dead in tostring(t.crops or ""):gmatch("(%d+):(%d+):(%d+):(%d)") do
    i = tonumber(i)
    if CROPLIST[tonumber(k)] and g.obj[i] == OB.CROP then
      g.crops[i] = { k = CROPLIST[tonumber(k)], d = tonumber(d), dead = dead == "1" or nil }
    end
  end
  for i, v in tostring(t.hp or ""):gmatch("(%d+):(%d+)") do g.hp[tonumber(i)] = tonumber(v) end
  for i, v in tostring(t.chests or ""):gmatch("(%d+):(%d+)") do
    if g.obj[tonumber(i)] == OB.CHEST then g.chests[tonumber(i)] = tonumber(v) end
  end
  for i = 1, MW * MH do                        -- a crop marker without crop data: clear it
    if g.obj[i] == OB.CROP and not g.crops[i] then g.obj[i] = OB.NONE end
    if g.obj[i] == OB.CHEST and not g.chests[i] then g.chests[i] = 0 end
    if g.obj[i] > OB.CROP then g.obj[i] = OB.NONE end
  end
  return g
end

local function farmMeta(g)
  local ch = {}
  for i in pairs(g.chests) do ch[#ch + 1] = i end
  return serialization.serialize({ name = g.name, farmer = g.farmer, day = g.day, season = g.season,
    year = g.year, gold = g.gold, played = floor(g.played), saved = ctx.now and ctx.now() or 0, chests = ch })
end

---------------------------------------------------------------- NETWORK
-- One request at a time to the storage server; re-sent every 2 s, given up
-- after 6 tries. The server keeps its last answer per computer, so a repeat
-- never does anything twice.
local NET = { addr = CONFIG.SGV_ADDR, q = {}, cur = nil, rid = floor((computer.uptime() * 1000) % 100000) * 10,
              last = -99, online = nil, heard = nil }
local CHUNK = 3600

local function netReq(op, a, b, c, cb, tag)
  NET.q[#NET.q + 1] = { op = op, a = a, b = b, c = c, cb = cb, tag = tag }
end
local function netFail(r, why)
  if r.tag then                                 -- drop the rest of the same transfer
    local keep = {}
    for _, q in ipairs(NET.q) do if q.tag ~= r.tag then keep[#keep + 1] = q end end
    NET.q = keep
  end
  if r.cb then r.cb(false, why) end
end
local function netPump()
  local up = computer.uptime()
  if not NET.cur and #NET.q > 0 then
    NET.cur = table.remove(NET.q, 1)
    NET.rid = NET.rid + 1
    NET.cur.rid, NET.cur.tries = NET.rid, 0
    NET.last = -99
  end
  local r = NET.cur
  if r and up - NET.last >= 2 then
    if r.tries >= 6 then
      NET.cur = nil
      NET.online = false
      NET.addr = CONFIG.SGV_ADDR               -- look for the server again next time
      netFail(r, "The storage server does not answer (port " .. PORT .. ").")
      return
    end
    r.tries = r.tries + 1
    NET.last = up
    local user = tostring(ctx.player())
    if NET.addr then pcall(wlan.send, NET.addr, PORT, "SGV", r.op, r.rid, user, r.a, r.b, r.c)
    else pcall(wlan.broadcast, PORT, "SGV", r.op, r.rid, user, r.a, r.b, r.c) end
  end
end
local function netMsg(from, kind, rid, ok, payload, extra)
  if kind ~= "R" then return end
  local r = NET.cur
  if not r or rid ~= r.rid then return end
  NET.cur = nil
  NET.online, NET.heard = true, computer.uptime()
  if not NET.addr then NET.addr = from end
  if ok then
    if r.cb then r.cb(true, payload, extra) end
  else
    netFail(r, tostring(payload or "refused"))
  end
end
local function netBusy() return NET.cur ~= nil or #NET.q > 0 end

-- whole-farm transfers ------------------------------------------------------
local function sendSave(id, g, cb)
  local blob = encodeFarm(g)
  local tag = {}
  local n = max(1, ceil(#blob / CHUNK))
  netReq("SBEG", id, n, farmMeta(g), nil, tag)
  for i = 1, n do netReq("SPART", id, i, ssub(blob, (i - 1) * CHUNK + 1, i * CHUNK), nil, tag) end
  local done = false
  local function finish(ok, why) if not done then done = true; cb(ok, why, #blob) end end
  for _, q in ipairs(NET.q) do if q.tag == tag then q.cb = function(ok, why) if not ok then finish(false, why) end end end end
  netReq("SEND", id, nil, nil, function(ok, why) finish(ok, why) end, tag)
end

local function loadSave(id, cb)
  netReq("LOAD", id, nil, nil, function(ok, p1, n)
    if not ok then return cb(false, p1) end
    n = tonumber(n) or 1
    local parts = { p1 }
    if n <= 1 then return cb(true, tostring(p1 or "")) end
    local tag = {}
    for i = 2, n do
      netReq("LPART", id, i, nil, function(ok2, p)
        if not ok2 then return cb(false, p) end
        parts[i] = p
        if i == n then cb(true, concat(parts)) end
      end, tag)
    end
  end)
end

---------------------------------------------------------------- RENDERER
-- The map is drawn with half-block characters: every character cell is two
-- pixels stacked, so the 160x50 screen is a 160x100 pixel picture. Only the
-- parts that change are redrawn, and Lymanos' screen buffer then sends only
-- the cells that really changed to the GPU.
local TOP, BOT = {}, {}
local tintLevel, tintCache = 0, {}
local TINTS = { [0] = nil, { 0x0A1440, 0.18 }, { 0x0A1440, 0.34 }, { 0x060A28, 0.5 }, rain = { 0x3A4A66, 0.3 } }

local function blend(c, t, f)
  local r1, g1, b1 = floor(c / 65536) % 256, floor(c / 256) % 256, c % 256
  local r2, g2, b2 = floor(t / 65536) % 256, floor(t / 256) % 256, t % 256
  return floor(r1 + (r2 - r1) * f) * 65536 + floor(g1 + (g2 - g1) * f) * 256 + floor(b1 + (b2 - b1) * f)
end
local function tint(c)
  if tintLevel == 0 then return c end
  local v = tintCache[c]
  if not v then
    local t = TINTS[tintLevel]
    v = blend(c, t[1], t[2])
    tintCache[c] = v
  end
  return v
end

local tgtIdx = nil                 -- tile under the red target box (nil = none)

-- ground sprite and object sprite of a tile
local function tileSprites(L, idx)
  local gs = L.gsp[byte(L.code, idx)]
  local os
  if L == FARM then
    local s = G.soil[idx]
    if s == 1 then gs = SP.tilled elseif s == 2 then gs = SP.wet end
    local o = G.obj[idx]
    if o == OB.CROP then
      local c = G.crops[idx]
      if c then
        local cd = CROPS[c.k]
        if c.dead then os = SP.dead
        elseif c.d >= cd.days then os = cd.ripe
        else
          local f = c.d / cd.days
          if c.d == 0 then os = SP.c_seed
          elseif cd.trellis and f >= 0.3 then os = SP.c_trellis
          elseif f < 0.34 then os = SP.c_sprout
          elseif f < 0.67 then os = SP.c_small
          else os = SP.c_big end
        end
      end
    elseif o ~= OB.NONE then os = OBJSPR[o] end
  elseif L == HOUSE and G.gift and idx == 6 * HOUSE.w + 3 + 1 then
    os = SP.gift
  end
  return gs, os
end

-- the colors of one row of world pixels, for screen columns c1..c2
local function computeRow(wy, c1, c2, out)
  local L = LOC
  local Lw, Lh = L.w, L.h
  local ty = floor(wy / TS)
  local sy = wy - ty * TS
  local rowOff = sy * TS
  local void = L.void
  local cover = L.cover
  local inP = wy >= P.sy and wy < P.sy + 12
  local pRow = inP and (wy - P.sy) * 6 or 0
  local psx, pspr, pbase = P.sx, P.spr, P.base
  local c = c1
  while c <= c2 do
    local wx = camX + c - 1
    local tx = floor(wx / TS)
    local sx = wx - tx * TS
    local n = min(c2 - c, TS - 1 - sx)
    if ty < 0 or ty >= Lh or tx < 0 or tx >= Lw then
      for k = 0, n do out[c + k] = void end
    else
      local idx = ty * Lw + tx + 1
      local gs, os = tileSprites(L, idx)
      local cov = cover[idx]
      local isT = (idx == tgtIdx)
      for k = 0, n do
        local px = sx + k
        local x = wx + k
        local ch, bb = nil, -1e9
        if cov then
          for j = 1, #cov do
            local b = cov[j]
            local lx, ly = x - b.x, wy - b.y
            if lx >= 0 and ly >= 0 and lx < b.w and ly < b.h then
              local v = byte(b.s, ly * b.w + lx + 1)
              if v ~= 46 and b.base >= bb then ch, bb = v, b.base end
            end
          end
        end
        if inP then
          local lx = x - psx
          if lx >= 0 and lx < 6 then
            local v = byte(pspr, pRow + lx + 1)
            if v ~= 46 and (ch == nil or pbase >= bb) then ch = v end
          end
        end
        if ch == nil and os then
          local v = byte(os, rowOff + px + 1)
          if v ~= 46 then ch = v end
        end
        local col = PAL[ch or byte(gs, rowOff + px + 1)] or 0xFF00FF
        if isT and (px == 0 or px == 5 or sy == 0 or sy == 5) then col = CURSOR end
        out[c + k] = col
      end
    end
    c = c + n + 1
  end
end

-- send a block of two pixel rows per character row to the screen
local function emit(r, c1, c2)
  local x = c1
  while x <= c2 do
    local t0, b0 = TOP[x], BOT[x]
    local x2 = x + 1
    while x2 <= c2 and TOP[x2] == t0 and BOT[x2] == b0 do x2 = x2 + 1 end
    local t, b = tint(t0), tint(b0)
    if t == b then
      bgc(t); gpu.set(x, r, srep(" ", x2 - x))
    else
      bgc(b); fgc(t); gpu.set(x, r, srep(HALF, x2 - x))
    end
    x = x2
  end
end

local function renderRect(c1, r1, c2, r2)
  c1, c2, r1, r2 = max(1, c1), min(W, c2), max(1, r1), min(H, r2)
  for r = r1, r2 do
    local wy = camY + (r - 1) * 2
    computeRow(wy, c1, c2, TOP)
    computeRow(wy + 1, c1, c2, BOT)
    emit(r, c1, c2)
  end
end

-- any picture given as a function f(x, y) -> color (title screen etc.)
local function renderFn(f, c1, r1, c2, r2)
  local saveT = tintLevel
  tintLevel = 0
  for r = r1, r2 do
    for c = c1, c2 do TOP[c] = f(c - 1, (r - 1) * 2); BOT[c] = f(c - 1, (r - 1) * 2 + 1) end
    emit(r, c1, c2)
  end
  tintLevel = saveT
end

-- a sprite drawn at a screen position (cell x, y), scaled up 'sc' times
local function drawSprite(x, y, spr, w, h, back, sc)
  sc = sc or 1
  local pw, ph = w * sc, h * sc
  local saveT = tintLevel
  tintLevel = 0
  for r = 0, ceil(ph / 2) - 1 do
    for c = 0, pw - 1 do
      local function at(py)
        if py >= ph then return back end
        local v = byte(spr, floor(py / sc) * w + floor(c / sc) + 1)
        if not v or v == 46 then return back end
        return PAL[v] or back
      end
      TOP[x + c] = at(r * 2); BOT[x + c] = at(r * 2 + 1)
    end
    emit(y + r, x, x + pw - 1)
  end
  tintLevel = saveT
end
local function drawIcon(x, y, s, back) drawSprite(x, y, s, 6, 6, back, 1) end

-- dirty areas (screen rectangles) waiting to be redrawn
local DIRTY = {}
local fullDirty = true
local function dirtyPix(x, y, w, h)               -- world pixels
  local c1 = x - camX + 1
  local r1 = floor((y - camY) / 2) + 1
  local c2 = c1 + w - 1
  local r2 = floor((y + h - 1 - camY) / 2) + 1
  if c2 < 1 or r2 < 1 or c1 > W or r1 > H then return end
  DIRTY[#DIRTY + 1] = { c1, r1, c2, r2 }
end
local function dirtyTile(tx, ty, tw, th) dirtyPix(tx * TS, ty * TS, (tw or 1) * TS, (th or 1) * TS) end
local function dirtyScreen(c1, r1, c2, r2) DIRTY[#DIRTY + 1] = { c1, r1, c2, r2 } end

---------------------------------------------------------------- UI KIT
-- Stardew-like wooden panels drawn with plain characters.
local UI = {
  edge = 0x5B2B10, edge2 = 0xB8682C, panel = 0xF8D59A, panel2 = 0xF0C27C, slot = 0xFBE6BC,
  slot2 = 0xE6B878, text = 0x4A2208, dim = 0x9A6A3A, red = 0xD92B2B, green = 0x3A9A2A,
  gold = 0xE8A51C, white = 0xFFFFFF, dark = 0x2A1408, night = 0x10142E, sel = 0xFFF2D0,
}
local function fit(s, w, align)
  s = tostring(s)
  local len = unicode.len(s)
  if len > w then return unicode.sub(s, 1, w) end
  if align == "right" then return srep(" ", w - len) .. s end
  if align == "center" then
    local l = floor((w - len) / 2)
    return srep(" ", l) .. s .. srep(" ", w - len - l)
  end
  return s .. srep(" ", w - len)
end
local function txt(x, y, s, f, b)
  if b then bgc(b) end
  if f then fgc(f) end
  gpu.set(x, y, s)
end
local function txtW(x, y, w, s, f, b, align) txt(x, y, fit(s, w, align), f, b) end
local function box(x, y, w, h, c)
  if w <= 0 or h <= 0 then return end
  bgc(c); gpu.fill(x, y, w, h, " ")
end
-- wooden frame: dark outer line, orange inner line, tan inside
local function panel(x, y, w, h, inner)
  box(x, y, w, h, UI.edge)
  box(x + 1, y, w - 2, h, UI.edge2)
  box(x + 2, y, w - 4, h, UI.edge)
  box(x + 2, y + 1, w - 4, h - 2, inner or UI.panel)
  bgc(UI.edge2); fgc(UI.edge)
  gpu.set(x + 2, y, srep("▄", w - 4))
  gpu.set(x + 2, y + h - 1, srep("▀", w - 4))
end

-- click regions of the screen that is up
local REG = {}
local function region(x, y, w, h, fn, rfn)
  REG[#REG + 1] = { x = x, y = y, w = w, h = h, fn = fn, rfn = rfn }
end
local function hitRegion(x, y, right)
  for i = #REG, 1, -1 do
    local r = REG[i]
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      local f = right and (r.rfn or r.fn) or r.fn
      if f then f(x, y, right) end
      return true
    end
  end
  return false
end

local function btn(x, y, w, label, fn, on, rfn)
  local face = on == false and UI.slot2 or UI.panel2
  box(x, y, w, 3, UI.edge)
  box(x + 1, y, w - 2, 3, face)
  bgc(UI.edge); fgc(face)
  gpu.set(x + 1, y, srep("▄", w - 2))
  gpu.set(x + 1, y + 2, srep("▀", w - 2))
  txtW(x + 1, y + 1, w - 2, label, on == false and UI.dim or UI.text, face, "center")
  if fn and on ~= false then region(x, y, w, 3, fn, rfn) end
end

-- one item slot: 7 x 4 cells (icon 6x3 + count line)
local function slot(x, y, s, back)
  back = back or UI.slot
  box(x, y, 7, 4, back)
  if s then
    drawIcon(x + 1, y, IT[s.id].ic, back)
    if s.n > 1 then txt(x, y + 3, fit(tostring(s.n), 7, "right"), UI.text, back)
    elseif s.id == "can" and G then txt(x, y + 3, fit(G.water .. "/40", 7, "right"), 0x2C62B0, back) end
  end
end

-- 12 slots in a row, framed; sel = highlighted slot (red frame)
local function slotRow(x, y, list, first, sel, onClick)
  for i = 0, 11 do
    local k = first + i
    local sx = x + i * 8
    slot(sx, y, list[k] or nil, UI.slot)
    if k == sel then
      bgc(UI.red)
      gpu.fill(sx - 1, y - 1, 9, 1, " "); gpu.fill(sx - 1, y + 4, 9, 1, " ")
      gpu.fill(sx - 1, y, 1, 4, " "); gpu.fill(sx + 7, y, 1, 4, " ")
    end
    if onClick then
      region(sx, y, 7, 4, function() onClick(k, false) end, function() onClick(k, true) end)
    end
  end
end

local function fmtClock(m)
  m = floor(m / 10) * 10
  local h = floor(m / 60) % 24
  local ap = (h < 12) and "am" or "pm"
  local h12 = h % 12
  if h12 == 0 then h12 = 12 end
  return string.format("%d:%02d %s", h12, m % 60, ap)
end
local WDAY = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local SEASON = { "Spring", "Summer", "Fall", "Winter" }
local function commas(n)
  local s = string.format("%d", floor(n + 0.5))
  local k
  repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
  return s
end

---------------------------------------------------------------- UI STATE
local U = {
  mode = "title",          -- title | list | new | busy | play | summary
  menu = nil,              -- (play) inv | chest | shop | bin
  tab = "inv",             -- inventory tabs: inv | craft | exit
  full = true, hud = true, menuDirty = true,
  sel = 1, held = nil, keys = {}, lastDir = nil, lastStep = 0,
  toasts = {}, tip = nil, tbTop = false,
  lastUp = computer.uptime(), lastTen = nil,
  farmId = nil, farms = nil, status = "", busyText = "",
  form = { farm = "", farmer = "", hair = 1, shirt = 1, focus = "farm" },
  msgBox = nil, msgReg = {}, chest = nil, saving = false, saveNote = nil, summary = nil,
}

local function toast(s)
  if U.mode == "play" and not U.menu then          -- the map under the old messages is drawn again
    dirtyScreen(1, 33, 62, 50); dirtyScreen(1, 1, 62, 12)
  end
  local top = U.toasts[1]
  local n, rest = s:match("^%+(%d+) (.+)$")
  if top and n and top.rest == rest and computer.uptime() - top.t < 3.5 then
    top.n = top.n + tonumber(n)
    top.s = "+" .. top.n .. " " .. rest
    top.t = computer.uptime()
    U.hud = true
    return
  end
  table.insert(U.toasts, 1, { s = s, t = computer.uptime(), n = tonumber(n), rest = rest })
  while #U.toasts > 4 do table.remove(U.toasts) end
  U.hud = true
end

-- message box (works on every screen): lines + buttons { label, fn }
local function msg(lines, buttons, title)
  U.msgBox = { lines = lines, buttons = buttons or { { "OK" } }, title = title }
  U.keys = {}
  U.msgDirty = true
  if U.mode ~= "play" then U.full = true end
end
local function closeMsg()
  U.msgBox = nil
  U.full, U.bg = true, true
  fullDirty = true
  U.menuDirty = true
end

---------------------------------------------------------------- INVENTORY
local function invAdd(id, n)
  local inv, ms = G.inv, maxStack(id)
  for i = 1, 36 do
    local s = inv[i]
    if n > 0 and s and s.id == id and s.n < ms then
      local k = min(n, ms - s.n); s.n = s.n + k; n = n - k
    end
  end
  for i = 1, 36 do
    if n > 0 and not inv[i] then
      local k = min(n, ms); inv[i] = { id = id, n = k }; n = n - k
    end
  end
  U.hud = true
  return n
end
local function invCount(id)
  local n = 0
  for i = 1, 36 do local s = G.inv[i]; if s and s.id == id then n = n + s.n end end
  return n
end
local function invTake(id, n)
  for i = 36, 1, -1 do
    local s = G.inv[i]
    if n > 0 and s and s.id == id then
      local k = min(n, s.n); s.n = s.n - k; n = n - k
      if s.n <= 0 then G.inv[i] = false end
    end
  end
  U.hud = true
end
local function takeSel(n)
  local s = G.inv[U.sel]
  if not s then return end
  s.n = s.n - (n or 1)
  if s.n <= 0 then G.inv[U.sel] = false end
  U.hud = true
end
local function gain(id, n)
  if n <= 0 then return end
  local left = invAdd(id, n)
  if left < n then toast("+" .. (n - left) .. " " .. itemName(id)) end
  if left > 0 then toast("Inventory full! " .. left .. " " .. itemName(id) .. " lost") end
end
local function freeSlot()
  for i = 1, 36 do if not G.inv[i] then return true end end
  return false
end

---------------------------------------------------------------- PLAYER / CAMERA
local function idxOf(tx, ty) return ty * LOC.w + tx + 1 end
local DIRV = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
local KEYDIR = { [17] = "up", [200] = "up", [31] = "down", [208] = "down", [30] = "left", [203] = "left",
                 [32] = "right", [205] = "right" }

local function facingTile()
  local d = DIRV[P.face] or DIRV.down
  return G.x + d[1], G.y + d[2]
end
local function setTarget()
  local tx, ty = facingTile()
  local new = nil
  if tx >= 0 and ty >= 0 and tx < LOC.w and ty < LOC.h then new = idxOf(tx, ty) end
  if new ~= tgtIdx then
    if tgtIdx then dirtyTile((tgtIdx - 1) % LOC.w, floor((tgtIdx - 1) / LOC.w)) end
    tgtIdx = new
    if new then dirtyTile(tx, ty) end
  end
end
local function updatePlayer()
  P.sx, P.sy, P.base = G.x * TS, G.y * TS - 6, G.y
  P.spr = (SP["p_" .. P.face] or SP.p_down)[P.step]
  dirtyTile(G.x, G.y - 1, 1, 2)
  setTarget()
end
local function small(L) return L.w * TS <= W and L.h * TS <= 100 end
local function camFor(L)
  if small(L) then
    camX = floor((L.w * TS - W) / 2)
    camY = floor((L.h * TS - 100) / 2)
  else
    camX = max(0, min(L.w * TS - W, G.x * TS + 3 - floor(W / 2)))
    camY = max(0, min(L.h * TS - 100, G.y * TS - 50))
  end
  camY = camY - camY % 2
  fullDirty = true
end
local function camCheck()
  if not small(LOC) then
    local sx, sy = G.x * TS - camX, G.y * TS - camY
    if sx < 30 or sx > W - 36 or sy < 24 or sy > 100 - 24 then camFor(LOC) end
  end
  local top = (G.y * TS - camY) > 70
  if top ~= U.tbTop then U.tbTop = top; fullDirty = true end
end
local function updateTint()
  local lvl = 0
  if LOC == FARM then
    local m = G.mins
    if m >= 22 * 60 then lvl = 3 elseif m >= 20 * 60 then lvl = 2 elseif m >= 18 * 60 then lvl = 1
    elseif G.weather == "rain" then lvl = "rain" end
  end
  if lvl ~= tintLevel then tintLevel = lvl; tintCache = {}; fullDirty = true end
end

local function enter(L, x, y, face)
  LOC = L
  G.loc = (L == FARM) and "farm" or "house"
  G.x, G.y = x, y
  P.face, P.step = face, 1
  tgtIdx = nil
  updatePlayer()
  camFor(L)
  camCheck()
  updateTint()
  U.keys = {}
end
local function goHouse() enter(HOUSE, HOUSE_DOOR[1], HOUSE_DOOR[2] - 1, "up") end
local function goFarm() enter(FARM, FARM_DOOR[1], FARM_DOOR[2], "down") end

local function blocked(tx, ty)
  if tx < 0 or ty < 0 or tx >= LOC.w or ty >= LOC.h then return true end
  local i = idxOf(tx, ty)
  if LOC.solid[i] then return true end
  if LOC == FARM then
    local o = G.obj[i]
    if OBJSOLID[o] then return true end
    if o == OB.CROP then local c = G.crops[i]; return c and CROPS[c.k].trellis and not c.dead end
  elseif LOC == HOUSE and G.gift and i == 6 * HOUSE.w + 3 + 1 then
    return true
  end
  return false
end

---------------------------------------------------------------- DAY CYCLE
local startNight                                  -- forward
local function spend(n)
  if n <= 0 then return end
  local was = G.energy
  G.energy = G.energy - n
  if was > 0 and G.energy <= 0 then toast("You feel exhausted...") end
  U.hud = true
  if G.energy <= -15 then startNight("You passed out from exhaustion.") end
end

local function rollWeather(season, day, year)
  if day == 1 then return "sun" end
  if season == 1 and day == 3 and year == 1 then return "rain" end
  local chance = ({ 0.18, 0.12, 0.18, 0 })[season] or 0.15
  return (math.random() < chance) and "rain" or "sun"
end

---------------------------------------------------------------- TOOLS
local function removeObj(i, tx, ty)
  G.obj[i] = OB.NONE
  G.hp[i] = nil
  G.crops[i] = nil
  dirtyTile(tx, ty)
end
local function weedHit(i, tx, ty)
  removeObj(i, tx, ty)
  if math.random() < 0.5 then gain("fiber", 1) end
  return true
end
local function treeHit(i, tx, ty, o)
  local hp = (G.hp[i] or ((o == OB.STUMP) and 5 or 10)) - 1
  if hp > 0 then G.hp[i] = hp; toast("Chop! (" .. hp .. " left)"); return true end
  if o == OB.STUMP then
    removeObj(i, tx, ty)
    gain("wood", 4)
  else
    G.obj[i] = OB.STUMP
    G.hp[i] = nil
    gain("wood", o == OB.PINE and 12 or 10)
    gain("sap", 3 + math.random(0, 2))
    rebuildCover(FARM)
    dirtyTile(tx - 1, ty - 4, 3, 5)
    toast("Timber!")
  end
  return true
end
local function pickUp(i, tx, ty, o)
  if o == OB.CHEST then
    if (G.chests[i] or 0) > 0 then toast("Empty the chest first."); return false end
    G.chests[i] = nil
    removeObj(i, tx, ty); gain("chest", 1); return true
  end
  local id = ({ [OB.FENCE] = "fence", [OB.WPATH] = "wpath", [OB.GPATH] = "gpath" })[o]
  if id then removeObj(i, tx, ty); gain(id, 1); return true end
  return false
end

local TOOL = {}
TOOL.hoe = function(i, tx, ty, o)
  local gr = gAt(FARM, i)
  if o == OB.NONE and G.soil[i] == 0 and (gr == GR.GRASS or gr == GR.SAND) and not FARM.solid[i] then
    G.soil[i] = 1; dirtyTile(tx, ty); return true
  end
  return false
end
TOOL.can = function(i, tx, ty, o)
  if gAt(FARM, i) == GR.WATER then
    if G.water >= 40 then toast("The watering can is full.") return false end
    G.water = 40; toast("Filled the watering can."); return true
  end
  if G.soil[i] >= 1 then
    if G.water <= 0 then toast("The watering can is empty. Refill it at the pond.") return false end
    G.water = G.water - 1
    if G.soil[i] == 1 then G.soil[i] = 2; dirtyTile(tx, ty) end
    return true
  end
  return false
end
TOOL.axe = function(i, tx, ty, o)
  if o == OB.TWIG then removeObj(i, tx, ty); gain("wood", 1); return true end
  if o == OB.PINE or o == OB.OAK or o == OB.STUMP then return treeHit(i, tx, ty, o) end
  if o == OB.FENCE or o == OB.CHEST then return pickUp(i, tx, ty, o) end
  return false
end
TOOL.pick = function(i, tx, ty, o)
  if o == OB.STONE then removeObj(i, tx, ty); gain("stone", 1); return true end
  if o == OB.WPATH or o == OB.GPATH or o == OB.CHEST then return pickUp(i, tx, ty, o) end
  if o == OB.NONE and G.soil[i] >= 1 then G.soil[i] = 0; dirtyTile(tx, ty); return true end
  return false
end
TOOL.scythe = function(i, tx, ty, o) return false end

local function placeOrPlant(i, tx, ty, s)
  local it = IT[s.id]
  local o = G.obj[i]
  if it.k == "seed" then
    if G.soil[i] >= 1 and o == OB.NONE then
      G.obj[i] = OB.CROP
      G.crops[i] = { k = it.crop, d = 0 }
      takeSel(1)
      dirtyTile(tx, ty)
      return true
    end
    if G.soil[i] == 0 then toast("Seeds need tilled soil (use the hoe).") end
    return false
  end
  if it.k == "place" then
    local gr = gAt(FARM, i)
    if o == OB.NONE and G.soil[i] == 0 and not FARM.solid[i] and (gr == GR.GRASS or gr == GR.SAND or gr == GR.COBBLE) then
      G.obj[i] = it.obj
      if it.obj == OB.CHEST then G.chests[i] = 0 end
      takeSel(1)
      dirtyTile(tx, ty)
      return true
    end
    return false
  end
  return false
end

-- left click / C: use what is in the selected slot on a tile
local function useAt(tx, ty)
  local s = G.inv[U.sel]
  if not s then return end
  local it = IT[s.id]
  if LOC ~= FARM then
    if it.k == "tool" then toast("Better not do that indoors.") end
    return
  end
  if tx < 0 or ty < 0 or tx >= MW or ty >= MH then return end
  local i = idxOf(tx, ty)
  local o = G.obj[i]
  if it.k == "tool" then
    local did
    if o == OB.WEED then did = weedHit(i, tx, ty)
    elseif o == OB.CROP and G.crops[i] and G.crops[i].dead then removeObj(i, tx, ty); did = true
    else did = TOOL[s.id](i, tx, ty, o) end
    if did and s.id ~= "scythe" then spend(2) end
    if did then U.hud = true end
  else
    placeOrPlant(i, tx, ty, s)
  end
end

---------------------------------------------------------------- INTERACTING
local openMenu, openChest, eatPrompt         -- forward

local function harvest(i, tx, ty)
  local c = G.crops[i]
  local cd = CROPS[c.k]
  if c.dead or c.d < cd.days then return false end
  local n = (cd.extra and math.random() < cd.extra) and 2 or 1
  local left = invAdd(c.k, n)
  if left == n then toast("Your inventory is full."); return true end
  toast("+" .. (n - left) .. " " .. cd.n)
  if cd.regrow then c.d = cd.days - cd.regrow
  else G.crops[i] = nil; G.obj[i] = OB.NONE end
  dirtyTile(tx, ty)
  return true
end

local function shipStack(k)
  local s = G.inv[k]
  if not s then return false end
  local it = IT[s.id]
  if not it.sell or it.k == "tool" then toast("You can't ship that."); return false end
  local merged = false
  local last = G.bin[#G.bin]
  if last and last.id == s.id then last.n = last.n + s.n; merged = true end
  if not merged then G.bin[#G.bin + 1] = { id = s.id, n = s.n } end
  toast("Shipped " .. s.n .. " " .. it.n)
  G.inv[k] = false
  U.hud = true
  return true
end

local function forecast()
  return "Tomorrow's forecast: " .. (G.tom == "rain" and "rain all day. Your crops will be watered!" or "clear skies and sunshine.")
end

local function interactAt(tx, ty)
  if tx < 0 or ty < 0 or tx >= LOC.w or ty >= LOC.h then return end
  local i = idxOf(tx, ty)
  local act = LOC.act[i]
  local s = G.inv[U.sel]
  if LOC == HOUSE then
    if act == "bed" then
      msg({ "Go to sleep for the night?", "", "(The day ends and your farm is saved.)" },
        { { "Yes", function() closeMsg(); startNight(nil) end }, { "No", closeMsg } })
    elseif act == "tv" then
      msg({ "The weather channel:", "", forecast() })
    elseif act == "fire" then
      msg({ "The fire crackles. It's cozy in here." })
    elseif act == "gift" and G.gift then
      G.gift = false
      dirtyTile(tx, ty)
      gain("parsnip_s", 15)
      msg({ "You open the gift box.", "", "Inside: 15 Parsnip Seeds!", "Till some soil with the hoe and plant them." })
    elseif s and IT[s.id].eat then eatPrompt()
    end
    return
  end
  if act == "door" then goHouse(); return end
  if act == "bin" then
    if s and IT[s.id].sell and IT[s.id].k ~= "tool" then shipStack(U.sel) else openMenu("bin") end
    return
  end
  if act == "shop" then openMenu("shop"); return end
  if act == "mail" then
    if G.mail then
      G.mail = false
      msg({ "Dear " .. G.farmer .. ",", "",
        "Welcome to Stargate Valley! The old farm is yours now.",
        "There's a gift box by your bed. Clear some ground, plant,",
        "water your crops every day and drop what you grow in the",
        "shipping bin next to the house - it's collected overnight.",
        "The seed stall down the east path sells more seeds.", "",
        "                                        - The Mayor" }, nil, "Mail")
    else
      msg({ "There's no new mail." })
    end
    return
  end
  local o = G.obj[i]
  if o == OB.CHEST then openChest(i); return end
  if o == OB.CROP and G.crops[i] and harvest(i, tx, ty) then return end
  if s and (IT[s.id].k == "seed" or IT[s.id].k == "place") then
    if placeOrPlant(i, tx, ty, s) then return end
  end
  if s and IT[s.id].eat then eatPrompt() end
end

eatPrompt = function()
  local s = G.inv[U.sel]
  if not s or not IT[s.id].eat then return end
  local it = IT[s.id]
  msg({ "Eat " .. it.n .. "?  (+" .. it.eat .. " energy)" }, {
    { "Yes", function()
        G.energy = min(G.maxE, G.energy + it.eat)
        takeSel(1)
        closeMsg()
        toast("+" .. it.eat .. " energy")
      end },
    { "No", closeMsg } })
end

---------------------------------------------------------------- SAVING
local function doSave(cb)
  if U.saving then return end
  U.saving = true
  U.saveNote = "Saving..."
  sendSave(U.farmId, G, function(ok, why, size)
    U.saving = false
    U.saveNote = ok and string.format("Saved  (%.1f KB on the storage server)", (size or 0) / 1024) or ("Not saved: " .. tostring(why))
    U.full, U.menuDirty = true, true
    if cb then cb(ok, why) end
  end)
end

startNight = function(passedOut)
  U.menu, U.msgBox, U.held = nil, nil, nil
  local lines, total = {}, 0
  for _, s in ipairs(G.bin) do
    local v = (IT[s.id].sell or 0) * s.n
    total = total + v
    lines[#lines + 1] = { itemName(s.id) .. " x" .. s.n, v }
  end
  G.gold, G.earned, G.bin = G.gold + total, G.earned + total, {}
  for i, c in pairs(G.crops) do
    if not c.dead and G.soil[i] == 2 and c.d < CROPS[c.k].days then c.d = c.d + 1 end
  end
  for i = 1, MW * MH do if G.soil[i] == 2 then G.soil[i] = 1 end end
  local late = G.mins > 24 * 60
  G.day = G.day + 1
  if G.day > 28 then
    G.day, G.season = 1, G.season + 1
    if G.season > 4 then G.season, G.year = 1, G.year + 1 end
    if G.season ~= 1 then for _, c in pairs(G.crops) do c.dead = true end end
  end
  G.weather = G.tom
  local td, ts = G.day + 1, G.season
  if td > 28 then td, ts = 1, ts % 4 + 1 end
  G.tom = rollWeather(ts, td, G.year)
  if G.weather == "rain" then
    for i = 1, MW * MH do if G.soil[i] == 1 then G.soil[i] = 2 end end
  end
  -- a few weeds grow overnight
  for _ = 1, math.random(1, 4) do
    local x, y = math.random(4, MW - 5), math.random(17, MH - 4)
    local i = y * MW + x + 1
    if gAt(FARM, i) == GR.GRASS and G.obj[i] == OB.NONE and G.soil[i] == 0 then G.obj[i] = OB.WEED end
  end
  local frac = passedOut and 0.5 or (late and 0.75 or 1)
  G.energy = floor(G.maxE * frac)
  G.mins = 360
  G.loc, G.x, G.y, G.face = "house", BED_SPOT[1], BED_SPOT[2], "down"
  U.summary = { lines = lines, total = total, passedOut = passedOut, late = late }
  U.mode = "summary"
  U.full = true
  doSave(function() U.full = true end)
end

---------------------------------------------------------------- CHEST
openChest = function(i)
  U.chest = { idx = i, items = nil, wait = "Opening the chest..." }
  U.menu = "chest"
  U.menuDirty, U.keys = true, {}
  netReq("CGET", U.farmId, i, nil, function(ok, data)
    if not U.chest or U.chest.idx ~= i then return end
    if ok then
      U.chest.items, U.chest.wait = unpackStacks(data, 36), nil
    else
      U.chest.wait = "Couldn't open it: " .. tostring(data)
    end
    U.menuDirty = true
  end)
end
local function closeChest()
  local ch = U.chest
  if not ch or not ch.items then U.chest, U.menu = nil, nil; fullDirty = true; return end
  local n = 0
  for k = 1, 36 do if ch.items[k] then n = n + 1 end end
  ch.wait = "Putting the lid back on..."
  U.menuDirty = true
  netReq("CPUT", U.farmId, ch.idx, packStacks(ch.items, 36), function(ok, why)
    if ok then
      G.chests[ch.idx] = n
      U.chest, U.menu = nil, nil
      fullDirty, U.hud = true, true
    else
      ch.wait = nil
      msg({ "The storage server didn't take the chest contents:", tostring(why), "",
        "Keep the chest open and try again in a moment." },
        { { "Try again", function() closeMsg(); closeChest() end }, { "Keep open", closeMsg } })
    end
  end)
end
local function moveStack(from, k, to, n)
  local s = from[k]
  if not s then return end
  n = min(n or s.n, s.n)
  local ms = maxStack(s.id)
  local left = n
  for j = 1, 36 do
    local d = to[j]
    if left > 0 and d and d.id == s.id and d.n < ms then local m = min(left, ms - d.n); d.n = d.n + m; left = left - m end
  end
  for j = 1, 36 do
    if left > 0 and not to[j] then local m = min(left, ms); to[j] = { id = s.id, n = m }; left = left - m end
  end
  s.n = s.n - (n - left)
  if s.n <= 0 then from[k] = false end
end

---------------------------------------------------------------- MENUS
openMenu = function(m)
  U.menu, U.menuDirty, U.keys = m, true, {}
  if m == "inv" and U.tab ~= "exit" then U.tab = U.tab or "inv" end
end
local function closeMenu()
  if U.menu == "chest" then closeChest(); return end
  if U.held then
    local left = invAdd(U.held.id, U.held.n)
    if left > 0 then toast(left .. " " .. itemName(U.held.id) .. " didn't fit and was lost.") end
    U.held = nil
  end
  U.menu = nil
  fullDirty, U.hud = true, true
end

-- inventory grid clicks (pick up / put down / swap, like the real thing)
local function invClick(k, right)
  local s, h = G.inv[k], U.held
  if right then
    if s and (not h or (h.id == s.id and h.n < maxStack(h.id))) then
      if h then h.n = h.n + 1 else U.held = { id = s.id, n = 1 } end
      s.n = s.n - 1
      if s.n <= 0 then G.inv[k] = false end
    end
  elseif h then
    if not s then G.inv[k], U.held = h, nil
    elseif s.id == h.id and s.n < maxStack(s.id) then
      local m = min(h.n, maxStack(s.id) - s.n); s.n = s.n + m; h.n = h.n - m
      if h.n <= 0 then U.held = nil end
    else G.inv[k], U.held = h, s end
  elseif s then
    U.held, G.inv[k] = s, false
  end
  U.menuDirty = true
end

local leaveGame                                     -- forward
local MENU = (function()
local function gridLabel(x, y, s) txt(x, y, s, UI.text, UI.panel) end

local function drawInvTab(x0, y0)
  for r = 0, 2 do slotRow(x0, y0 + r * 5, G.inv, r * 12 + 1, (r == 0) and U.sel or nil, invClick) end
  local y = y0 + 16
  box(x0 - 4, y, 104, 1, UI.panel2)
  -- portrait
  box(x0, y + 2, 16, 14, UI.slot2)
  box(x0 + 1, y + 2, 14, 13, 0x8FC2F2)
  box(x0 + 1, y + 12, 14, 3, 0x6CB33C)
  drawSprite(x0 + 2, y + 3, SP.p_down[1], 6, 12, 0x8FC2F2, 2)
  txtW(x0, y + 17, 16, G.farmer, UI.text, UI.panel, "center")
  local ix = x0 + 22
  txt(ix, y + 3, G.name .. " Farm", UI.text, UI.panel)
  txt(ix, y + 6, "Current Funds:  " .. commas(G.gold) .. "g", UI.text, UI.panel)
  txt(ix, y + 8, "Total Earnings: " .. commas(G.earned) .. "g", UI.text, UI.panel)
  txt(ix, y + 10, "Energy:         " .. max(0, floor(G.energy)) .. " / " .. G.maxE, UI.text, UI.panel)
  txt(ix, y + 12, SEASON[G.season] .. " " .. G.day .. ", Year " .. G.year .. "  (" .. WDAY[(G.day - 1) % 7 + 1] .. ")", UI.text, UI.panel)
  -- trash can
  local tx = x0 + 88
  drawSprite(tx, y + 3, SP.i_trash, 6, 6, UI.panel, 1)
  txt(tx - 1, y + 7, "Trash", UI.dim, UI.panel)
  region(tx - 1, y + 2, 9, 6, function()
    if U.held then
      if IT[U.held.id].k == "tool" then toast("You'll need that!") else U.held = nil end
      U.menuDirty = true
    end
  end)
  local hold = U.held and ("Holding: " .. itemName(U.held.id) .. (U.held.n > 1 and (" x" .. U.held.n) or "") ..
    "   (click a slot to put it down)") or "Click an item to pick it up. Right click takes one."
  txtW(ix, y + 15, 70, hold, U.held and UI.red or UI.dim, UI.panel)
  local sel = G.inv[U.sel]
  if sel then txtW(ix, y + 17, 70, itemName(sel.id) .. " - " .. (IT[sel.id].d or ""), UI.dim, UI.panel) end
end

local function drawCraftTab(x0, y0)
  gridLabel(x0, y0, "Crafting - click Craft to make one.")
  for k, r in ipairs(RECIPES) do
    local y = y0 + 2 + (k - 1) * 5
    box(x0, y, 7, 4, UI.slot)
    drawIcon(x0 + 1, y, IT[r.id].ic, UI.slot)
    txt(x0 + 10, y, itemName(r.id), UI.text, UI.panel)
    local can = true
    local need = {}
    for _, nd in ipairs(r.need) do
      local have = invCount(nd[1])
      if have < nd[2] then can = false end
      need[#need + 1] = nd[2] .. " " .. itemName(nd[1]) .. " (you have " .. have .. ")"
    end
    txt(x0 + 10, y + 1, "Needs " .. concat(need, ", "), can and UI.green or UI.red, UI.panel)
    txt(x0 + 10, y + 2, IT[r.id].d or "", UI.dim, UI.panel)
    btn(x0 + 80, y, 14, "Craft", function()
      if not freeSlot() and invCount(r.id) == 0 then toast("No room in your inventory."); return end
      for _, nd in ipairs(r.need) do invTake(nd[1], nd[2]) end
      invAdd(r.id, r.n)
      toast("Crafted " .. itemName(r.id))
      U.menuDirty = true
    end, can)
  end
end

local function drawExitTab(x0, y0)
  local bx = x0 + 28
  gridLabel(bx, y0, "Stargate Valley " .. VERSION .. "  -  farm '" .. G.name .. "' of " .. tostring(ctx.player()))
  btn(bx, y0 + 3, 40, "Save Game", function() doSave() ; U.menuDirty = true end, not U.saving)
  btn(bx, y0 + 7, 40, "Back to Lymanos (pause)", function() closeMenu(); ctx.minimize() end)
  btn(bx, y0 + 11, 40, "Exit to Title", function() leaveGame(false) end)
  btn(bx, y0 + 15, 40, "Quit Stargate Valley", function() leaveGame(true) end)
  txtW(x0, y0 + 20, 96, U.saveNote or "Your farm is saved every night when you sleep, or with Save Game.",
    (U.saveNote and U.saveNote:find("^Not")) and UI.red or UI.dim, UI.panel, "center")
  txtW(x0, y0 + 22, 96, "Time is stopped while this menu is open.", UI.dim, UI.panel, "center")
end

local function drawInvMenu()
  local px, py, pw, ph = 24, 4, 112, 42
  local tabs = { { "inv", "Inventory" }, { "craft", "Crafting" }, { "exit", "Exit Game" } }
  local tx = px + 4
  for _, t in ipairs(tabs) do
    local on = U.tab == t[1]
    local w = unicode.len(t[2]) + 4
    box(tx, 1, w, 3, UI.edge)
    box(tx + 1, 1, w - 2, 3, on and UI.panel or UI.panel2)
    txtW(tx + 1, 2, w - 2, t[2], on and UI.text or UI.dim, on and UI.panel or UI.panel2, "center")
    region(tx, 1, w, 3, function() U.tab = t[1]; U.menuDirty = true end)
    tx = tx + w + 1
  end
  panel(px, py, pw, ph)
  local x0, y0 = px + 8, py + 2
  if U.tab == "craft" then drawCraftTab(x0, y0)
  elseif U.tab == "exit" then drawExitTab(x0, y0)
  else drawInvTab(x0, y0) end
  txtW(px + 4, py + ph - 2, pw - 8, "E or Esc: close", UI.dim, UI.panel, "right")
end

local function drawChestMenu()
  local px, py, pw, ph = 24, 3, 112, 44
  panel(px, py, pw, ph)
  local x0 = px + 8
  local ch = U.chest
  gridLabel(x0, py + 1, "Chest")
  if ch.items then
    for r = 0, 2 do
      slotRow(x0, py + 3 + r * 5, ch.items, r * 12 + 1, nil, function(k, right)
        moveStack(ch.items, k, G.inv, right and 1 or nil); U.menuDirty = true
      end)
    end
  end
  txtW(x0, py + 17, 96, ch.wait or "", UI.dim, UI.panel, "center")
  gridLabel(x0, py + 19, "Inventory   (click: move the stack  -  right click: move one)")
  for r = 0, 2 do
    slotRow(x0, py + 21 + r * 5, G.inv, r * 12 + 1, nil, function(k, right)
      if ch.items then moveStack(G.inv, k, ch.items, right and 1 or nil); U.menuDirty = true end
    end)
  end
  btn(px + pw - 22, py + ph - 4, 16, "Close", closeChest, not (ch.wait and not ch.items and ch.wait:find("^Open")))
end

local function drawShopMenu()
  local px, py, pw, ph = 14, 2, 118, 46
  panel(px, py, pw, ph)
  local x0 = px + 4
  txt(x0, py + 1, "Seed Stall", UI.text, UI.panel)
  txtW(px + pw - 30, py + 1, 24, "Gold: " .. commas(G.gold) .. "g", UI.text, UI.panel, "right")
  txt(x0, py + 2, "Click: buy one   Right click: buy five", UI.dim, UI.panel)
  for k, id in ipairs(SHOPLIST) do
    local col, row = (k - 1) % 2, floor((k - 1) / 2)
    local x, y = x0 + col * 56, py + 4 + row * 5
    local it = IT[id]
    local afford = G.gold >= it.buy
    box(x, y, 54, 4, afford and UI.slot or UI.slot2)
    drawIcon(x + 1, y, it.ic, afford and UI.slot or UI.slot2)
    txt(x + 9, y, it.n, UI.text, afford and UI.slot or UI.slot2)
    txt(x + 9, y + 1, it.buy .. "g", afford and UI.text or UI.red, afford and UI.slot or UI.slot2)
    txt(x + 9, y + 2, CROPS[it.crop].days .. " days" .. (CROPS[it.crop].regrow and ", regrows" or "") ..
      "  -  sells for " .. CROPS[it.crop].sell .. "g", UI.dim, afford and UI.slot or UI.slot2)
    local function buy(n)
      n = min(n, floor(G.gold / it.buy))
      if n <= 0 then toast("Not enough money."); U.menuDirty = true; return end
      local left = invAdd(id, n)
      local got = n - left
      if got <= 0 then toast("No room in your inventory.") else G.gold = G.gold - got * it.buy; toast("Bought " .. got .. " " .. it.n) end
      U.menuDirty = true
    end
    region(x, y, 54, 4, function() buy(1) end, function() buy(5) end)
  end
  local gy = py + 25
  gridLabel(x0, gy, "Sell to the stall: click an item to sell the whole stack")
  for r = 0, 2 do
    slotRow(x0 + 8, gy + 2 + r * 5, G.inv, r * 12 + 1, nil, function(k)
      local s = G.inv[k]
      if not s then return end
      local it = IT[s.id]
      if not it.sell or it.k == "tool" then toast("The stall doesn't buy that.")
      else
        local v = it.sell * s.n
        G.gold, G.earned = G.gold + v, G.earned + v
        toast("Sold " .. s.n .. " " .. it.n .. " for " .. v .. "g")
        G.inv[k] = false
      end
      U.menuDirty = true
    end)
  end
  btn(px + pw - 20, py + ph - 4, 14, "Close", closeMenu)
end

local function drawBinMenu()
  local px, py, pw, ph = 24, 5, 112, 38
  panel(px, py, pw, ph)
  local x0 = px + 8
  txt(x0, py + 1, "Shipping Bin", UI.text, UI.panel)
  txt(x0, py + 2, "Click an item to ship it. Everything in the bin is sold overnight.", UI.dim, UI.panel)
  local total, parts = 0, {}
  for _, s in ipairs(G.bin) do
    local v = (IT[s.id].sell or 0) * s.n
    total = total + v
    parts[#parts + 1] = itemName(s.id) .. " x" .. s.n
  end
  txtW(x0, py + 4, 96, #parts == 0 and "The bin is empty." or ("In the bin: " .. concat(parts, ", ")), UI.text, UI.panel)
  txtW(x0, py + 5, 96, "Worth " .. commas(total) .. "g tomorrow morning.", UI.green, UI.panel)
  btn(x0, py + 7, 24, "Take back last", function()
    local last = G.bin[#G.bin]
    if not last then return end
    local left = invAdd(last.id, last.n)
    if left == 0 then G.bin[#G.bin] = nil else last.n = left; toast("No room for all of it.") end
    U.menuDirty = true
  end, #G.bin > 0)
  for r = 0, 2 do
    slotRow(x0, py + 12 + r * 5, G.inv, r * 12 + 1, nil, function(k) shipStack(k); U.menuDirty = true end)
  end
  btn(px + pw - 20, py + ph - 4, 14, "Close", closeMenu)
end

return { inv = drawInvMenu, chest = drawChestMenu, shop = drawShopMenu, bin = drawBinMenu }
end)()

---------------------------------------------------------------- HUD
local function toolbarRow() return U.tbTop and 1 or 45 end

local function drawHUD()
  REG = {}
  -- toolbar
  local ty = toolbarRow()
  panel(30, ty, 101, 6)
  slotRow(33, ty + 1, G.inv, 1, U.sel, function(k) U.sel = k; U.tip = { t = computer.uptime() }; U.hud = true end)
  -- clock
  panel(134, 1, 26, 8)
  local night = G.mins >= 18 * 60
  drawIcon(137, 2, night and SP.i_dial_night or (G.weather == "rain" and SP.i_rain or SP.i_dial_day), UI.panel)
  txtW(144, 2, 13, WDAY[(G.day - 1) % 7 + 1] .. ". " .. G.day, UI.text, UI.panel, "right")
  txtW(144, 3, 13, SEASON[G.season] .. (G.weather == "rain" and "  Rain" or "  Sunny"), UI.dim, UI.panel, "right")
  txtW(144, 4, 13, fmtClock(G.mins), UI.text, UI.panel, "right")
  box(136, 5, 22, 1, UI.panel2)
  box(137, 6, 20, 1, 0x7A3A12)
  txt(137, 6, "G", UI.gold, 0x7A3A12)
  txtW(139, 6, 17, commas(G.gold), 0xFFE6A0, 0x7A3A12, "right")
  -- energy bar
  panel(152, 30, 7, 15)
  txt(155, 31, "E", UI.text, UI.panel)
  local f = max(0, min(1, G.energy / G.maxE))
  local col = (f > 0.5) and 0x3CC43C or (f > 0.2 and 0xE8C020 or 0xE03020)
  local nfill = floor(f * 11 + 0.5)
  box(154, 32, 3, 11, 0x3A2010)
  if nfill > 0 then box(154, 43 - nfill, 3, nfill, col) end
  -- tooltip of the selected item
  local s = G.inv[U.sel]
  if U.tip and s then
    local name = itemName(s.id)
    local extra = kindName(s.id)
    if s.id == "can" then extra = "Water: " .. G.water .. "/40" end
    local w = max(unicode.len(name), unicode.len(extra)) + 6
    local x = min(W - w, max(1, 33 + (U.sel - 1) * 8 - 2))
    local y = U.tbTop and (ty + 6) or (ty - 4)
    panel(x, y, w, 4)
    txt(x + 3, y + 1, name, UI.text, UI.panel)
    txt(x + 3, y + 2, extra, UI.dim, UI.panel)
  end
  -- messages
  for k, t in ipairs(U.toasts) do
    local y = 43 - (k - 1) * 2
    if U.tbTop then y = 49 - (k - 1) * 2 end
    local w = unicode.len(t.s) + 4
    box(2, y, w, 1, UI.edge2)
    txt(3, y, " " .. t.s .. " ", UI.dark, UI.panel)
  end
end

---------------------------------------------------------------- MESSAGE BOX
local function drawMsg()
  local m = U.msgBox
  U.msgReg = {}
  local w = 60
  for _, l in ipairs(m.lines) do w = max(w, unicode.len(l) + 8) end
  w = min(W - 4, w)
  local h = #m.lines + 7
  local x, y = floor((W - w) / 2) + 1, floor((H - h) / 2)
  panel(x, y, w, h)
  if m.title then txtW(x + 3, y + 1, w - 6, m.title, UI.red, UI.panel) end
  for i, l in ipairs(m.lines) do txtW(x + 4, y + 1 + i, w - 8, l, UI.text, UI.panel) end
  local bw = 16
  local total = #m.buttons * bw + (#m.buttons - 1) * 2
  local bx = x + floor((w - total) / 2)
  local saveReg = REG
  REG = U.msgReg
  for _, b in ipairs(m.buttons) do
    btn(bx, y + h - 4, bw, b[1], b[2] or closeMsg)
    bx = bx + bw + 2
  end
  REG = saveReg
end

local SCR = (function()
---------------------------------------------------------------- TITLE ART
local CLOUDS = { { 20, 14, 11, 4 }, { 62, 8, 14, 4 }, { 118, 16, 12, 4 }, { 150, 6, 9, 3 } }
local TREES = { { 2, 64 }, { 16, 70 }, { 30, 66 } }
local function logoBit(x, y)
  local lines = { { "STARGATE", 8 }, { "VALLEY", 27 } }
  for _, L in ipairs(lines) do
    local word, y0 = L[1], L[2]
    local x0 = floor((W - (#word * 12 - 2)) / 2)
    local ly = y - y0
    if ly >= 0 and ly < 14 then
      local lx = x - x0
      if lx >= 0 and lx < #word * 12 then
        local k = floor(lx / 12)
        local gx = lx - k * 12
        if gx < 10 then
          local gl = GLYPH[ssub(word, k + 1, k + 1)]
          if gl and ssub(gl, floor(ly / 2) * 5 + floor(gx / 2) + 1, floor(ly / 2) * 5 + floor(gx / 2) + 1) == "1" then
            return ly
          end
        end
      end
    end
  end
  return nil
end
local function titlePixel(x, y)
  if y >= 6 and y <= 42 and x >= 30 and x <= 130 then
    local ly = logoBit(x, y)
    if ly then return blend(0xFFE070, 0xE07A1A, ly / 13) end
    if logoBit(x - 1, y) or logoBit(x + 1, y) or logoBit(x, y - 1) or logoBit(x, y + 1)
       or logoBit(x - 1, y - 1) or logoBit(x + 1, y + 1) then return 0x4A1E08 end
  end
  for _, t in ipairs(TREES) do
    local lx, ly2 = x - t[1], y - t[2]
    if lx >= 0 and ly2 >= 0 and lx < BIG.pine.w and ly2 < BIG.pine.h then
      local v = byte(BIG.pine.s, ly2 * BIG.pine.w + lx + 1)
      if v ~= 46 then return PAL[v] end
    end
  end
  local hx, hy = x - 98, y - 56
  if hx >= 0 and hy >= 0 and hx < BIG.house.w and hy < BIG.house.h then
    local v = byte(BIG.house.s, hy * BIG.house.w + hx + 1)
    if v ~= 46 then return PAL[v] end
  end
  if y >= 96 then return 0xE9B55E end
  if y > 74 + 3 * math.sin(x / 11) then return (hash(x, y) % 9 == 0) and 0x84C84C or 0x5AA032 end
  if y > 66 + 5 * math.sin(x / 17 + 1) then return 0x6CB33C end
  if y > 58 + 6 * math.sin(x / 23 + 2) then return 0x8CCB6A end
  for _, cl in ipairs(CLOUDS) do
    local dx, dy = (x - cl[1]) / cl[3], (y - cl[2]) / cl[4]
    if dx * dx + dy * dy <= 1 then return (dy > 0.35) and 0xD8E8F8 or 0xFFFFFF end
  end
  return blend(0x5AA8EC, 0xC8E8FF, y / 60)
end

---------------------------------------------------------------- SCREENS
local function playerSprite() return SP.p_down[1] end

local function background()
  if U.bg then renderFn(titlePixel, 1, 1, W, H); U.bg = false end
end
local function drawTitle()
  background()
  local by = 23
  btn(44, by, 22, "New Farm", function() U.mode = "new"; U.form = { farm = "", farmer = tostring(ctx.player()), hair = 1, shirt = 1, focus = "farm" }; U.full = true end)
  btn(69, by, 22, "Load Farm", function()
    U.mode, U.farms, U.status, U.full = "list", nil, "Asking the storage server for your farms...", true
    netReq("LIST", nil, nil, nil, function(ok, data)
      if ok then
        local okd, list = pcall(serialization.unserialize, data or "{}")
        U.farms = (okd and type(list) == "table") and list or {}
        U.status = #U.farms == 0 and "You have no farms yet - start a New Farm." or ""
      else
        U.status = tostring(data)
      end
      U.full = true
    end)
  end)
  btn(94, by, 22, "Exit", function() ctx.quit() end)
  local srv = NET.online == true and ("storage server online" .. (NET.addr and (" (" .. NET.addr:sub(1, 8) .. ")") or ""))
    or (NET.online == false and "storage server NOT answering" or "looking for the storage server...")
  txtW(1, H, W, "  Playing as " .. tostring(ctx.player()) .. "   ·   " .. srv .. "   ·   v" .. VERSION .. " ",
    0xFFFFFF, 0x3A2A1A)
end

local function bigPanel(x, y, w, h)
  background()
  panel(x, y, w, h)
end

local function startPlay(id, g)
  G = g
  U.farmId = id
  PAL[byte("a")] = (HAIRS[g.hair] or HAIRS[1])[2]
  PAL[byte("z")] = (SHIRTS[g.shirt] or SHIRTS[1])[2]
  rebuildCover(FARM)
  rebuildCover(HOUSE)
  U.mode, U.menu, U.msgBox, U.held, U.sel = "play", nil, nil, nil, 1
  U.toasts, U.tip, U.saveNote = {}, nil, nil
  P.face, P.step = g.face, 1
  enter(g.loc == "farm" and FARM or HOUSE, g.x, g.y, g.face)
  U.full, U.hud = true, true
end

local function drawList()
  bigPanel(20, 4, 120, 40)
  txt(25, 5, "Your farms", UI.text, UI.panel)
  txtW(60, 5, 75, "saved on the storage server for " .. tostring(ctx.player()), UI.dim, UI.panel, "right")
  local list = U.farms or {}
  for k, f in ipairs(list) do
    local y = 7 + (k - 1) * 5
    if y > 36 then break end
    box(24, y, 112, 4, UI.slot)
    txt(26, y, tostring(f.name) .. " Farm", UI.text, UI.slot)
    txt(26, y + 1, "Farmer " .. tostring(f.farmer) .. "   ·   " .. (SEASON[tonumber(f.season) or 1] or "?") .. " " ..
      tostring(f.day) .. ", Year " .. tostring(f.year) .. "   ·   " .. commas(tonumber(f.gold) or 0) .. "g", UI.dim, UI.slot)
    local pl = tonumber(f.played) or 0
    txt(26, y + 2, string.format("Played %dh %02dm", floor(pl / 3600), floor(pl % 3600 / 60)), UI.dim, UI.slot)
    btn(100, y, 16, "Load", function()
      U.mode, U.busyText, U.full = "busy", "Loading " .. tostring(f.name) .. " Farm...", true
      loadSave(f.id, function(ok, data)
        if not ok then U.mode, U.status, U.full = "list", "Couldn't load: " .. tostring(data), true; return end
        local g, why = decodeFarm(data)
        if not g then U.mode, U.status, U.full = "list", "Couldn't load: " .. tostring(why), true; return end
        startPlay(f.id, g)
      end)
    end)
    btn(118, y, 16, "Delete", function()
      msg({ "Delete " .. tostring(f.name) .. " Farm for good?", "", "Everything on it, its chests too, is removed",
        "from the storage server. This can't be undone." }, {
        { "Delete", function()
            closeMsg()
            U.status = "Deleting..."
            netReq("DEL", f.id, nil, nil, function(ok, why)
              if ok then
                for i, v in ipairs(U.farms or {}) do if v == f then table.remove(U.farms, i); break end end
                U.status = "Deleted " .. tostring(f.name) .. " Farm."
              else U.status = "Couldn't delete: " .. tostring(why) end
              U.full = true
            end)
          end },
        { "Keep it", closeMsg } })
    end)
  end
  txtW(24, 39, 90, U.status or "", (U.status or ""):find("^Couldn") and UI.red or UI.dim, UI.panel)
  btn(118, 39, 16, "Back", function() U.mode, U.full = "title", true end)
end

local function drawNew()
  bigPanel(28, 4, 104, 40)
  local f = U.form
  txt(33, 5, "A new farm", UI.text, UI.panel)
  local function field(id, y, label, value)
    txt(34, y, label, UI.text, UI.panel)
    local on = f.focus == id
    box(54, y, 40, 1, on and 0xFFFFE0 or UI.slot)
    txt(55, y, fit(value .. (on and "_" or ""), 38), UI.text, on and 0xFFFFE0 or UI.slot)
    region(54, y, 40, 1, function() f.focus = id; U.full = true end)
  end
  field("farm", 9, "Farm name:", f.farm)
  field("farmer", 12, "Farmer name:", f.farmer)
  local function cycler(y, label, list, key)
    txt(34, y, label, UI.text, UI.panel)
    btn(54, y - 1, 5, "<", function() f[key] = (f[key] - 2) % #list + 1; U.full = true end)
    txtW(60, y, 14, list[f[key]][1], UI.text, UI.panel, "center")
    btn(75, y - 1, 5, ">", function() f[key] = f[key] % #list + 1; U.full = true end)
  end
  cycler(16, "Hair:", HAIRS, "hair")
  cycler(20, "Shirt:", SHIRTS, "shirt")
  PAL[byte("a")], PAL[byte("z")] = HAIRS[f.hair][2], SHIRTS[f.shirt][2]
  box(100, 8, 18, 15, 0x8FC2F2)
  box(100, 20, 18, 3, 0x6CB33C)
  drawSprite(103, 9, playerSprite(), 6, 12, 0x8FC2F2, 2)
  txt(34, 26, "The farm is saved on the storage server under your Lymanos name", UI.dim, UI.panel)
  txt(34, 27, "(" .. tostring(ctx.player()) .. "). You start with 500g, your tools and the old farmhouse.", UI.dim, UI.panel)
  txtW(34, 30, 90, U.status or "", UI.red, UI.panel)
  btn(34, 37, 20, "Create", function()
    local name = f.farm:gsub("^%s+", ""):gsub("%s+$", "")
    local who = f.farmer:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then U.status = "Give your farm a name first."; U.full = true; return end
    if who == "" then who = tostring(ctx.player()) end
    U.mode, U.busyText, U.status, U.full = "busy", "Creating " .. name .. " Farm...", "", true
    netReq("NEW", name, who, nil, function(ok, id)
      if not ok then U.mode, U.status, U.full = "new", tostring(id), true; return end
      local g = newFarm(name, who, f.hair, f.shirt, math.random(1, 2147483646))
      g.tom = rollWeather(1, 2, 1)
      sendSave(id, g, function(ok2, why)
        if not ok2 then U.mode, U.status, U.full = "new", "Couldn't save the new farm: " .. tostring(why), true; return end
        startPlay(id, g)
        msg({ "Welcome to " .. name .. " Farm, " .. who .. "!", "",
          "WASD walks, left click uses the tool in your hand, right click",
          "interacts. E opens your inventory, Esc the menu. 1-9 pick a slot.",
          "Check the mailbox and the gift box by your bed." }, nil, "Stargate Valley")
      end)
    end)
  end)
  btn(108, 37, 20, "Back", function() U.mode, U.status, U.full = "title", "", true end)
end

local function drawBusy()
  bigPanel(45, 18, 70, 9)
  txtW(48, 21, 64, U.busyText, UI.text, UI.panel, "center")
  txtW(48, 23, 64, "talking to the storage server on port " .. PORT .. "...", UI.dim, UI.panel, "center")
end

local function drawSummary()
  box(1, 1, W, H, UI.night)
  local s = U.summary
  local w, h = 80, 14 + #s.lines
  local x, y = floor((W - w) / 2), 4
  panel(x, y, w, min(H - 6, h))
  local d = SEASON[G.season] .. " " .. G.day .. ", Year " .. G.year
  txtW(x + 3, y + 1, w - 6, s.passedOut or (s.late and "You stayed up late and went to bed tired." or "You slept well."),
    s.passedOut and UI.red or UI.text, UI.panel, "center")
  txtW(x + 3, y + 3, w - 6, "Shipped yesterday:", UI.text, UI.panel)
  if #s.lines == 0 then txtW(x + 5, y + 4, w - 10, "nothing", UI.dim, UI.panel) end
  for i, l in ipairs(s.lines) do
    if y + 3 + i > H - 12 then break end
    txtW(x + 5, y + 3 + i, w - 24, l[1], UI.text, UI.panel)
    txtW(x + w - 18, y + 3 + i, 14, commas(l[2]) .. "g", UI.text, UI.panel, "right")
  end
  local yy = y + 5 + max(1, #s.lines)
  txtW(x + 5, yy, w - 10, "Total:  " .. commas(s.total) .. "g", UI.green, UI.panel, "right")
  txtW(x + 3, yy + 2, w - 6, "Good morning! It's " .. WDAY[(G.day - 1) % 7 + 1] .. ", " .. d .. "  -  " ..
    (G.weather == "rain" and "raining today." or "sunny today."), UI.text, UI.panel, "center")
  local note = U.saving and "Saving your farm..." or (U.saveNote or "")
  txtW(x + 3, yy + 4, w - 6, note, (note:find("^Not") and UI.red) or UI.dim, UI.panel, "center")
  if not U.saving then
    local failed = (U.saveNote or ""):find("^Not")
    if failed then
      btn(x + floor(w / 2) - 30, yy + 6, 26, "Try again", function() doSave(); U.full = true end)
      btn(x + floor(w / 2) + 4, yy + 6, 26, "Play without saving", function()
        U.mode = "play"; enter(HOUSE, BED_SPOT[1], BED_SPOT[2], "down"); U.full = true end)
    else
      btn(x + floor(w / 2) - 10, yy + 6, 20, "OK", function()
        U.mode = "play"; enter(HOUSE, BED_SPOT[1], BED_SPOT[2], "down"); U.full = true end)
    end
  end
end

return { title = drawTitle, list = drawList, new = drawNew, busy = drawBusy, summary = drawSummary }
end)()

local function drawPlay()
  if U.menu then
    if fullDirty or U.full then
      renderRect(1, 1, W, H); drawHUD(); fullDirty = false; U.menuDirty = true
    end
    if U.menuDirty then
      REG = {}
      MENU[U.menu]()
      U.menuDirty = false
      U.msgDirty = true
    end
    if U.msgBox and U.msgDirty then drawMsg(); U.msgDirty = false end
    DIRTY = {}
    return
  end
  local any = fullDirty or U.full or #DIRTY > 0
  if fullDirty or U.full then renderRect(1, 1, W, H)
  else for _, d in ipairs(DIRTY) do renderRect(d[1], d[2], d[3], d[4]) end end
  DIRTY = {}
  fullDirty = false
  if any or U.hud then drawHUD(); U.hud = false end
  if U.msgBox and (any or U.msgDirty) then drawMsg(); U.msgDirty = false end
end

local function drawScreen()
  local m = U.mode
  if m == "play" then drawPlay(); U.full = false; U.drawnMode = m; return end
  if not U.full then return end
  if m ~= U.drawnMode then U.bg, U.drawnMode = true, m end
  REG = {}
  SCR[m]()
  if U.msgBox then drawMsg() end
  U.full = false
end

---------------------------------------------------------------- LEAVING
leaveGame = function(quit)
  local function go()
    G = nil
    LOC = nil
    FARM.cover, HOUSE.cover = {}, {}
    U.menu, U.msgBox, U.held, U.chest = nil, nil, nil, nil
    if quit then ctx.quit() else U.mode, U.full = "title", true end
  end
  msg({ "Save your farm before leaving?", "", "If you don't, you go back to the last save",
    "(the last night you slept, or the last Save Game)." }, {
    { "Save", function()
        closeMsg()
        U.menu = nil
        U.mode, U.busyText, U.full = "busy", "Saving " .. G.name .. " Farm...", true
        doSave(function(ok, why)
          if ok then go()
          else
            U.mode = "play"
            msg({ "The farm could not be saved:", tostring(why) },
              { { "Leave anyway", function() closeMsg(); go() end }, { "Stay", closeMsg } })
          end
        end)
      end },
    { "Don't save", function() closeMsg(); go() end },
    { "Cancel", closeMsg } })
end

---------------------------------------------------------------- UPDATE
local function tryMove(dir)
  local d = DIRV[dir]
  local turned = P.face ~= dir
  P.face = dir
  local nx, ny = G.x + d[1], G.y + d[2]
  if LOC == HOUSE and dir == "down" and G.x == HOUSE_DOOR[1] and G.y == HOUSE_DOOR[2] then goFarm(); return end
  if LOC == FARM and LOC.act[idxOf(nx, ny)] == "door" then goHouse(); return end
  if blocked(nx, ny) then
    if turned then updatePlayer() end
    if LOC == HOUSE and LOC.act[idxOf(nx, ny)] == "bed" then U.keys = {}; interactAt(nx, ny) end
    return
  end
  dirtyTile(G.x, G.y - 1, 1, 2)
  G.x, G.y = nx, ny
  P.step = 3 - P.step
  updatePlayer()
  camCheck()
end

local function heldDir()
  if U.lastDir then
    for code, d in pairs(KEYDIR) do if d == U.lastDir and U.keys[code] then return d end end
  end
  for code, d in pairs(KEYDIR) do if U.keys[code] then return d end end
  return nil
end

local function updatePlay(dt, up)
  G.played = G.played + dt
  G.mins = G.mins + dt * (1200 / DAY_SECONDS)
  local ten = floor(G.mins / 10)
  if ten ~= U.lastTen then U.lastTen = ten; U.hud = true end
  updateTint()
  if G.mins >= 26 * 60 then startNight("It's 2:00 am... you passed out."); return end
  local dir = heldDir()
  local stepT = (G.energy <= 0) and 0.22 or 0.12
  if dir and up - U.lastStep >= stepT then
    U.lastStep = up
    tryMove(dir)
  elseif not dir and P.step ~= 1 and up - U.lastStep > 0.2 then
    P.step = 1; updatePlayer()
  end
end

---------------------------------------------------------------- INPUT
local function mapClick(x, y, right)
  local tx = floor((x - 1 + camX) / TS)
  local ty = floor(((y - 1) * 2 + camY) / TS)
  local dx, dy = tx - G.x, ty - G.y
  local tgx, tgy
  if (dx ~= 0 or dy ~= 0) and abs(dx) <= 1 and abs(dy) <= 1 then
    tgx, tgy = tx, ty
    local face = (dy ~= 0 and dx == 0) and (dy < 0 and "up" or "down") or (dx < 0 and "left" or "right")
    if face ~= P.face then P.face = face; updatePlayer() end
  else
    if dx ~= 0 or dy ~= 0 then
      local face = (abs(dx) >= abs(dy)) and (dx < 0 and "left" or "right") or (dy < 0 and "up" or "down")
      if face ~= P.face then P.face = face; updatePlayer() end
    end
    tgx, tgy = facingTile()
  end
  if right then interactAt(tgx, tgy) else useAt(tgx, tgy) end
end

local API = {}

function API.draw()
  U.full, fullDirty, U.hud, U.menuDirty, U.bg, U.msgDirty = true, true, true, true, true, true
  U.keys = {}
  U.lastUp = computer.uptime()
  drawScreen()
end

function API.frame(visible)
  netPump()
  local up = computer.uptime()
  local dt = min(0.25, max(0, up - U.lastUp))
  U.lastUp = up
  if not visible then return end
  if U.mode == "play" and G then
    if not U.menu and not U.msgBox then updatePlay(dt, up) end
    local n = #U.toasts
    while n > 0 and up - U.toasts[n].t > 3.5 do table.remove(U.toasts); n = n - 1; U.expired = true end
    if U.tip and up - U.tip.t > 2.5 then U.tip = nil; U.expired = true end
    if U.expired then
      U.expired = false
      if not U.menu then
        dirtyScreen(1, 34, 60, 50); dirtyScreen(1, 1, 60, 12); dirtyScreen(1, 37, W, 44); dirtyScreen(1, 7, W, 11)
        U.hud = true
      end
    end
  elseif U.mode == "title" and NET.online == nil and not netBusy() and not U.pinged then
    U.pinged = true
    netReq("FIND", nil, nil, nil, function() U.full = true end)
  end
  drawScreen()
end

function API.touch(x, y, button)
  local right = button == 1
  if U.msgBox then
    for i = #U.msgReg, 1, -1 do
      local r = U.msgReg[i]
      if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then r.fn(); break end
    end
    return
  end
  if U.mode == "play" and G then
    if U.menu then
      if not hitRegion(x, y, right) and U.menu == "inv" and U.held and U.tab == "inv" then
        -- clicked outside the grid with an item in hand: put it back
        local left = invAdd(U.held.id, U.held.n); U.held = nil
        if left > 0 then toast(left .. " lost") end
        U.menuDirty = true
      end
      return
    end
    if hitRegion(x, y, right) then return end
    mapClick(x, y, right)
    return
  end
  hitRegion(x, y, right)
end

function API.scroll(x, y, dir)
  if U.mode == "play" and G and not U.menu and not U.msgBox then
    U.sel = (U.sel - 1 - dir) % 12 + 1
    U.tip = { t = computer.uptime() }
    U.hud = true
  end
end

function API.key(ch, code)
  if U.msgBox then
    local b = U.msgBox.buttons
    if code == 28 or code == 156 then (b[1][2] or closeMsg)()
    elseif code == 1 then (b[#b][2] or closeMsg)() end
    return
  end
  if U.mode == "new" then
    local f = U.form
    if code == 15 then f.focus = (f.focus == "farm") and "farmer" or "farm"
    elseif code == 14 then f[f.focus] = f[f.focus]:sub(1, -2)
    elseif code == 28 or code == 156 then f.focus = (f.focus == "farm") and "farmer" or "farm"
    elseif ch and ch >= 32 and ch < 127 and #f[f.focus] < 20 then
      local c = string.char(ch)
      if c:match("[%w %-'_%.]") then f[f.focus] = f[f.focus] .. c end
    end
    U.full = true
    return
  end
  if U.mode ~= "play" or not G then
    if code == 1 and (U.mode == "list" or U.mode == "new") then U.mode, U.full = "title", true end
    return
  end
  if U.menu then
    if code == 1 or code == 18 or code == 23 then closeMenu() end
    return
  end
  local d = KEYDIR[code]
  if d then
    U.keys[code] = true
    if U.lastDir ~= d then U.lastDir = d end
    if U.lastStep < computer.uptime() - 0.12 then U.lastStep = computer.uptime(); tryMove(d) end
    return
  end
  if code == 18 or code == 23 then U.tab = (U.tab == "exit") and "inv" or U.tab; openMenu("inv")
  elseif code == 1 then U.tab = "exit"; openMenu("inv")
  elseif code == 46 or code == 57 then useAt(facingTile())
  elseif code == 45 or code == 33 then interactAt(facingTile())
  elseif code >= 2 and code <= 13 then
    U.sel = code - 1
    U.tip = { t = computer.uptime() }
    U.hud = true
  end
end

function API.keyUp(ch, code)
  U.keys[code] = nil
end

function API.net(from, kind, rid, ok, payload, extra) netMsg(from, kind, rid, ok, payload, extra) end
function API.fast() return true end
function API.debug()
  return { G = G, U = U, P = P, FARM = FARM, HOUSE = HOUSE, NET = NET, cam = function() return camX, camY end }
end
function API.label()
  return " ♣ Stargate Valley"
end
function API.shutdown()
  G, LOC = nil, nil
  FARM.cover, HOUSE.cover = {}, {}
end

return API
