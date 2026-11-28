--[[
  lymsheets.lua  -  Spreadsheets for Lymanos (Google Sheets style)

  Lymanos loads this file when you open Spreadsheets and drops it from memory
  when you close the app (X), so it costs no RAM while you don't use it.
  Put it next to lymanos.lua:   /home/lymsheets.lua

  What it does:
    * Start page: a new blank spreadsheet, Import from Google Sheets, and your
      recent spreadsheets (saved in /home/sheets/, one .lsh file each).
    * Grid, formula bar, menus, toolbar and sheet tabs like Google Sheets.
    * Formulas: 144 Google Sheets functions (SUM, IF, VLOOKUP, XLOOKUP, SUMIFS,
      INDEX/MATCH, TEXT, DATE..., FILTER, SORT, UNIQUE, SPLIT, SEQUENCE,
      ARRAYFORMULA ...), arrays that spill into the cells below/right, sheet
      references ('Sheet 2'!A1:B5), $absolute refs, circular-reference detection.
    * Import: the sheet must be shared as "Anyone with the link". It is
      downloaded as .xlsx (formulas + values + formats), unpacked here in Lua
      and every formula is recalculated. A formula that uses a function this
      app doesn't have keeps the value Google calculated (marked with a dot).

  RAM: only one spreadsheet is in memory at a time; cells are stored in a few
  flat tables (no table per cell); the import unpacks the file in 2 KB pieces
  and reads the XML piece by piece, so even big sheets don't need the whole
  file in memory. Lua 5.2 and 5.3.
]]

local A = ...                         -- what Lymanos hands over (drawing, dialogs, clock, ...)
local unicode, computer, filesystem = A.unicode, A.computer, A.filesystem
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local huge = math.huge

-- cells live in flat tables keyed by row * 1024 + column
local MAXR, MAXC = 50000, 1000
local function key(r, c) return r * 1024 + c end
local function keyRC(k) return floor(k / 1024), k % 1024 end

local function colName(c)
  local s = ""
  while c > 0 do
    local m = (c - 1) % 26
    s = string.char(65 + m) .. s
    c = floor((c - 1) / 26)
  end
  return s
end
local function colNum(s)
  local n = 0
  s = s:upper()
  for i = 1, #s do n = n * 26 + (s:byte(i) - 64) end
  return n
end

-- values: number | string | boolean | BLANK | error { e = "#DIV/0!", msg = ... } |
--         range { rg = true, sh, r1, c1, r2, c2 } | array { ar = true, nr, nc, [i] = value }
local ERR = {}
for _, e in ipairs({ "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#N/A", "#NUM!", "#NULL!", "#ERROR!" }) do ERR[e] = { e = e } end
local BLANK = { blank = true }        -- an empty cell
local OMIT = { omit = true }          -- a left-out function argument: IF(A1,,2)
local function isErr(v) return type(v) == "table" and v.e ~= nil end
local function isMulti(v) return type(v) == "table" and (v.rg or v.ar) ~= nil end
local function err(e, msg) return { e = e, msg = msg } end

-- dates: serial days since 1899-12-30 (like Google Sheets and Excel)
local function civil(z)              -- days since 1970-01-01 -> y, m, d
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
local function daysOf(y, m, d)       -- y, m, d -> days since 1970-01-01
  if m <= 2 then y = y - 1 end
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = m > 2 and m - 3 or m + 9
  local doy = floor((153 * mp + 2) / 5) + d - 1
  return era * 146097 + yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy - 719468
end
local function serialOf(y, m, d) return daysOf(y, m, d) + 25569 end
local function ymdOf(serial) return civil(floor(serial) - 25569) end
local function monthLen(y, m) return daysOf(m == 12 and y + 1 or y, m == 12 and 1 or m + 1, 1) - daysOf(y, m, 1) end

-- "1,234.5" / "$12" / "-3e4" / "45%" -> number (nil if it isn't one). Used by formulas and typing.
local function parseNum(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  local neg, pct = false, false
  if s:sub(1, 1) == "(" and s:sub(-1) == ")" then neg, s = true, s:sub(2, -2) end
  if s:sub(1, 1) == "-" then neg, s = not neg, s:sub(2) elseif s:sub(1, 1) == "+" then s = s:sub(2) end
  s = s:gsub("^%$", "")
  if s:sub(1, 1) == "-" then neg, s = not neg, s:sub(2) end
  if s:sub(-1) == "%" then pct, s = true, s:sub(1, -2) end
  if s:find(",", 1, true) then                  -- 1,234,567.89: groups of three
    local ip, rest = s:match("^([%d,]+)(.*)$")
    if not ip or not ip:match("^%d%d?%d?,") or ip:find(",,", 1, true) or ip:sub(-1) == "," then return nil end
    for g in ip:gmatch(",(%d*)") do if #g ~= 3 then return nil end end
    s = ip:gsub(",", "") .. rest
  end
  if not (s:match("^%d+%.?%d*$") or s:match("^%.%d+$") or s:match("^%d+%.?%d*[eE][%+%-]?%d+$") or s:match("^%.%d+[eE][%+%-]?%d+$")) then
    return nil
  end
  local n = tonumber(s)
  if not n then return nil end
  if pct then n = n / 100 end
  return neg and -n or n
end

-- number -> text the way Sheets writes it without a format (up to 10 significant digits on screen)
local function numText(n, sig)
  if n ~= n then return "#NUM!" end
  if n == floor(n) and abs(n) < 1e15 then return string.format("%.0f", n) end
  local s = string.format("%." .. (sig or 10) .. "g", n)
  if s:find("e") then
    local m, e = s:match("^(.-)e(.*)$")
    if m:find("%.") then m = m:gsub("0+$", ""):gsub("%.$", "") end
    return m .. "E" .. (tonumber(e) >= 0 and "+" or "-") .. string.format("%02d", abs(tonumber(e)))
  end
  if s:find("%.") then s = s:gsub("0+$", ""):gsub("%.$", "") end
  return s
end

local WB = nil          -- the open workbook: { name, file, sheets = {...}, cur, styles = {...} }
local FMT, ENG          -- number formats, formula engine (below)

local function newSheet(name)
  return { name = name, val = {}, fml = {}, sty = {}, cg = {}, fix = {}, cv = {}, sp = {}, so = {},
           colW = {}, rows = 1000, cols = 26, frR = 0, frC = 0, maxR = 0, maxC = 0 }
end
local function sheetByName(name)
  local low = name:lower()
  for _, sh in ipairs(WB.sheets) do if sh.name:lower() == low then return sh end end
end
local function grow(sh, r, c)
  if r > sh.maxR then sh.maxR = r end
  if c > sh.maxC then sh.maxC = c end
  if r > sh.rows then sh.rows = r end
  if c > sh.cols then sh.cols = c end
end

--------------------------------------------------------------- FORMULA ENGINE
ENG = (function()
local GEN = 0                          -- calculation generation (bumped by every recalc)
local BUSY = setmetatable({}, { __mode = "k" })   -- [sheet] = { [key] = true } while being calculated
local ctxSh, ctxR, ctxC                -- the cell whose formula is being calculated
local spillChanged = false
local CIRC = err("#REF!", "Circular dependency detected.")

---------------------------------------------------------------- tokens
-- every character of the formula belongs to exactly one token, so the text
-- can be rebuilt (and references rewritten) without losing spaces or case
local ERRLIT = { "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#N/A", "#NUM!", "#NULL!", "#ERROR!" }

local function refTail(s, p) local ch = s:sub(p, p); return not ch:match("[%w_%(%.!:%$]") end

-- a reference or range starting at position j (no sheet prefix), or nil
local function refAt(s, j)
  -- A1:B2
  local st, en, x1, c1, y1, r1, x2, c2, y2, r2 = s:find("^(%$?)(%a%a?%a?)(%$?)(%d+):(%$?)(%a%a?%a?)(%$?)(%d+)", j)
  if st and refTail(s, en + 1) then
    return { "rng", r1 = tonumber(r1), c1 = colNum(c1), r2 = tonumber(r2), c2 = colNum(c2),
             ar1 = y1 == "$", ac1 = x1 == "$", ar2 = y2 == "$", ac2 = x2 == "$", stop = en }
  end
  -- A2:A (open below)
  st, en, x1, c1, y1, r1, x2, c2 = s:find("^(%$?)(%a%a?%a?)(%$?)(%d+):(%$?)(%a%a?%a?)", j)
  if st and refTail(s, en + 1) and not s:sub(en + 1, en + 1):match("[%d%$]") then
    return { "rng", r1 = tonumber(r1), c1 = colNum(c1), r2 = nil, c2 = colNum(c2),
             ar1 = y1 == "$", ac1 = x1 == "$", ac2 = x2 == "$", stop = en }
  end
  -- A:B (whole columns)
  st, en, x1, c1, x2, c2 = s:find("^(%$?)(%a%a?%a?):(%$?)(%a%a?%a?)", j)
  if st and refTail(s, en + 1) and not s:sub(en + 1, en + 1):match("[%d%$]") then
    return { "rng", r1 = 1, c1 = colNum(c1), r2 = nil, c2 = colNum(c2), col = true,
             ac1 = x1 == "$", ac2 = x2 == "$", stop = en }
  end
  -- 1:3 (whole rows)
  st, en, y1, r1, y2, r2 = s:find("^(%$?)(%d+):(%$?)(%d+)", j)
  if st and refTail(s, en + 1) then
    return { "rng", r1 = tonumber(r1), c1 = 1, r2 = tonumber(r2), c2 = nil, row = true,
             ar1 = y1 == "$", ar2 = y2 == "$", stop = en }
  end
  -- A1
  st, en, x1, c1, y1, r1 = s:find("^(%$?)(%a%a?%a?)(%$?)(%d+)", j)
  if st and refTail(s, en + 1) then
    return { "ref", r = tonumber(r1), c = colNum(c1), ar = y1 == "$", ac = x1 == "$", stop = en }
  end
end

local function tokenize(s)
  local t, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      local a, b = s:find("^%s+", i)
      t[#t + 1] = { "ws", s:sub(a, b) }; i = b + 1
    elseif c == '"' then
      local j, buf = i + 1, {}
      while true do
        local q = s:find('"', j, true)
        if not q then return nil, "Text is missing its closing quote." end
        buf[#buf + 1] = s:sub(j, q - 1)
        if s:sub(q + 1, q + 1) == '"' then buf[#buf + 1] = '"'; j = q + 2 else j = q + 1; break end
      end
      t[#t + 1] = { "str", s:sub(i, j - 1), v = table.concat(buf) }; i = j
    elseif c == "#" then
      local hitE
      for _, e in ipairs(ERRLIT) do if s:sub(i, i + #e - 1):upper() == e then hitE = e; break end end
      if not hitE then return nil, "Unknown error value." end
      t[#t + 1] = { "err", s:sub(i, i + #hitE - 1), v = hitE }; i = i + #hitE
    else
      local sheet, j = nil, i
      if c == "'" then                              -- 'My sheet'!A1
        local k, buf = i + 1, {}
        while true do
          local q = s:find("'", k, true)
          if not q then return nil, "Sheet name is missing its closing quote." end
          buf[#buf + 1] = s:sub(k, q - 1)
          if s:sub(q + 1, q + 1) == "'" then buf[#buf + 1] = "'"; k = q + 2 else k = q + 1; break end
        end
        if s:sub(k, k) ~= "!" then return nil, "Expected ! after the sheet name." end
        sheet, j = table.concat(buf), k + 1
      else
        local p, q = s:find("^[%a_][%w_%.]*!", i)
        if p then sheet, j = s:sub(p, q - 1), q + 1 end
      end
      local tk = refAt(s, j)
      if tk then
        tk.sheet = sheet
        tk[2] = s:sub(i, tk.stop)
        t[#t + 1] = tk; i = tk.stop + 1
      elseif sheet then
        return nil, "Bad reference after " .. sheet .. "!"
      elseif c:match("[%d%.]") then
        local a, b = s:find("^%d*%.?%d*", i)
        local num = s:sub(a, b)
        if not num:find("%d") then return nil, "Unexpected ." end
        local ea, eb = s:find("^[eE][%+%-]?%d+", b + 1)
        if ea then b = eb end
        t[#t + 1] = { "num", s:sub(i, b), v = tonumber(s:sub(i, b)) }; i = b + 1
      elseif c:match("[%a_]") then
        local a, b = s:find("^[%a_][%w_%.]*", i)
        local word = s:sub(a, b)
        local up = word:upper()
        local nx = s:find("[^%s]", b + 1)
        if nx and s:sub(nx, nx) == "(" then
          up = up:gsub("^_XLFN%.", ""):gsub("^_XLWS%.", "")
          t[#t + 1] = { "fn", word, v = up }
        elseif up == "TRUE" or up == "FALSE" then
          t[#t + 1] = { "bool", word, v = up == "TRUE" }
        else
          t[#t + 1] = { "name", word }
        end
        i = b + 1
      else
        local two = s:sub(i, i + 1)
        if two == "<=" or two == ">=" or two == "<>" then
          t[#t + 1] = { "op", two, v = two }; i = i + 2
        elseif c:match("[%+%-%*/%^&=<>%%]") then
          t[#t + 1] = { "op", c, v = c }; i = i + 1
        elseif c:match("[%(%),;{}]") then
          t[#t + 1] = { c, c }; i = i + 1
        else
          return nil, "Unexpected character " .. c
        end
      end
    end
  end
  return t
end

local function quoteSheet(name)
  if name:match("^[%a_][%w_]*$") and not name:match("^%a%a?%a?%d+$") then return name end
  return "'" .. name:gsub("'", "''") .. "'"
end
local function refText(tk)
  local pre = tk.sheet and (quoteSheet(tk.sheet) .. "!") or ""
  local function cell(c, r, ac, ar)
    return (c and ((ac and "$" or "") .. colName(c)) or "") .. (r and ((ar and "$" or "") .. r) or "")
  end
  if tk[1] == "ref" then return pre .. cell(tk.c, tk.r, tk.ac, tk.ar) end
  if tk.col then return pre .. cell(tk.c1, nil, tk.ac1) .. ":" .. cell(tk.c2, nil, tk.ac2) end
  if tk.row then return pre .. cell(nil, tk.r1, nil, tk.ar1) .. ":" .. cell(nil, tk.r2, nil, tk.ar2) end
  return pre .. cell(tk.c1, tk.r1, tk.ac1, tk.ar1) .. ":" .. cell(tk.c2, tk.r2, tk.ac2, tk.ar2)
end

-- rebuild a formula, letting fn(token) replace any reference (return new text or nil)
local function rewrite(src, fn)
  local toks = tokenize(src)
  if not toks then return src end
  local out = {}
  for i, tk in ipairs(toks) do
    if (tk[1] == "ref" or tk[1] == "rng") and fn then out[i] = fn(tk) or tk[2] else out[i] = tk[2] end
  end
  return table.concat(out)
end

-- what Sheets does when you press Enter: function names and references in capitals
local function normalize(src)
  local toks = tokenize(src)
  if not toks then return src end
  local out = {}
  for i, tk in ipairs(toks) do
    local k = tk[1]
    if k == "ref" or k == "rng" then out[i] = refText(tk)
    elseif k == "fn" or k == "bool" then out[i] = tk[2]:upper()
    else out[i] = tk[2] end
  end
  return table.concat(out)
end

---------------------------------------------------------------- parser
-- AST nodes: {"n",v} {"s",v} {"b",v} {"e",err} {"r",sheet,r,c} {"g",sheet,r1,c1,r2,c2}
--            {"f",NAME,args...} {"o",op,a,b} {"u",a} (minus) {"p",a} (percent) {"a",nr,nc,...} {"x"} (left out)
local T, pos
local expr
local function peek() return T[pos] end
local function take() pos = pos + 1; return T[pos - 1] end
local function isOp(tk, ...)
  if not tk or tk[1] ~= "op" then return false end
  for i = 1, select("#", ...) do if tk.v == select(i, ...) then return true end end
  return false
end
local function primary()
  local tk = take()
  if not tk then error("The formula ends too early.", 0) end
  local k = tk[1]
  if k == "num" then return { "n", tk.v }
  elseif k == "str" then return { "s", tk.v }
  elseif k == "bool" then return { "b", tk.v }
  elseif k == "err" then return { "e", ERR[tk.v] }
  elseif k == "ref" then return { "r", tk.sheet, tk.r, tk.c }
  elseif k == "rng" then return { "g", tk.sheet, tk.r1, tk.c1, tk.r2, tk.c2 }
  elseif k == "name" then return { "e", err("#NAME?", "Unknown range name: '" .. tk[2] .. "'.") }
  elseif k == "fn" then
    local node = { "f", tk.v }
    take()                                              -- "("
    if peek() and peek()[1] == ")" then take(); return node end
    while true do
      local nx = peek()
      if nx and (nx[1] == "," or nx[1] == ")") then node[#node + 1] = { "x" } else node[#node + 1] = expr() end
      local sep = take()
      if not sep then error("Missing ) after " .. tk.v .. "(", 0) end
      if sep[1] == ")" then break end
      if sep[1] ~= "," then error("Expected , or ) in " .. tk.v, 0) end
    end
    return node
  elseif k == "(" then
    local e = expr()
    local rp = take()
    if not rp or rp[1] ~= ")" then error("Missing )", 0) end
    return e
  elseif k == "{" then                                  -- {1,2;3,4}
    local rows, row = {}, {}
    while true do
      row[#row + 1] = expr()
      local sep = take()
      if not sep then error("Missing }", 0) end
      if sep[1] == ";" then rows[#rows + 1] = row; row = {}
      elseif sep[1] == "}" then rows[#rows + 1] = row; break
      elseif sep[1] ~= "," then error("Bad array literal", 0) end
    end
    local nc = #rows[1]
    local node = { "a", #rows, nc }
    for _, r in ipairs(rows) do
      if #r ~= nc then error("Array rows must be the same length", 0) end
      for _, v in ipairs(r) do node[#node + 1] = v end
    end
    return node
  end
  error("Unexpected " .. tostring(tk[2]), 0)
end
local function postfix()
  local e = primary()
  while isOp(peek(), "%") do take(); e = { "p", e } end
  return e
end
local function unary()
  if isOp(peek(), "-") then take(); return { "u", unary() } end
  if isOp(peek(), "+") then take(); return unary() end
  return postfix()
end
local function binary(next, ...)
  local ops = { ... }
  return function()
    local e = next()
    while isOp(peek(), table.unpack(ops)) do
      local op = take().v
      e = { "o", op, e, next() }
    end
    return e
  end
end
local pow = binary(unary, "^")
local mul = binary(pow, "*", "/")
local add = binary(mul, "+", "-")
local cat = binary(add, "&")
expr = binary(cat, "=", "<>", "<", ">", "<=", ">=")

local function parse(src)
  local toks, terr = tokenize(src)
  if not toks then return nil, terr end
  T, pos = {}, 1
  for _, tk in ipairs(toks) do if tk[1] ~= "ws" then T[#T + 1] = tk end end
  if #T == 0 then return nil, "The formula is empty." end
  local ok, res = pcall(expr)
  if ok and pos <= #T then ok, res = false, "Unexpected " .. tostring(T[pos][2]) end
  T = nil
  if not ok then return nil, tostring(res) end
  return res
end

local ASTC = setmetatable({}, { __mode = "v" })     -- parsed formulas; Lua may drop them when RAM is short
local function getAst(src)
  local a = ASTC[src]
  if a then return a end
  local ast, perr = parse(src)
  if not ast then ast = { "e", err("#ERROR!", "Formula parse error. " .. tostring(perr)) } end
  ASTC[src] = ast
  return ast
end

---------------------------------------------------------------- values
local cellValue, ev     -- forward

local function mkRange(sh, r1, c1, r2, c2)
  r2 = r2 or max(r1, sh.maxR)
  c2 = c2 or max(c1, sh.maxC)
  if r2 < r1 then r1, r2 = r2, r1 end
  if c2 < c1 then c1, c2 = c2, c1 end
  return { rg = true, sh = sh, r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
end
local function dims(v)
  if v.rg then return v.r2 - v.r1 + 1, v.c2 - v.c1 + 1 end
  return v.nr, v.nc
end
local function get(v, i, j)
  if v.rg then return cellValue(v.sh, v.r1 + i - 1, v.c1 + j - 1) end
  local x = v[(i - 1) * v.nc + j]
  if x == nil then return BLANK end
  return x
end
local function mkArray(nr, nc) return { ar = true, nr = nr, nc = nc } end
local function first(v)
  if isMulti(v) then
    local nr, nc = dims(v)
    if nr == 0 or nc == 0 then return BLANK end
    return get(v, 1, 1)
  end
  return v
end
-- call fn(value, i, j) for every cell of a range / array, or once for a plain value
local function each(v, fn)
  if isMulti(v) then
    local nr, nc = dims(v)
    for i = 1, nr do for j = 1, nc do
      local stop = fn(get(v, i, j), i, j)
      if stop then return stop end
    end end
  else
    return fn(v, 1, 1)
  end
end

local function toNum(v)
  local t = type(v)
  if t == "number" then return v end
  if t == "boolean" then return v and 1 or 0 end
  if v == BLANK or v == OMIT or v == nil then return 0 end
  if t == "string" then
    if v == "" then return 0 end
    local n = parseNum(v)
    if not n and FMT then n = FMT.parseDate(v) end
    if n then return n end
    return err("#VALUE!", "Expects number values, but '" .. v:sub(1, 30) .. "' is text and cannot be coerced to a number.")
  end
  if isErr(v) then return v end
  if isMulti(v) then return toNum(first(v)) end
  return ERR["#VALUE!"]
end
local function toStr(v)
  local t = type(v)
  if t == "string" then return v end
  if t == "number" then return numText(v, 15) end
  if t == "boolean" then return v and "TRUE" or "FALSE" end
  if isMulti(v) then return toStr(first(v)) end
  if isErr(v) then return v.e end
  return ""
end
local function toBool(v)
  local t = type(v)
  if t == "boolean" then return v end
  if t == "number" then return v ~= 0 end
  if v == BLANK or v == OMIT or v == nil then return false end
  if t == "string" then
    local u = v:upper()
    if u == "TRUE" then return true elseif u == "FALSE" or u == "" then return false end
    return err("#VALUE!", "'" .. v:sub(1, 30) .. "' is text and cannot be coerced to a boolean.")
  end
  if isErr(v) then return v end
  if isMulti(v) then return toBool(first(v)) end
  return ERR["#VALUE!"]
end

local RANK = { number = 1, string = 2, boolean = 3 }
local function compare(a, b)
  if a == BLANK or a == OMIT then a = type(b) == "string" and "" or (type(b) == "boolean" and false or 0) end
  if b == BLANK or b == OMIT then b = type(a) == "string" and "" or (type(a) == "boolean" and false or 0) end
  local ta, tb = type(a), type(b)
  if ta ~= tb then return (RANK[ta] or 9) < (RANK[tb] or 9) and -1 or 1 end
  if ta == "string" then a, b = a:lower(), b:lower()
  elseif ta == "boolean" then a, b = a and 1 or 0, b and 1 or 0 end
  if a < b then return -1 elseif a > b then return 1 end
  return 0
end

local function bad(n) return n ~= n or n == huge or n == -huge end

local function arith(op, x, y)
  if isErr(x) then return x end
  if isErr(y) then return y end
  if op == "&" then return toStr(x) .. toStr(y) end
  if op == "=" or op == "<>" or op == "<" or op == ">" or op == "<=" or op == ">=" then
    local c = compare(x, y)
    if op == "=" then return c == 0 elseif op == "<>" then return c ~= 0
    elseif op == "<" then return c < 0 elseif op == ">" then return c > 0
    elseif op == "<=" then return c <= 0 else return c >= 0 end
  end
  local a, b = toNum(x), toNum(y)
  if isErr(a) then return a end
  if isErr(b) then return b end
  local r
  if op == "+" then r = a + b
  elseif op == "-" then r = a - b
  elseif op == "*" then r = a * b
  elseif op == "/" then
    if b == 0 then return err("#DIV/0!", "Function DIVIDE parameter 2 cannot be zero.") end
    r = a / b
  elseif op == "^" then
    if a == 0 and b < 0 then return ERR["#DIV/0!"] end
    if a < 0 and b ~= floor(b) then return ERR["#NUM!"] end
    r = a ^ b
  end
  if bad(r) then return ERR["#NUM!"] end
  return r
end

-- apply fn element by element when any argument is a range / array (broadcasting 1-wide ones)
local function lift(fn, args, n)
  local nr, nc = 1, 1
  for i = 1, n do
    local a = args[i]
    if isMulti(a) then
      local r, c = dims(a)
      if r > nr then nr = r end
      if c > nc then nc = c end
    end
  end
  local out = mkArray(nr, nc)
  local tmp = {}
  for i = 1, nr do for j = 1, nc do
    local bad2 = false
    for k = 1, n do
      local a = args[k]
      if isMulti(a) then
        local r, c = dims(a)
        local ii, jj = r == 1 and 1 or i, c == 1 and 1 or j
        if ii > r or jj > c then bad2 = true; tmp[k] = ERR["#N/A"] else tmp[k] = get(a, ii, jj) end
      else
        tmp[k] = a
      end
    end
    out[(i - 1) * nc + j] = fn(table.unpack(tmp, 1, n))
  end end
  return out
end

local function binop(op, a, b)
  if isMulti(a) or isMulti(b) then return lift(function(x, y) return arith(op, x, y) end, { a, b }, 2) end
  return arith(op, a, b)
end
local function neg(a)
  if isMulti(a) then return lift(neg, { a }, 1) end
  local n = toNum(a)
  if isErr(n) then return n end
  return -n
end
local function pct(a)
  if isMulti(a) then return lift(pct, { a }, 1) end
  local n = toNum(a)
  if isErr(n) then return n end
  return n / 100
end

---------------------------------------------------------------- functions
local F, LAZY, AGG = {}, {}, {}
local function opt(v, d) if v == nil or v == OMIT then return d end return v end
local function argc(n, lo, hi, name)
  if n < lo or (hi and n > hi) then
    return err("#N/A", "Wrong number of arguments to " .. name .. ". Expected " ..
      (hi == lo and lo or (lo .. (hi and (" to " .. hi) or " or more"))) .. " arguments, but got " .. n .. ".")
  end
end
-- scalar function: fn receives plain values; ranges are worked element by element
local function S(name, lo, hi, fn)
  F[name] = function(args, n)
    local e = argc(n, lo, hi, name)
    if e then return e end
    for i = 1, n do
      if isMulti(args[i]) then return lift(fn, args, n) end
    end
    return fn(table.unpack(args, 1, n))
  end
end
-- numbers out of every argument: ranges give their numbers (text, TRUE/FALSE and empty
-- cells are skipped), typed values are converted. Returns list or error.
local function numbers(args, n)
  local out = {}
  for i = 1, n do
    local a = args[i]
    if isMulti(a) then
      local e = each(a, function(v)
        if type(v) == "number" then out[#out + 1] = v elseif isErr(v) then return v end
      end)
      if e then return nil, e end
    elseif a ~= OMIT then
      local v = toNum(a)
      if isErr(v) then return nil, v end
      out[#out + 1] = v
    end
  end
  return out
end
local function aggregate(name, fn)
  AGG[name] = true
  F[name] = function(args, n)
    local list, e = numbers(args, n)
    if not list then return e end
    return fn(list)
  end
end
local function N(v) local x = toNum(v); if isErr(x) then return nil, x end return x end
local function round(x, d)
  local m = 10 ^ (d or 0)
  local y = abs(x) * m
  local r = floor(y + 0.5 + 1e-9 * max(1, y))
  return (x < 0 and -r or r) / m
end

-- math ------------------------------------------------------------------
aggregate("SUM", function(l) local s = 0 for _, v in ipairs(l) do s = s + v end return s end)
aggregate("PRODUCT", function(l) local s = 1 for _, v in ipairs(l) do s = s * v end return #l > 0 and s or 0 end)
aggregate("AVERAGE", function(l)
  if #l == 0 then return err("#DIV/0!", "Evaluation of function AVERAGE caused a divide by zero error.") end
  local s = 0 for _, v in ipairs(l) do s = s + v end return s / #l
end)
aggregate("MIN", function(l) if #l == 0 then return 0 end local m = huge for _, v in ipairs(l) do if v < m then m = v end end return m end)
aggregate("MAX", function(l) if #l == 0 then return 0 end local m = -huge for _, v in ipairs(l) do if v > m then m = v end end return m end)
aggregate("MEDIAN", function(l)
  if #l == 0 then return ERR["#NUM!"] end
  table.sort(l)
  local h = floor(#l / 2)
  if #l % 2 == 1 then return l[h + 1] end
  return (l[h] + l[h + 1]) / 2
end)
aggregate("SUMSQ", function(l) local s = 0 for _, v in ipairs(l) do s = s + v * v end return s end)
local function variance(l, sample)
  local n = #l
  if n < (sample and 2 or 1) then return nil end
  local s = 0 for _, v in ipairs(l) do s = s + v end
  local m, q = s / n, 0
  for _, v in ipairs(l) do q = q + (v - m) ^ 2 end
  return q / (sample and n - 1 or n)
end
aggregate("VAR", function(l) return variance(l, true) or ERR["#DIV/0!"] end)
aggregate("VARP", function(l) return variance(l, false) or ERR["#DIV/0!"] end)
aggregate("STDEV", function(l) local v = variance(l, true) return v and math.sqrt(v) or ERR["#DIV/0!"] end)
aggregate("STDEVP", function(l) local v = variance(l, false) return v and math.sqrt(v) or ERR["#DIV/0!"] end)
F["VAR.S"], F["VAR.P"], F["STDEV.S"], F["STDEV.P"] = F.VAR, F.VARP, F.STDEV, F.STDEVP
AGG["VAR.S"], AGG["VAR.P"], AGG["STDEV.S"], AGG["STDEV.P"] = true, true, true, true

AGG.COUNT = true
F.COUNT = function(args, n)
  local c = 0
  for i = 1, n do
    local a = args[i]
    if isMulti(a) then each(a, function(v) if type(v) == "number" then c = c + 1 end end)
    elseif a ~= OMIT and not isErr(toNum(a)) and a ~= BLANK then c = c + 1 end
  end
  return c
end
AGG.COUNTA = true
F.COUNTA = function(args, n)
  local c = 0
  for i = 1, n do
    local a = args[i]
    if isMulti(a) then each(a, function(v) if v ~= BLANK then c = c + 1 end end)
    elseif a ~= OMIT then c = c + 1 end
  end
  return c
end
AGG.COUNTBLANK = true
F.COUNTBLANK = function(args, n)
  local c = 0
  each(args[1], function(v) if v == BLANK or v == "" then c = c + 1 end end)
  return c
end
AGG.COUNTUNIQUE = true
F.COUNTUNIQUE = function(args, n)
  local seen, c = {}, 0
  for i = 1, n do each(args[i], function(v)
    if v ~= BLANK and v ~= OMIT and not isErr(v) then
      local k = type(v):sub(1, 1) .. (type(v) == "string" and v:lower() or tostring(v))
      if not seen[k] then seen[k] = true; c = c + 1 end
    end
  end) end
  return c
end

S("ABS", 1, 1, function(x) local a, e = N(x) if not a then return e end return abs(a) end)
S("SQRT", 1, 1, function(x) local a, e = N(x) if not a then return e end
  if a < 0 then return err("#NUM!", "Function SQRT parameter 1 value is negative. It should be positive or zero.") end
  return math.sqrt(a) end)
S("INT", 1, 1, function(x) local a, e = N(x) if not a then return e end return floor(a) end)
S("SIGN", 1, 1, function(x) local a, e = N(x) if not a then return e end return a > 0 and 1 or (a < 0 and -1 or 0) end)
S("EXP", 1, 1, function(x) local a, e = N(x) if not a then return e end return math.exp(a) end)
S("LN", 1, 1, function(x) local a, e = N(x) if not a then return e end if a <= 0 then return ERR["#NUM!"] end return math.log(a) end)
S("LOG10", 1, 1, function(x) local a, e = N(x) if not a then return e end if a <= 0 then return ERR["#NUM!"] end return math.log(a) / math.log(10) end)
S("LOG", 1, 2, function(x, b) local a, e = N(x) if not a then return e end
  local bb, e2 = N(opt(b, 10)) if not bb then return e2 end
  if a <= 0 or bb <= 0 or bb == 1 then return ERR["#NUM!"] end return math.log(a) / math.log(bb) end)
S("POWER", 2, 2, function(x, y) return arith("^", x, y) end)
S("MOD", 2, 2, function(x, y) local a, e = N(x) if not a then return e end local b, e2 = N(y) if not b then return e2 end
  if b == 0 then return err("#DIV/0!", "Function MOD parameter 2 cannot be zero.") end
  return a - b * floor(a / b) end)
S("QUOTIENT", 2, 2, function(x, y) local a, e = N(x) if not a then return e end local b, e2 = N(y) if not b then return e2 end
  if b == 0 then return ERR["#DIV/0!"] end local q = a / b return q < 0 and ceil(q) or floor(q) end)
S("ROUND", 1, 2, function(x, d) local a, e = N(x) if not a then return e end local p, e2 = N(opt(d, 0)) if not p then return e2 end
  return round(a, floor(p)) end)
S("ROUNDUP", 1, 2, function(x, d) local a, e = N(x) if not a then return e end local p, e2 = N(opt(d, 0)) if not p then return e2 end
  local m = 10 ^ floor(p) local y = abs(a) * m local r = ceil(y - 1e-9 * max(1, y)) return (a < 0 and -r or r) / m end)
S("ROUNDDOWN", 1, 2, function(x, d) local a, e = N(x) if not a then return e end local p, e2 = N(opt(d, 0)) if not p then return e2 end
  local m = 10 ^ floor(p) local y = abs(a) * m local r = floor(y + 1e-9 * max(1, y)) return (a < 0 and -r or r) / m end)
F.TRUNC = F.ROUNDDOWN
S("CEILING", 1, 2, function(x, s) local a, e = N(x) if not a then return e end local b, e2 = N(opt(s, 1)) if not b then return e2 end
  if b == 0 then return 0 end return ceil(a / b - 1e-12) * b end)
S("FLOOR", 1, 2, function(x, s) local a, e = N(x) if not a then return e end local b, e2 = N(opt(s, 1)) if not b then return e2 end
  if b == 0 then return ERR["#DIV/0!"] end return floor(a / b + 1e-12) * b end)
S("EVEN", 1, 1, function(x) local a, e = N(x) if not a then return e end local r = ceil(abs(a) / 2) * 2 return a < 0 and -r or r end)
S("ODD", 1, 1, function(x) local a, e = N(x) if not a then return e end local r = ceil(abs(a)) if r % 2 == 0 then r = r + 1 end return a < 0 and -r or r end)
S("SIN", 1, 1, function(x) local a, e = N(x) if not a then return e end return math.sin(a) end)
S("COS", 1, 1, function(x) local a, e = N(x) if not a then return e end return math.cos(a) end)
S("TAN", 1, 1, function(x) local a, e = N(x) if not a then return e end return math.tan(a) end)
S("DEGREES", 1, 1, function(x) local a, e = N(x) if not a then return e end return a * 180 / math.pi end)
S("RADIANS", 1, 1, function(x) local a, e = N(x) if not a then return e end return a * math.pi / 180 end)
F.PI = function() return math.pi end
F.RAND = function() return math.random() end
S("RANDBETWEEN", 2, 2, function(x, y) local a, e = N(x) if not a then return e end local b, e2 = N(y) if not b then return e2 end
  a, b = ceil(a), floor(b) if b < a then return ERR["#NUM!"] end return math.random(a, b) end)
F.SUMPRODUCT = function(args, n)
  if n < 1 then return argc(n, 1, nil, "SUMPRODUCT") end
  local r0, c0 = isMulti(args[1]) and dims(args[1]) or 1, nil
  local nr, nc = 1, 1
  if isMulti(args[1]) then nr, nc = dims(args[1]) end
  for i = 2, n do
    local r, c = 1, 1
    if isMulti(args[i]) then r, c = dims(args[i]) end
    if r ~= nr or c ~= nc then return err("#VALUE!", "SUMPRODUCT has mismatched range sizes.") end
  end
  local s = 0
  for i = 1, nr do for j = 1, nc do
    local p = 1
    for k = 1, n do
      local v = isMulti(args[k]) and get(args[k], i, j) or args[k]
      if isErr(v) then return v end
      p = p * (type(v) == "number" and v or (type(v) == "boolean" and (v and 1 or 0) or 0))
    end
    s = s + p
  end end
  return s
end
local function kth(args, n, name, largest)
  local e = argc(n, 2, 2, name) if e then return e end
  local list, e2 = numbers({ args[1] }, 1) if not list then return e2 end
  local k, e3 = N(args[2]) if not k then return e3 end
  k = floor(k)
  if k < 1 or k > #list then return err("#NUM!", name .. " has no " .. k .. "th value.") end
  table.sort(list, function(a, b) if largest then return a > b end return a < b end)
  return list[k]
end
F.LARGE = function(args, n) return kth(args, n, "LARGE", true) end
F.SMALL = function(args, n) return kth(args, n, "SMALL", false) end
F.RANK = function(args, n)
  local e = argc(n, 2, 3, "RANK") if e then return e end
  local v, e2 = N(args[1]) if not v then return e2 end
  local list, e3 = numbers({ args[2] }, 1) if not list then return e3 end
  local asc = toBool(opt(args[3], false))
  local r, found = 1, false
  for _, x in ipairs(list) do
    if x == v then found = true end
    if (asc == true and x < v) or (asc ~= true and x > v) then r = r + 1 end
  end
  if not found then return err("#N/A", "RANK: the value isn't in the list.") end
  return r
end
F["RANK.EQ"] = F.RANK

-- criteria: "<5", ">=10", "<>done", "app*", 7, TRUE
local function wildcard(s)
  local out = { "^" }
  local i = 1
  while i <= #s do
    local ch = s:sub(i, i)
    if ch == "~" and i < #s then out[#out + 1] = "%" .. s:sub(i + 1, i + 1); i = i + 1
    elseif ch == "*" then out[#out + 1] = ".-"
    elseif ch == "?" then out[#out + 1] = "."
    elseif ch:match("%p") then out[#out + 1] = "%" .. ch
    else out[#out + 1] = ch end
    i = i + 1
  end
  out[#out + 1] = "$"
  return table.concat(out)
end
local function criterion(c)
  if isErr(c) then return function(v) return isErr(v) and v.e == c.e end end
  if type(c) == "number" then return function(v) return type(v) == "number" and v == c or (type(v) == "string" and parseNum(v) == c) end end
  if type(c) == "boolean" then return function(v) return v == c end end
  if c == BLANK or c == OMIT then return function(v) return v == BLANK or v == "" end end
  local s = toStr(c)
  local op, rest = s:match("^(<>)(.*)$")
  if not op then op, rest = s:match("^([<>]=)(.*)$") end
  if not op then op, rest = s:match("^([<>=])(.*)$") end
  if not op then op, rest = "=", s end
  local n = parseNum(rest)
  if not n and FMT then n = FMT.parseDate(rest) end
  if op == "=" or op == "<>" then
    local test
    if rest == "" then test = function(v) return v == BLANK or v == "" end
    elseif n then test = function(v) return (type(v) == "number" and v == n) or (type(v) == "string" and parseNum(v) == n) end
    elseif rest:upper() == "TRUE" or rest:upper() == "FALSE" then
      local b = rest:upper() == "TRUE"
      test = function(v) return v == b end
    elseif rest:find("[%*%?]") then
      local pat = wildcard(rest:lower())
      test = function(v) return type(v) == "string" and v:lower():match(pat) ~= nil end
    else
      local low = rest:lower()
      test = function(v) return type(v) == "string" and v:lower() == low end
    end
    if op == "<>" then return function(v) return not test(v) end end
    return test
  end
  local target = n or rest
  return function(v)
    if v == BLANK then return false end
    if n then if type(v) ~= "number" then return false end
    elseif type(v) ~= "string" then return false end
    local c2 = compare(v, target)
    if op == "<" then return c2 < 0 elseif op == ">" then return c2 > 0
    elseif op == "<=" then return c2 <= 0 else return c2 >= 0 end
  end
end
local function sameShape(a, b)
  local r1, c1 = 1, 1
  local r2, c2 = 1, 1
  if isMulti(a) then r1, c1 = dims(a) end
  if isMulti(b) then r2, c2 = dims(b) end
  return r1 == r2 and c1 == c2
end
local function at(v, i, j) if isMulti(v) then return get(v, i, j) end return v end
-- rows/cols where every (range, criterion) pair matches: fn(i, j)
local function ifsLoop(pairs_, fn)
  local base = pairs_[1]
  local nr, nc = 1, 1
  if isMulti(base) then nr, nc = dims(base) end
  local tests = {}
  for p = 1, #pairs_, 2 do
    if not sameShape(base, pairs_[p]) then return err("#VALUE!", "Array arguments are of different size.") end
    tests[#tests + 1] = { pairs_[p], criterion(pairs_[p + 1]) }
  end
  for i = 1, nr do for j = 1, nc do
    local ok = true
    for _, t in ipairs(tests) do if not t[2](at(t[1], i, j)) then ok = false; break end end
    if ok then local e = fn(i, j) if e then return e end end
  end end
end
local function ifsAgg(name, sumFirst, kind)
  F[name] = function(args, n)
    local sumR, pr = nil, {}
    if sumFirst then
      if n < 3 or n % 2 == 0 then return argc(n, 3, nil, name) end
      sumR = args[1]
      for i = 2, n do pr[#pr + 1] = args[i] end
    else
      if kind == "count" then
        if n < 2 or n % 2 == 1 then return argc(n, 2, nil, name) end
        for i = 1, n do pr[#pr + 1] = args[i] end
      else                                               -- SUMIF(range, crit, [sum_range])
        local e = argc(n, 2, 3, name) if e then return e end
        pr = { args[1], args[2] }
        sumR = opt(args[3], nil) or args[1]
      end
    end
    local s, c, mn, mx = 0, 0, huge, -huge
    local e = ifsLoop(pr, function(i, j)
      if kind == "count" then c = c + 1; return end
      local v = at(sumR, i, j)
      if isErr(v) then return v end
      if type(v) == "number" then
        s, c = s + v, c + 1
        if v < mn then mn = v end
        if v > mx then mx = v end
      end
    end)
    if e then return e end
    if kind == "count" then return c end
    if kind == "avg" then if c == 0 then return ERR["#DIV/0!"] end return s / c end
    if kind == "min" then return c == 0 and 0 or mn end
    if kind == "max" then return c == 0 and 0 or mx end
    return s
  end
end
ifsAgg("SUMIF", false, "sum")
ifsAgg("AVERAGEIF", false, "avg")
ifsAgg("COUNTIF", false, "count")
ifsAgg("COUNTIFS", false, "count")
ifsAgg("SUMIFS", true, "sum")
ifsAgg("AVERAGEIFS", true, "avg")
ifsAgg("MINIFS", true, "min")
ifsAgg("MAXIFS", true, "max")

-- logic -------------------------------------------------------------------
LAZY.IF = function(n)
  local na = #n - 2
  if na < 2 or na > 3 then return argc(na, 2, 3, "IF") end
  local c = ev(n[3])
  if isMulti(c) then
    local a = ev(n[4])
    local b = n[5] and ev(n[5]) or false
    return lift(function(cc, x, y)
      if isErr(cc) then return cc end
      local t = toBool(cc)
      if isErr(t) then return t end
      if t then return x == OMIT and BLANK or x end
      return y == OMIT and BLANK or y
    end, { c, a, b }, 3)
  end
  if isErr(c) then return c end
  local t = toBool(c)
  if isErr(t) then return t end
  if t then local v = ev(n[4]) return v == OMIT and BLANK or v end
  if not n[5] then return false end
  local v = ev(n[5])
  return v == OMIT and BLANK or v
end
LAZY.IFERROR = function(n)
  local na = #n - 2
  if na < 1 or na > 2 then return argc(na, 1, 2, "IFERROR") end
  local v = ev(n[3])
  if isMulti(v) then
    local alt = n[4] and ev(n[4]) or BLANK
    return lift(function(x, y) if isErr(x) then return y end return x end, { v, alt }, 2)
  end
  if isErr(v) then
    if not n[4] then return BLANK end
    local a = ev(n[4])
    return a == OMIT and BLANK or a
  end
  return v
end
LAZY.IFNA = function(n)
  local v = ev(n[3])
  if isErr(v) and v.e == "#N/A" then return n[4] and ev(n[4]) or BLANK end
  return v
end
LAZY.IFS = function(n)
  local na = #n - 2
  if na < 2 or na % 2 == 1 then return argc(na, 2, nil, "IFS") end
  for i = 3, #n, 2 do
    local c = first(ev(n[i]))
    if isErr(c) then return c end
    local t = toBool(c)
    if isErr(t) then return t end
    if t then return ev(n[i + 1]) end
  end
  return err("#N/A", "No match.")
end
LAZY.SWITCH = function(n)
  local na = #n - 2
  if na < 3 then return argc(na, 3, nil, "SWITCH") end
  local v = first(ev(n[3]))
  if isErr(v) then return v end
  local i = 4
  while i + 1 <= #n do
    local c = first(ev(n[i]))
    if not isErr(c) and compare(v, c) == 0 then return ev(n[i + 1]) end
    i = i + 2
  end
  if i == #n then return ev(n[i]) end
  return err("#N/A", "No match.")
end
local function logic(name, fn)
  F[name] = function(args, n)
    local list, any = {}, false
    for i = 1, n do
      local a = args[i]
      local e = each(a, function(v)
        if isErr(v) then return v end
        if type(v) == "boolean" then list[#list + 1] = v; any = true
        elseif type(v) == "number" then list[#list + 1] = v ~= 0; any = true
        elseif not isMulti(a) and type(v) == "string" then
          local b = toBool(v)
          if isErr(b) then return b end
          list[#list + 1] = b; any = true
        end
      end)
      if e then return e end
    end
    if not any then return err("#VALUE!", name .. " has no logical values.") end
    return fn(list)
  end
end
logic("AND", function(l) for _, b in ipairs(l) do if not b then return false end end return true end)
logic("OR", function(l) for _, b in ipairs(l) do if b then return true end end return false end)
logic("XOR", function(l) local c = 0 for _, b in ipairs(l) do if b then c = c + 1 end end return c % 2 == 1 end)
S("NOT", 1, 1, function(x) local b = toBool(x) if isErr(b) then return b end return not b end)
F.TRUE = function() return true end
F.FALSE = function() return false end
F.NA = function() return err("#N/A", "Value not available.") end
F.CHOOSE = function(args, n)
  local i, e = N(args[1]) if not i then return e end
  i = floor(i)
  if i < 1 or i > n - 1 then return err("#NUM!", "CHOOSE index out of range.") end
  return args[i + 1]
end

-- info --------------------------------------------------------------------
S("ISBLANK", 1, 1, function(v) return v == BLANK end)
S("ISNUMBER", 1, 1, function(v) return type(v) == "number" end)
S("ISTEXT", 1, 1, function(v) return type(v) == "string" end)
S("ISNONTEXT", 1, 1, function(v) return type(v) ~= "string" end)
S("ISLOGICAL", 1, 1, function(v) return type(v) == "boolean" end)
S("ISERROR", 1, 1, function(v) return isErr(v) end)
S("ISERR", 1, 1, function(v) return isErr(v) and v.e ~= "#N/A" end)
S("ISNA", 1, 1, function(v) return isErr(v) and v.e == "#N/A" end)
S("ISEVEN", 1, 1, function(v) local a, e = N(v) if not a then return e end return floor(abs(a)) % 2 == 0 end)
S("ISODD", 1, 1, function(v) local a, e = N(v) if not a then return e end return floor(abs(a)) % 2 == 1 end)
S("N", 1, 1, function(v) if type(v) == "number" then return v elseif type(v) == "boolean" then return v and 1 or 0 end return 0 end)
S("T", 1, 1, function(v) if type(v) == "string" then return v end return "" end)

-- text --------------------------------------------------------------------
local ulen, usub = unicode.len, unicode.sub
local function txt(v) if isErr(v) then return nil, v end return toStr(v) end
F.CONCATENATE = function(args, n)
  local out = {}
  for i = 1, n do
    local e = each(args[i], function(v) if isErr(v) then return v end out[#out + 1] = toStr(v) end)
    if e then return e end
  end
  return table.concat(out)
end
F.CONCAT = F.CONCATENATE
S("LEN", 1, 1, function(v) local s, e = txt(v) if not s then return e end return ulen(s) end)
S("LEFT", 1, 2, function(v, k) local s, e = txt(v) if not s then return e end local n, e2 = N(opt(k, 1)) if not n then return e2 end
  if n < 0 then return ERR["#VALUE!"] end return usub(s, 1, floor(n)) end)
S("RIGHT", 1, 2, function(v, k) local s, e = txt(v) if not s then return e end local n, e2 = N(opt(k, 1)) if not n then return e2 end
  if n < 0 then return ERR["#VALUE!"] end n = floor(n) if n == 0 then return "" end
  local L = ulen(s) return usub(s, max(1, L - n + 1), L) end)
S("MID", 3, 3, function(v, a, b) local s, e = txt(v) if not s then return e end local st, e2 = N(a) if not st then return e2 end
  local n, e3 = N(b) if not n then return e3 end if st < 1 or n < 0 then return ERR["#VALUE!"] end
  st = floor(st) return usub(s, st, st + floor(n) - 1) end)
S("UPPER", 1, 1, function(v) local s, e = txt(v) if not s then return e end return unicode.upper(s) end)
S("LOWER", 1, 1, function(v) local s, e = txt(v) if not s then return e end return unicode.lower(s) end)
S("PROPER", 1, 1, function(v) local s, e = txt(v) if not s then return e end
  return (s:lower():gsub("(%a)([%w']*)", function(x, y) return x:upper() .. y end)) end)
S("TRIM", 1, 1, function(v) local s, e = txt(v) if not s then return e end
  return (s:gsub("^ +", ""):gsub(" +$", ""):gsub(" +", " ")) end)
S("CLEAN", 1, 1, function(v) local s, e = txt(v) if not s then return e end return (s:gsub("%c", "")) end)
S("REPT", 2, 2, function(v, k) local s, e = txt(v) if not s then return e end local n, e2 = N(k) if not n then return e2 end
  if n < 0 or #s * n > 32000 then return ERR["#VALUE!"] end return string.rep(s, floor(n)) end)
S("EXACT", 2, 2, function(a, b) local s, e = txt(a) if not s then return e end local t, e2 = txt(b) if not t then return e2 end return s == t end)
S("CHAR", 1, 1, function(v) local n, e = N(v) if not n then return e end n = floor(n)
  if n < 1 or n > 0x10FFFF then return ERR["#VALUE!"] end return unicode.char(n) end)
S("CODE", 1, 1, function(v) local s, e = txt(v) if not s then return e end if s == "" then return ERR["#VALUE!"] end
  local ch = usub(s, 1, 1) return #ch == 1 and ch:byte() or ch:byte() end)
S("VALUE", 1, 1, function(v) if type(v) == "number" then return v end return toNum(toStr(v)) end)
S("SUBSTITUTE", 3, 4, function(v, o, nw, inst)
  local s, e = txt(v) if not s then return e end
  local old, e2 = txt(o) if not old then return e2 end
  local new, e3 = txt(nw) if not new then return e3 end
  if old == "" then return s end
  local which = inst ~= nil and inst ~= OMIT and floor(toNum(inst)) or nil
  local out, i, count = {}, 1, 0
  while true do
    local a, b = s:find(old, i, true)
    if not a then break end
    count = count + 1
    out[#out + 1] = s:sub(i, a - 1)
    out[#out + 1] = (which == nil or which == count) and new or old
    i = b + 1
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out)
end)
S("REPLACE", 4, 4, function(v, a, b, nw)
  local s, e = txt(v) if not s then return e end
  local st, e2 = N(a) if not st then return e2 end
  local n, e3 = N(b) if not n then return e3 end
  local new, e4 = txt(nw) if not new then return e4 end
  st, n = floor(st), floor(n)
  return usub(s, 1, st - 1) .. new .. usub(s, st + n)
end)
local function finder(name, insensitive)
  S(name, 2, 3, function(nd, hay, st)
    local needle, e = txt(nd) if not needle then return e end
    local s, e2 = txt(hay) if not s then return e2 end
    local start, e3 = N(opt(st, 1)) if not start then return e3 end
    if insensitive then needle, s = needle:lower(), s:lower() end
    local bytePos = #usub(s, 1, floor(start) - 1) + 1
    local a = s:find(needle, bytePos, true)
    if not a then return err("#VALUE!", name .. " evaluates to an out of bounds range.") end
    return ulen(s:sub(1, a - 1)) + 1
  end)
end
finder("FIND", false)
finder("SEARCH", true)
S("TEXT", 2, 2, function(v, f)
  local fs, e = txt(f) if not fs then return e end
  if isErr(v) then return v end
  if type(v) == "string" then local n = parseNum(v) or (FMT and FMT.parseDate(v)) if n then v = n else return v end end
  if type(v) == "boolean" then return v and "TRUE" or "FALSE" end
  return (FMT.format(toNum(v), fs))
end)
local function joiner(args, start, n, delim, skipEmpty)
  local out = {}
  for i = start, n do
    local e = each(args[i], function(v)
      if isErr(v) then return v end
      if not (skipEmpty and (v == BLANK or v == "")) and v ~= OMIT then out[#out + 1] = toStr(v) end
    end)
    if e then return nil, e end
  end
  return table.concat(out, delim)
end
F.JOIN = function(args, n)
  local d, e = txt(args[1]) if not d then return e end
  local s, e2 = joiner(args, 2, n, d, false)
  return s or e2
end
F.TEXTJOIN = function(args, n)
  local e = argc(n, 3, nil, "TEXTJOIN") if e then return e end
  local d, e1 = txt(args[1]) if not d then return e1 end
  local skip = toBool(args[2])
  if isErr(skip) then return skip end
  local s, e2 = joiner(args, 3, n, d, skip)
  return s or e2
end
F.SPLIT = function(args, n)
  local e = argc(n, 2, 4, "SPLIT") if e then return e end
  local s, e1 = txt(first(args[1])) if not s then return e1 end
  local d, e2 = txt(first(args[2])) if not d then return e2 end
  local byEach = toBool(opt(args[3], true))
  local dropEmpty = toBool(opt(args[4], true))
  local parts = {}
  if d == "" then parts = { s }
  elseif byEach == true then
    local set = {}
    for i = 1, ulen(d) do set[usub(d, i, i)] = true end
    local cur = {}
    for i = 1, ulen(s) do
      local ch = usub(s, i, i)
      if set[ch] then parts[#parts + 1] = table.concat(cur); cur = {} else cur[#cur + 1] = ch end
    end
    parts[#parts + 1] = table.concat(cur)
  else
    local i = 1
    while true do
      local a, b = s:find(d, i, true)
      if not a then parts[#parts + 1] = s:sub(i); break end
      parts[#parts + 1] = s:sub(i, a - 1)
      i = b + 1
    end
  end
  local out = mkArray(1, 0)
  for _, p in ipairs(parts) do
    if not (dropEmpty == true and p == "") then
      out.nc = out.nc + 1
      out[out.nc] = parseNum(p) or p
    end
  end
  if out.nc == 0 then return BLANK end
  return out
end

-- lookup ------------------------------------------------------------------
local function eqLookup(a, b)
  if type(a) == "string" and type(b) == "string" then return a:lower() == b:lower() end
  if a == BLANK or b == BLANK then return false end
  return type(a) == type(b) and a == b
end
-- position in a 1-D list (getter g(i), length n) of key: exact (0), largest <= (1), smallest >= (-1)
local function locate(g, n, k, mode, wild)
  if mode == 0 then
    local pat = wild and type(k) == "string" and k:find("[%*%?]") and wildcard(k:lower())
    for i = 1, n do
      local v = g(i)
      if pat then if type(v) == "string" and v:lower():match(pat) then return i end
      elseif eqLookup(v, k) then return i end
    end
    return nil
  end
  local best
  for i = 1, n do
    local v = g(i)
    if v ~= BLANK and type(v) == type(k) then
      local c = compare(v, k)
      if mode == 1 then
        if c <= 0 then best = i else break end
      else
        if c >= 0 then best = i else break end
      end
    end
  end
  return best
end
local function lookupFn(name, horiz)
  F[name] = function(args, n)
    local e = argc(n, 3, 4, name) if e then return e end
    local k, rg = first(args[1]), args[2]
    if isErr(k) then return k end
    if not isMulti(rg) then return err("#N/A", name .. " needs a range.") end
    local idx, e2 = N(args[3]) if not idx then return e2 end
    idx = floor(idx)
    local nr, nc = dims(rg)
    if idx < 1 or idx > (horiz and nr or nc) then
      return err("#REF!", name .. " evaluates to an out of bounds range.")
    end
    local sorted = toBool(opt(args[4], true))
    local g = horiz and function(i) return get(rg, 1, i) end or function(i) return get(rg, i, 1) end
    local pos2 = locate(g, horiz and nc or nr, k, sorted == true and 1 or 0, true)
    if not pos2 then return err("#N/A", "Did not find value '" .. toStr(k):sub(1, 30) .. "' in " .. name .. " evaluation.") end
    if horiz then return get(rg, idx, pos2) end
    return get(rg, pos2, idx)
  end
end
lookupFn("VLOOKUP", false)
lookupFn("HLOOKUP", true)
F.MATCH = function(args, n)
  local e = argc(n, 2, 3, "MATCH") if e then return e end
  local k, rg = first(args[1]), args[2]
  if isErr(k) then return k end
  if not isMulti(rg) then rg = { ar = true, nr = 1, nc = 1, rg }; end
  local nr, nc = dims(rg)
  if nr > 1 and nc > 1 then return err("#N/A", "MATCH range must be a single row or a single column.") end
  local mode = floor(toNum(opt(args[3], 1)))
  local len = nr > 1 and nr or nc
  local g = nr > 1 and function(i) return get(rg, i, 1) end or function(i) return get(rg, 1, i) end
  local p = locate(g, len, k, mode == 0 and 0 or (mode > 0 and 1 or -1), true)
  if not p then return err("#N/A", "Did not find value '" .. toStr(k):sub(1, 30) .. "' in MATCH evaluation.") end
  return p
end
F.XLOOKUP = function(args, n)
  local e = argc(n, 3, 6, "XLOOKUP") if e then return e end
  local k, lr, rr = first(args[1]), args[2], args[3]
  if isErr(k) then return k end
  if not isMulti(lr) or not isMulti(rr) then return err("#VALUE!", "XLOOKUP needs ranges.") end
  local lnr, lnc = dims(lr)
  local vert = lnc == 1
  local len = vert and lnr or lnc
  local mode = floor(toNum(opt(args[5], 0)))
  local rev = floor(toNum(opt(args[6], 1))) < 0
  local found
  local function g(i) return vert and get(lr, i, 1) or get(lr, 1, i) end
  local best, bestV
  for step = 1, len do
    local i = rev and (len - step + 1) or step
    local v = g(i)
    if mode == 2 and type(k) == "string" then
      if type(v) == "string" and v:lower():match(wildcard(k:lower())) then found = i; break end
    elseif eqLookup(v, k) then found = i; break
    elseif (mode == -1 or mode == 1) and v ~= BLANK and type(v) == type(k) then
      local c = compare(v, k)
      if mode == -1 and c < 0 and (not bestV or compare(v, bestV) > 0) then best, bestV = i, v end
      if mode == 1 and c > 0 and (not bestV or compare(v, bestV) < 0) then best, bestV = i, v end
    end
  end
  found = found or best
  if not found then
    if args[4] ~= nil and args[4] ~= OMIT then return args[4] end
    return err("#N/A", "Did not find value '" .. toStr(k):sub(1, 30) .. "' in XLOOKUP evaluation.")
  end
  local rnr, rnc = dims(rr)
  if vert then
    if rr.rg then return mkRange(rr.sh, rr.r1 + found - 1, rr.c1, rr.r1 + found - 1, rr.c2) end
    if rnc == 1 then return get(rr, found, 1) end
  else
    if rr.rg then return mkRange(rr.sh, rr.r1, rr.c1 + found - 1, rr.r2, rr.c1 + found - 1) end
    if rnr == 1 then return get(rr, 1, found) end
  end
  return get(rr, vert and found or 1, vert and 1 or found)
end
F.INDEX = function(args, n)
  local e = argc(n, 1, 3, "INDEX") if e then return e end
  local rg = args[1]
  if not isMulti(rg) then return rg end
  local nr, nc = dims(rg)
  local r = floor(toNum(opt(args[2], 0)))
  local c = floor(toNum(opt(args[3], 0)))
  if n == 2 and nr == 1 then r, c = 1, r end
  if r < 0 or c < 0 or r > nr or c > nc then return err("#REF!", "INDEX evaluates to an out of bounds range.") end
  if r == 0 and c == 0 then return rg end
  if rg.rg then
    if r == 0 then return mkRange(rg.sh, rg.r1, rg.c1 + c - 1, rg.r2, rg.c1 + c - 1) end
    if c == 0 then if nc == 1 then return get(rg, r, 1) end return mkRange(rg.sh, rg.r1 + r - 1, rg.c1, rg.r1 + r - 1, rg.c2) end
  else
    if r == 0 then r = 1 end
    if c == 0 then c = 1 end
  end
  return get(rg, r, c)
end
F.ROWS = function(args, n) if isMulti(args[1]) then local r = dims(args[1]) return r end return 1 end
F.COLUMNS = function(args, n) if isMulti(args[1]) then local _, c = dims(args[1]) return c end return 1 end
local function sheetOf(name)
  if name then return sheetByName(name) end
  return ctxSh
end
local function refNode(nd)
  if nd and (nd[1] == "r" or nd[1] == "g") then
    local sh = sheetOf(nd[2])
    if not sh then return nil end
    if nd[1] == "r" then return sh, nd[3], nd[4], nd[3], nd[4] end
    local r2, c2 = nd[5] or max(nd[3], sh.maxR), nd[6] or max(nd[4], sh.maxC)
    return sh, nd[3], nd[4], r2, c2
  end
end
LAZY.ROW = function(n)
  if not n[3] or n[3][1] == "x" then return ctxR end
  local sh, r1 = refNode(n[3])
  if not sh then local v = ev(n[3]) if v and v.rg then return v.r1 end return err("#N/A", "ROW needs a reference.") end
  return r1
end
LAZY.COLUMN = function(n)
  if not n[3] or n[3][1] == "x" then return ctxC end
  local sh, _, c1 = refNode(n[3])
  if not sh then local v = ev(n[3]) if v and v.rg then return v.c1 end return err("#N/A", "COLUMN needs a reference.") end
  return c1
end
LAZY.OFFSET = function(n)
  local na = #n - 2
  if na < 3 or na > 5 then return argc(na, 3, 5, "OFFSET") end
  local sh, r1, c1, r2, c2 = refNode(n[3])
  if not sh then local v = ev(n[3]) if v and v.rg then sh, r1, c1, r2, c2 = v.sh, v.r1, v.c1, v.r2, v.c2 else return ERR["#REF!"] end end
  local dr, dc = toNum(ev(n[4])), toNum(ev(n[5]))
  if isErr(dr) then return dr end
  if isErr(dc) then return dc end
  local h = n[6] and n[6][1] ~= "x" and toNum(ev(n[6])) or (r2 - r1 + 1)
  local w = n[7] and n[7][1] ~= "x" and toNum(ev(n[7])) or (c2 - c1 + 1)
  if isErr(h) then return h end
  if isErr(w) then return w end
  local nr1, nc1 = r1 + floor(dr), c1 + floor(dc)
  if nr1 < 1 or nc1 < 1 or h < 1 or w < 1 then return err("#REF!", "OFFSET evaluates to an out of bounds range.") end
  return mkRange(sh, nr1, nc1, nr1 + floor(h) - 1, nc1 + floor(w) - 1)
end
S("INDIRECT", 1, 2, function(v)
  local s, e = txt(v) if not s then return e end
  local toks = tokenize(s)
  local tk
  if toks then for _, t in ipairs(toks) do if t[1] ~= "ws" then if tk then tk = nil; break end tk = t end end end
  if not tk or (tk[1] ~= "ref" and tk[1] ~= "rng") then return err("#REF!", "Unable to parse range: " .. s:sub(1, 30)) end
  local sh = sheetOf(tk.sheet)
  if not sh then return ERR["#REF!"] end
  if tk[1] == "ref" then return cellValue(sh, tk.r, tk.c) end
  return mkRange(sh, tk.r1, tk.c1, tk.r2, tk.c2)
end)
F.ADDRESS = function(args, n)
  local r, c = floor(toNum(args[1])), floor(toNum(args[2]))
  local mode = floor(toNum(opt(args[3], 1)))
  local s = ((mode == 1 or mode == 3) and "$" or "") .. colName(c) .. ((mode == 1 or mode == 2) and "$" or "") .. r
  local sh = opt(args[5], nil)
  if sh and sh ~= BLANK then s = quoteSheet(toStr(sh)) .. "!" .. s end
  return s
end

-- arrays ------------------------------------------------------------------
F.ARRAYFORMULA = function(args, n) return args[1] end
F.SEQUENCE = function(args, n)
  local e = argc(n, 1, 4, "SEQUENCE") if e then return e end
  local nr, nc = floor(toNum(args[1])), floor(toNum(opt(args[2], 1)))
  local st, step = toNum(opt(args[3], 1)), toNum(opt(args[4], 1))
  if nr < 1 or nc < 1 or nr * nc > 20000 then return err("#NUM!", "SEQUENCE size is out of range.") end
  local out = mkArray(nr, nc)
  for i = 1, nr * nc do out[i] = st + (i - 1) * step end
  return out
end
F.TRANSPOSE = function(args, n)
  local v = args[1]
  if not isMulti(v) then return v end
  local nr, nc = dims(v)
  local out = mkArray(nc, nr)
  for i = 1, nr do for j = 1, nc do out[(j - 1) * nr + i] = get(v, i, j) end end
  return out
end
F.FLATTEN = function(args, n)
  local out = mkArray(0, 1)
  for i = 1, n do each(args[i], function(v) if v ~= BLANK and v ~= OMIT then out.nr = out.nr + 1; out[out.nr] = v end end) end
  if out.nr == 0 then return BLANK end
  return out
end
local function rowsOf(v)
  local nr, nc = 1, 1
  if isMulti(v) then nr, nc = dims(v) end
  local rows = {}
  for i = 1, nr do
    local row = { idx = i }
    for j = 1, nc do row[j] = at(v, i, j) end
    rows[i] = row
  end
  return rows, nc
end
local function fromRows(rows, nc)
  if #rows == 0 then return nil end
  local out = mkArray(#rows, nc)
  for i, row in ipairs(rows) do for j = 1, nc do out[(i - 1) * nc + j] = row[j] end end
  return out
end
F.FILTER = function(args, n)
  local e = argc(n, 2, nil, "FILTER") if e then return e end
  local rows, nc = rowsOf(args[1])
  local keep = {}
  for i, row in ipairs(rows) do
    local ok = true
    for k = 2, n do
      local c = args[k]
      local nr2, nc2 = 1, 1
      if isMulti(c) then nr2, nc2 = dims(c) end
      local v
      if nr2 == #rows then v = at(c, i, 1) elseif nc2 == #rows and nr2 == 1 then v = at(c, 1, i) end
      if v == nil then return err("#VALUE!", "FILTER has mismatched range sizes.") end
      if isErr(v) then return v end
      local b = toBool(v)
      if isErr(b) or not b then ok = false; break end
    end
    if ok then keep[#keep + 1] = row end
  end
  local out = fromRows(keep, nc)
  return out or err("#N/A", "No matches are found in FILTER evaluation.")
end
F.SORT = function(args, n)
  local rows, nc = rowsOf(args[1])
  local keys = {}
  local i = 2
  repeat
    local col = floor(toNum(opt(args[i], 1)))
    local asc = toBool(opt(args[i + 1], true))
    if col < 1 or col > nc then return err("#VALUE!", "SORT column is out of range.") end
    keys[#keys + 1] = { col, asc == true }
    i = i + 2
  until i > n
  table.sort(rows, function(a, b)
    for _, k in ipairs(keys) do
      local x, y = a[k[1]], b[k[1]]
      if x == BLANK and y ~= BLANK then return false end
      if y == BLANK and x ~= BLANK then return true end
      if not isErr(x) and not isErr(y) then
        local c = compare(x, y)
        if c ~= 0 then if k[2] then return c < 0 end return c > 0 end
      end
    end
    return a.idx < b.idx
  end)
  return fromRows(rows, nc) or BLANK
end
F.UNIQUE = function(args, n)
  local rows, nc = rowsOf(args[1])
  local seen, keep = {}, {}
  for _, row in ipairs(rows) do
    local parts = {}
    for j = 1, nc do local v = row[j] parts[j] = type(v):sub(1, 1) .. (type(v) == "string" and v:lower() or tostring(isErr(v) and v.e or v)) end
    local k = table.concat(parts, "\1")
    if not seen[k] then seen[k] = true; keep[#keep + 1] = row end
  end
  return fromRows(keep, nc) or BLANK
end

-- dates -------------------------------------------------------------------
local function nowSerial()
  local e = A.toEastern(A.now())
  return serialOf(e.year, e.month, e.day) + (e.hour * 3600 + e.min * 60 + floor(e.sec)) / 86400
end
F.TODAY = function() return floor(nowSerial()) end
F.NOW = function() return nowSerial() end
S("DATE", 3, 3, function(y, m, d)
  local Y, e = N(y) if not Y then return e end
  local M, e2 = N(m) if not M then return e2 end
  local D, e3 = N(d) if not D then return e3 end
  Y, M, D = floor(Y), floor(M), floor(D)
  if Y < 1900 then Y = Y + 1900 end
  Y = Y + floor((M - 1) / 12)
  M = (M - 1) % 12 + 1
  return serialOf(Y, M, 1) + D - 1
end)
S("TIME", 3, 3, function(h, m, s)
  local H, e = N(h) if not H then return e end
  local M, e2 = N(m) if not M then return e2 end
  local Sx, e3 = N(s) if not Sx then return e3 end
  local t = (floor(H) * 3600 + floor(M) * 60 + floor(Sx)) / 86400
  return t - floor(t)
end)
local function datePart(name, fn)
  S(name, 1, 1, function(v)
    local n, e = N(v) if not n then return e end
    return fn(n)
  end)
end
datePart("YEAR", function(n) local y = ymdOf(n) return y end)
datePart("MONTH", function(n) local _, m = ymdOf(n) return m end)
datePart("DAY", function(n) local _, _, d = ymdOf(n) return d end)
local function secsOf(n) return floor((n - floor(n)) * 86400 + 0.5) % 86400 end
datePart("HOUR", function(n) return floor(secsOf(n) / 3600) end)
datePart("MINUTE", function(n) return floor(secsOf(n) / 60) % 60 end)
datePart("SECOND", function(n) return secsOf(n) % 60 end)
S("WEEKDAY", 1, 2, function(v, t)
  local n, e = N(v) if not n then return e end
  local ty = floor(toNum(opt(t, 1)))
  local d = floor(n)
  if ty == 1 then return (d - 1) % 7 + 1 elseif ty == 2 then return (d - 2) % 7 + 1 elseif ty == 3 then return (d - 2) % 7 end
  return ERR["#NUM!"]
end)
S("DAYS", 2, 2, function(a, b) local x, e = N(a) if not x then return e end local y, e2 = N(b) if not y then return e2 end return floor(x) - floor(y) end)
local function addMonths(n, k)
  local y, m, d = ymdOf(n)
  local tot = y * 12 + (m - 1) + floor(k)
  y, m = floor(tot / 12), tot % 12 + 1
  return y, m, min(d, monthLen(y, m))
end
S("EDATE", 2, 2, function(a, b) local x, e = N(a) if not x then return e end local k, e2 = N(b) if not k then return e2 end
  local y, m, d = addMonths(x, k) return serialOf(y, m, d) end)
S("EOMONTH", 2, 2, function(a, b) local x, e = N(a) if not x then return e end local k, e2 = N(b) if not k then return e2 end
  local y, m = addMonths(x, k) return serialOf(y, m, monthLen(y, m)) end)
S("DATEDIF", 3, 3, function(a, b, u)
  local x, e = N(a) if not x then return e end
  local y, e2 = N(b) if not y then return e2 end
  local unit = toStr(u):upper()
  if y < x then return err("#NUM!", "DATEDIF start date must be before the end date.") end
  local y1, m1, d1 = ymdOf(x)
  local y2, m2, d2 = ymdOf(y)
  local months = (y2 - y1) * 12 + (m2 - m1) - (d2 < d1 and 1 or 0)
  if unit == "D" then return floor(y) - floor(x)
  elseif unit == "M" then return months
  elseif unit == "Y" then return floor(months / 12)
  elseif unit == "YM" then return months % 12
  elseif unit == "MD" then return d2 >= d1 and d2 - d1 or (monthLen(m2 == 1 and y2 - 1 or y2, m2 == 1 and 12 or m2 - 1) - d1 + d2)
  end
  return err("#NUM!", "DATEDIF unit must be D, M, Y, YM or MD.")
end)
S("DATEVALUE", 1, 1, function(v)
  if type(v) == "number" then return floor(v) end
  local n = FMT.parseDate(toStr(v))
  if not n then return err("#VALUE!", "DATEVALUE parameter '" .. toStr(v):sub(1, 30) .. "' cannot be parsed to date/time.") end
  return floor(n)
end)
S("TIMEVALUE", 1, 1, function(v)
  local n = FMT.parseDate(toStr(v))
  if not n then return ERR["#VALUE!"] end
  return n - floor(n)
end)

---------------------------------------------------------------- evaluation
local function callFn(n)
  local name = n[2]
  local lz = LAZY[name]
  if lz then return lz(n) end
  local f = F[name]
  if not f then return err("#NAME?", "Unknown function: '" .. name .. "'.") end
  local args, agg = {}, AGG[name]
  local na = #n - 2
  for i = 1, na do
    local a = n[i + 2]
    if agg and a[1] == "r" then
      local sh = sheetOf(a[2])
      args[i] = sh and mkRange(sh, a[3], a[4], a[3], a[4]) or ERR["#REF!"]
    else
      args[i] = ev(a)
    end
  end
  return f(args, na)
end

ev = function(n)
  local k = n[1]
  if k == "n" or k == "s" or k == "b" or k == "e" then return n[2]
  elseif k == "r" then
    local sh = sheetOf(n[2])
    if not sh then return err("#REF!", "Unresolved sheet name '" .. tostring(n[2]) .. "'.") end
    return cellValue(sh, n[3], n[4])
  elseif k == "g" then
    local sh = sheetOf(n[2])
    if not sh then return err("#REF!", "Unresolved sheet name '" .. tostring(n[2]) .. "'.") end
    return mkRange(sh, n[3], n[4], n[5], n[6])
  elseif k == "o" then return binop(n[2], ev(n[3]), ev(n[4]))
  elseif k == "f" then return callFn(n)
  elseif k == "u" then return neg(ev(n[2]))
  elseif k == "p" then return pct(ev(n[2]))
  elseif k == "x" then return OMIT
  elseif k == "a" then
    local out = mkArray(n[2], n[3])
    for i = 4, #n do out[i - 3] = first(ev(n[i])) end
    return out
  end
  return ERR["#ERROR!"]
end

---------------------------------------------------------------- spill
local function clearSpill(sh, k)
  local ext = sh.so[k]
  if not ext then return end
  local r0, c0 = keyRC(k)
  local nr, nc = floor(ext / 1024), ext % 1024
  for i = 0, nr - 1 do for j = 0, nc - 1 do
    local kk = key(r0 + i, c0 + j)
    if kk ~= k and sh.sp[kk] == k then sh.sp[kk] = nil; sh.val[kk] = nil end
  end end
  sh.so[k] = nil
  spillChanged = true
end
local function spill(sh, k, r0, c0, v)
  local nr, nc = dims(v)
  if nr == 0 or nc == 0 then clearSpill(sh, k); return BLANK end
  if nr == 1 and nc == 1 then clearSpill(sh, k); return first(get(v, 1, 1)) end
  if nr * nc > 20000 or r0 + nr - 1 > MAXR or c0 + nc - 1 > MAXC then
    clearSpill(sh, k); return err("#REF!", "Result too large.")
  end
  for i = 0, nr - 1 do for j = 0, nc - 1 do
    local kk = key(r0 + i, c0 + j)
    if kk ~= k and sh.sp[kk] ~= k and not sh.cv[kk] and (sh.val[kk] ~= nil or sh.fml[kk]) then
      clearSpill(sh, k)
      return err("#REF!", "Array result was not expanded because it would overwrite data in " .. colName(c0 + j) .. (r0 + i) .. ".")
    end
  end end
  local vals = {}
  for i = 1, nr do for j = 1, nc do
    local x = get(v, i, j)
    if isMulti(x) then x = first(x) end
    vals[(i - 1) * nc + j] = x
  end end
  if sh.so[k] ~= nr * 1024 + nc then clearSpill(sh, k); spillChanged = true end
  for i = 0, nr - 1 do for j = 0, nc - 1 do
    local kk = key(r0 + i, c0 + j)
    if kk ~= k then
      local x = vals[i * nc + j + 1]
      sh.val[kk] = (x ~= BLANK and x ~= OMIT) and x or nil
      sh.sp[kk], sh.cv[kk] = k, nil
    end
  end end
  grow(sh, r0 + nr - 1, c0 + nc - 1)
  sh.so[k] = nr * 1024 + nc
  return vals[1]
end

local function calcCell(sh, k, r, c)
  if sh.fix[k] then sh.cg[k] = GEN; return end
  local busy = BUSY[sh]
  if not busy then busy = {}; BUSY[sh] = busy end
  busy[k] = true
  local psh, pr, pc = ctxSh, ctxR, ctxC
  ctxSh, ctxR, ctxC = sh, r, c
  local v = ev(getAst(sh.fml[k]))
  ctxSh, ctxR, ctxC = psh, pr, pc
  busy[k] = nil
  if isMulti(v) then v = spill(sh, k, r, c, v) elseif sh.so[k] then clearSpill(sh, k) end
  if v == BLANK or v == OMIT then v = nil end
  sh.val[k] = v
  sh.cg[k] = GEN
end

cellValue = function(sh, r, c)
  local k = r * 1024 + c
  if sh.fml[k] and sh.cg[k] ~= GEN then
    local busy = BUSY[sh]
    if busy and busy[k] then return CIRC end
    calcCell(sh, k, r, c)
  end
  local o = sh.sp[k]
  if o and sh.cg[o] ~= GEN and sh.fml[o] then
    local busy = BUSY[sh]
    if not (busy and busy[o]) then calcCell(sh, o, keyRC(o)) end
  end
  local v = sh.val[k]
  if v == nil then return BLANK end
  return v
end

-- recalculate every formula of the workbook (spills may need a second pass)
-- (the "already calculated" marks live only during a recalc, so they cost no RAM afterwards)
local function recalc()
  for pass = 1, 3 do
    GEN = GEN + 1
    spillChanged = false
    for _, sh in ipairs(WB.sheets) do sh.cg = {} end
    for _, sh in ipairs(WB.sheets) do
      for k in pairs(sh.fml) do
        if sh.cg[k] ~= GEN then calcCell(sh, k, keyRC(k)) end
      end
    end
    if not spillChanged then break end
  end
  for _, sh in ipairs(WB.sheets) do sh.cg = {} end
end

-- does a formula use only functions this engine knows? (imported ones that don't keep Google's value)
local function unknownFn(src)
  local toks = tokenize(src)
  if not toks then return nil end
  for _, tk in ipairs(toks) do
    if tk[1] == "fn" and not F[tk.v] and not LAZY[tk.v] then return tk.v end
  end
end

-- shift relative references by dr rows / dc columns (copy & paste, filling)
local function shift(src, dr, dc)
  return rewrite(src, function(tk)
    local t = {}
    for k2, v in pairs(tk) do t[k2] = v end
    if tk[1] == "ref" then
      if not tk.ar then t.r = tk.r + dr end
      if not tk.ac then t.c = tk.c + dc end
      if t.r < 1 or t.c < 1 or t.c > MAXC then return "#REF!" end
    else
      if t.r1 and not tk.ar1 and not tk.col then t.r1 = tk.r1 + dr end
      if t.r2 and not tk.ar2 and not tk.col then t.r2 = tk.r2 + dr end
      if t.c1 and not tk.ac1 and not tk.row then t.c1 = tk.c1 + dc end
      if t.c2 and not tk.ac2 and not tk.row then t.c2 = tk.c2 + dc end
      if (t.r1 and t.r1 < 1) or (t.r2 and t.r2 < 1) or (t.c1 and t.c1 < 1) or (t.c2 and t.c2 < 1) then return "#REF!" end
    end
    return refText(t)
  end)
end

-- rows / columns inserted (n > 0) or deleted (n < 0) at index `at` on sheet `name`:
-- fix one formula that lives on sheet `home`
local function moveRefs(src, home, name, axis, at, n)
  local low = name:lower()
  return rewrite(src, function(tk)
    local target = tk.sheet and tk.sheet:lower() or home:lower()
    if target ~= low then return nil end
    local t = {}
    for k2, v in pairs(tk) do t[k2] = v end
    local function mv(x)
      if not x then return x end
      if n > 0 then return x >= at and x + n or x end
      local last = at - n - 1
      if x < at then return x end
      if x > last then return x + n end
      return false                                       -- deleted
    end
    if tk[1] == "ref" then
      local v = mv(axis == "r" and tk.r or tk.c)
      if v == false then return "#REF!" end
      if axis == "r" then t.r = v else t.c = v end
      return refText(t)
    end
    local a1, a2 = axis == "r" and "r1" or "c1", axis == "r" and "r2" or "c2"
    if (axis == "r" and tk.col) or (axis == "c" and tk.row) then return nil end
    local x1, x2 = tk[a1], tk[a2]
    if n < 0 then
      local last = at - n - 1
      local e2 = x2 or huge
      if x1 >= at and e2 <= last then return "#REF!" end
      local nx1 = (x1 >= at and x1 <= last) and at or mv(x1)
      local nx2 = x2
      if x2 then nx2 = (x2 >= at and x2 <= last) and (at - 1) or mv(x2) end
      t[a1], t[a2] = nx1, nx2
    else
      t[a1] = mv(x1)
      if x2 then t[a2] = mv(x2) end
    end
    return refText(t)
  end)
end

-- a sheet was renamed: fix references in a formula
local function renameRefs(src, old, new)
  local low = old:lower()
  return rewrite(src, function(tk)
    if tk.sheet and tk.sheet:lower() == low then
      local t = {}
      for k2, v in pairs(tk) do t[k2] = v end
      t.sheet = new
      return refText(t)
    end
  end)
end

local NAMES = {}
for k2 in pairs(F) do NAMES[#NAMES + 1] = k2 end
for k2 in pairs(LAZY) do NAMES[#NAMES + 1] = k2 end
table.sort(NAMES)

return {
  recalc = recalc, cellValue = function(sh, r, c) return cellValue(sh, r, c) end,
  parse = parse, tokenize = tokenize, normalize = normalize, shift = shift, moveRefs = moveRefs,
  renameRefs = renameRefs, unknownFn = unknownFn, refText = refText, quoteSheet = quoteSheet,
  toStr = toStr, toNum = toNum, compare = compare, names = NAMES,
  clearSpill = clearSpill,
}
end)()

--------------------------------------------------------------- NUMBER FORMATS
-- Google Sheets / Excel format codes:  0.00   #,##0   "$"#,##0.00   0%   0.00E+00
--   m/d/yyyy   mmm d, yyyy   h:mm am/pm   [h]:mm:ss   #,##0;[Red](#,##0)   @
FMT = (function()
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August",
                 "September", "October", "November", "December" }
local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local COLORS = { red = 0xFF0000, blue = 0x0000FF, green = 0x00A000, black = 0x000000, white = 0xFFFFFF,
                 yellow = 0xFFFF00, magenta = 0xFF00FF, cyan = 0x00FFFF }
local cache = setmetatable({}, { __mode = "v" })

-- one section -> { kind = "num"|"date"|"text"|"general", toks = {...}, color }
local function compileSection(s)
  local toks, i, n = {}, 1, #s
  local sec = { toks = toks, kind = "num" }
  local isDate, hasNum, hasText = false, false, false
  local function lit(x) toks[#toks + 1] = { "l", x } end
  while i <= n do
    local c = s:sub(i, i)
    local lc = c:lower()
    if c == '"' then
      local j = s:find('"', i + 1, true) or (n + 1)
      lit(s:sub(i + 1, j - 1)); i = j + 1
    elseif c == "\\" then lit(s:sub(i + 1, i + 1)); i = i + 2
    elseif c == "_" then lit(" "); i = i + 2
    elseif c == "*" then i = i + 2
    elseif c == "[" then
      local j = s:find("]", i, true) or n
      local inner = s:sub(i + 1, j - 1)
      local low = inner:lower()
      if inner:sub(1, 1) == "$" then lit((inner:sub(2):match("^([^%-]*)")))
      elseif COLORS[low] then sec.color = COLORS[low]
      elseif low:match("^h+$") or low:match("^m+$") or low:match("^s+$") then
        toks[#toks + 1] = { "el", low:sub(1, 1), #low }; isDate = true
      end
      i = j + 1
    elseif s:sub(i, i + 4):upper() == "AM/PM" then toks[#toks + 1] = { "ap", 5 }; isDate = true; i = i + 5
    elseif s:sub(i, i + 2):upper() == "A/P" then toks[#toks + 1] = { "ap", 3 }; isDate = true; i = i + 3
    elseif s:sub(i, i + 6):lower() == "general" then toks[#toks + 1] = { "g" }; hasNum = true; i = i + 7
    elseif lc == "y" or lc == "m" or lc == "d" or lc == "h" or lc == "s" then
      local j = i
      while s:sub(j + 1, j + 1):lower() == lc do j = j + 1 end
      toks[#toks + 1] = { "d", lc, j - i + 1 }
      isDate = true; i = j + 1
    elseif c == "0" or c == "#" or c == "?" or c == "." or c == "," or c == "%" then
      toks[#toks + 1] = { "n", c }; hasNum = true; i = i + 1
    elseif (c == "E" or c == "e") and s:sub(i + 1, i + 1):match("[%+%-]") then
      toks[#toks + 1] = { "x", s:sub(i + 1, i + 1) }; i = i + 2
    elseif c == "@" then toks[#toks + 1] = { "t" }; hasText = true; i = i + 1
    else lit(c); i = i + 1 end
  end
  if isDate then
    sec.kind = "date"
    for _, t in ipairs(toks) do if t[1] == "n" or t[1] == "x" then t[1] = "l"; if t[2] == "+" or t[2] == "-" then t[2] = "E" .. t[2] end end end
    -- an m right after h or right before s means minutes
    local prev
    for k, t in ipairs(toks) do
      if t[1] == "d" then
        if t[2] == "m" then
          local nxt
          for k2 = k + 1, #toks do if toks[k2][1] == "d" or toks[k2][1] == "el" then nxt = toks[k2]; break end end
          if (prev and (prev[2] == "h")) or (nxt and nxt[2] == "s") then t[2] = "M" end
        end
        prev = t
      elseif t[1] == "el" then prev = t end
    end
    for _, t in ipairs(toks) do if t[1] == "ap" then sec.ampm = true end end
    return sec
  end
  if hasText and not hasNum then sec.kind = "text"; return sec end
  if not hasNum then sec.kind = "lit"; return sec end
  for _, t in ipairs(toks) do if t[1] == "g" then sec.kind = "general" end end
  -- number layout
  local firstN, lastN
  for k, t in ipairs(toks) do if t[1] == "n" or t[1] == "x" then firstN = firstN or k; lastN = k end end
  local intZ, intAll, dec, decZ, grp, scale, pctc, sciD = 0, 0, 0, 0, false, 0, 0, nil
  local afterDot, sawDigit, trailingCommas = false, false, 0
  local k = firstN
  while k <= lastN do
    local t = toks[k]
    if t[1] == "n" then
      local c = t[2]
      if c == "." then afterDot = true
      elseif c == "%" then pctc = pctc + 1
      elseif c == "," then
        if sawDigit then trailingCommas = trailingCommas + 1 end
      else
        if trailingCommas > 0 and not afterDot then grp = true; trailingCommas = 0 end
        sawDigit = true
        if sciD then sciD = sciD + 1
        elseif afterDot then dec = dec + 1; if c == "0" then decZ = decZ + 1 end
        else intAll = intAll + 1; if c == "0" then intZ = intZ + 1 end end
      end
    elseif t[1] == "x" then sciD = 0
    end
    k = k + 1
  end
  scale = trailingCommas
  for k2 = lastN + 1, #toks do if toks[k2][1] == "l" and toks[k2][2] == "%" then pctc = pctc + 1 end end
  local pre, post = {}, {}
  for k2 = 1, firstN - 1 do if toks[k2][1] == "l" then pre[#pre + 1] = toks[k2][2] end end
  for k2 = lastN + 1, #toks do if toks[k2][1] == "l" then post[#post + 1] = toks[k2][2] end end
  local mid = {}
  for k2 = firstN, lastN do if toks[k2][1] == "l" then mid[#mid + 1] = toks[k2][2] end end
  sec.pre, sec.post, sec.mid = table.concat(pre), table.concat(post), table.concat(mid)
  sec.intZ, sec.dec, sec.decZ, sec.grp, sec.scale, sec.pct, sec.sci = intZ, dec, decZ, grp, scale, pctc, sciD
  if pctc > 0 then sec.post = sec.post .. string.rep("%", pctc) end
  return sec
end

local function compile(code)
  local c = cache[code]
  if c then return c end
  local secs, cur, i, q = {}, {}, 1, false
  while i <= #code do
    local ch = code:sub(i, i)
    if ch == '"' then q = not q; cur[#cur + 1] = ch
    elseif ch == "\\" and not q then cur[#cur + 1] = code:sub(i, i + 1); i = i + 1
    elseif ch == ";" and not q then secs[#secs + 1] = table.concat(cur); cur = {}
    else cur[#cur + 1] = ch end
    i = i + 1
  end
  secs[#secs + 1] = table.concat(cur)
  c = {}
  for k, s in ipairs(secs) do c[k] = compileSection(s) end
  cache[code] = c
  return c
end

local function group(s)
  local k
  repeat s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2") until k == 0
  return s
end

local function fmtNumber(x, sec, neg)
  if sec.kind == "general" then return (neg and "-" or "") .. sec.pre .. numText(x) .. sec.post end
  x = x * 100 ^ sec.pct / 1000 ^ sec.scale
  local s
  if sec.sci then
    local e = x == 0 and 0 or floor(math.log(x) / math.log(10) + 1e-12) - max(0, sec.intZ - 1)
    local m = x / 10 ^ e
    local ms = string.format("%." .. sec.dec .. "f", m)
    if tonumber(ms) >= 10 ^ max(1, sec.intZ) then e = e + 1; ms = string.format("%." .. sec.dec .. "f", x / 10 ^ e) end
    s = ms .. "E" .. (e < 0 and "-" or "+") .. string.format("%0" .. max(1, sec.sci) .. "d", abs(e))
  else
    s = string.format("%." .. sec.dec .. "f", x + (x > 0 and 1e-9 * 10 ^ -sec.dec or 0))
    local ip, fp = s:match("^(%d+)%.?(%d*)$")
    if not ip then return s end
    if #fp > sec.decZ then fp = fp:gsub("0+$", "") if #fp < sec.decZ then fp = fp .. string.rep("0", sec.decZ - #fp) end end
    if sec.intZ == 0 and ip == "0" then ip = "" end
    if #ip < sec.intZ then ip = string.rep("0", sec.intZ - #ip) .. ip end
    if sec.grp then ip = group(ip) end
    s = ip .. (fp ~= "" and ("." .. fp) or "") .. sec.mid
  end
  return (neg and "-" or "") .. sec.pre .. s .. sec.post
end

local function fmtDate(v, sec)
  if v < 0 then return "#NUM!" end
  local days = floor(v)
  local secs = floor((v - days) * 86400 + 0.5)
  if secs >= 86400 then days, secs = days + 1, secs - 86400 end
  local y, m, d = ymdOf(days)
  local H, M, Sx = floor(secs / 3600), floor(secs / 60) % 60, secs % 60
  local out = {}
  for _, t in ipairs(sec.toks) do
    local k = t[1]
    if k == "l" then out[#out + 1] = t[2]
    elseif k == "ap" then
      local pm = H >= 12
      out[#out + 1] = t[2] == 5 and (pm and "PM" or "AM") or (pm and "P" or "A")
    elseif k == "el" then
      local tot = v * 86400
      local val = t[2] == "h" and floor(tot / 3600) or (t[2] == "m" and floor(tot / 60) or floor(tot + 0.5))
      out[#out + 1] = string.format("%0" .. t[3] .. "d", val)
    elseif k == "d" then
      local c, n = t[2], t[3]
      if c == "y" then out[#out + 1] = n <= 2 and string.format("%02d", y % 100) or tostring(y)
      elseif c == "m" then
        if n == 1 then out[#out + 1] = tostring(m)
        elseif n == 2 then out[#out + 1] = string.format("%02d", m)
        elseif n == 3 then out[#out + 1] = MONTHS[m]:sub(1, 3)
        elseif n == 5 then out[#out + 1] = MONTHS[m]:sub(1, 1)
        else out[#out + 1] = MONTHS[m] end
      elseif c == "d" then
        local wd = (days - 1) % 7 + 1
        if n == 1 then out[#out + 1] = tostring(d)
        elseif n == 2 then out[#out + 1] = string.format("%02d", d)
        elseif n == 3 then out[#out + 1] = DAYS[wd]:sub(1, 3)
        else out[#out + 1] = DAYS[wd] end
      elseif c == "h" then
        local h = H
        if sec.ampm then h = H % 12; if h == 0 then h = 12 end end
        out[#out + 1] = n >= 2 and string.format("%02d", h) or tostring(h)
      elseif c == "M" then out[#out + 1] = n >= 2 and string.format("%02d", M) or tostring(M)
      elseif c == "s" then out[#out + 1] = n >= 2 and string.format("%02d", Sx) or tostring(Sx)
      end
    end
  end
  return table.concat(out)
end

-- value + format code -> text, color (color only from [Red] etc.)
local function format(v, code)
  if type(v) ~= "number" then return tostring(v) end
  if not code or code == "" or code:lower() == "general" then return numText(v) end
  local c = compile(code)
  local sec, neg = c[1], v < 0
  if v < 0 and c[2] and c[2].kind ~= "text" then sec, neg = c[2], false
  elseif v == 0 and c[3] and c[3].kind ~= "text" then sec = c[3] end
  if sec.kind == "date" then return fmtDate(v, sec), sec.color end
  if sec.kind == "text" or sec.kind == "lit" then
    local out = {}
    for _, t in ipairs(sec.toks) do out[#out + 1] = t[1] == "l" and t[2] or numText(v) end
    return table.concat(out), sec.color
  end
  return fmtNumber(abs(v), sec, neg and v < 0 and sec == c[1]), sec.color
end
local function formatText(s, code)
  if not code or code == "" then return s end
  local c = compile(code)
  local sec = c[4] or (c[1] and c[1].kind == "text" and c[1])
  if not sec then return s end
  local out = {}
  for _, t in ipairs(sec.toks) do
    if t[1] == "l" then out[#out + 1] = t[2] elseif t[1] == "t" then out[#out + 1] = s end
  end
  return table.concat(out)
end
local function isDateCode(code)
  if not code or code == "" then return false end
  return compile(code)[1].kind == "date"
end

-- "11/28/2026", "2026-11-28", "Nov 28, 2026", "3:45 PM", "11/28/2026 13:05:00" -> serial
local MONIDX = {}
for i, m in ipairs(MONTHS) do MONIDX[m:sub(1, 3):lower()] = i end
local function parseTime(s)
  local h, m, sec, ap = s:match("^(%d%d?):(%d%d):?(%d?%d?)%s*([AaPp]?[Mm]?)$")
  if not h then
    h, ap = s:match("^(%d%d?)%s*([AaPp][Mm])$")
    m, sec = "0", ""
  end
  if not h then return nil end
  h, m, sec = tonumber(h), tonumber(m), tonumber(sec) or 0
  ap = ap:upper()
  if ap ~= "" and ap ~= "AM" and ap ~= "PM" then return nil end
  if ap == "PM" and h < 12 then h = h + 12 elseif ap == "AM" and h == 12 then h = 0 end
  if h > 23 or m > 59 or sec > 59 then return nil end
  return (h * 3600 + m * 60 + sec) / 86400, ap ~= ""
end
local function parseDate(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  local y, m, d, rest
  local a, b, c, r = s:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)(.*)$")
  if a then y, m, d, rest = tonumber(a), tonumber(b), tonumber(c), r
  else
    a, b, c, r = s:match("^(%d%d?)/(%d%d?)/(%d%d%d?%d?)(.*)$")
    if a then
      m, d, y, rest = tonumber(a), tonumber(b), tonumber(c), r
      if #c <= 2 then y = y + (y < 30 and 2000 or 1900) end
    else
      local mn, dd, yy, r2 = s:match("^(%a%a%a)%a*%.? (%d%d?),? (%d%d%d%d)(.*)$")
      if mn and MONIDX[mn:lower()] then m, d, y, rest = MONIDX[mn:lower()], tonumber(dd), tonumber(yy), r2
      else
        local t, ap = parseTime(s)
        if t then return t, ap and "h:mm am/pm" or "h:mm:ss" end
        return nil
      end
    end
  end
  if m < 1 or m > 12 or d < 1 or d > monthLen(y, m) then return nil end
  local v = serialOf(y, m, d)
  rest = rest:gsub("^[T%s]+", "")
  if rest ~= "" then
    local t = parseTime(rest)
    if not t then return nil end
    return v + t, "m/d/yyyy h:mm:ss"
  end
  return v, "m/d/yyyy"
end

-- what typing into a cell gives: value, inferred format code (or nil)
local function parseInput(s)
  if s == "" then return nil end
  if s:sub(1, 1) == "'" then return s:sub(2) end
  local up = s:upper()
  if up == "TRUE" then return true end
  if up == "FALSE" then return false end
  local n = parseNum(s)
  if n then
    local t = s:gsub("%s", "")
    local decs = t:match("%.(%d+)") or ""
    if t:find("%%") then return n, #decs > 0 and ("0." .. string.rep("0", #decs) .. "%") or "0%" end
    if t:find("%$") then return n, '"$"#,##0.00' end
    if t:find("[eE]") then return n, "0.00E+00" end
    if t:find(",") then return n, #decs > 0 and ("#,##0." .. string.rep("0", #decs)) or "#,##0" end
    return n
  end
  local d, code = parseDate(s)
  if d then return d, code end
  return s
end

-- how a cell shows: text, align ("l"/"c"/"r"), color or nil
local function display(v, st)
  if v == nil then return "", "l" end
  local t = type(v)
  local al = st and st.al
  if t == "number" then
    local s, col = format(v, st and st.nf)
    return s, al or "r", col
  elseif t == "string" then
    return st and st.nf and formatText(v, st.nf) or v, al or "l"
  elseif t == "boolean" then
    return v and "TRUE" or "FALSE", al or "c"
  elseif isErr(v) then
    return v.e, al or "c"
  end
  return "", "l"
end

return { format = format, display = display, parseInput = parseInput, parseDate = parseDate,
         isDate = isDateCode, compile = compile }
end)()

--------------------------------------------------------------- STYLES
-- WB.styles[id] = { nf = format code, b = bold, fg = text color, bg = fill color, al = "l"|"c"|"r" }
local function styleId(st)
  if not st or (not st.nf and not st.b and not st.fg and not st.bg and not st.al) then return nil end
  local sig = (st.nf or "") .. "\1" .. (st.b and "1" or "") .. "\1" .. tostring(st.fg or "") .. "\1" ..
              tostring(st.bg or "") .. "\1" .. (st.al or "")
  local id = WB.styleKey[sig]
  if not id then
    WB.styles[#WB.styles + 1] = { nf = st.nf, b = st.b, fg = st.fg, bg = st.bg, al = st.al }
    id = #WB.styles
    WB.styleKey[sig] = id
  end
  return id
end
local function styleOf(sh, k) local id = sh.sty[k]; return id and WB.styles[id] end

local function newWorkbook(name)
  WB = { name = name, sheets = { newSheet("Sheet1") }, cur = 1, styles = {}, styleKey = {} }
  return WB
end

--------------------------------------------------------------- SAVE / LOAD
-- text file, one line per cell:  c <TAB> row <TAB> col <TAB> style <TAB> kind <TAB> value [<TAB> formula <TAB> flags]
-- written and read line by line, so saving never builds the whole file in memory
local IO = (function()
local function esc(s) return (tostring(s):gsub("\\", "\\\\"):gsub("\t", "\\t"):gsub("\n", "\\n"):gsub("\r", "")) end
local function unesc(s)
  return (s:gsub("\\(.)", function(c) if c == "t" then return "\t" elseif c == "n" then return "\n" end return c end))
end
local function encode(v)
  local t = type(v)
  if v == nil then return "", "" end
  if t == "number" then return "n", string.format("%.17g", v) end
  if t == "boolean" then return "b", v and "1" or "0" end
  if t == "string" then return "s", esc(v) end
  if isErr(v) then return "e", v.e end
  return "", ""
end
local function decode(k, s)
  if k == "n" then return tonumber(s) end
  if k == "b" then return s == "1" end
  if k == "s" then return unesc(s) end
  if k == "e" then return ERR[s] or ERR["#ERROR!"] end
end

local function save(path)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false, "Cannot write " .. tmp end
  local ok = f:write("LSHEETS\t1\n", "name\t", esc(WB.name), "\n")
  for id, st in ipairs(WB.styles) do
    f:write("style\t", id, "\t", esc(st.nf or ""), "\t", st.b and "1" or "", "\t",
      st.fg and string.format("%06X", st.fg) or "", "\t", st.bg and string.format("%06X", st.bg) or "", "\t", st.al or "", "\n")
  end
  for _, sh in ipairs(WB.sheets) do
    f:write("sheet\t", esc(sh.name), "\t", sh.rows, "\t", sh.cols, "\t", sh.frR, "\t", sh.frC, "\n")
    for c, w in pairs(sh.colW) do f:write("w\t", c, "\t", w, "\n") end
    local seen = {}
    local function cell(k)
      if seen[k] or sh.sp[k] then return end
      seen[k] = true
      local r, c = keyRC(k)
      local kind, v = encode(sh.val[k])
      local fm = sh.fml[k]
      local flags = (sh.fix[k] and "x" or "") .. (sh.cv[k] and "v" or "")
      if fm or flags ~= "" then
        f:write("c\t", r, "\t", c, "\t", sh.sty[k] or "", "\t", kind, "\t", v, "\t", esc(fm or ""), "\t", flags, "\n")
      else
        f:write("c\t", r, "\t", c, "\t", sh.sty[k] or "", "\t", kind, "\t", v, "\n")
      end
    end
    for k in pairs(sh.val) do cell(k) end
    for k in pairs(sh.fml) do cell(k) end
    for k in pairs(sh.sty) do cell(k) end
  end
  ok = f:write("cur\t", WB.cur, "\n") and ok
  f:close()
  if not ok then filesystem.remove(tmp); return false, "The disk is full." end
  if filesystem.exists(path) then filesystem.remove(path) end
  filesystem.rename(tmp, path)
  return true
end

local function split(line)
  local out, i = {}, 1
  while true do
    local j = line:find("\t", i, true)
    if not j then out[#out + 1] = line:sub(i); break end
    out[#out + 1] = line:sub(i, j - 1)
    i = j + 1
  end
  return out
end

local function load(path)
  local f = io.open(path, "r")
  if not f then return nil, "Cannot open " .. path end
  local head = f:read("*l")
  if not head or not head:match("^LSHEETS") then f:close(); return nil, "Not a Lymanos spreadsheet." end
  local wb = { name = "Untitled spreadsheet", sheets = {}, cur = 1, styles = {}, styleKey = {} }
  local prevWB = WB
  WB = wb
  local sh
  for line in f:lines() do
    local p = split(line)
    local k = p[1]
    if k == "c" and sh then
      local r, c = tonumber(p[2]), tonumber(p[3])
      if r and c then
        local kk = key(r, c)
        local v = decode(p[5], p[6] or "")
        if v ~= nil then sh.val[kk] = v end
        if p[4] ~= "" then sh.sty[kk] = tonumber(p[4]) end
        if p[7] and p[7] ~= "" then sh.fml[kk] = unesc(p[7]) end
        if p[8] then
          if p[8]:find("x") then sh.fix[kk] = true end
          if p[8]:find("v") then sh.cv[kk] = true end
        end
        grow(sh, r, c)
      end
    elseif k == "sheet" then
      sh = newSheet(unesc(p[2] or "Sheet"))
      sh.rows, sh.cols = tonumber(p[3]) or 1000, tonumber(p[4]) or 26
      sh.frR, sh.frC = tonumber(p[5]) or 0, tonumber(p[6]) or 0
      wb.sheets[#wb.sheets + 1] = sh
    elseif k == "w" and sh then
      sh.colW[tonumber(p[2])] = tonumber(p[3])
    elseif k == "style" then
      local id = tonumber(p[2])
      local st = { nf = (p[3] and p[3] ~= "") and unesc(p[3]) or nil, b = p[4] == "1",
                   fg = (p[5] and p[5] ~= "") and tonumber(p[5], 16) or nil,
                   bg = (p[6] and p[6] ~= "") and tonumber(p[6], 16) or nil, al = (p[7] and p[7] ~= "") and p[7] or nil }
      if not st.b then st.b = nil end
      wb.styles[id] = st
    elseif k == "name" then wb.name = unesc(p[2] or "")
    elseif k == "cur" then wb.cur = tonumber(p[2]) or 1 end
  end
  f:close()
  for id, st in ipairs(wb.styles) do
    local sig = (st.nf or "") .. "\1" .. (st.b and "1" or "") .. "\1" .. tostring(st.fg or "") .. "\1" ..
                tostring(st.bg or "") .. "\1" .. (st.al or "")
    wb.styleKey[sig] = id
  end
  if #wb.sheets == 0 then wb.sheets[1] = newSheet("Sheet1") end
  if wb.cur > #wb.sheets then wb.cur = 1 end
  WB = prevWB
  return wb
end

return { save = save, load = load }
end)()

--------------------------------------------------------------- GOOGLE SHEETS IMPORT (loader)
-- Google gives any sheet shared as "Anyone with the link" as an .xlsx file. The code that
-- reads it is in the long comment at the very end of this file: it is compiled only while
-- an import runs, so it uses no RAM the rest of the time.
local function loadImporter()
  local path = A.CONFIG.SHEETS_FILE or "/home/lymsheets.lua"
  local f = io.open(path, "r")
  if not f then error("Cannot read " .. path .. " (needed for importing).", 0) end
  local all = f:read("*a")
  f:close()
  local mark = "--[==[" .. "XLSX-IMPORT"
  local a = all:find(mark, 1, true)
  local b = a and all:find("]==" .. "]", a, true)
  if not b then error("The importer is missing from " .. path .. ".", 0) end
  local src = all:sub(a + #mark, b - 1)
  all = nil
  local env = setmetatable({
    A = A, unicode = unicode, computer = computer, filesystem = filesystem, floor = floor, min = min, max = max,
    MAXR = MAXR, MAXC = MAXC, key = key, colNum = colNum, ERR = ERR, styleId = styleId, newSheet = newSheet,
    grow = grow, ENG = ENG, setWB = function(w) WB = w end,
  }, { __index = _G })
  local chunk, e = load(src, "=lymsheets-import", "t", env)
  if not chunk then error(e, 0) end
  return chunk()
end

--------------------------------------------------------------- APP (Google Sheets look)
return (function()
local fill, text, textW, bevel, titleBar = A.fill, A.text, A.textW, A.bevel, A.titleBar
local region, hit = A.region, A.hit
local K = A.K
local WX, WY, WW, WH = A.WX, A.WY, A.WW, A.WH
local ulen, usub = unicode.len, unicode.sub
local okKb, keyboard = pcall(require, "keyboard")
if not okKb then keyboard = nil end
local function ctrlDown() return keyboard ~= nil and keyboard.isControlDown() end
local function shiftDown() return keyboard ~= nil and keyboard.isShiftDown() end
local DIR = A.CONFIG.SHEETS_DIR or "/home/sheets"
if not filesystem.exists(DIR) then filesystem.makeDirectory(DIR) end

local C = {
  white = 0xFFFFFF, ink = 0x1F1F1F, dim = 0x5F6368, line = 0xE1E1E1, hdr = 0xF8F9FA, hdrInk = 0x444746,
  top = 0xF9FBFD, tool = 0xEDF2FA, green = 0x0F9D58, blue = 0x0B57D0, selHdr = 0xD3E3FD, selFill = 0xE8F0FE,
  frz = 0xBDC1C6, red = 0xD93025, tab = 0xE1E9F7, band = 0xF1F3F4, border = 0xC4C7C5, warn = 0xE37400,
  btn = 0x0B57D0, chip = 0xE8EAED,
}
local X0, X1 = WX + 1, WX + WW - 2
local YT, YB, YF, YH = WY + 2, WY + 3, WY + 4, WY + 5      -- title + menus, toolbar, formula bar, column letters
local G1, G2 = WY + 6, WY + WH - 3                           -- grid rows
local YS = WY + WH - 2                                       -- sheet tabs
local RHW, DEFW = 5, 12                                      -- row-number width, default column width
local PALETTE = {
  { 0x000000, 0x434343, 0x666666, 0x999999, 0xB7B7B7, 0xCCCCCC, 0xD9D9D9, 0xEFEFEF, 0xF3F3F3, 0xFFFFFF },
  { 0x980000, 0xFF0000, 0xFF9900, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x4A86E8, 0x0000FF, 0x9900FF, 0xFF00FF },
  { 0xE6B8AF, 0xF4CCCC, 0xFCE5CD, 0xFFF2CC, 0xD9EAD3, 0xD0E0E3, 0xC9DAF8, 0xCFE2F3, 0xD9D2E9, 0xEAD1DC },
  { 0x85200C, 0x990000, 0xB45F06, 0xBF9000, 0x38761D, 0x134F5C, 0x1155CC, 0x0B5394, 0x351C75, 0x741B47 },
}

local V = {
  mode = "home", reg = {}, file = nil, dirty = false, lastEdit = 0, saveMsg = "",
  ed = nil, drag = nil, prompt = nil, pop = nil,
  link = "", importOpen = false, job = nil, jobMsg = nil, jobErr = nil, jobDirty = false,
  files = nil, listScroll = 0,
  undo = {}, redo = {}, rec = nil, clip = nil, showF = false, stat = 1,
  lastClick = 0, lastRC = nil, tabScroll = 0,
}
local L = { cols = {}, rows = {} }
local drawWindow                                              -- forward

---------------------------------------------------------------- basics
local function curSheet() return WB.sheets[WB.cur] end
local function view(sh)
  local v = sh.v
  if not v then v = { top = 1, left = 1, r = 1, c = 1, er = 1, ec = 1 }; sh.v = v end
  return v
end
local function colW(sh, c) return sh.colW[c] or DEFW end
local function selBox(sh)
  local v = view(sh)
  return min(v.r, v.er), min(v.c, v.ec), max(v.r, v.er), max(v.c, v.ec)
end
local function refName(r, c) return colName(c) .. r end
local function isFormula(s) return s:sub(1, 1) == "=" and #s > 1 end
local function clampMenu(x, y, items)
  local w = 4
  for _, it in ipairs(items) do w = max(w, ulen(it[1]) + 6) end
  if x + w > 160 then x = 160 - w end
  if y + #items + 2 > 47 then y = 47 - #items - 2 end
  return max(1, x), max(1, y)
end
local function menu(x, y, items)
  x, y = clampMenu(x, y, items)
  A.popupMenu(x, y, items)
end
local function say(msg) V.saveMsg = msg end

-- what the cell "contains" as you would type it (formula bar / editing)
local function rawText(sh, k)
  local f = sh.fml[k]
  if f then return "=" .. f end
  local v = sh.val[k]
  if v == nil then return "" end
  local t = type(v)
  if t == "number" then
    local st = styleOf(sh, k)
    if st and st.nf then
      if FMT.isDate(st.nf) then
        if v == floor(v) then return FMT.format(v, "m/d/yyyy") end
        if v < 1 then return FMT.format(v, "h:mm:ss AM/PM") end
        return FMT.format(v, "m/d/yyyy h:mm:ss")
      end
      if st.nf:find("%%") then return numText(v * 100, 15) .. "%" end
    end
    return numText(v, 15)
  end
  if t == "boolean" then return v and "TRUE" or "FALSE" end
  if t == "string" then
    local pv = FMT.parseInput(v)
    if type(pv) ~= "string" or v:sub(1, 1) == "'" or isFormula(v) then return "'" .. v end
    return v
  end
  if isErr(v) then return v.e end
  return ""
end

---------------------------------------------------------------- saving
local function safeName(s)
  s = s:gsub("[%c/\\:%*%?\"<>|]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then s = "Untitled spreadsheet" end
  return s:sub(1, 60)
end
local function uniquePath(name)
  local base = DIR .. "/" .. safeName(name)
  local p, n = base .. ".lsh", 2
  while filesystem.exists(p) do p = base .. " (" .. n .. ").lsh"; n = n + 1 end
  return p
end
local function saveNow()
  if not WB or not V.file then return end
  local ok, e = IO.save(V.file)
  V.dirty = not ok
  say(ok and "All changes saved" or ("Not saved: " .. tostring(e)))
end
local function changed()
  ENG.recalc()
  V.dirty, V.lastEdit = true, computer.uptime()
  say("Saving...")
end

---------------------------------------------------------------- undo
local function record(sh, k)
  local rec = V.rec
  if not rec or rec.seen[k] then return end
  rec.seen[k] = true
  rec.cells[#rec.cells + 1] = { k, sh.val[k], sh.fml[k], sh.sty[k], sh.fix[k], sh.cv[k] }
end
local function beginEdit(sh) V.rec = { sh = sh, cells = {}, seen = {} } end
local function pushUndo(rec)
  V.undo[#V.undo + 1] = rec
  if #V.undo > 40 then table.remove(V.undo, 1) end
  V.redo = {}
end
local function endEdit()
  local rec = V.rec
  V.rec = nil
  if not rec then return end
  rec.seen = nil
  if #rec.cells > 0 then pushUndo(rec) end
  changed()
end
local function swapCells(rec)                                  -- put the recorded cells back, return the opposite
  local sh, back = rec.sh, { sh = rec.sh, cells = {} }
  for i = #rec.cells, 1, -1 do
    local c = rec.cells[i]
    local k = c[1]
    back.cells[#back.cells + 1] = { k, sh.val[k], sh.fml[k], sh.sty[k], sh.fix[k], sh.cv[k] }
    if sh.so[k] then ENG.clearSpill(sh, k) end
    sh.val[k], sh.fml[k], sh.sty[k], sh.fix[k], sh.cv[k] = c[2], c[3], c[4], c[5], c[6]
    sh.sp[k], sh.cg[k] = nil, nil
    local r, cc = keyRC(k)
    grow(sh, r, cc)
  end
  return back
end

---------------------------------------------------------------- editing cells
local function copyStyle(st)
  if not st then return {} end
  return { nf = st.nf, b = st.b, fg = st.fg, bg = st.bg, al = st.al }
end
local function setCell(sh, r, c, s)
  local k = key(r, c)
  record(sh, k)
  if sh.so[k] then ENG.clearSpill(sh, k) end
  sh.fix[k], sh.cv[k], sh.sp[k], sh.cg[k] = nil, nil, nil, nil
  if isFormula(s) then
    sh.fml[k], sh.val[k] = ENG.normalize(s:sub(2)), nil
  else
    sh.fml[k] = nil
    local v, nf = FMT.parseInput(s)
    sh.val[k] = v
    if nf then
      local st = copyStyle(styleOf(sh, k))
      if not st.nf or (FMT.isDate(nf) ~= FMT.isDate(st.nf)) then st.nf = nf; sh.sty[k] = styleId(st) end
    end
  end
  grow(sh, r, c)
end
local function eachSel(sh, fn)
  local r1, c1, r2, c2 = selBox(sh)
  if (r2 - r1 + 1) * (c2 - c1 + 1) > 60000 then r2 = min(r2, sh.maxR); c2 = min(c2, sh.maxC) end
  for r = r1, r2 do for c = c1, c2 do fn(r, c, key(r, c)) end end
end
local function clearSel(what)                                  -- "values" | "formats" | "all"
  local sh = curSheet()
  beginEdit(sh)
  eachSel(sh, function(r, c, k)
    if sh.val[k] ~= nil or sh.fml[k] or sh.sty[k] or sh.cv[k] then
      record(sh, k)
      if what ~= "formats" then
        if sh.so[k] then ENG.clearSpill(sh, k) end
        if not sh.sp[k] then sh.val[k], sh.fml[k], sh.fix[k], sh.cv[k] = nil, nil, nil, nil end
      end
      if what ~= "values" then sh.sty[k] = nil end
    end
  end)
  endEdit()
end
local function styleSel(fn)
  local sh = curSheet()
  beginEdit(sh)
  eachSel(sh, function(r, c, k)
    record(sh, k)
    local st = copyStyle(styleOf(sh, k))
    fn(st, k)
    sh.sty[k] = styleId(st)
    grow(sh, r, c)
  end)
  endEdit()
end
local function activeStyle()
  local sh = curSheet()
  local v = view(sh)
  return styleOf(sh, key(v.r, v.c)) or {}
end
local function decimals(delta)
  local sh = curSheet()
  local v = view(sh)
  local cur = activeStyle().nf
  local val = sh.val[key(v.r, v.c)]
  styleSel(function(st)
    local code = st.nf or cur
    if not code then
      local shown = type(val) == "number" and numText(val) or "0"
      local d = #(shown:match("%.(%d+)$") or "")
      code = "#,##0" .. (d > 0 and ("." .. string.rep("0", d)) or "")
    end
    local secs = {}
    for part in (code .. ";"):gmatch("(.-);") do
      local a, dd, b = part:match("^(.-[0#])%.([0#]*)(.*)$")
      if a then
        local n = max(0, #dd + delta)
        part = a .. (n > 0 and ("." .. string.rep("0", n)) or "") .. b
      elseif delta > 0 then
        part = part:gsub("([0#])([^0#]*)$", "%1.0%2", 1)
      end
      secs[#secs + 1] = part
    end
    st.nf = table.concat(secs, ";")
  end)
end

---------------------------------------------------------------- layout / scrolling
local function layout(sh)
  local v = view(sh)
  local cols, rows = {}, {}
  local x = X0 + RHW
  local function addC(c)
    if x > X1 then return false end
    local w = colW(sh, c)
    cols[#cols + 1] = { c = c, x = x, w = min(w, X1 - x + 1), clip = x + w - 1 > X1 }
    x = x + w
    return true
  end
  for c = 1, min(sh.frC, sh.cols) do if not addC(c) then break end end
  local c = max(v.left, sh.frC + 1)
  while c <= sh.cols and addC(c) do c = c + 1 end
  local y = G1
  for r = 1, min(sh.frR, sh.rows) do
    if y > G2 then break end
    rows[#rows + 1] = { r = r, y = y }; y = y + 1
  end
  local r = max(v.top, sh.frR + 1)
  while r <= sh.rows and y <= G2 do rows[#rows + 1] = { r = r, y = y }; y = y + 1; r = r + 1 end
  L.cols, L.rows, L.sh = cols, rows, sh
end
local function ensureVisible(sh, r, c)
  local v = view(sh)
  if r > sh.frR then
    local vis = (G2 - G1 + 1) - min(sh.frR, G2 - G1)
    if r < v.top then v.top = r elseif r > v.top + vis - 1 then v.top = r - vis + 1 end
    if v.top <= sh.frR then v.top = sh.frR + 1 end
  end
  if c > sh.frC then
    if c < v.left then v.left = c
    else
      local avail = X1 - (X0 + RHW) + 1
      for cc = 1, min(sh.frC, sh.cols) do avail = avail - colW(sh, cc) end
      while true do
        local w = 0
        for cc = max(v.left, sh.frC + 1), c do w = w + colW(sh, cc) end
        if w <= avail or v.left >= c then break end
        v.left = v.left + 1
      end
    end
    if v.left <= sh.frC then v.left = sh.frC + 1 end
  end
end
local function cellAt(x, y)
  local r, c
  for _, row in ipairs(L.rows) do if row.y == y then r = row.r end end
  for _, col in ipairs(L.cols) do if x >= col.x and x < col.x + col.w then c = col.c end end
  return r, c
end
local function selectCell(r, c, keepAnchor)
  local sh = curSheet()
  local v = view(sh)
  r, c = max(1, min(sh.rows, r)), max(1, min(sh.cols, c))
  if keepAnchor then v.er, v.ec = r, c else v.r, v.c, v.er, v.ec = r, c, r, c end
  ensureVisible(sh, r, c)
end

---------------------------------------------------------------- the cell editor
local function startEdit(initial, quick)
  local sh = curSheet()
  local v = view(sh)
  ensureVisible(sh, v.r, v.c)
  V.ed = { text = initial, cur = ulen(initial), r = v.r, c = v.c, quick = quick, orig = rawText(sh, key(v.r, v.c)) }
end
local function cancelEdit() V.ed = nil end
local function commitEdit(dr, dc)
  local ed = V.ed
  if not ed then return end
  V.ed = nil
  local sh = curSheet()
  if ed.text ~= ed.orig then
    local s = ed.text
    if isFormula(s) then                                        -- close brackets left open, like Sheets
      local depth, inStr = 0, false
      for i = 2, #s do
        local ch = s:sub(i, i)
        if ch == '"' then inStr = not inStr
        elseif not inStr then if ch == "(" then depth = depth + 1 elseif ch == ")" then depth = depth - 1 end end
      end
      if depth > 0 and not inStr then s = s .. string.rep(")", depth) end
    end
    beginEdit(sh)
    setCell(sh, ed.r, ed.c, s)
    endEdit()
  end
  selectCell(ed.r + (dr or 0), ed.c + (dc or 0))
end
local function edInsert(s)
  local ed = V.ed
  ed.text = usub(ed.text, 1, ed.cur) .. s .. usub(ed.text, ed.cur + 1)
  ed.cur = ed.cur + ulen(s)
  ed.ins = nil
end
-- clicking a cell while typing a formula puts its address in (Sheets' "point" mode)
local function canPoint()
  local ed = V.ed
  if not ed or not isFormula(ed.text) and ed.text ~= "=" then return false end
  if ed.ins and ed.ins.e == ed.cur then return true end
  local before = usub(ed.text, ed.cur, ed.cur)
  return before ~= "" and ("=(,+-*/^&<>:;{"):find(before, 1, true) ~= nil
end
local function pointRef(r1, c1, r2, c2)
  local ed = V.ed
  local sh = curSheet()
  local s = refName(r1, c1)
  if r2 and (r2 ~= r1 or c2 ~= c1) then s = refName(min(r1, r2), min(c1, c2)) .. ":" .. refName(max(r1, r2), max(c1, c2)) end
  local start = (ed.ins and ed.ins.e == ed.cur) and ed.ins.s or ed.cur
  ed.text = usub(ed.text, 1, start) .. s .. usub(ed.text, ed.cur + 1)
  ed.cur = start + ulen(s)
  ed.ins = { s = start, e = ed.cur }
end
-- function names matching the word being typed (autocomplete list)
local function acWord()
  local ed = V.ed
  if not ed or not isFormula(ed.text) and ed.text:sub(1, 1) ~= "=" then return nil end
  local before = usub(ed.text, 1, ed.cur)
  local _, q = before:gsub('"', '')
  if q % 2 == 1 then return nil end
  local w = before:match("([%a_][%w_%.]*)$")
  if not w then return nil end
  local prev = before:sub(-#w - 1, -#w - 1)
  if prev:match("[%w_%$!']") then return nil end
  return w
end
local function acList()
  local w = acWord()
  if not w then return {} end
  local up, out = w:upper(), {}
  for _, n in ipairs(ENG.names) do
    if n:sub(1, #up) == up and n ~= up then out[#out + 1] = n; if #out >= 6 then break end end
  end
  return out, w
end
local function acAccept(name)
  local _, w = acList()
  local ed = V.ed
  if not w then return end
  local start = ed.cur - ulen(w)
  ed.text = usub(ed.text, 1, start) .. name .. "(" .. usub(ed.text, ed.cur + 1)
  ed.cur = start + ulen(name) + 1
end

---------------------------------------------------------------- copy / paste
local function copySel(cut)
  local sh = curSheet()
  local r1, c1, r2, c2 = selBox(sh)
  r2, c2 = min(r2, max(r1, sh.maxR)), min(c2, max(c1, sh.maxC))
  if (r2 - r1 + 1) * (c2 - c1 + 1) > 20000 then say("That selection is too big to copy."); return end
  local cells = {}
  for r = r1, r2 do for c = c1, c2 do
    local k = key(r, c)
    cells[#cells + 1] = { sh.val[k], sh.fml[k], sh.sty[k] }
  end end
  V.clip = { sh = sh, r1 = r1, c1 = c1, nr = r2 - r1 + 1, nc = c2 - c1 + 1, cells = cells, cut = cut }
  say((cut and "Cut " or "Copied ") .. refName(r1, c1) .. (cells[2] and (":" .. refName(r2, c2)) or ""))
end
local function pasteClip(valuesOnly)
  local cl = V.clip
  if not cl then return end
  local sh = curSheet()
  local v = view(sh)
  local r0, c0 = v.r, v.c
  beginEdit(sh)
  if cl.cut and cl.sh == sh then
    for i = 0, cl.nr - 1 do for j = 0, cl.nc - 1 do
      local k = key(cl.r1 + i, cl.c1 + j)
      record(sh, k)
      if sh.so[k] then ENG.clearSpill(sh, k) end
      sh.val[k], sh.fml[k], sh.sty[k], sh.fix[k], sh.cv[k] = nil, nil, nil, nil, nil
    end end
  end
  for i = 0, cl.nr - 1 do for j = 0, cl.nc - 1 do
    local cell = cl.cells[i * cl.nc + j + 1]
    local r, c = r0 + i, c0 + j
    if r <= MAXR and c <= MAXC then
      local k = key(r, c)
      record(sh, k)
      if sh.so[k] then ENG.clearSpill(sh, k) end
      sh.fix[k], sh.cv[k], sh.sp[k], sh.cg[k] = nil, nil, nil, nil
      local f = cell[2]
      if f and not valuesOnly then
        sh.fml[k], sh.val[k] = cl.cut and f or ENG.shift(f, r - (cl.r1 + i), c - (cl.c1 + j)), nil
      else
        sh.fml[k] = nil
        if f and valuesOnly then sh.val[k] = cl.sh.val[key(cl.r1 + i, cl.c1 + j)] else sh.val[k] = cell[1] end
      end
      if not valuesOnly then sh.sty[k] = cell[3] end
      grow(sh, r, c)
    end
  end end
  v.er, v.ec = r0 + cl.nr - 1, c0 + cl.nc - 1
  if cl.cut then V.clip = nil end
  endEdit()
end
-- text from the real clipboard (middle-click / Insert in OpenComputers): tabs and lines become cells
local function pasteText(s)
  local sh = curSheet()
  local v = view(sh)
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n$", "")
  beginEdit(sh)
  local r = v.r
  for line in (s .. "\n"):gmatch("(.-)\n") do
    local c = v.c
    for cellText in (line .. "\t"):gmatch("(.-)\t") do
      if r <= MAXR and c <= MAXC then setCell(sh, r, c, cellText) end
      c = c + 1
    end
    r = r + 1
  end
  endEdit()
end
local function fillCells(dir)                                  -- Ctrl+D (down) / Ctrl+R (right)
  local sh = curSheet()
  local r1, c1, r2, c2 = selBox(sh)
  beginEdit(sh)
  for r = r1, r2 do for c = c1, c2 do
    local sr, sc = dir == "down" and r1 or r, dir == "down" and c or c1
    if r ~= sr or c ~= sc then
      local sk, k = key(sr, sc), key(r, c)
      record(sh, k)
      if sh.so[k] then ENG.clearSpill(sh, k) end
      sh.fix[k], sh.cv[k], sh.sp[k], sh.cg[k] = nil, nil, nil, nil
      if sh.fml[sk] then sh.fml[k], sh.val[k] = ENG.shift(sh.fml[sk], r - sr, c - sc), nil
      else sh.fml[k], sh.val[k] = nil, sh.val[sk] end
      sh.sty[k] = sh.sty[sk]
      grow(sh, r, c)
    end
  end end
  endEdit()
end

---------------------------------------------------------------- rows / columns
local function remap(t, axis, at, n)
  local nt = {}
  local last = at - n - 1
  for k, v in pairs(t) do
    local r, c = keyRC(k)
    local x = axis == "r" and r or c
    local keep = true
    if n > 0 then if x >= at then x = x + n end
    elseif x >= at and x <= last then keep = false
    elseif x > last then x = x + n end
    if keep and x >= 1 then
      if axis == "r" then nt[key(x, c)] = v else nt[key(r, x)] = v end
    end
  end
  return nt
end
local function structural(sh, axis, at, n)
  for _, s in ipairs(WB.sheets) do
    for k, f in pairs(s.fml) do
      local nf = ENG.moveRefs(f, s.name, sh.name, axis, at, n)
      if nf ~= f then s.fml[k] = nf end
    end
  end
  for k in pairs(sh.sp) do sh.val[k] = nil end
  sh.val, sh.fml, sh.sty = remap(sh.val, axis, at, n), remap(sh.fml, axis, at, n), remap(sh.sty, axis, at, n)
  sh.fix, sh.cv = remap(sh.fix, axis, at, n), remap(sh.cv, axis, at, n)
  sh.sp, sh.so, sh.cg = {}, {}, {}
  if axis == "c" then
    local nw = {}
    for c, w in pairs(sh.colW) do
      if n > 0 then nw[c >= at and c + n or c] = w
      elseif c < at then nw[c] = w
      elseif c > at - n - 1 then nw[c + n] = w end
    end
    sh.colW = nw
    sh.cols = max(1, sh.cols + n)
    sh.maxC = max(0, sh.maxC + n)
    if sh.frC >= at then sh.frC = max(at - 1, sh.frC + n) end
  else
    sh.rows = max(1, sh.rows + n)
    sh.maxR = max(0, sh.maxR + n)
    if sh.frR >= at then sh.frR = max(at - 1, sh.frR + n) end
  end
end
local function snapFormulas()
  local all = {}
  for i, s in ipairs(WB.sheets) do
    local t = {}
    for k, f in pairs(s.fml) do t[k] = f end
    all[i] = t
  end
  return all
end
local function doStructural(axis, at, n)
  local sh = curSheet()
  local rec = { kind = "struct", sh = sh, axis = axis, at = at, n = n, fml = snapFormulas(), frR = sh.frR, frC = sh.frC }
  if axis == "c" then rec.colW = {} for c, w in pairs(sh.colW) do rec.colW[c] = w end end
  if n < 0 then
    rec.cells = {}
    for _, t in ipairs({ "val", "sty", "fix", "cv" }) do
      for k, v in pairs(sh[t]) do
        local r, c = keyRC(k)
        local x = axis == "r" and r or c
        if x >= at and x <= at - n - 1 and not (t == "val" and sh.sp[k]) then rec.cells[#rec.cells + 1] = { t, k, v } end
      end
    end
  end
  structural(sh, axis, at, n)
  pushUndo(rec)
  changed()
end
local function undoStructural(rec)
  local sh = rec.sh
  structural(sh, rec.axis, rec.at, -rec.n)
  if rec.cells then for _, c in ipairs(rec.cells) do sh[c[1]][c[2]] = c[3] end end
  for i, s in ipairs(WB.sheets) do if rec.fml[i] then s.fml = rec.fml[i] end s.cg = {} end
  if rec.colW then sh.colW = rec.colW end
  sh.frR, sh.frC = rec.frR, rec.frC
  for k in pairs(sh.val) do local r, c = keyRC(k); grow(sh, r, c) end
  return { kind = "redoStruct", sh = sh, axis = rec.axis, at = rec.at, n = rec.n }
end
local function insertRows(where)
  local sh = curSheet()
  local r1, _, r2 = selBox(sh)
  local n = r2 - r1 + 1
  doStructural("r", where == "above" and r1 or r2 + 1, n)
  if where == "above" then local v = view(sh); v.r, v.er = v.r + n, v.er + n end
end
local function insertCols(where)
  local sh = curSheet()
  local _, c1, _, c2 = selBox(sh)
  local n = c2 - c1 + 1
  doStructural("c", where == "left" and c1 or c2 + 1, n)
  if where == "left" then local v = view(sh); v.c, v.ec = v.c + n, v.ec + n end
end
local function deleteRows()
  local sh = curSheet()
  local r1, _, r2 = selBox(sh)
  doStructural("r", r1, -(r2 - r1 + 1))
  selectCell(r1, view(sh).c)
end
local function deleteCols()
  local sh = curSheet()
  local _, c1, _, c2 = selBox(sh)
  doStructural("c", c1, -(c2 - c1 + 1))
  selectCell(view(sh).r, c1)
end

local function undo()
  local rec = table.remove(V.undo)
  if not rec then say("Nothing to undo"); return end
  local back
  if rec.kind == "struct" then back = undoStructural(rec) else back = swapCells(rec) end
  V.redo[#V.redo + 1] = back
  ENG.recalc()
  V.dirty, V.lastEdit = true, computer.uptime()
end
local function redo()
  local rec = table.remove(V.redo)
  if not rec then say("Nothing to redo"); return end
  local back
  if rec.kind == "struct" then back = undoStructural(rec)
  elseif rec.kind == "redoStruct" then
    local keepRedo = V.redo
    local cur = WB.cur
    for i, s in ipairs(WB.sheets) do if s == rec.sh then WB.cur = i end end
    doStructural(rec.axis, rec.at, rec.n)
    WB.cur = cur
    V.redo = keepRedo
    return
  else back = swapCells(rec) end
  V.undo[#V.undo + 1] = back
  ENG.recalc()
  V.dirty, V.lastEdit = true, computer.uptime()
end

---------------------------------------------------------------- sorting
local function sortRange(asc, wholeSheet)
  local sh = curSheet()
  local v = view(sh)
  local r1, c1, r2, c2 = selBox(sh)
  if wholeSheet or (r1 == r2 and c1 == c2) then r1, c1, r2, c2 = sh.frR + 1, 1, max(sh.frR + 1, sh.maxR), max(1, sh.maxC) end
  local col = v.c
  if col < c1 or col > c2 then col = c1 end
  local rows = {}
  for r = r1, r2 do
    local row = { r = r, key = ENG.cellValue(sh, r, col) }
    for c = c1, c2 do local k = key(r, c); row[c] = { sh.val[k], sh.fml[k], sh.sty[k] } end
    rows[#rows + 1] = row
  end
  table.sort(rows, function(a, b)
    local x, y = a.key, b.key
    if x == BLANK and y ~= BLANK then return false end
    if y == BLANK and x ~= BLANK then return true end
    if x ~= BLANK and y ~= BLANK and not isErr(x) and not isErr(y) then
      local c = ENG.compare(x, y)
      if c ~= 0 then if asc then return c < 0 end return c > 0 end
    end
    return a.r < b.r
  end)
  beginEdit(sh)
  for i, row in ipairs(rows) do
    local r = r1 + i - 1
    for c = c1, c2 do
      local k, cell = key(r, c), row[c]
      record(sh, k)
      if sh.so[k] then ENG.clearSpill(sh, k) end
      sh.sp[k], sh.cg[k], sh.fix[k], sh.cv[k] = nil, nil, nil, nil
      sh.val[k], sh.sty[k] = cell[1], cell[3]
      sh.fml[k] = cell[2] and ENG.shift(cell[2], r - row.r, 0) or nil
      if cell[2] then sh.val[k] = nil end
    end
  end
  endEdit()
end

---------------------------------------------------------------- sheets (tabs)
local function sheetName(base)
  local n, name = 1, base
  while sheetByName(name) do n = n + 1; name = base .. n end
  return name
end
local function addSheet()
  commitEdit(0, 0)
  local sh = newSheet(sheetName("Sheet"))
  table.insert(WB.sheets, WB.cur + 1, sh)
  WB.cur = WB.cur + 1
  V.undo, V.redo = {}, {}
  changed()
end
local function renameSheet(sh, new)
  new = new:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[%c]", "")
  if new == "" or new == sh.name then return end
  local other = sheetByName(new)
  if other and other ~= sh then A.dialog("Rename", { "A sheet named \"" .. new .. "\" already exists." }, { { "OK" } }); return end
  for _, s in ipairs(WB.sheets) do
    for k, f in pairs(s.fml) do s.fml[k] = ENG.renameRefs(f, sh.name, new) end
  end
  sh.name = new
  changed()
end
local function deleteSheet()
  if #WB.sheets == 1 then A.dialog("Delete sheet", { "A spreadsheet needs at least one sheet." }, { { "OK" } }); return end
  local sh = curSheet()
  A.dialog("Delete sheet", { "Delete \"" .. sh.name .. "\"? Formulas that use it will show #REF!.", "This can't be undone." }, {
    { "Delete", function()
        table.remove(WB.sheets, WB.cur)
        WB.cur = min(WB.cur, #WB.sheets)
        V.undo, V.redo = {}, {}
        changed()
      end }, { "Cancel" } })
end
local function duplicateSheet()
  local sh = curSheet()
  local cp = newSheet(sheetName("Copy of " .. sh.name))
  for _, t in ipairs({ "val", "fml", "sty", "fix", "cv", "colW" }) do for k, v in pairs(sh[t]) do cp[t][k] = v end end
  for k in pairs(sh.sp) do cp.val[k] = nil end
  cp.rows, cp.cols, cp.frR, cp.frC, cp.maxR, cp.maxC = sh.rows, sh.cols, sh.frR, sh.frC, sh.maxR, sh.maxC
  table.insert(WB.sheets, WB.cur + 1, cp)
  WB.cur = WB.cur + 1
  changed()
end
local function moveSheet(d)
  local i, j = WB.cur, WB.cur + d
  if j < 1 or j > #WB.sheets then return end
  WB.sheets[i], WB.sheets[j] = WB.sheets[j], WB.sheets[i]
  WB.cur = j
  changed()
end

---------------------------------------------------------------- prompt (small text box)
local function prompt(title, initial, onOk, hint)
  V.prompt = { title = title, text = initial or "", onOk = onOk, hint = hint, fresh = (initial or "") ~= "" }
  V.prompt.cur = ulen(V.prompt.text)
end

---------------------------------------------------------------- files (start page)
local function listFiles()
  local out = {}
  for name in filesystem.list(DIR) do
    if name:match("%.lsh$") then
      local p = DIR .. "/" .. name
      out[#out + 1] = { name = name:gsub("%.lsh$", ""), path = p, size = filesystem.size(p) or 0,
                        time = (filesystem.lastModified(p) or 0) / 1000 }
    end
  end
  table.sort(out, function(a, b) return a.time > b.time end)
  V.files = out
end
local function when(t)
  if not t or t < 1e9 then return "--" end
  local e = A.toEastern(t)
  local n = A.toEastern(A.now())
  local mon = ({ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" })[e.month]
  if e.year == n.year and e.month == n.month and e.day == n.day then
    local h = e.hour % 12
    return string.format("%d:%02d %s", h == 0 and 12 or h, e.min, e.hour < 12 and "AM" or "PM")
  end
  if e.year == n.year then return mon .. " " .. e.day end
  return mon .. " " .. e.day .. ", " .. e.year
end
local function openWorkbook(wb, path)
  WB = wb
  V.file, V.mode = path, "grid"
  V.undo, V.redo, V.ed, V.prompt, V.pop, V.clip = {}, {}, nil, nil, nil, nil
  ENG.recalc()
  say("All changes saved")
  collectgarbage()
end
local function openFile(f)
  local wb, e = IO.load(f.path)
  if not wb then A.dialog("Open", { "Could not open " .. f.name .. ":", tostring(e) }, { { "OK" } }); return end
  wb.name = f.name
  openWorkbook(wb, f.path)
end
local function closeWorkbook()
  if V.ed then commitEdit(0, 0) end
  if V.dirty then saveNow() end
  WB, V.file, V.mode = nil, nil, "home"
  V.undo, V.redo, V.clip, V.files = {}, {}, nil, nil
  collectgarbage()
end
local function newBlank()
  closeWorkbook()
  newWorkbook("Untitled spreadsheet")
  local path = uniquePath("Untitled spreadsheet")
  WB.name = path:match("([^/]+)%.lsh$")
  openWorkbook(WB, path)
  saveNow()
end
local function renameWorkbook(new)
  new = safeName(new)
  if not WB or new == WB.name then return end
  local p = DIR .. "/" .. new .. ".lsh"
  if filesystem.exists(p) then A.dialog("Rename", { "There is already a spreadsheet called \"" .. new .. "\"." }, { { "OK" } }); return end
  saveNow()
  filesystem.rename(V.file, p)
  V.file, WB.name = p, new
end
local function fileMenu(f, x, y)
  menu(x, y, {
    { "Open", function() openFile(f) end },
    { "Rename...", function()
        prompt("Rename spreadsheet", f.name, function(s)
          s = safeName(s)
          local p = DIR .. "/" .. s .. ".lsh"
          if s ~= f.name and not filesystem.exists(p) then filesystem.rename(f.path, p) end
          V.files = nil
        end)
      end },
    { "Make a copy", function()
        local p = uniquePath("Copy of " .. f.name)
        local src, dst = io.open(f.path, "r"), io.open(p, "w")
        if src and dst then
          while true do local s = src:read(4096); if not s then break end dst:write(s) end
        end
        if src then src:close() end
        if dst then dst:close() end
        V.files = nil
      end },
    { "-" },
    { "Delete...", function()
        A.dialog("Delete", { "Delete \"" .. f.name .. "\"? This can't be undone." }, {
          { "Delete", function() filesystem.remove(f.path); V.files = nil end }, { "Cancel" } })
      end },
  })
end

---------------------------------------------------------------- import job
local slice = 0
local function pause() if os.clock() - slice > 0.04 then coroutine.yield() end end
local function startImport()
  if V.job then return end
  local link = V.link
  if link:gsub("%s", "") == "" then V.jobErr = "Paste the link of the Google Sheet first."; return end
  if not A.inet() then V.jobErr = "No Internet Card found. Install one to import."; return end
  closeWorkbook()
  V.jobErr, V.jobMsg = nil, "Starting..."
  V.job = coroutine.create(function()
    V.jobMsg, V.jobDirty = "Loading the importer...", true
    local XL = loadImporter()
    return XL.import(link, DIR .. "/.import.xlsx", function(s) V.jobMsg, V.jobDirty = s, true end, pause)
  end)
end
local function finishImport(wb, missing)
  local path = uniquePath(wb.name)
  wb.name = path:match("([^/]+)%.lsh$")
  openWorkbook(wb, path)
  saveNow()
  V.link, V.importOpen, V.jobMsg = "", false, nil
  if missing and #missing > 0 then
    A.dialog("Imported " .. wb.name, {
      "These Google Sheets functions aren't available here:",
      "  " .. table.concat(missing, ", "):sub(1, 70),
      "Their cells keep the values Google calculated (marked with a dot).",
      "Everything else is recalculated by Lymanos.",
    }, { { "OK" } })
  end
end
local function pump()
  if not V.job then return end
  slice = os.clock()
  local ok, a, b = coroutine.resume(V.job)
  if coroutine.status(V.job) == "dead" then
    V.job = nil
    if ok then finishImport(a, b)
    else V.jobErr, V.jobMsg = tostring(a), nil; WB = nil; collectgarbage() end
    if A.isActive() and not A.getOverlay() then A.drawAll() end
  elseif V.jobDirty and A.isActive() and not A.getOverlay() then
    V.jobDirty = false
    drawWindow()
  end
end

---------------------------------------------------------------- menus
local function goHome() closeWorkbook(); listFiles() end
local NUMFMT = {
  { "Automatic", nil }, { "Plain text", "@" }, { "Number          1,000.12", "#,##0.00" },
  { "Percent         10.12%", "0.00%" }, { "Scientific      1.01E+03", "0.00E+00" },
  { "Currency        $1,000.12", '"$"#,##0.00' }, { "Currency (rounded)  $1,000", '"$"#,##0' },
  { "Date            9/26/2008", "m/d/yyyy" }, { "Time            3:59:00 PM", "h:mm:ss AM/PM" },
  { "Date time       9/26/2008 15:59:00", "m/d/yyyy h:mm:ss" }, { "Duration        24:01:00", "[h]:mm:ss" },
}
local function numberMenu(x, y)
  local items = {}
  for _, it in ipairs(NUMFMT) do
    items[#items + 1] = { it[1], function() styleSel(function(st) st.nf = it[2] end) end }
  end
  menu(x, y, items)
end
local function alignMenu(x, y)
  menu(x, y, {
    { "Left", function() styleSel(function(st) st.al = "l" end) end },
    { "Center", function() styleSel(function(st) st.al = "c" end) end },
    { "Right", function() styleSel(function(st) st.al = "r" end) end },
    { "Automatic", function() styleSel(function(st) st.al = nil end) end },
  })
end
local function fnMenu(x, y)
  local items = {}
  for _, n in ipairs({ "SUM", "AVERAGE", "COUNT", "MAX", "MIN", "IF", "VLOOKUP", "XLOOKUP", "SUMIF", "COUNTIF",
                       "CONCATENATE", "TODAY" }) do
    items[#items + 1] = { n, function() startEdit("=" .. n .. "(", false) end }
  end
  menu(x, y, items)
end
local function freezeMenu(x, y)
  local sh = curSheet()
  local v = view(sh)
  menu(x, y, {
    { "No rows", function() sh.frR = 0; changed() end },
    { "1 row", function() sh.frR = 1; changed() end },
    { "2 rows", function() sh.frR = 2; changed() end },
    { "Up to row " .. v.r, function() sh.frR = v.r; changed() end },
    { "-" },
    { "No columns", function() sh.frC = 0; changed() end },
    { "1 column", function() sh.frC = 1; changed() end },
    { "2 columns", function() sh.frC = 2; changed() end },
    { "Up to column " .. colName(v.c), function() sh.frC = v.c; changed() end },
  })
end
local MENUS = {
  { "File", function(x, y)
      menu(x, y, {
        { "New spreadsheet", newBlank },
        { "Open (start page)", goHome },
        { "Import from Google Sheets...", function() goHome(); V.importOpen = true end },
        { "Make a copy", function()
            saveNow()
            local p = uniquePath("Copy of " .. WB.name)
            local ok = IO.save(p)
            if ok then WB.name = p:match("([^/]+)%.lsh$"); V.file = p; V.undo, V.redo = {}, {} end
            say(ok and "Now editing the copy" or "Could not copy")
          end },
        { "Rename...", function() prompt("Rename spreadsheet", WB.name, renameWorkbook) end },
        { "-" },
        { "Delete...", function()
            A.dialog("Delete", { "Delete \"" .. WB.name .. "\"? This can't be undone." }, {
              { "Delete", function() local p = V.file; V.dirty = false; closeWorkbook(); filesystem.remove(p); listFiles() end },
              { "Cancel" } })
          end },
        { "Close", goHome },
      })
    end },
  { "Edit", function(x, y)
      menu(x, y, {
        { "Undo            Ctrl+Z", undo }, { "Redo            Ctrl+Y", redo }, { "-" },
        { "Cut             Ctrl+X", function() copySel(true) end },
        { "Copy            Ctrl+C", function() copySel(false) end },
        { "Paste           Ctrl+V", function() pasteClip(false) end },
        { "Paste values only", function() pasteClip(true) end }, { "-" },
        { "Fill down       Ctrl+D", function() fillCells("down") end },
        { "Fill right      Ctrl+R", function() fillCells("right") end }, { "-" },
        { "Delete values   Delete", function() clearSel("values") end },
        { "Delete row(s)", deleteRows }, { "Delete column(s)", deleteCols },
      })
    end },
  { "View", function(x, y)
      menu(x, y, {
        { (V.showF and "✓ " or "  ") .. "Show formulas   Ctrl+`", function() V.showF = not V.showF end },
        { "Freeze...", function() freezeMenu(x + 10, y + 2) end },
        { "Go to cell...", function()
            prompt("Go to cell", "", function(s)
              local toks = ENG.tokenize(s)
              local tk = toks and toks[1]
              if tk and (tk[1] == "ref" or tk[1] == "rng") then
                if tk.sheet and sheetByName(tk.sheet) then for i, sh in ipairs(WB.sheets) do if sh == sheetByName(tk.sheet) then WB.cur = i end end end
                selectCell(tk.r or tk.r1, tk.c or tk.c1)
              end
            end, "for example B12 or Sheet2!A1")
          end },
      })
    end },
  { "Insert", function(x, y)
      menu(x, y, {
        { "Row above", function() insertRows("above") end }, { "Row below", function() insertRows("below") end },
        { "Column left", function() insertCols("left") end }, { "Column right", function() insertCols("right") end },
        { "-" }, { "New sheet", addSheet }, { "Function...", function() fnMenu(x + 10, y + 6) end },
      })
    end },
  { "Format", function(x, y)
      menu(x, y, {
        { "Number...", function() numberMenu(x + 10, y + 1) end },
        { "Bold            Ctrl+B", function() local b = not activeStyle().b; styleSel(function(st) st.b = b or nil end) end },
        { "Alignment...", function() alignMenu(x + 10, y + 3) end },
        { "-" },
        { "Clear formatting", function() clearSel("formats") end },
      })
    end },
  { "Data", function(x, y)
      menu(x, y, {
        { "Sort range A → Z", function() sortRange(true) end },
        { "Sort range Z → A", function() sortRange(false) end },
        { "Sort sheet A → Z (by this column)", function() sortRange(true, true) end },
        { "Sort sheet Z → A (by this column)", function() sortRange(false, true) end },
      })
    end },
  { "Help", function(x, y)
      menu(x, y, {
        { "Keyboard shortcuts", function()
            A.dialog("Keyboard shortcuts", {
              "Arrows move · Shift+arrows select · Ctrl+arrows jump to the edge of the data",
              "Type to replace a cell · Enter or F2 edits it · Enter / Tab saves and moves",
              "Esc cancels · Delete clears · Ctrl+Z undo · Ctrl+Y redo · Ctrl+B bold",
              "Ctrl+C copy · Ctrl+X cut · Ctrl+V paste · Ctrl+D fill down · Ctrl+R fill right",
              "Ctrl+` show formulas · Ctrl+A select all · Ctrl+Home goes to A1",
              "While typing a formula: click a cell (or drag a range) to put its address in.",
              "Middle-click / Insert pastes text from your real clipboard (tabs = columns).",
            }, { { "OK" } })
          end },
        { "Functions list", function()
            local lines, cur = {}, ""
            for _, n in ipairs(ENG.names) do
              if #cur + #n + 2 > 96 then lines[#lines + 1] = cur; cur = "" end
              cur = cur .. (cur == "" and "" or ", ") .. n
            end
            lines[#lines + 1] = cur
            A.dialog(#ENG.names .. " functions", lines, { { "OK" } })
          end },
        { "About Spreadsheets", function()
            A.dialog("About Spreadsheets", {
              "Spreadsheets for Lymanos - works like Google Sheets.",
              "Saved in " .. DIR .. "  ·  this file: " .. tostring(V.file):match("[^/]*$"),
              string.format("RAM free: %d KB of %d KB", floor(computer.freeMemory() / 1024), floor(computer.totalMemory() / 1024)),
            }, { { "OK" } })
          end },
      })
    end },
}

local function contextMenu(x, y)
  menu(x, y, {
    { "Cut", function() copySel(true) end }, { "Copy", function() copySel(false) end },
    { "Paste", function() pasteClip(false) end }, { "Paste values only", function() pasteClip(true) end },
    { "-" },
    { "Insert row above", function() insertRows("above") end }, { "Insert row below", function() insertRows("below") end },
    { "Insert column left", function() insertCols("left") end }, { "Insert column right", function() insertCols("right") end },
    { "Delete row", deleteRows }, { "Delete column", deleteCols },
    { "-" },
    { "Delete values", function() clearSel("values") end },
  })
end

---------------------------------------------------------------- drawing: header, toolbar, formula bar
local function drawTitle()
  fill(X0, YT, X1 - X0 + 1, 1, C.top)
  text(X0 + 1, YT, " ▦ ", C.white, C.green)
  region(V.reg, X0 + 1, YT, 3, 1, goHome)
  local name = WB.name
  if ulen(name) > 28 then name = usub(name, 1, 27) .. "…" end
  textW(X0 + 5, YT, ulen(name) + 1, name, C.ink, C.top)
  region(V.reg, X0 + 5, YT, ulen(name) + 1, 1, function() prompt("Rename spreadsheet", WB.name, renameWorkbook) end)
  local x = X0 + 7 + ulen(name)
  for _, m in ipairs(MENUS) do
    local lbl = " " .. m[1] .. " "
    text(x, YT, lbl, C.ink, C.top)
    local mx = x
    region(V.reg, x, YT, #lbl, 1, function() if V.ed then commitEdit(0, 0) end m[2](mx, YT + 1) end)
    x = x + #lbl
  end
  local st = V.saveMsg or ""
  textW(X1 - 30, YT, 30, st, st:find("^Not") and C.red or C.dim, C.top, "right")
end

local function drawToolbar()
  fill(X0, YB, X1 - X0 + 1, 1, C.tool)
  local st = activeStyle()
  local x = X0 + 1
  local function sep() text(x, YB, "│", C.border, C.tool); x = x + 2 end
  local function btn(lbl, fn, on, fgc)
    text(x, YB, " " .. lbl .. " ", fgc or C.ink, on and C.selHdr or C.tool)
    local bx, w = x, ulen(lbl) + 2
    region(V.reg, x, YB, w, 1, function() if V.ed then commitEdit(0, 0) end fn(bx, YB + 1) end)
    x = x + w + 1
  end
  btn("↶", undo) btn("↷", redo) sep()
  btn("$", function() styleSel(function(s) s.nf = '"$"#,##0.00' end) end)
  btn("%", function() styleSel(function(s) s.nf = "0.00%" end) end)
  btn(".0←", function() decimals(-1) end) btn(".00→", function() decimals(1) end)
  btn("123▾", numberMenu) sep()
  btn("B", function() local b = not st.b; styleSel(function(s) s.b = b or nil end) end, st.b)
  btn("A▾", function(bx, by) V.pop = { kind = "fg", x = bx, y = by } end, false, st.fg or C.ink)
  btn("◧▾", function(bx, by) V.pop = { kind = "bg", x = bx, y = by } end, false, st.bg and st.bg ~= 0xFFFFFF and st.bg or C.ink)
  sep()
  btn(st.al == "c" and "≡ center▾" or (st.al == "r" and "≡ right▾" or "≡ left▾"), alignMenu) sep()
  btn("Σ▾", fnMenu)
  btn("⇅ Sort", function() sortRange(true) end)
  btn("❄ Freeze▾", freezeMenu)
  btn(V.showF and "fx on" or "fx", function() V.showF = not V.showF end, V.showF)
end

local function drawFx()
  local sh = curSheet()
  local v = view(sh)
  local r1, c1, r2, c2 = selBox(sh)
  fill(X0, YF, X1 - X0 + 1, 1, C.white)
  local nm = refName(v.r, v.c)
  if r1 ~= r2 or c1 ~= c2 then nm = refName(r1, c1) .. ":" .. refName(r2, c2) end
  textW(X0 + 1, YF, 12, nm, C.ink, C.white)
  region(V.reg, X0 + 1, YF, 12, 1, function()
    prompt("Go to cell", "", function(s)
      local toks = ENG.tokenize(s)
      local tk = toks and toks[1]
      if tk and (tk[1] == "ref" or tk[1] == "rng") then selectCell(tk.r or tk.r1, tk.c or tk.c1) end
    end, "for example B12")
  end)
  text(X0 + 13, YF, "│ ", C.border, C.white)
  text(X0 + 15, YF, "fx", C.dim, C.white)
  local fx = X0 + 18
  local w = X1 - fx
  local ed = V.ed
  if ed then
    local s = ed.text
    local off = 0
    if ed.cur > w - 2 then off = ed.cur - (w - 2) end
    local shown = usub(s, off + 1, off + w)
    textW(fx, YF, w, shown, C.ink, C.white)
    local cx = fx + ed.cur - off
    if cx <= X1 then text(cx, YF, ed.cur < ulen(s) and usub(s, ed.cur + 1, ed.cur + 1) or " ", C.white, C.blue) end
  else
    local k = key(v.r, v.c)
    local raw = rawText(sh, k)
    local val = sh.val[k]
    local note, noteCol
    if sh.fix[k] then note, noteCol = "• value from Google Sheets: " .. tostring(ENG.unknownFn(sh.fml[k] or "")) .. " isn't available here", C.warn
    elseif isErr(val) and val.msg then note, noteCol = "▲ " .. val.msg, C.red end
    if note then
      local nw = min(ulen(note), floor(w * 0.6))
      textW(fx, YF, w - nw - 1, raw, C.ink, C.white)
      textW(X1 - nw, YF, nw + 1, note, noteCol, C.white)
    else
      textW(fx, YF, w, raw, C.ink, C.white)
    end
  end
  region(V.reg, fx, YF, w, 1, function()
    if not V.ed then local k = key(v.r, v.c); startEdit(rawText(sh, k), false) end
  end)
end

---------------------------------------------------------------- drawing: grid
local function cellText(sh, k, w, st)
  local val = sh.val[k]
  if V.showF and sh.fml[k] then return "=" .. sh.fml[k], "l", nil end
  local s, al, col = FMT.display(val, st)
  if type(val) == "number" and ulen(s) > w then
    if not (st and st.nf) then
      for sig = 9, 1, -1 do s = numText(val, sig); if ulen(s) <= w then break end end
    end
    if ulen(s) > w then s = string.rep("#", w) end
  end
  if isErr(val) then col = C.red end
  if type(s) == "string" and s:find("\n", 1, true) then s = s:gsub("\n", " ") end
  return s, al, col
end

local function drawGrid()
  local sh = curSheet()
  local v = view(sh)
  layout(sh)
  local r1, c1, r2, c2 = selBox(sh)
  local cols, rows = L.cols, L.rows
  -- column letters
  fill(X0, YH, RHW, 1, C.hdr)
  text(X0 + RHW - 1, YH, "│", C.line, C.hdr)
  region(V.reg, X0, YH, RHW, 1, function() v.r, v.c, v.er, v.ec = 1, 1, sh.rows, sh.cols end)
  local lastX = X0 + RHW
  for _, col in ipairs(cols) do
    local insel = col.c >= c1 and col.c <= c2
    local b = insel and C.selHdr or C.hdr
    local cw = col.clip and col.w or col.w - 1
    textW(col.x, YH, cw, colName(col.c), insel and C.blue or C.hdrInk, b, "center")
    if not col.clip then text(col.x + col.w - 1, YH, "│", col.c == sh.frC and C.frz or C.line, b) end
    lastX = col.x + col.w
  end
  if lastX <= X1 then fill(lastX, YH, X1 - lastX + 1, 1, C.hdr) end
  -- rows
  for _, row in ipairs(rows) do
    local y, r = row.y, row.r
    local rsel = r >= r1 and r <= r2
    local hb = rsel and C.selHdr or C.hdr
    textW(X0, y, RHW - 1, tostring(r), rsel and C.blue or C.hdrInk, hb, "right")
    text(X0 + RHW - 1, y, "│", C.line, hb)
    local n, i = #cols, 1
    while i <= n do
      local col = cols[i]
      local c = col.c
      local k = key(r, c)
      local st = styleOf(sh, k)
      local insel = rsel and c >= c1 and c <= c2
      local act = (r == v.r and c == v.c)
      local b = st and st.bg or C.white
      if insel and not act then b = (st and st.bg) and A.lerp(st.bg, C.selHdr, 0.5) or C.selFill end
      local cw = col.clip and col.w or col.w - 1
      local s, al, fc = cellText(sh, k, cw, st)
      fc = (st and st.fg) or fc or C.ink
      local j, span = i, cw
      if (al == "l" or al == "c") and ulen(s) > cw and type(sh.val[k]) ~= "number" and not col.clip then
        while ulen(s) > span and j < n do                       -- long text runs into empty cells on the right
          local nxt = cols[j + 1]
          local nk = key(r, nxt.c)
          if sh.val[nk] ~= nil or sh.fml[nk] then break end
          j = j + 1
          span = span + 1 + (nxt.clip and nxt.w or nxt.w - 1)
          if nxt.clip then break end
        end
      end
      textW(col.x, y, span, s, fc, b, al == "c" and "center" or (al == "r" and "right" or nil))
      if sh.fix[k] then text(al == "r" and col.x or (col.x + cw - 1), y, "•", C.warn, b) end
      local last = cols[j]
      if not last.clip then
        local sx = last.x + last.w - 1
        local scol = C.line
        if last.c == sh.frC then scol = C.frz end
        if act and j == i then scol = C.blue end
        text(sx, y, act and "▕" or "│", scol, act and C.white or b)
      end
      if act then
        local px = col.x - 1
        text(px, y, "▏", C.blue, (i == 1) and hb or C.white)
      end
      i = j + 1
    end
    local lx = cols[#cols] and (cols[#cols].x + cols[#cols].w) or (X0 + RHW)
    if lx <= X1 then fill(lx, y, X1 - lx + 1, 1, C.white) end
  end
  local yEnd = rows[#rows] and rows[#rows].y + 1 or G1
  if yEnd <= G2 then fill(X0, yEnd, X1 - X0 + 1, G2 - yEnd + 1, C.white) end
end

local function drawEditor()
  local ed = V.ed
  if not ed then return end
  local sh = curSheet()
  local x, y
  for _, col in ipairs(L.cols) do if col.c == ed.c then x = col.x end end
  for _, row in ipairs(L.rows) do if row.r == ed.r then y = row.y end end
  if not x or not y then return end
  local w = colW(sh, ed.c) - 1
  local need = ulen(ed.text) + 1
  if need > w then w = min(need, X1 - x + 1) end
  local off = 0
  if ed.cur > w - 1 then off = ed.cur - (w - 1) end
  textW(x, y, w, usub(ed.text, off + 1, off + w), C.ink, C.white)
  local cx = x + ed.cur - off
  if cx <= X1 then text(cx, y, ed.cur < ulen(ed.text) and usub(ed.text, ed.cur + 1, ed.cur + 1) or " ", C.white, C.blue) end
  if x - 1 >= X0 then text(x - 1, y, "▏", C.blue, C.white) end
  if x + w <= X1 then text(x + w, y, "▕", C.blue, C.white) end
  -- autocomplete
  local list = acList()
  if #list > 0 then
    local bx, by = x, y + 1
    local bw = 22
    if by + #list > G2 then by = y - #list end
    if bx + bw > X1 then bx = X1 - bw end
    for i, name in ipairs(list) do
      textW(bx, by + i - 1, bw, " " .. name .. (i == 1 and "   Tab" or ""), i == 1 and C.blue or C.ink, i == 1 and C.selFill or C.white)
      region(V.reg, bx, by + i - 1, bw, 1, function() acAccept(name) end)
    end
    V.acTop = list[1]
  else
    V.acTop = nil
  end
end

---------------------------------------------------------------- drawing: tabs, popups
local function selStats(sh)
  local r1, c1, r2, c2 = selBox(sh)
  if r1 == r2 and c1 == c2 then return nil end
  r2, c2 = min(r2, sh.maxR), min(c2, sh.maxC)
  local s, n, mn, mx, cnt = 0, 0, huge, -huge, 0
  for r = r1, r2 do for c = c1, c2 do
    local v = sh.val[key(r, c)]
    if v ~= nil then cnt = cnt + 1 end
    if type(v) == "number" then s, n = s + v, n + 1; mn, mx = min(mn, v), max(mx, v) end
  end end
  if n == 0 then return cnt > 0 and ("Count: " .. cnt) or nil end
  local kinds = { { "Sum", s }, { "Average", s / n }, { "Min", mn }, { "Max", mx }, { "Count", n } }
  local kd = kinds[V.stat] or kinds[1]
  return kd[1] .. ": " .. numText(kd[2]) .. " ▾"
end
local function drawTabs()
  fill(X0, YS, X1 - X0 + 1, 1, C.top)
  text(X0 + 1, YS, " + ", C.dim, C.top)
  region(V.reg, X0 + 1, YS, 3, 1, addSheet)
  text(X0 + 4, YS, " ≡ ", C.dim, C.top)
  region(V.reg, X0 + 4, YS, 3, 1, function(xx)
    local items = {}
    for i, sh in ipairs(WB.sheets) do items[#items + 1] = { (i == WB.cur and "✓ " or "  ") .. sh.name, function() commitEdit(0, 0); WB.cur = i end } end
    menu(X0 + 4, YS - #items - 2, items)
  end)
  local x = X0 + 8
  local stats = selStats(curSheet())
  local limit = X1 - (stats and ulen(stats) + 3 or 1)
  if V.tabScroll >= #WB.sheets then V.tabScroll = 0 end
  for i = V.tabScroll + 1, #WB.sheets do
    local sh = WB.sheets[i]
    local act = i == WB.cur
    local lbl = " " .. sh.name .. (act and " ▾ " or " ")
    local w = ulen(lbl)
    if x + w > limit then
      text(limit - 3, YS, " ▸ ", C.dim, C.top)
      region(V.reg, limit - 3, YS, 3, 1, function() V.tabScroll = V.tabScroll + 1 end)
      break
    end
    text(x, YS, lbl, act and C.blue or C.dim, act and C.tab or C.top)
    local tx = x
    region(V.reg, x, YS, w, 1, function(px)
      if act and px >= tx + w - 3 then
        menu(tx, YS - 8, {
          { "Rename...", function() prompt("Rename sheet", sh.name, function(s) renameSheet(sh, s) end) end },
          { "Duplicate", duplicateSheet },
          { "Delete", deleteSheet },
          { "Move right", function() moveSheet(1) end },
          { "Move left", function() moveSheet(-1) end },
        })
      else
        commitEdit(0, 0)
        WB.cur = i
      end
    end)
    x = x + w + 1
  end
  if V.tabScroll > 0 then
    text(X0 + 7, YS, "◂", C.dim, C.top)
    region(V.reg, X0 + 7, YS, 1, 1, function() V.tabScroll = V.tabScroll - 1 end)
  end
  if stats then
    textW(X1 - ulen(stats) - 1, YS, ulen(stats) + 2, stats, C.ink, C.chip)
    region(V.reg, X1 - ulen(stats) - 1, YS, ulen(stats) + 2, 1, function() V.stat = V.stat % 5 + 1 end)
  end
end

local function drawPop()
  local p = V.pop
  if not p then return end
  local w, h = 34, 8
  local x, y = min(p.x, X1 - w), p.y
  bevel(x, y, w, h, "raised", C.white, C.white)
  textW(x + 2, y + 1, w - 4, p.kind == "fg" and "Text color" or "Fill color", C.dim, C.white)
  for ri, row in ipairs(PALETTE) do
    for ci, col in ipairs(row) do
      local sx = x + 2 + (ci - 1) * 3
      fill(sx, y + 1 + ri, 2, 1, col)
      region(V.reg, sx, y + 1 + ri, 3, 1, function()
        V.pop = nil
        styleSel(function(st) if p.kind == "fg" then st.fg = (col ~= 0) and col or nil else st.bg = (col ~= 0xFFFFFF) and col or nil end end)
      end)
    end
  end
  text(x + 2, y + 6, " Reset ", C.blue, C.chip)
  region(V.reg, x + 2, y + 6, 7, 1, function()
    V.pop = nil
    styleSel(function(st) if p.kind == "fg" then st.fg = nil else st.bg = nil end end)
  end)
end

local function drawPrompt()
  local p = V.prompt
  if not p then return end
  local w, h = 66, 8
  local x, y = WX + floor((WW - w) / 2), WY + 14
  bevel(x, y, w, h, "raised", C.white, C.white)
  textW(x + 2, y + 1, w - 4, p.title, C.ink, C.white)
  local fw = w - 6
  local off = p.cur > fw - 2 and p.cur - (fw - 2) or 0
  textW(x + 3, y + 3, fw, usub(p.text, off + 1, off + fw), p.fresh and C.white or C.ink, p.fresh and C.blue or C.band)
  local cx = x + 3 + p.cur - off
  text(cx, y + 3, p.cur < ulen(p.text) and usub(p.text, p.cur + 1, p.cur + 1) or " ", C.white, C.blue)
  if p.hint then textW(x + 3, y + 4, fw, p.hint, C.dim, C.white) end
  text(x + w - 22, y + 6, " Cancel ", C.blue, C.white)
  text(x + w - 12, y + 6, "   OK   ", C.white, C.btn)
  p.okX, p.cancelX, p.by = x + w - 12, x + w - 22, y + 6
end

---------------------------------------------------------------- drawing: start page
local function drawHome()
  fill(X0, YT, X1 - X0 + 1, YS - YT + 1, C.white)
  text(X0 + 1, YT, " ▦ ", C.white, C.green)
  text(X0 + 5, YT, "Sheets", C.dim, C.white)
  textW(X1 - 40, YT, 40, "Spreadsheets for Lymanos", C.dim, C.white, "right")
  -- start a new spreadsheet
  local by = YT + 2
  fill(X0, by, X1 - X0 + 1, 13, C.band)
  text(X0 + 4, by + 1, "Start a new spreadsheet", C.ink, C.band)
  local tx, ty = X0 + 4, by + 3
  fill(tx, ty, 20, 7, C.white)
  text(tx + 9, ty + 2, "╋", C.green, C.white)
  text(tx + 7, ty + 3, "━━╋━━", C.green, C.white)
  text(tx + 9, ty + 4, "╋", C.green, C.white)
  textW(tx, ty + 8, 20, "Blank spreadsheet", C.ink, C.band)
  region(V.reg, tx, ty, 20, 9, newBlank)
  local ix = tx + 24
  fill(ix, ty, 20, 7, C.white)
  text(ix + 6, ty + 1, "▄▄▄▄▄▄▄", C.green, C.white)
  text(ix + 6, ty + 2, "▌ ▦ ▦ ▐", C.green, C.white)
  text(ix + 6, ty + 3, "▌ ▦ ▦ ▐", C.green, C.white)
  text(ix + 6, ty + 4, "▀▀▀▀▀▀▀", C.green, C.white)
  text(ix + 8, ty + 5, "⇩ xlsx", C.dim, C.white)
  textW(ix, ty + 8, 20, "Import from Google", C.ink, C.band)
  region(V.reg, ix, ty, 20, 9, function() V.importOpen = true; V.jobErr = nil end)
  if V.importOpen or V.job then
    local px = ix + 26
    local pw = X1 - px - 2
    fill(px, ty - 1, pw, 10, C.white)
    text(px + 2, ty, "Import a Google Sheet", C.ink, C.white)
    textW(px + 2, ty + 2, 6, "Link:", C.dim, C.white)
    local fw = pw - 10
    local s = V.link
    if ulen(s) > fw - 2 then s = "…" .. usub(s, -(fw - 3)) end
    textW(px + 8, ty + 2, fw, " " .. s .. (V.job and "" or "_"), C.ink, C.band)
    if V.job then
      textW(px + 2, ty + 4, pw - 4, V.jobMsg or "Working...", C.blue, C.white)
      textW(px + 2, ty + 6, pw - 4, "You can keep using Lymanos while this runs.", C.dim, C.white)
    else
      text(px + 2, ty + 4, "  Import  ", C.white, C.btn)
      region(V.reg, px + 2, ty + 4, 10, 1, startImport)
      text(px + 14, ty + 4, " Cancel ", C.blue, C.white)
      region(V.reg, px + 14, ty + 4, 8, 1, function() V.importOpen, V.jobErr = false, nil end)
      text(px + 24, ty + 4, " Clear ", C.blue, C.white)
      region(V.reg, px + 24, ty + 4, 7, 1, function() V.link = "" end)
      if V.jobErr then
        textW(px + 2, ty + 6, pw - 4, V.jobErr, C.red, C.white)
      else
        textW(px + 2, ty + 6, pw - 4, "1. In Google Sheets: Share > General access > Anyone with the link.", C.dim, C.white)
        textW(px + 2, ty + 7, pw - 4, "2. Copy the link, then paste it here: middle-click or press Insert.", C.dim, C.white)
      end
    end
  end
  -- recent spreadsheets
  if not V.files then listFiles() end
  local ly = by + 14
  text(X0 + 4, ly, "Recent spreadsheets", C.ink, C.white)
  textW(X0 + 74, ly, 20, "Last modified", C.dim, C.white)
  textW(X0 + 98, ly, 12, "Size", C.dim, C.white, "right")
  local rowsN = YS - (ly + 2)
  local files = V.files
  V.listScroll = max(0, min(V.listScroll, #files - rowsN))
  for i = 1, rowsN do
    local f = files[i + V.listScroll]
    local y = ly + 1 + i
    if f then
      text(X0 + 4, y, "▦", C.green, C.white)
      textW(X0 + 6, y, 66, f.name, C.ink, C.white)
      textW(X0 + 74, y, 20, when(f.time), C.dim, C.white)
      textW(X0 + 98, y, 12, string.format("%.1f KB", f.size / 1024), C.dim, C.white, "right")
      text(X1 - 4, y, " ⋮ ", C.dim, C.white)
      region(V.reg, X0 + 2, y, X1 - X0 - 8, 1, function() openFile(f) end)
      region(V.reg, X1 - 4, y, 3, 1, function() fileMenu(f, X1 - 30, y) end)
    else
      fill(X0, y, X1 - X0 + 1, 1, C.white)
      if i == 1 and #files == 0 then text(X0 + 6, y, "No spreadsheets yet - start a blank one or import one from Google Sheets.", C.dim, C.white) end
    end
  end
  fill(X0, YS, X1 - X0 + 1, 1, C.top)
  local total = 0
  for _, f in ipairs(files) do total = total + f.size end
  textW(X0 + 2, YS, X1 - X0 - 2, string.format("%d spreadsheet%s in %s · %.1f KB · RAM free %d KB", #files,
    #files == 1 and "" or "s", DIR, total / 1024, floor(computer.freeMemory() / 1024)), C.dim, C.top)
end

drawWindow = function()
  V.reg = {}
  bevel(WX, WY, WW, WH, "raised", K.desk, K.face)
  titleBar(WX + 1, WY + 1, WW - 2, "▦ Spreadsheets" .. (WB and (" - " .. WB.name) or ""), true)
  local bx = WX + WW - 12
  text(bx, WY + 1, " _ ", K.black, K.face)
  text(bx + 3, WY + 1, " □ ", K.black, K.face)
  text(bx + 7, WY + 1, " X ", K.black, K.face)
  region(V.reg, bx, WY + 1, 3, 1, function() A.setActive(nil); A.drawAll() end)
  region(V.reg, bx + 7, WY + 1, 3, 1, function() A.closeApp() end)
  if V.mode == "home" or not WB then
    drawHome()
  else
    local sh = curSheet()
    local v = view(sh)
    if v.r > sh.rows or v.c > sh.cols then selectCell(1, 1) end
    drawTitle()
    drawToolbar()
    drawGrid()
    drawFx()
    drawTabs()
    drawEditor()
    drawPop()
  end
  drawPrompt()
end

---------------------------------------------------------------- input
local function promptKey(ch, code)
  local p = V.prompt
  if p.fresh and (code == 14 or code == 211 or (ch and ch >= 32 and code ~= 28 and code ~= 156)) then
    p.text, p.cur = "", 0                       -- the old text starts selected: typing replaces it
  end
  if code ~= 28 and code ~= 156 then p.fresh = false end
  if code == 28 or code == 156 then V.prompt = nil; p.onOk(p.text)
  elseif code == 1 then V.prompt = nil
  elseif code == 14 then if p.cur > 0 then p.text = usub(p.text, 1, p.cur - 1) .. usub(p.text, p.cur + 1); p.cur = p.cur - 1 end
  elseif code == 211 then p.text = usub(p.text, 1, p.cur) .. usub(p.text, p.cur + 2)
  elseif code == 203 then p.cur = max(0, p.cur - 1)
  elseif code == 205 then p.cur = min(ulen(p.text), p.cur + 1)
  elseif code == 199 then p.cur = 0
  elseif code == 207 then p.cur = ulen(p.text)
  elseif ch and ch >= 32 and ulen(p.text) < 120 then
    local c = unicode.char(ch)
    p.text = usub(p.text, 1, p.cur) .. c .. usub(p.text, p.cur + 1)
    p.cur = p.cur + 1
  end
end

local function jump(dr, dc)                                    -- Ctrl+arrow: edge of the data
  local sh = curSheet()
  local v = view(sh)
  local r, c = v.er, v.ec
  local function filled(rr, cc) return sh.val[key(rr, cc)] ~= nil or sh.fml[key(rr, cc)] ~= nil end
  local nr, nc = r + dr, c + dc
  if nr < 1 or nc < 1 or nr > sh.rows or nc > sh.cols then return r, c end
  if filled(r, c) and filled(nr, nc) then
    while nr + dr >= 1 and nc + dc >= 1 and nr + dr <= sh.rows and nc + dc <= sh.cols and filled(nr + dr, nc + dc) do
      nr, nc = nr + dr, nc + dc
    end
    return nr, nc
  end
  local limitR = dr > 0 and max(sh.maxR, r) or 1
  local limitC = dc > 0 and max(sh.maxC, c) or 1
  while not filled(nr, nc) do
    if (dr ~= 0 and nr == limitR) or (dc ~= 0 and nc == limitC) then break end
    nr, nc = nr + dr, nc + dc
    if nr < 1 or nc < 1 then nr, nc = max(1, nr), max(1, nc); break end
  end
  if not filled(nr, nc) then nr, nc = dr > 0 and sh.rows or (dr < 0 and 1 or nr), dc > 0 and sh.cols or (dc < 0 and 1 or nc) end
  return nr, nc
end

local function gridKey(ch, code)
  local sh = curSheet()
  local v = view(sh)
  local ctrl, shift = ctrlDown(), shiftDown()
  local ed = V.ed
  if ed then
    if code == 28 or code == 156 then commitEdit(shift and -1 or 1, 0)
    elseif code == 15 then
      if V.acTop then acAccept(V.acTop) else commitEdit(0, shift and -1 or 1) end
    elseif code == 1 then cancelEdit()
    elseif code == 14 then
      if ed.cur > 0 then ed.text = usub(ed.text, 1, ed.cur - 1) .. usub(ed.text, ed.cur + 1); ed.cur = ed.cur - 1 end
      ed.ins = nil
    elseif code == 211 then ed.text = usub(ed.text, 1, ed.cur) .. usub(ed.text, ed.cur + 2); ed.ins = nil
    elseif code == 203 or code == 205 then
      if ed.quick and not isFormula(ed.text) then commitEdit(0, code == 203 and -1 or 1)
      else ed.cur = max(0, min(ulen(ed.text), ed.cur + (code == 203 and -1 or 1))); ed.ins = nil end
    elseif code == 200 or code == 208 then commitEdit(code == 200 and -1 or 1, 0)
    elseif code == 199 then ed.cur = 0
    elseif code == 207 then ed.cur = ulen(ed.text)
    elseif ch and ch >= 32 then edInsert(unicode.char(ch))
    end
    return
  end
  if ctrl then
    if code == 44 then undo() elseif code == 21 then redo()
    elseif code == 45 then copySel(true)
    elseif code == 47 then pasteClip(shift)
    elseif code == 48 then local b = not activeStyle().b; styleSel(function(st) st.b = b or nil end)
    elseif code == 32 then fillCells("down") elseif code == 19 then fillCells("right")
    elseif code == 41 then V.showF = not V.showF
    elseif code == 30 then v.r, v.c, v.er, v.ec = 1, 1, sh.rows, sh.cols
    elseif code == 31 then saveNow()
    elseif code == 199 then selectCell(1, 1)
    elseif code == 207 then selectCell(max(1, sh.maxR), max(1, sh.maxC))
    elseif code == 200 or code == 208 or code == 203 or code == 205 then
      local dr = code == 200 and -1 or (code == 208 and 1 or 0)
      local dc = code == 203 and -1 or (code == 205 and 1 or 0)
      local nr, nc = jump(dr, dc)
      selectCell(nr, nc, shift)
    end
    return
  end
  if code == 200 or code == 208 or code == 203 or code == 205 then
    local dr = code == 200 and -1 or (code == 208 and 1 or 0)
    local dc = code == 203 and -1 or (code == 205 and 1 or 0)
    if shift then selectCell(v.er + dr, v.ec + dc, true) else selectCell(v.r + dr, v.c + dc) end
  elseif code == 28 or code == 156 or code == 60 then startEdit(rawText(sh, key(v.r, v.c)), false)
  elseif code == 15 then selectCell(v.r, v.c + (shift and -1 or 1))
  elseif code == 211 or code == 14 then clearSel("values")
  elseif code == 201 or code == 209 then
    local page = G2 - G1 - sh.frR
    selectCell(v.r + (code == 201 and -page or page), v.c)
  elseif code == 199 then selectCell(v.r, 1)
  elseif code == 207 then selectCell(v.r, max(1, sh.maxC))
  elseif code == 1 then V.clip = nil
  elseif ch and ch >= 32 then
    startEdit(unicode.char(ch), true)
  end
end

local function key2(ch, code)
  if V.prompt then promptKey(ch, code); if not A.getOverlay() then drawWindow() end return end
  if V.mode == "home" or not WB then
    if V.importOpen and not V.job then
      if code == 28 or code == 156 then startImport()
      elseif code == 14 then V.link = usub(V.link, 1, -2)
      elseif code == 1 then V.importOpen = false
      elseif ch and ch >= 32 and #V.link < 300 then V.link = V.link .. unicode.char(ch); V.jobErr = nil end
      drawWindow()
    end
    return
  end
  if V.pop and code == 1 then V.pop = nil; drawWindow(); return end
  gridKey(ch, code)
  if A.isActive() and not A.getOverlay() then drawWindow() end
end

local function touch(x, y, btn)
  if V.prompt then
    local p = V.prompt
    if y == p.by and x >= p.okX and x < p.okX + 8 then V.prompt = nil; p.onOk(p.text)
    elseif y == p.by and x >= p.cancelX and x < p.cancelX + 8 then V.prompt = nil end
    if not A.getOverlay() then drawWindow() end
    return true
  end
  if x < WX or x >= WX + WW or y < WY or y >= WY + WH then return false end
  local hadPop = V.pop
  if hit(V.reg, x, y) then
    if hadPop and V.pop == hadPop then V.pop = nil end
    if A.isActive() and not A.getOverlay() then drawWindow() end
    return true
  end
  if V.pop then V.pop = nil; drawWindow(); return true end
  if V.mode ~= "grid" or not WB then return true end
  local sh = curSheet()
  local v = view(sh)
  if y == YH then                                               -- column letters: select / resize
    for _, col in ipairs(L.cols) do
      if x >= col.x and x < col.x + col.w then
        if x == col.x + col.w - 1 and not col.clip then
          V.drag = { mode = "resize", c = col.c, x0 = col.x }
        else
          if V.ed then commitEdit(0, 0) end
          if shiftDown() then v.ec = col.c; v.er = sh.rows else v.r, v.c, v.er, v.ec = 1, col.c, sh.rows, col.c end
          V.drag = { mode = "cols" }
        end
      end
    end
    drawWindow()
    return true
  end
  if y >= G1 and y <= G2 and x < X0 + RHW then                  -- row numbers
    local r = cellAt(X0 + RHW, y)
    if r then
      if V.ed then commitEdit(0, 0) end
      if shiftDown() then v.er = r; v.ec = sh.cols else v.r, v.c, v.er, v.ec = r, 1, r, sh.cols end
      V.drag = { mode = "rows" }
    end
    drawWindow()
    return true
  end
  if y >= G1 and y <= G2 then
    local r, c = cellAt(x, y)
    if not r or not c then return true end
    if V.ed and canPoint() then
      pointRef(r, c)
      V.drag = { mode = "ref", r = r, c = c }
      drawWindow()
      return true
    end
    if V.ed then commitEdit(0, 0) end
    local r1, c1, r2, c2 = selBox(sh)
    if btn == 1 then
      if r < r1 or r > r2 or c < c1 or c > c2 then selectCell(r, c) end
      drawWindow()
      contextMenu(x, y)
      return true
    end
    local now2 = computer.uptime()
    if V.lastRC == r * 4096 + c and now2 - V.lastClick < 0.5 then
      selectCell(r, c)
      startEdit(rawText(sh, key(r, c)), false)
      V.lastClick = 0
    else
      if shiftDown() then selectCell(r, c, true) else selectCell(r, c) end
      V.drag = { mode = "sel" }
      V.lastClick, V.lastRC = now2, r * 4096 + c
    end
    drawWindow()
    return true
  end
  return true
end

local function drag(x, y)
  local d = V.drag
  if not d or V.mode ~= "grid" or not WB then return end
  local sh = curSheet()
  local v = view(sh)
  if d.mode == "resize" then
    sh.colW[d.c] = max(2, min(80, x - d.x0 + 1))
    V.dirty, V.lastEdit = true, computer.uptime()
  else
    local yy = max(G1, min(G2, y))
    local xx = max(X0 + RHW, min(X1, x))
    if y > G2 then v.top = v.top + 1 elseif y < G1 and v.top > sh.frR + 1 then v.top = v.top - 1 end
    layout(sh)
    local r, c = cellAt(xx, yy)
    if d.mode == "ref" and V.ed and r and c then pointRef(d.r, d.c, r, c)
    elseif d.mode == "sel" and r and c then v.er, v.ec = r, c
    elseif d.mode == "cols" and c then v.ec = c
    elseif d.mode == "rows" and r then v.er = r end
  end
  drawWindow()
end

local function scroll(x, y, dir)
  if V.mode == "home" or not WB then
    V.listScroll = max(0, V.listScroll - dir)
    drawWindow()
    return
  end
  local sh = curSheet()
  local v = view(sh)
  if shiftDown() or y == YH then
    v.left = max(sh.frC + 1, min(sh.cols, v.left - dir))
  else
    v.top = max(sh.frR + 1, min(sh.rows, v.top - dir * 3))
  end
  drawWindow()
end

local function clipboard(s)
  if type(s) ~= "string" then return end
  if V.prompt then
    local p = V.prompt
    s = s:gsub("[\r\n\t]", " ")
    p.text = usub(p.text, 1, p.cur) .. s .. usub(p.text, p.cur + 1)
    p.cur = p.cur + ulen(s)
  elseif V.mode == "home" or not WB then
    V.importOpen = true
    V.link = (V.link .. s:gsub("[\r\n\t]", "")):sub(1, 300)
    V.jobErr = nil
  elseif V.ed then
    edInsert((s:gsub("[\r\n\t]", " ")))
  else
    pasteText(s)
  end
  drawWindow()
end

local function tick()
  if V.dirty and WB and not V.ed and computer.uptime() - V.lastEdit > 2 then
    saveNow()
    if A.isActive() and not A.getOverlay() and V.mode == "grid" then drawTitle() end
  end
end

return {
  open = function() if not WB then V.mode = "home"; V.files = nil end end,
  drawWindow = function() drawWindow() end,
  touch = touch, drag = drag, drop = function() V.drag = nil end, scroll = scroll,
  key = key2, clipboard = clipboard,
  copy = function() if V.mode == "grid" and WB and not V.ed then copySel(false); drawWindow() end end,
  tick = tick, pump = pump, busy = function() return V.job ~= nil end,
  save = function() if V.ed then commitEdit(0, 0) end if V.dirty then saveNow() end end,
  close = function() closeWorkbook() end,
}
end)()

--[==[XLSX-IMPORT
--------------------------------------------------------------- GOOGLE SHEETS IMPORT (code)
-- (compiled only while importing; see loadImporter)
local XL = (function()
local POW = {}
for i = 0, 31 do POW[i] = 2 ^ i end

---------------------------------------------------------------- inflate (RFC 1951)
local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- canonical Huffman table from code lengths (lengths[0..n-1])
local function build(lengths, n)
  local count = {}
  for i = 0, 15 do count[i] = 0 end
  for s = 0, n - 1 do local l = lengths[s] or 0; count[l] = count[l] + 1 end
  local offs = { [1] = 0 }
  for l = 1, 14 do offs[l + 1] = offs[l] + count[l] end
  local symbol = {}
  for s = 0, n - 1 do
    local l = lengths[s] or 0
    if l ~= 0 then symbol[offs[l]] = s; offs[l] = offs[l] + 1 end
  end
  return { count = count, symbol = symbol }
end
local FIXL, FIXD
do
  local l = {}
  for i = 0, 143 do l[i] = 8 end
  for i = 144, 255 do l[i] = 9 end
  for i = 256, 279 do l[i] = 7 end
  for i = 280, 287 do l[i] = 8 end
  FIXL = build(l, 288)
  local d = {}
  for i = 0, 29 do d[i] = 5 end
  FIXD = build(d, 30)
end

-- nextByte() -> next compressed byte; out(str) gets the result in 2 KB pages.
-- Only the last 32 KB of output (+ the page being filled) are kept.
local function inflate(nextByte, out, pause)
  local bitbuf, bitcnt = 0, 0
  local function bits(n)
    while bitcnt < n do
      local b = nextByte()
      if not b then error("The file ends too early.", 0) end
      bitbuf = bitbuf + b * POW[bitcnt]
      bitcnt = bitcnt + 8
    end
    local v = bitbuf % POW[n]
    bitbuf = (bitbuf - v) / POW[n]
    bitcnt = bitcnt - n
    return v
  end
  local function decode(h)
    local count, code, firstc, index = h.count, 0, 0, 0
    for len = 1, 15 do
      if bitcnt == 0 then
        local b = nextByte()
        if not b then error("The file ends too early.", 0) end
        bitbuf, bitcnt = b, 8
      end
      local bit = bitbuf % 2
      bitbuf, bitcnt = (bitbuf - bit) / 2, bitcnt - 1
      code = code + bit
      local c = count[len]
      if code - c < firstc then return h.symbol[index + code - firstc] end
      index = index + c
      firstc = (firstc + c) * 2
      code = code * 2
    end
    error("Damaged compressed data.", 0)
  end
  local PAGE = 2048
  local cur, curN, pages, pageIdx, total = {}, 0, {}, 0, 0
  local function flush()
    local s = string.char(table.unpack(cur, 1, curN))
    pages[pageIdx] = s
    pages[pageIdx - 17] = nil
    pageIdx, curN = pageIdx + 1, 0
    out(s)
  end
  local function put(b)
    curN = curN + 1
    cur[curN] = b
    total = total + 1
    if curN == PAGE then flush() end
  end
  local function byteAt(p)
    local pi = floor(p / PAGE)
    local off = p - pi * PAGE + 1
    if pi == pageIdx then return cur[off] end
    return pages[pi]:byte(off)
  end
  local function dynamic()
    local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
    local lens = {}
    for i = 1, 19 do lens[ORDER[i]] = 0 end
    for i = 1, ncode do lens[ORDER[i]] = bits(3) end
    local lencode = build(lens, 19)
    local L, idx = {}, 0
    while idx < nlen + ndist do
      local sym = decode(lencode)
      if sym < 16 then L[idx] = sym; idx = idx + 1
      else
        local v, rep = 0, 0
        if sym == 16 then
          if idx == 0 then error("Damaged compressed data.", 0) end
          v, rep = L[idx - 1], 3 + bits(2)
        elseif sym == 17 then rep = 3 + bits(3)
        else rep = 11 + bits(7) end
        for _ = 1, rep do L[idx] = v; idx = idx + 1 end
      end
    end
    local ll, dl = {}, {}
    for i = 0, nlen - 1 do ll[i] = L[i] end
    for i = 0, ndist - 1 do dl[i] = L[nlen + i] end
    return build(ll, nlen), build(dl, ndist)
  end
  local count = 0
  repeat
    local final, typ = bits(1), bits(2)
    if typ == 0 then
      bitbuf, bitcnt = 0, 0
      local a, b, c, d = nextByte(), nextByte(), nextByte(), nextByte()
      if not d then error("The file ends too early.", 0) end
      for _ = 1, a + b * 256 do
        local x = nextByte()
        if not x then error("The file ends too early.", 0) end
        put(x)
      end
    elseif typ == 1 or typ == 2 then
      local lit, dist = FIXL, FIXD
      if typ == 2 then lit, dist = dynamic() end
      while true do
        local sym = decode(lit)
        if sym < 256 then put(sym)
        elseif sym == 256 then break
        else
          sym = sym - 256
          if sym > 29 then error("Damaged compressed data.", 0) end
          local len = LBASE[sym] + bits(LEXT[sym])
          local ds = decode(dist) + 1
          local d = DBASE[ds] + bits(DEXT[ds])
          if d > total then error("Damaged compressed data.", 0) end
          for _ = 1, len do put(byteAt(total - d)) end
        end
        count = count + 1
        if count % 1024 == 0 then pause() end
      end
    else
      error("Damaged compressed data.", 0)
    end
  until final == 1
  if curN > 0 then flush() end
end

---------------------------------------------------------------- zip
local function u16(s, i) local a, b = s:byte(i, i + 1) return a + b * 256 end
local function u32(s, i) local a, b, c, d = s:byte(i, i + 3) return a + b * 256 + c * 65536 + d * 16777216 end

local function openZip(path)
  local f = io.open(path, "rb")
  if not f then error("Cannot open the downloaded file.", 0) end
  local size = f:seek("end")
  local tail = min(size, 65557)
  f:seek("set", size - tail)
  local t = f:read(tail) or ""
  local p
  for i = #t - 21, 1, -1 do if t:sub(i, i + 3) == "PK\5\6" then p = i; break end end
  if not p then f:close(); error("The download is not an .xlsx file.", 0) end
  local cnt, cdSize, cdOff = u16(t, p + 10), u32(t, p + 12), u32(t, p + 16)
  t = nil
  f:seek("set", cdOff)
  local cd = f:read(cdSize) or ""
  local entries, i = {}, 1
  for _ = 1, cnt do
    if cd:sub(i, i + 3) ~= "PK\1\2" then break end
    local nlen, xlen, clen = u16(cd, i + 28), u16(cd, i + 30), u16(cd, i + 32)
    entries[cd:sub(i + 46, i + 45 + nlen)] = { method = u16(cd, i + 10), csize = u32(cd, i + 20), off = u32(cd, i + 42) }
    i = i + 46 + nlen + xlen + clen
  end
  return { f = f, entries = entries }
end

-- unpack one file of the zip; out(piece) is called with the text, a piece at a time
local function readEntry(zip, name, out, pause)
  local e = zip.entries[name]
  if not e then return false end
  local f = zip.f
  f:seek("set", e.off)
  local h = f:read(30) or ""
  if #h < 30 or h:sub(1, 4) ~= "PK\3\4" then error("Damaged .xlsx file.", 0) end
  f:seek("set", e.off + 30 + u16(h, 27) + u16(h, 29))
  local left, buf, bi = e.csize, "", 1
  if e.method == 0 then
    while left > 0 do
      local s = f:read(min(2048, left)) or ""
      if s == "" then break end
      left = left - #s
      out(s)
      pause()
    end
    return true
  end
  if e.method ~= 8 then error("Unsupported compression in the .xlsx file.", 0) end
  local function nextByte()
    if bi > #buf then
      if left <= 0 then return nil end
      buf = f:read(min(4096, left)) or ""
      left, bi = left - #buf, 1
      if buf == "" then return nil end
    end
    local b = buf:byte(bi)
    bi = bi + 1
    return b
  end
  inflate(nextByte, out, pause)
  return true
end
local function readAll(zip, name, pause)
  local parts = {}
  if not readEntry(zip, name, function(s) parts[#parts + 1] = s end, pause) then return nil end
  return table.concat(parts)
end

---------------------------------------------------------------- xml
local ENT = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }
local function unxml(s)
  if not s:find("&", 1, true) then return s end
  return (s:gsub("&(#?x?)(%w+);", function(p, v)
    if p == "" then return ENT[v] or ("&" .. v .. ";") end
    local n = tonumber(v, p == "#x" and 16 or 10)
    if n then return unicode.char(n) end
  end))
end
local function attrs(tag)
  local t = {}
  for k, v in tag:gmatch('([%w:_]+)%s*=%s*"([^"]*)"') do t[k] = unxml(v) end
  return t
end
-- feed(chunk) calls onEl(text) for each complete <name ...>...</name> or <name .../>
local function elements(name, onEl)
  local carry = ""
  local open, close = "<" .. name .. "[%s>/]", "</" .. name .. ">"
  return function(chunk)
    local buf = carry .. chunk
    local i = 1
    while true do
      local a = buf:find(open, i)
      if not a then carry = buf:sub(max(i, #buf - #name - 2)); return end
      local gt = buf:find(">", a, true)
      if not gt then carry = buf:sub(a); return end
      if buf:sub(gt - 1, gt - 1) == "/" then
        onEl(buf:sub(a, gt)); i = gt + 1
      else
        local c1, c2 = buf:find(close, gt, true)
        if not c1 then carry = buf:sub(a); return end
        onEl(buf:sub(a, c2)); i = c2 + 1
      end
    end
  end
end
local function textOf(el)                       -- all <t> runs of a string item
  el = el:gsub("<rPh.-</rPh>", "")
  local parts = {}
  for inner in el:gmatch("<t[^>]*>(.-)</t>") do parts[#parts + 1] = unxml(inner) end
  return table.concat(parts)
end
local function rgb(s)
  if not s then return nil end
  s = s:match("(%x%x%x%x%x%x)$")
  return s and tonumber(s, 16) or nil
end

local BUILTIN = { [1] = "0", [2] = "0.00", [3] = "#,##0", [4] = "#,##0.00", [9] = "0%", [10] = "0.00%",
  [11] = "0.00E+00", [14] = "m/d/yyyy", [15] = "d-mmm-yy", [16] = "d-mmm", [17] = "mmm-yy", [18] = "h:mm AM/PM",
  [19] = "h:mm:ss AM/PM", [20] = "h:mm", [21] = "h:mm:ss", [22] = "m/d/yyyy h:mm", [37] = "#,##0;(#,##0)",
  [38] = "#,##0;[Red](#,##0)", [39] = "#,##0.00;(#,##0.00)", [40] = "#,##0.00;[Red](#,##0.00)", [45] = "mm:ss",
  [46] = "[h]:mm:ss", [47] = "mm:ss.0", [48] = "##0.0E+0", [49] = "@" }

-- styles.xml -> list (0-based, like the file) of our style ids
local function readStyles(xml)
  local map = {}
  if not xml then return map end
  local fmts = {}
  for tag in xml:gmatch("<numFmt%s[^>]*>") do
    local a = attrs(tag)
    if a.numFmtId then fmts[tonumber(a.numFmtId)] = a.formatCode end
  end
  local fonts, fills = {}, {}
  local fsec = xml:match("<fonts[^>]*>(.-)</fonts>") or ""
  elements("font", function(el)
    local b = el:find("<b/>", 1, true) or el:find('<b val="1"', 1, true) or el:find('<b val="true"', 1, true)
    fonts[#fonts + 1] = { b = b and true or nil, fg = rgb(el:match('<color[^>]-rgb="(%x+)"')) }
  end)(fsec)
  local flsec = xml:match("<fills[^>]*>(.-)</fills>") or ""
  elements("fill", function(el)
    local solid = el:find('patternType="solid"', 1, true)
    fills[#fills + 1] = solid and rgb(el:match('<fgColor[^>]-rgb="(%x+)"')) or false
  end)(flsec)
  local xsec = xml:match("<cellXfs[^>]*>(.-)</cellXfs>") or ""
  local idx = 0
  elements("xf", function(el)
    local a = attrs(el:match("^<xf[^>]*>") or el)
    local nfid = tonumber(a.numFmtId or 0) or 0
    local nf = fmts[nfid] or BUILTIN[nfid]
    if nf and nf:lower() == "general" then nf = nil end
    local font = fonts[(tonumber(a.fontId or 0) or 0) + 1] or {}
    local fill = fills[(tonumber(a.fillId or 0) or 0) + 1]
    local al = el:match('<alignment[^>]-horizontal="(%a+)"')
    al = (al == "center" or al == "centerContinuous") and "c" or (al == "right" and "r" or (al == "left" and "l" or nil))
    local fg = font.fg
    if fg == 0 then fg = nil end
    local bg = fill or nil
    if bg == 0xFFFFFF then bg = nil end
    map[idx] = styleId({ nf = nf, b = font.b, fg = fg, bg = bg, al = al })
    idx = idx + 1
  end)(xsec)
  return map
end

-- Google writes Sheets-only functions as __xludf.DUMMYFUNCTION("THE FORMULA") (sometimes inside
-- IFERROR(..., cached value)); this returns the real formula, or nil
local function dummyInner(f)
  local a = f:find("__xludf.DUMMYFUNCTION(\"", 1, true)
  if not a then return nil end
  local i, out = a + #"__xludf.DUMMYFUNCTION(\"", {}
  while i <= #f do
    local ch = f:sub(i, i)
    if ch == '"' then
      if f:sub(i + 1, i + 1) == '"' then out[#out + 1] = '"'; i = i + 2 else break end
    else out[#out + 1] = ch; i = i + 1 end
  end
  return table.concat(out)
end

-- one worksheet XML -> sheet
local function readSheet(zip, path, sh, strings, styles, pause, note)
  local shared, arrays = {}, {}
  local defW
  local function onCell(el)
    local tag = el:match("^<c[^>]*>") or el
    local a = attrs(tag)
    local ref = a.r
    if not ref then return end
    local col, row = ref:match("^(%a+)(%d+)$")
    if not col then return end
    local r, c = tonumber(row), colNum(col)
    if c > MAXC or r > MAXR then return end
    local k = key(r, c)
    local t = a.t
    local fAttr, fText = el:match("<f([^>]*)>(.-)</f>")
    if not fAttr then fAttr = el:match("<f([^>]*)/>") end
    local v = el:match("<v[^>]*>(.-)</v>")
    local val
    if t == "s" then val = v and strings[(tonumber(v) or -1) + 1]
    elseif t == "b" then val = v == "1"
    elseif t == "e" then val = v and (ERR[unxml(v)] or ERR["#ERROR!"])
    elseif t == "str" then val = v and unxml(v)
    elseif t == "inlineStr" then val = textOf(el:match("<is>(.-)</is>") or "")
    elseif v then val = tonumber(v) end
    if val == "" and t ~= "str" and t ~= "s" and t ~= "inlineStr" then val = nil end
    if val ~= nil then sh.val[k] = val end
    if a.s then sh.sty[k] = styles[tonumber(a.s)] end
    if fAttr then
      local fa = attrs(fAttr)
      local f = fText and unxml(fText) or nil
      if fa.t == "shared" and fa.si then
        if f and f ~= "" then shared[fa.si] = { f = f, r = r, c = c }
        else
          local m = shared[fa.si]
          if m then f = ENG.shift(m.f, r - m.r, c - m.c) end
        end
      end
      if f and f ~= "" then
        if f == '"""COMPUTED_VALUE"""' or f == '"COMPUTED_VALUE"' then
          sh.cv[k] = true                              -- a value spilled by a Sheets array function
        else
          local inner = dummyInner(f)
          if inner then f = inner end
          f = f:gsub("^=", ""):gsub("_xlfn%.", ""):gsub("_xlws%.", "")
          sh.fml[k] = f
          local unk = ENG.unknownFn(f)
          if unk then sh.fix[k] = true; note(unk) end
          if fa.t == "array" and fa.ref then arrays[#arrays + 1] = { k, fa.ref } end
        end
      end
    end
    if sh.val[k] ~= nil or sh.fml[k] or sh.sty[k] then grow(sh, r, c) end
  end
  local feedC = elements("c", onCell)
  local feedCol = elements("col", function(el)
    local a = attrs(el)
    local lo, hi, w = tonumber(a.min), tonumber(a.max), tonumber(a.width)
    if lo and hi and w then
      for c = lo, min(hi, lo + 200, MAXC) do sh.colW[c] = max(3, min(60, floor(w + 2))) end
    end
  end)
  local head, headDone = {}, false
  readEntry(zip, path, function(s)
    if not headDone then
      head[#head + 1] = s
      local h = table.concat(head)
      if h:find("<sheetData", 1, true) or #h > 65536 then
        headDone = true
        local pane = h:match("<pane[^>]*>")
        if pane and pane:find('state="frozen"', 1, true) then
          local pa = attrs(pane)
          sh.frR, sh.frC = floor(tonumber(pa.ySplit or 0) or 0), floor(tonumber(pa.xSplit or 0) or 0)
        end
        local dim = h:match('<dimension ref="([^"]+)"')
        if dim then
          local c2, r2 = dim:match(":(%a+)(%d+)$")
          if c2 then sh.rows, sh.cols = max(sh.rows, tonumber(r2)), max(sh.cols, min(MAXC, colNum(c2))) end
        end
        local fp = h:match("<sheetFormatPr[^>]*>")
        if fp then defW = tonumber(attrs(fp).defaultColWidth) end
        feedCol(h)
        feedC(h)
        head = nil
      end
    else
      feedC(s)
    end
  end, pause)
  if head then local h = table.concat(head); feedCol(h); feedC(h) end
  if defW then sh.defW = max(3, min(60, floor(defW + 2))) end
  -- cells inside an array formula's result become spill targets (if the formula works here)
  for _, ar in ipairs(arrays) do
    local k0 = ar[1]
    if not sh.fix[k0] then
      local c1, r1, c2, r2 = ar[2]:match("^(%a+)(%d+):(%a+)(%d+)$")
      if c1 then
        for r = tonumber(r1), tonumber(r2) do for c = colNum(c1), colNum(c2) do
          local kk = key(r, c)
          if kk ~= k0 and not sh.fml[kk] then sh.cv[kk] = true end
        end end
      end
    end
  end
end

---------------------------------------------------------------- download
local function header(hd, name)
  if type(hd) ~= "table" then return nil end
  for k, v in pairs(hd) do
    if type(k) == "string" and k:lower() == name then
      if type(v) == "table" then return v[1] end
      return v
    end
  end
end
local function urldecode(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

-- downloads url to path, following redirects; yields while waiting (runs in the import job)
local function download(url, path, progress)
  local inet = A.inet()
  if not inet then error("No Internet Card found. Install one to import from Google Sheets.", 0) end
  for _ = 1, 8 do
    local ok, h = pcall(inet.request, url, nil, { ["User-Agent"] = "Mozilla/5.0 (compatible; OpenComputers Lymanos)" })
    if not ok or not h then error("The request failed: " .. tostring(h), 0) end
    local t0 = computer.uptime()
    while true do
      local ok2, done = pcall(h.finishConnect)
      if not ok2 then pcall(h.close); error("Could not connect: " .. tostring(done), 0) end
      if done then break end
      if computer.uptime() - t0 > 30 then pcall(h.close); error("Timed out connecting to Google.", 0) end
      coroutine.yield()
    end
    local okr, code, _, hd = pcall(h.response)
    if not okr then code = nil end
    if code and code >= 300 and code < 400 then
      local loc = header(hd, "location")
      pcall(h.close)
      if not loc then error("Google sent a redirect without an address.", 0) end
      if loc:sub(1, 1) == "/" then loc = url:match("^(https?://[^/]+)") .. loc end
      url = loc
    else
      if code == 401 or code == 403 or code == 404 then
        pcall(h.close)
        error("Google refused (HTTP " .. code .. "). Share the sheet: Share > General access > Anyone with the link.", 0)
      end
      if code and code ~= 200 then pcall(h.close); error("Google answered HTTP " .. code .. ".", 0) end
      local name
      local cd = header(hd, "content-disposition")
      if cd then
        name = cd:match("filename%*=[Uu][Tt][Ff]%-8''([^;]+)")
        name = name and urldecode(name) or cd:match('filename="([^"]+)"')
        if name then name = name:gsub("%.xlsx$", "") end
      end
      local f = io.open(path, "wb")
      if not f then pcall(h.close); error("Cannot write " .. path, 0) end
      local size, last = 0, computer.uptime()
      while true do
        local okc, chunk = pcall(h.read, 8192)
        if not okc then f:close(); pcall(h.close); error("Download failed: " .. tostring(chunk), 0) end
        if chunk == nil then break end
        if chunk == "" then
          if computer.uptime() - last > 30 then f:close(); pcall(h.close); error("The download stopped.", 0) end
          coroutine.yield()
        else
          last = computer.uptime()
          if not f:write(chunk) then f:close(); pcall(h.close); error("The disk is full.", 0) end
          size = size + #chunk
          if size > (A.CONFIG.SHEETS_MAX_IMPORT or 4 * 1024 * 1024) then
            f:close(); pcall(h.close); error("The file is too big to import here.", 0)
          end
          progress(size)
        end
      end
      f:close()
      pcall(h.close)
      return size, name
    end
  end
  error("Too many redirects.", 0)
end

-- the whole import; runs inside a coroutine. report(text) shows progress. Returns the workbook.
local function import(link, tmp, report, pause)
  local id = link:match("/spreadsheets/d/([%w%-_]+)") or link:match("^%s*([%w%-_]+)%s*$")
  if not id or #id < 20 then error("That doesn't look like a Google Sheets link.", 0) end
  report("Connecting to Google...")
  local size, fname = download("https://docs.google.com/spreadsheets/d/" .. id .. "/export?format=xlsx", tmp,
    function(n) report(string.format("Downloading... %.1f KB", n / 1024)) end)
  local f = io.open(tmp, "rb")
  local sig = f and f:read(2)
  if f then f:close() end
  if sig ~= "PK" then
    error("Google sent a web page instead of the sheet - share it as \"Anyone with the link\".", 0)
  end
  report("Reading the spreadsheet...")
  local zip = openZip(tmp)
  local wb
  local ok, res = pcall(function()
    local wbx = readAll(zip, "xl/workbook.xml", pause)
    if not wbx then error("The file has no workbook.", 0) end
    local rels = readAll(zip, "xl/_rels/workbook.xml.rels", pause) or ""
    local targets = {}
    for tag in rels:gmatch("<Relationship%s[^>]*>") do
      local a = attrs(tag)
      if a.Id and a.Target then targets[a.Id] = a.Target end
    end
    wb = { name = fname or "Imported spreadsheet", sheets = {}, cur = 1, styles = {}, styleKey = {} }
    setWB(wb)                                          -- styleId() files the styles into it
    local styles = readStyles(readAll(zip, "xl/styles.xml", pause))
    local strings = {}
    readEntry(zip, "xl/sharedStrings.xml", elements("si", function(el) strings[#strings + 1] = textOf(el) end), pause)
    local list = {}
    for tag in wbx:gmatch("<sheet%s[^>]*>") do
      local a = attrs(tag)
      local rid = a["r:id"]
      if not rid then for k2, v in pairs(a) do if k2:match(":id$") then rid = v end end end
      local tgt = rid and targets[rid]
      if a.name and tgt then
        tgt = tgt:gsub("^/", "")
        if not tgt:match("^xl/") then tgt = "xl/" .. tgt end
        list[#list + 1] = { name = a.name, path = tgt }
      end
    end
    if #list == 0 then error("The file has no sheets.", 0) end
    local missing = {}
    for i, it in ipairs(list) do
      report("Reading sheet " .. i .. " of " .. #list .. ": " .. it.name)
      local sh = newSheet(it.name)
      wb.sheets[#wb.sheets + 1] = sh
      readSheet(zip, it.path, sh, strings, styles, pause, function(fn) missing[fn] = true end)
      if sh.defW then for c = 1, sh.cols do if not sh.colW[c] then sh.colW[c] = sh.defW end end end
      sh.defW = nil
    end
    strings = nil
    report("Calculating formulas...")
    pause()
    ENG.recalc()
    local names = {}
    for fn in pairs(missing) do names[#names + 1] = fn end
    table.sort(names)
    return names
  end)
  zip.f:close()
  filesystem.remove(tmp)
  if not ok then setWB(nil); error(res, 0) end
  return wb, res
end

return { import = import, _readAll = readAll, _openZip = openZip }
end)()
return XL
]==]
