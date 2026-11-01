-- Fuzz of the elisp gate: forms generated from fixed seeds over the
-- builtin subset, each valid for its profile, evaluated by Emacs
-- (emacs.el, one process per profile) and by organ (organ.lua).  A
-- difference passes only as an XT-10 rewrite that Emacs confirms on
-- the year-first arguments, or as a refusal whose precondition holds on
-- organ's trace of the evaluation (see NORMALIZE.md).

local M = {}

local root = vim.fn.getcwd()

local V = require("organ.elisp.value")
local B = require("organ.elisp.builtins")
local chars = require("organ.elisp.chars")

local SEEDS = { 1, 2, 3, 4, 5 }
local FORMS = 2000
local CHUNK = 100
local PROFILES = { "table", "diary", "prefix", "capture", "var", "link" }
local MAX_DEPTH = 5
local MAX_LEN = 64
local MAX_WIDTH = 40
local MAX_BIGNUMS = 2
local WORK = 2000

-- Generator

local function new_rng(seed)
  local s = seed * 7919 % 2147483646 + 1
  local function next_s()
    s = s * 48271 % 2147483647
    return s
  end
  return {
    int = function(lo, hi)
      return lo + next_s() % (hi - lo + 1)
    end,
    real = function()
      return next_s() / 2147483647
    end,
  }
end

local G = {}
G.__index = G

function G:int(lo, hi)
  return self.rng.int(lo, hi)
end

function G:chance(p)
  return self.rng.real() < p
end

function G:pick(t)
  return t[self.rng.int(1, #t)]
end

local function codes(s)
  local out, i = {}, 1
  while i <= #s do
    local c, j = V.utf8_next(s, i)
    out[#out + 1] = c
    i = j
  end
  return out
end

local function str_src(cs)
  local out = { '"' }
  for _, c in ipairs(cs) do
    if c == 34 then
      out[#out + 1] = '\\"'
    elseif c == 92 then
      out[#out + 1] = "\\\\"
    elseif c == 10 then
      out[#out + 1] = "\\n"
    elseif c == 9 then
      out[#out + 1] = "\\t"
    elseif c < 32 or c == 127 then
      out[#out + 1] = string.format("\\%03o", c)
    else
      out[#out + 1] = V.utf8_char(c)
    end
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

local function quoted(s)
  return str_src(codes(s))
end

-- stylua: ignore
local WIDE = {
  0xE9, 0xC9, 0xDF, 0x3A3, 0x3C3, 0x3C2, 0x130, 0x131, 0x1C5, 0xFB03, 0x6F22, 0x3042, 0x1F600,
  0x301, 0x200D, 0x1F1EF, 0x414, 0x587, 0xFF21, 0x1E9E, 0xB5, 0xFF, 0x2126, 0x212A, 0xC5, 0x390,
  0x149, 0x1F0, 0xA0, 0x2028, 0xFE0F, 0x85, 0x1E9B, 0x3B0, 0xE000, 0x10FFFF, 0x2C65, 0x23A,
}
local CONTROL = { 0, 1, 7, 9, 10, 13, 27, 127 }
local NON_SCALAR = { 0xD800, 0xDFFF, 0x110000, 0x3FFF7F, 0x3FFFFF }

-- stylua: ignore
local STRINGS = {
  "", " ", "abc", "a b c", "  padded  ", "a,b,,c", "Hello World", "hello-world_foo", "ÀÉÎ",
  "straße", "ΣΑΣ", "ὈΔΥΣΣΕΎΣ", "漢字テキスト", "é", "tab\there", "line\nbreak", "ǅemal", "İstanbul",
  "ﬁnal", "MiXeD cAsE", "123", "-4.5", "foo.bar", "x*y+z", "[a]", "a\\b", "😀 emoji", "ﬃ", "ǰ",
  "ŉ", "ΌΣΟΣ", "ab ab ab", "%d", "50%", "\t x \n", "aaa", "AbC", "x", "日本", "a\0b",
}

-- stylua: ignore
local NUMSTRS = {
  "12", "-7", "+3", "1.5", ".5", "1.", "1e5", "1.5e-3", "-0", "0.0", "0x1F", "  42", "42abc",
  "abc", "", "1e400", "-1e400", "1.0e+INF", "0.0e+NaN", "-0.0e+NaN",
  "123456789012345678901234567890", "0.1000000000000000055511151231257827", "9007199254740993",
  "4.35", "1_000", "#x10", "1/2", "١٢", "\t5", "1e", "e5", "-.5e2", "2.5e-310", "ff", "FF", "777",
  "101", "z", "  -12.5e+2xyz",
  "179769313486231570814527423731704356798070567525844996598917476803157260780028538"
    .. "760589558632766878171540458953514382464234321326889464182768467546703537516986"
    .. "049910576551282076245490090389328944075868508455133942304583236903222948165808"
    .. "559332123348274797826204144723168738177180919299881250404026184124858368.0",
}

-- stylua: ignore
local EDGE = {
  "9007199254740991", "9007199254740992", "-9007199254740992", "-9007199254740993",
  "2305843009213693951", "2305843009213693952", "-2305843009213693952", "-2305843009213693953",
  "9223372036854775807", "9223372036854775808", "-9223372036854775808", "18446744073709551615",
  "18446744073709551616", "4294967295", "4294967296", "2147483647", "-2147483648", "65535",
  "65536", "1114111", "4194303", "4194304", "-1", "0",
}

-- stylua: ignore
local FLOATS = {
  "0.0", "-0.0", "1.5", "-2.5", "0.5", "2.0", "1e3", "-1e-3", "1.0e+INF", "-1.0e+INF", "0.0e+NaN",
  "5e-324", "2.2250738585072014e-308", "1.7976931348623157e+308", "0.1", "1e21", "1e22",
  "123456789.123", "0.30000000000000004", "4.35", "1e16", "9007199254740993.0",
  "0.1000000000000000055511151231257827", "3.14159265358979323846264338327950288", "-1.5e300",
  "1.0e-400", ".5", "-.5e2", "2.5e-310", "-0.0e+NaN", "0.5e1", "1e-7", "100.0", "-3.0", "2.5",
  "3.5",
}

-- stylua: ignore
local SYMS = {
  "foo", "bar", "a", "b", "x", "abc", "Foo", "nil", "t", ":key", ":k", "car", "+", "error", "1+",
  "foo-bar", "list", "upcase",
}

function G:len(max)
  max = math.min(max or MAX_LEN, MAX_LEN)
  local r = self:int(1, 100)
  local n
  if r <= 10 then
    n = 0
  elseif r <= 70 then
    n = self:int(1, 6)
  elseif r <= 95 then
    n = self:int(7, 20)
  else
    n = self:int(21, MAX_LEN)
  end
  return math.min(n, math.max(max, 0))
end

function G:char()
  local r = self:int(1, 100)
  if r <= 72 then
    return self:int(32, 126)
  elseif r <= 80 then
    return self:pick(CONTROL)
  end
  return self:pick(WIDE)
end

function G:string()
  if self:chance(0.3) then
    return quoted(self:pick(STRINGS))
  end
  local cs = {}
  for i = 1, self:len() do
    cs[i] = self:char()
  end
  return str_src(cs)
end

function G:digits(n)
  local t = { tostring(self:int(1, 9)) }
  for i = 2, n do
    t[i] = tostring(self:int(0, 9))
  end
  return table.concat(t)
end

function G:integer()
  local r = self:int(1, 100)
  if r <= 50 then
    return tostring(self:int(-20, 100))
  elseif r <= 62 then
    return (self:chance(0.3) and "-" or "") .. self:digits(self:int(4, 15))
  elseif r <= 75 then
    return self:pick(EDGE)
  elseif r <= 90 and self.bigs > 0 then
    self.bigs = self.bigs - 1
    local n = self:chance(0.7) and self:int(16, 40) or self:int(41, 300)
    return (self:chance(0.4) and "-" or "") .. self:digits(n)
  elseif r <= 95 then
    local radix = self:pick({ "#x", "#b", "#o", "#24r", "#36r" })
    local alphabet = radix == "#b" and "01"
      or radix == "#o" and "01234567"
      or radix == "#x" and "0123456789abcdefABCDEF"
      or radix == "#24r" and "0123456789abcdefghijklmn"
      or "0123456789abcdefghijklmnopqrstuvwxyz"
    local t = {}
    for i = 1, self:int(1, 18) do
      local k = self:int(1, #alphabet)
      t[i] = alphabet:sub(k, k)
    end
    return radix .. (self:chance(0.2) and "-" or "") .. table.concat(t)
  end
  return self:pick({ "1.", "+7", "-0", "+0", "-1.", "0" })
end

function G:float()
  if self:chance(0.5) then
    return self:pick(FLOATS)
  end
  local m = (self.rng.real() * 2 - 1) * 10 ^ self:int(-12, 25)
  local s = string.format("%.17g", m)
  if not s:find("[.eEn]") then
    s = s .. ".0"
  end
  return s
end

function G:char_src()
  local r = self:int(1, 100)
  if r <= 50 then
    local c = self:pick({ self:int(97, 122), self:int(65, 90), self:int(48, 57) })
    return "?" .. string.char(c)
  elseif r <= 96 then
    return tostring(self:char())
  end
  return tostring(self:pick(NON_SCALAR))
end

function G:small(lo, hi)
  return tostring(self:int(lo, hi))
end

-- Literal data of kind `k` as read syntax; the second value says
-- whether evaluating it needs a quote.
function G:datum(k, d)
  d = d or 2
  if k == "int" then
    return self:integer(), false
  elseif k == "flt" then
    return self:float(), false
  elseif k == "num" then
    if self:chance(0.7) then
      return self:integer(), false
    end
    return self:float(), false
  elseif k == "chr" then
    return self:char_src(), false
  elseif k == "str" then
    return self:string(), false
  elseif k == "sym" then
    local s = self:pick(SYMS)
    return s, not (s == "nil" or s == "t" or s:sub(1, 1) == ":")
  elseif k == "bool" then
    local r = self:int(1, 10)
    if r <= 4 then
      return "nil", false
    elseif r <= 8 then
      return "t", false
    end
    return self:datum("any", d)
  elseif k == "list" or k == "vec" or k == "intlist" or k == "strlist" then
    local ek = (k == "intlist" and "int") or (k == "strlist" and "str") or "any"
    local items = {}
    for i = 1, self:len(self.maxlen) do
      items[i] = (self:datum(ek, d - 1))
    end
    if k == "vec" then
      return "[" .. table.concat(items, " ") .. "]", false
    end
    if #items == 0 then
      return "nil", false
    end
    if k == "list" and self:chance(0.08) then
      return "(" .. table.concat(items, " ") .. " . " .. (self:datum("any", 0)) .. ")", true
    end
    return "(" .. table.concat(items, " ") .. ")", true
  elseif k == "alist" then
    local items = {}
    for i = 1, self:len(12) do
      local key = self:chance(0.5) and self:pick({ "a", "b", "c", "x", "nil" })
        or (self:datum(self:pick({ "int", "str", "flt" }), 0))
      items[i] = "(" .. key .. " . " .. (self:datum("any", d - 1)) .. ")"
    end
    if self:chance(0.1) then
      items[#items + 1] = (self:datum("any", 0))
    end
    return #items == 0 and "nil" or "(" .. table.concat(items, " ") .. ")", #items > 0
  elseif k == "seq" then
    return self:datum(self:pick({ "list", "vec", "str" }), d)
  end
  if d <= 0 then
    return self:datum(self:pick({ "int", "int", "flt", "str", "sym", "chr" }), 0)
  end
  return self:datum(self:pick({ "int", "int", "flt", "str", "sym", "chr", "list", "vec" }), d)
end

local function in_scope_value(kind, want)
  if kind == want or want == "any" then
    return true
  end
  if want == "num" then
    return kind == "int" or kind == "flt" or kind == "chr"
  elseif want == "int" then
    return kind == "chr"
  elseif want == "seq" then
    return kind == "list"
      or kind == "vec"
      or kind == "str"
      or kind == "intlist"
      or kind == "strlist"
  elseif want == "list" then
    return kind == "intlist" or kind == "strlist"
  end
  return false
end

function G:var_of(kind)
  local c = {}
  for _, v in ipairs(self.scope) do
    if in_scope_value(v.kind, kind) then
      c[#c + 1] = v.name
    end
  end
  if #c == 0 then
    return nil
  end
  return self:pick(c)
end

function G:fresh()
  self.nvars = self.nvars + 1
  return "v" .. self.nvars
end

function G:push(name, kind, fixed)
  self.scope[#self.scope + 1] = { name = name, kind = kind, fixed = fixed }
end

function G:pop(n)
  for _ = 1, n or 1 do
    self.scope[#self.scope] = nil
  end
end

-- Kinds generated only from their own generators (never replaced by a
-- value of another kind): sizes and counts Emacs would allocate or loop
-- over, time values (nil means now), and format strings.
local OWN = {
  count = true,
  exp = true,
  shift = true,
  time = true,
  zone = true,
  tfmt = true,
  fmt = true,
  nsint = true,
  step = true,
  fn1 = true,
  fn2 = true,
  re = true,
  date = true,
  numstr = true,
  orgts = true,
  symname = true,
  ellipsis = true,
}

local LITERAL = {}

function G:lit(kind)
  local f = LITERAL[kind]
  if f then
    return f(self)
  end
  local d, q = self:datum(kind)
  return q and ("'" .. d) or d
end

LITERAL.count = function(g)
  local r = g:int(1, 100)
  if r <= 80 then
    return g:small(0, 12)
  elseif r <= 92 then
    return g:small(13, MAX_LEN)
  elseif r <= 97 then
    return g:small(-3, -1)
  end
  return g:pick({ "1.5", "nil", '"3"', "-9223372036854775809", "99999999999999999999999" })
end
LITERAL.idx = function(g)
  if g:chance(0.9) then
    return g:small(-3, 10)
  end
  return g:pick({ "1.0", "nil", "4611686018427387904", "-99999999999999999999" })
end
LITERAL.exp = function(g)
  if g:chance(0.85) then
    return g:small(-3, 12)
  end
  return g:pick({ "0.5", "2.0", "-1.5", "1.0e+INF", "nil" })
end
LITERAL.shift = function(g)
  if g:chance(0.85) then
    return g:small(-70, 70)
  end
  return g:pick({ "300", "-300", "-9223372036854775808", "2305843009213693952", "1.0" })
end
LITERAL.nsint = function(g)
  if g:chance(0.9) then
    return g:small(-20, 40)
  end
  return g:pick({ "1.5", "-2.5", "0.0" })
end
LITERAL.step = function(g)
  if g:chance(0.9) then
    return g:pick({ g:small(1, 5), g:small(-5, -1), "0.5", "1.5", "nil" })
  end
  return g:pick({ "0", "0.0", "-0.5" })
end
LITERAL.numstr = function(g)
  if g:chance(0.7) then
    return quoted(g:pick(NUMSTRS))
  end
  local s = (g:chance(0.3) and "-" or "")
    .. g:digits(g:int(1, 30))
    .. (g:chance(0.5) and ("." .. g:digits(g:int(1, 30))) or "")
    .. (g:chance(0.3) and ("e" .. g:small(-330, 330)) or "")
  return quoted(s)
end
LITERAL.base = function(g)
  return g:pick({ "nil", "2", "8", "10", "16", "1", "17", "36" })
end
LITERAL.re = function(g)
  local r = g:int(1, 100)
  if r <= 80 then
    return quoted(
      g:pick({ " ", ",", ", ", "-", "ab", "x", "", "\t", "é", "É", "Σ", ";", "a", "  " })
    )
  elseif r <= 90 then
    return quoted(g:pick({ "[ ]+", "a.b", "\\s-", "^x", "x*", "[,;]", "a+", "\\(", "$" }))
  end
  return "nil"
end
LITERAL.fn1 = function(g)
  return g:fn1("any", 0)
end
LITERAL.fn2 = function(g)
  return g:fn2("any", 0)
end

-- stylua: ignore
local ZONES = {
  "nil", "t", '"UTC"', "0", "3600", "-18000", "19800", "43200", "-43200", "50400", "90000",
  "-90000", '\'(3600 "CET")', '\'(-18000 "EST")', '\'(19800 "IST")', '\'(0 "UTC")',
  '\'(3600 "C")', "'(7200 nil)", '\'(3600 "a b")', '"EST5EDT"', '"JST-9"', '"Asia/Tokyo"',
  '"America/New_York"', '"Australia/Lord_Howe"', '"Europe/Dublin"', '"<+0530>-5:30"', '"XYZ0"',
  "'wall", '"Etc/GMT+5"', '"CET-1CEST,M3.5.0,M10.5.0/3"', "1.5", "'(3600)",
}
LITERAL.zone = function(g)
  return g:pick(ZONES)
end

-- stylua: ignore
local TIMES = {
  "0", "1", "-1", "86400", "1700000000", "-2208988800", "253402300799", "1.5", "-0.5",
  "1700000000.25", "1e20", "0.0", "-0.0", "1.0e+INF", "0.0e+NaN", "'(25000 1234)",
  "'(0 1 500000)", "'(1 2 3 4)", "'(25972 40000 999999 999999)", "'(123456 . 1000)", "'(1 . 3)",
  "'(100 . 0)", "'(5 . -1)", "'(1700000000123456789 . 1000000000)", "'(-1 . 65536)",
  "'(1 2 3 4 5)", "'(1.5 2)", "'(-1 70000)", '"x"', "'foo", "[1 2]", "4611686018427387904",
  "-9223372036854775809", "99999999999999999999999", "'(0 . 1)", "'(7 . 2)", "-62167219200",
  "67767976233316800", "-67768040609740800",
}
LITERAL.time = function(g)
  local r = g:int(1, 100)
  if r <= 50 then
    return g:pick(TIMES)
  elseif r <= 80 then
    return tostring(g:int(-2147483647, 2147483647) * g:pick({ 1, 2, 3, 7 }))
  elseif r <= 90 then
    return string.format(
      "'(%d %d %d %d)",
      g:int(-5, 30000),
      g:int(0, 65535),
      g:int(0, 999999),
      g:int(0, 999999)
    )
  end
  return string.format(
    "'(%d . %s)",
    g:int(-1000000, 1000000),
    g:pick({ "1", "10", "1000", "65536", "1000000000", "7" })
  )
end

-- stylua: ignore
local TDIRECTIVES = {
  "Y", "m", "d", "H", "M", "S", "z", "s", "N", "j", "e", "k", "l", "y", "C", "G", "g", "V", "U",
  "W", "u", "w", "D", "F", "T", "R", "n", "t", "%", "I", ":z", "::z", ":::z", "3N", "6N", "9N",
  "1N", "Z", "q", "O", "Q",
}
local TLOCALE = { "a", "A", "b", "B", "h", "c", "x", "X", "p", "P", "r", "Ey", "OH", "EC" }
LITERAL.tfmt = function(g)
  local parts = {}
  for _ = 1, g:int(1, 4) do
    if g:chance(0.3) then
      parts[#parts + 1] = g:pick({ " ", "-", ":", "T", "x", "<", "" })
    end
    local flags = g:chance(0.25) and g:pick({ "-", "0", "^", "#", "+", "^#", "-0" }) or ""
    local width = g:chance(0.15) and tostring(g:int(1, 20)) or ""
    local conv = g:chance(0.04) and g:pick(TLOCALE) or g:pick(TDIRECTIVES)
    parts[#parts + 1] = "%" .. flags .. width .. conv
  end
  if g:chance(0.02) then
    parts[#parts + 1] = g:pick({ "é", "%", "%E" })
  end
  return quoted(table.concat(parts))
end

-- stylua: ignore
local ORGTS = {
  "<2024-03-10 Sun>", "<2024-03-10 Sun 10:30>", "[2023-12-31 Sun 23:59]", "2024-02-30",
  "<1970-01-01 Thu>", "<9999-12-31>", "<0001-01-01>", "garbage", "", "<2024-03-10 Sun 25:00>",
  "<2024-13-01>", "<2024-03-10 10:30-11:00>", "2024-03-10 7:05", "<2038-01-19 Tue 03:14>",
  "<1900-02-28>", "<2024-02-29 Thu 00:00>", "<2000-01-01 +1w>",
}
-- Names without a newline, which prin1 leaves raw in a symbol name.
LITERAL.symname = function(g)
  local cs = {}
  for i = 1, g:len(12) do
    local c = g:char()
    cs[i] = c == 10 and 32 or c
  end
  return str_src(cs)
end

LITERAL.orgts = function(g)
  return quoted(g:pick(ORGTS))
end

function G:month()
  if self:chance(0.9) then
    return self:small(1, 12)
  end
  return self:pick({ "0", "13", "-1", "2.0", "99999999999999999999" })
end

function G:day()
  if self:chance(0.9) then
    return self:small(1, 31)
  end
  return self:pick({ "0", "32", "-1", "29", "30", "1.5" })
end

function G:year()
  local r = self:int(1, 100)
  if r <= 70 then
    return self:small(1, 2100)
  elseif r <= 85 then
    return self:small(1, 9999)
  end
  return self:pick({
    "0",
    "-1",
    "-400",
    "1000000",
    "1900",
    "2000",
    "100000000000000000000",
    "2024.0",
    "-4713",
  })
end

LITERAL.date = function(g)
  local r = g:int(1, 100)
  if r <= 90 then
    return string.format("'(%s %s %s)", g:month(), g:day(), g:year())
  end
  return g:pick({
    "'(1 2)",
    '"x"',
    "'(1 2 3 4)",
    "nil",
    "'(2 29 2023)",
    "'(2 29 2024)",
    "[1 2 2024]",
  })
end
LITERAL.year = function(g)
  return g:year()
end
LITERAL.month = function(g)
  return g:month()
end
LITERAL.absint = function(g)
  local r = g:int(1, 100)
  if r <= 80 then
    return g:small(-1000000, 3700000)
  end
  return g:pick({ "0", "1", "-1", "738000.5", "100000000000000000000", "-100000000000000000000" })
end
LITERAL.dayname = function(g)
  if g:chance(0.9) then
    return g:small(0, 6)
  end
  return g:pick({ "7", "-1", "'(1 3)", "t" })
end

-- Format strings for `format' and `error', with their arguments.
local FCONV = { "s", "S", "d", "o", "x", "X", "c", "e", "f", "g", "b", "B", "i", "%" }
local FARG = {
  s = "any",
  S = "any",
  d = "num",
  o = "int",
  x = "int",
  X = "int",
  c = "chr",
  e = "num",
  f = "num",
  g = "num",
  b = "int",
  B = "int",
  i = "int",
}

function G:format_call(name, d)
  local parts, args = {}, {}
  local text = { "", " ", "x=", "-", "é", "漢", "[", "]", "ab", ":" }
  if name ~= "format" and self:chance(0.15) then
    text = { "can't", "`x'", "don't" }
  end
  for _ = 1, self:int(0, 4) do
    if self:chance(0.4) then
      parts[#parts + 1] = self:pick(text)
    end
    local conv = self:pick(FCONV)
    local spec = "%"
    if conv ~= "%" then
      if self:chance(0.05) then
        spec = spec .. tostring(math.min(#args + 1, self:int(1, 3))) .. "$"
      end
      for _, f in ipairs({ "-", "+", " ", "#", "0" }) do
        if self:chance(0.12) then
          spec = spec .. f
        end
      end
      local width = self:chance(0.4)
      if width then
        spec = spec .. tostring(self:int(0, MAX_WIDTH))
      end
      -- %.0c of a sign character with a width aborts Emacs.
      if self:chance(0.3) and not (conv == "c" and width) then
        spec = spec .. "." .. (self:chance(0.02) and "100" or tostring(self:int(0, 20)))
      end
      local k = FARG[conv]
      if self:chance(0.06) then
        k = "any"
      end
      args[#args + 1] = self:arg(k, d)
    end
    parts[#parts + 1] = spec .. conv
  end
  if self:chance(0.03) then
    parts[#parts + 1] = self:pick({ "%", "%y", "%5", "%-" })
  end
  if self:chance(0.05) then
    args[#args + 1] = self:arg("any", d)
  end
  if self:chance(0.03) and #args > 0 then
    args[#args] = nil
  end
  local out = { "(" .. name, quoted(table.concat(parts)) }
  for _, a in ipairs(args) do
    out[#out + 1] = a
  end
  return table.concat(out, " ") .. ")"
end

-- Functions over elements of kind `ek'.
local function words(s)
  return vim.split(vim.trim(s), "%s+")
end

local FN1 = {
  int = words([[
    1+ 1- abs float zerop natnump number-to-string lognot identity list null integerp -
    calendar-leap-year-p char-to-string upcase
  ]]),
  str = words([[
    upcase downcase capitalize length string-to-number string-to-list string-empty-p identity
    list string-to-char string-trim upcase-initials string-blank-p string-width reverse
  ]]),
  any = words([[
    identity null consp list atom symbolp stringp numberp sequencep car-safe length vectorp
    functionp keywordp booleanp characterp
  ]]),
}

local FN1S = {
  int = words("number-to-string char-to-string"),
  str = words("identity upcase downcase capitalize string-trim"),
  any = words("symbol-name identity"),
}

local FN1L = {
  int = words("list number-sequence"),
  str = words("list string-to-list split-string"),
  any = words("list"),
}

local FN2 = {
  int = words("+ - * max min < > = <= >= cons list logand eq eql equal /= mod %"),
  str = words([[
    string< string= string> concat string-prefix-p cons list equal string-search string-lessp
    string-equal string-suffix-p
  ]]),
  any = words("equal eq eql cons list"),
}

function G:fn_ref(name)
  local r = self:int(1, 10)
  if r <= 7 then
    return "#'" .. name
  end
  return "'" .. name
end

function G:lambda(params, body_kind, ek, d)
  local saved = self.mult
  self.mult = math.max(self.mult, 2)
  local names = {}
  for i = 1, params do
    names[i] = self:fresh()
    self:push(names[i], ek)
  end
  local body = self:expr(body_kind, d)
  self:pop(params)
  self.mult = saved
  local src = "(lambda (" .. table.concat(names, " ") .. ") " .. body .. ")"
  if self:chance(0.2) then
    return "#'" .. src
  end
  return src
end

function G:fn1(ek, d, ret)
  local pool = (ret == "str" and FN1S or ret == "list" and FN1L or FN1)[ek] or FN1.any
  if d <= 0 or self:chance(0.5) then
    return self:fn_ref(self:pick(pool))
  end
  if ret == "list" then
    local p = self:fresh()
    self:push(p, ek)
    local a, b = self:expr("any", d - 1), self:expr("any", d - 1)
    self:pop()
    return "(lambda (" .. p .. ") (list " .. a .. " " .. b .. "))"
  end
  return self:lambda(1, ret or "any", ek, d - 1)
end

function G:fn2(ek, d)
  if d <= 0 or self:chance(0.5) then
    return self:fn_ref(self:pick(FN2[ek] or FN2.any))
  end
  return self:lambda(2, "bool", ek, d - 1)
end

-- A sequence of elements of kind `ek': its source and an upper bound on
-- its length.
function G:seq(ek, d, container)
  container = container or self:pick({ "list", "list", "list", "vec", "str" })
  if container == "str" then
    if ek ~= "any" and ek ~= "chr" and ek ~= "int" then
      container = "list"
    else
      local v = self:var_of("str")
      if v and self:chance(0.3) then
        return v, MAX_LEN
      end
      return self:string(), MAX_LEN
    end
  end
  local r = self:int(1, 100)
  if r <= 15 then
    local v = self:var_of(ek == "int" and "intlist" or ek == "str" and "strlist" or "list")
    if v and container == "list" then
      return v, MAX_LEN
    end
  end
  local n = self:len(self.maxlen)
  if r <= 30 and ek == "int" and container == "list" and d > 0 then
    local a = self:int(-10, 20)
    return string.format("(number-sequence %d %d)", a, a + math.min(n, 20)), n + 1
  end
  local items = {}
  if r <= 60 and d > 0 and n <= 8 and container == "list" then
    for i = 1, n do
      items[i] = self:expr(ek, d - 1)
    end
    return "(list" .. (n > 0 and (" " .. table.concat(items, " ")) or "") .. ")", n
  end
  for i = 1, n do
    items[i] = (self:datum(ek, 1))
  end
  if container == "vec" then
    return "[" .. table.concat(items, " ") .. "]", n
  end
  return n == 0 and "nil" or ("'(" .. table.concat(items, " ") .. ")"), n
end

function G:with_work(n, f)
  local saved_mult, saved_max = self.mult, self.maxlen
  self.mult = self.mult * math.max(n, 1)
  self.maxlen = math.max(1, math.min(MAX_LEN, math.floor(WORK / self.mult)))
  local v = f()
  self.mult, self.maxlen = saved_mult, saved_max
  return v
end

local function call_src(name, args)
  if #args == 0 then
    return "(" .. name .. ")"
  end
  return "(" .. name .. " " .. table.concat(args, " ") .. ")"
end

-- Builtins: { name, ret, args = {...}, opt = {...}, rest = kind } or a
-- custom generator `gen(g, d)'.
local FUNCTIONS = {}
local function fn(name, ret, args, opt, rest)
  FUNCTIONS[#FUNCTIONS + 1] = { name = name, ret = ret, args = args or {}, opt = opt, rest = rest }
end
local function custom(name, ret, gen, hof)
  FUNCTIONS[#FUNCTIONS + 1] = { name = name, ret = ret, gen = gen, hof = hof }
end

for _, n in ipairs({ "+", "*" }) do
  fn(n, "num", {}, nil, "num")
end
fn("-", "num", {}, nil, "num")
fn("/", "num", { "num" }, nil, "num")
fn("%", "int", { "int", "int" })
fn("mod", "num", { "num", "num" })
for _, n in ipairs({ "1+", "1-", "abs" }) do
  fn(n, "num", { "num" })
end
fn("max", "num", { "num" }, nil, "num")
fn("min", "num", { "num" }, nil, "num")
for _, n in ipairs({ "floor", "ceiling", "round", "truncate" }) do
  fn(n, "int", { "num" }, { "num" })
end
fn("float", "flt", { "num" })
for _, n in ipairs({ "ffloor", "fceiling", "fround", "ftruncate" }) do
  fn(n, "flt", { "flt" })
end
custom("expt", "num", function(g)
  local base = g:lit("num")
  return call_src("expt", { base, #base > 20 and g:small(0, 3) or g:lit("exp") })
end)
for _, n in ipairs({ "sqrt", "exp", "sin", "cos", "tan", "asin", "acos" }) do
  fn(n, "flt", { "num" })
end
fn("log", "flt", { "num" }, { "num" })
fn("atan", "flt", { "num" }, { "num" })
fn("isnan", "bool", { "flt" })
for _, n in ipairs({ "logand", "logior", "logxor" }) do
  fn(n, "int", {}, nil, "int")
end
fn("lognot", "int", { "int" })
fn("ash", "int", { "int", "shift" })
for _, n in ipairs({ "=", "<", ">", "<=", ">=" }) do
  fn(n, "bool", { "num" }, nil, "num")
end
fn("/=", "bool", { "num", "num" })
fn("zerop", "bool", { "num" })
for _, n in ipairs({ "natnump", "numberp", "integerp", "floatp" }) do
  fn(n, "bool", { "any" })
end
fn("number-to-string", "str", { "num" })
fn("string-to-number", "num", { "numstr" }, { "base" })
for _, n in ipairs({
  "null",
  "not",
  "atom",
  "consp",
  "listp",
  "nlistp",
  "stringp",
  "symbolp",
  "vectorp",
  "sequencep",
  "booleanp",
  "characterp",
  "keywordp",
}) do
  fn(n, "bool", { "any" })
end
custom("functionp", "bool", function(g, d)
  if g:chance(0.5) then
    return "(functionp " .. g:fn1("any", d) .. ")"
  end
  return "(functionp " .. g:expr("any", d) .. ")"
end)
-- A literal written twice reads as two objects Emacs may or may not
-- share: strings, floats, bignums, vectors and time lists.
function G:twin()
  local r = self:int(1, 6)
  if r == 1 then
    return self:string()
  elseif r == 2 then
    return self:float()
  elseif r == 3 then
    return self:pick({ "2305843009213693951", "2305843009213693952", "9007199254740993" })
      .. self:pick({ "", "0", "00000000000" })
  elseif r == 4 then
    return "[" .. self:small(0, 9) .. " " .. self:string() .. "]"
  elseif r == 5 then
    return '""'
  end
  return (self:lit("time"):gsub("^'", ""))
end

local function quote_twin(x)
  return x:find("^[%(%a]") and ("'" .. x) or x
end

for _, n in ipairs({ "eq", "eql", "equal" }) do
  custom(n, "bool", function(g, d)
    if g:chance(0.25) then
      local x = quote_twin(g:twin())
      return call_src(n, { x, x })
    end
    return call_src(n, { g:arg("any", d), g:arg("any", d) })
  end)
end
fn("identity", "any", { "any" })
fn("ignore", "any", {}, nil, "any")
fn("concat", "str", {}, nil, "strish")
fn("substring", "str", { "str" }, { "idx", "idx" })
fn("string-to-char", "chr", { "str" })
fn("char-to-string", "str", { "chr" })
fn("string", "str", {}, nil, "chr")
fn("make-string", "str", { "count", "chr" }, { "bool" })
fn("string-to-list", "list", { "str" })
fn("string-to-vector", "vec", { "str" })
fn("length", "int", { "seq" })
for _, n in ipairs({
  "string=",
  "string-equal",
  "string<",
  "string-lessp",
  "string>",
  "string-greaterp",
}) do
  fn(n, "bool", { "strsym", "strsym" })
end
fn("string-prefix-p", "bool", { "str", "str" }, { "bool" })
fn("string-suffix-p", "bool", { "str", "str" }, { "bool" })
fn("string-search", "any", { "str", "str" }, { "idx" })
fn("string-replace", "str", { "str", "str", "str" })
fn("string-empty-p", "bool", { "str" })
fn("string-blank-p", "bool", { "str" })
for _, n in ipairs({ "upcase", "downcase", "capitalize", "upcase-initials" }) do
  fn(n, "any", { "strchr" })
end
fn("string-trim", "str", { "str" }, { "re", "re" })
fn("string-trim-left", "str", { "str" }, { "re" })
fn("string-trim-right", "str", { "str" }, { "re" })
fn("split-string", "strlist", { "str" }, { "re", "bool", "re" })
fn("string-join", "str", { "strlist" }, { "str" })
fn("symbol-name", "str", { "sym" })
fn("intern", "sym", { "symname" })
fn("string-width", "int", { "str" }, { "idx", "idx" })
fn("truncate-string-to-width", "str", { "str", "count" }, { "count", "chr", "ellipsis", "bool" })
fn("string-pad", "str", { "str", "count" }, { "chr", "bool" })
custom("format", "str", function(g, d)
  return g:format_call("format", d)
end)
custom("mapconcat", "str", function(g, d)
  local ek = g:pick({ "int", "str", "any" })
  local seq, n = g:seq(ek, d)
  local f = g:with_work(n, function()
    return g:fn1(ek, d, "str")
  end)
  local args = { f, seq }
  if g:chance(0.7) then
    args[3] = g:lit("str")
  end
  return call_src("mapconcat", args)
end, true)

fn("list", "list", {}, nil, "any")
fn("cons", "list", { "any", "any" })
for _, n in ipairs({ "car", "cdr", "caar", "cadr", "cdar", "cddr" }) do
  fn(n, "any", { "list" })
end
fn("car-safe", "any", { "any" })
fn("cdr-safe", "any", { "any" })
fn("nth", "any", { "idx", "list" })
fn("nthcdr", "any", { "idx", "list" })
fn("last", "list", { "list" }, { "count" })
fn("butlast", "list", { "list" }, { "count" })
fn("append", "list", {}, nil, "seq")
fn("vconcat", "vec", {}, nil, "seq")
-- Arguments are fresh lists, or quoted ones outside loops and
-- functions: Emacs would splice a shared list into a cycle, which later
-- builtins may walk forever.  Cycles are made only at top level (G:form).
custom("nconc", "list", function(g)
  local args = {}
  for i = 1, g:int(0, 4) do
    if g.mult == 1 and g:chance(0.4) then
      args[i] = g:lit("list")
    elseif g:chance(0.1) then
      args[i] = g:lit(g:pick({ "int", "str", "vec" }))
    else
      local items = {}
      for k = 1, g:int(0, 4) do
        items[k] = g:lit("any")
      end
      args[i] = call_src("list", items)
    end
  end
  return call_src("nconc", args)
end)
fn("reverse", "seq", { "seq" })
fn("nreverse", "seq", { "seq" })
for _, n in ipairs({ "member", "memq", "memql" }) do
  custom(n, "any", function(g, d)
    if g:chance(0.25) then
      local x = g:twin()
      return call_src(n, { quote_twin(x), "'(" .. g:lit("int") .. " " .. x .. ")" })
    end
    return call_src(n, { g:arg("any", d), g:arg("list", d) })
  end)
end
custom("assoc", "any", function(g, d)
  local args = { g:expr("any", d), g:lit("alist") }
  if g:chance(0.2) then
    args[3] = g:fn2("any", d)
  end
  return call_src("assoc", args)
end)
for _, n in ipairs({ "assq", "rassq", "rassoc" }) do
  custom(n, "any", function(g, d)
    if g:chance(0.25) then
      local x = g:twin()
      local pair = n == "assq" and ("(" .. x .. " . 1)") or ("(1 . " .. x .. ")")
      return call_src(n, { quote_twin(x), "'(" .. pair .. ")" })
    end
    return call_src(n, { g:arg("any", d), g:arg("alist", d) })
  end)
end
custom("alist-get", "any", function(g, d)
  local args = { g:expr("any", d), g:lit("alist") }
  local n = g:int(0, 3)
  if n >= 1 then
    args[3] = g:expr("any", d)
  end
  if n >= 2 then
    args[4] = g:lit("bool")
  end
  if n >= 3 then
    args[5] = g:fn2("any", d)
  end
  return call_src("alist-get", args)
end)
fn("number-sequence", "intlist", { "nsint" }, { "nsint", "step" })

local function mapper(name, ret, fret)
  custom(name, ret, function(g, d)
    local ek = g:pick({ "int", "str", "any" })
    local seq, n = g:seq(ek, d)
    local f = g:with_work(n, function()
      return g:fn1(ek, d, fret)
    end)
    return call_src(name, { f, seq })
  end, true)
end
mapper("mapcar", "list")
mapper("mapc", "seq")
mapper("mapcan", "list", "list")
mapper("seq-filter", "list")
mapper("seq-remove", "list")
mapper("seq-map", "list")

for _, n in ipairs({ "remove", "remq", "delete", "delq" }) do
  custom(n, "seq", function(g, d)
    if g:chance(0.25) then
      local x = g:twin()
      return call_src(n, { quote_twin(x), "(list 1 " .. quote_twin(x) .. ")" })
    end
    local ek = g:pick({ "int", "str", "any" })
    return call_src(n, { g:expr(ek, d), (g:seq(ek, d)) })
  end)
end
-- A list joined to itself, past the length where these hash.
function G:doubled(ek, d)
  local seq, n = self:seq(ek, d, "list")
  if self:chance(0.3) then
    return "(append " .. seq .. " " .. seq .. " " .. seq .. ")", 3 * n
  end
  return seq, n
end

custom("delete-dups", "list", function(g, d)
  return call_src("delete-dups", { (g:doubled(g:pick({ "int", "str", "any" }), d)) })
end)
custom("sort", "seq", function(g, d)
  local ek = g:pick({ "int", "str", "any" })
  local seq, n = g:seq(ek, d)
  return g:with_work(n, function()
    local r = g:int(1, 10)
    if r <= 2 then
      return call_src("sort", { seq })
    elseif r <= 7 then
      return call_src("sort", { seq, g:fn2(ek, d) })
    end
    local args = { seq }
    for _, kw in ipairs({ ":key", ":lessp", ":reverse", ":in-place" }) do
      if g:chance(0.4) then
        args[#args + 1] = kw
        if kw == ":key" then
          args[#args + 1] = g:fn1(ek, d)
        elseif kw == ":lessp" then
          args[#args + 1] = g:fn2(ek, d)
        else
          args[#args + 1] = g:lit("bool")
        end
      end
    end
    return call_src("sort", args)
  end)
end, true)
custom("aref", "any", function(g, d)
  return call_src("aref", { g:expr(g:pick({ "vec", "str" }), d), g:lit("idx") })
end)
fn("elt", "any", { "seq", "idx" })
custom("seq-reduce", "any", function(g, d)
  local ek = g:pick({ "int", "str", "any" })
  local seq, n = g:seq(ek, d)
  local f = g:with_work(n, function()
    return g:fn2(ek, d)
  end)
  return call_src("seq-reduce", { f, seq, g:expr(ek, d) })
end, true)
fn("seq-take", "seq", { "seq", "count" })
fn("seq-drop", "seq", { "seq", "count" })
for _, n in ipairs({ "seq-uniq", "seq-contains-p", "seq-position" }) do
  custom(n, "any", function(g, d)
    local ek = g:pick({ "int", "str", "any" })
    local seq, len, work
    if n == "seq-uniq" then
      seq, len = g:doubled(ek, d)
      work = len * len / 2
    else
      seq, len = g:seq(ek, d)
      work = len
    end
    local args = { seq }
    if n ~= "seq-uniq" then
      args[2] = g:expr(ek, d)
    end
    if g:chance(0.25) then
      args[#args + 1] = g:with_work(work, function()
        return g:fn2(ek, d)
      end)
    end
    return call_src(n, args)
  end, true)
end
fn("seq-elt", "any", { "seq", "idx" })
fn("seq-first", "any", { "seq" })
fn("seq-rest", "seq", { "seq" })

custom("apply", "any", function(g, d)
  local r = g:int(1, 6)
  if r == 1 then
    return call_src(
      "apply",
      { g:fn_ref(g:pick({ "+", "max", "min", "*", "logior" })), (g:seq("int", d, "list")) }
    )
  elseif r == 2 then
    return call_src("apply", { g:fn_ref("concat"), g:expr("str", d), (g:seq("str", d, "list")) })
  elseif r == 3 then
    return call_src("apply", { g:fn_ref("list"), g:expr("any", d), g:lit("list") })
  elseif r == 4 then
    return call_src("apply", { g:fn_ref("format"), quoted("%s-%S"), g:lit("list") })
  elseif r == 5 then
    return call_src("apply", { g:fn2("int", d), g:lit("intlist") })
  end
  return call_src("apply", { g:fn1("any", d), g:expr("any", d), "nil" })
end)
custom("funcall", "any", function(g, d)
  local r = g:int(1, 4)
  if r == 1 then
    local ek = g:pick({ "int", "str", "any" })
    return call_src("funcall", { g:fn1(ek, d), g:expr(ek, d) })
  elseif r == 2 then
    local ek = g:pick({ "int", "str", "any" })
    return call_src("funcall", { g:fn2(ek, d), g:expr(ek, d), g:expr(ek, d) })
  elseif r == 3 then
    local args = { g:fn_ref("list") }
    for i = 2, g:int(1, 4) do
      args[i] = g:expr("any", d)
    end
    return call_src("funcall", args)
  end
  return call_src(
    "funcall",
    { g:pick({ "nil", "1", "#'quote", "'(lambda)", '"f"' }), g:expr("any", d) }
  )
end)
custom("error", "any", function(g, d)
  return g:format_call("error", d)
end)
custom("user-error", "any", function(g, d)
  return g:format_call("user-error", d)
end)
custom("signal", "any", function(g, d)
  local sym = g:pick({
    "'error",
    "'wrong-type-argument",
    "'args-out-of-range",
    "'arith-error",
    "'overflow-error",
    "'void-variable",
    "'user-error",
    "'end-of-file",
    "'foo",
    "nil",
    "'wrong-number-of-arguments",
    "'invalid-read-syntax",
  })
  local data =
    g:pick({ "nil", g:lit("list"), g:expr("any", d), "(list " .. g:expr("any", d) .. ")" })
  return call_src("signal", { sym, data })
end)

custom("format-time-string", "str", function(g)
  local args = { g:lit("tfmt"), g:lit("time") }
  if g:chance(0.6) then
    args[3] = g:lit("zone")
  end
  return call_src("format-time-string", args)
end)
custom("decode-time", "list", function(g)
  local args = { g:lit("time") }
  local n = g:int(0, 2)
  if n >= 1 then
    args[2] = g:lit("zone")
  end
  if n >= 2 then
    args[3] = g:pick({ "nil", "t", "'integer", "1000" })
  end
  return call_src("decode-time", args)
end)
local function decoded(g)
  local r = g:int(1, 10)
  local function sec()
    return g:pick({ g:small(0, 60), g:small(-100, 100), "1.5", "'(3 . 2)", "'(1500 . 1000)" })
  end
  if r <= 3 then
    return "(decode-time " .. g:lit("time") .. " " .. g:lit("zone") .. ")"
  end
  return string.format(
    "'(%s %s %s %s %s %s %s %s %s)",
    sec(),
    g:pick({ g:small(0, 59), g:small(-100, 200) }),
    g:pick({ g:small(0, 23), g:small(-30, 50) }),
    g:day(),
    g:month(),
    g:year(),
    g:pick({ "nil", "0", "3" }),
    g:pick({ "nil", "t", "-1" }),
    (g:lit("zone"):gsub("^'", ""))
  )
end
custom("encode-time", "time", function(g)
  if g:chance(0.7) then
    return call_src("encode-time", { decoded(g) })
  end
  local args = { g:small(0, 59), g:small(0, 59), g:small(0, 23), g:day(), g:month(), g:year() }
  if g:chance(0.5) then
    args[7] = g:lit("zone")
  end
  return call_src("encode-time", args)
end)
local function time_pair(g, d)
  if g:chance(0.2) then
    local t = g:lit("time")
    return { t, t }
  end
  return { g:expr("time", d), g:expr("time", d) }
end
for _, n in ipairs({ "time-add", "time-subtract" }) do
  custom(n, "time", function(g, d)
    return call_src(n, time_pair(g, d))
  end)
end
for _, n in ipairs({ "time-less-p", "time-equal-p" }) do
  custom(n, "bool", function(g, d)
    return call_src(n, time_pair(g, d))
  end)
end
custom("float-time", "flt", function(g, d)
  return call_src("float-time", { g:expr("time", d) })
end)
custom("current-time", "any", function(g)
  return g:pick({
    "(length (current-time))",
    "(integerp (car (current-time)))",
    "(floatp (float-time))",
    "(consp (current-time))",
  })
end)
custom("org-time-string-to-time", "time", function(g)
  return call_src("org-time-string-to-time", { g:lit("orgts") })
end)
custom("org-time-stamp-format", "str", function(g)
  local args = {}
  for i = 1, g:int(0, 3) do
    args[i] = (i == 3 and g:chance(0.7)) and "nil" or g:lit("bool")
  end
  return call_src("org-time-stamp-format", args)
end)

for _, n in ipairs({
  "calendar-day-of-week",
  "calendar-absolute-from-gregorian",
  "calendar-extract-month",
  "calendar-extract-day",
  "calendar-extract-year",
  "calendar-day-number",
}) do
  fn(n, "int", { "date" })
end
fn("calendar-date-is-valid-p", "bool", { "date" })
fn("calendar-gregorian-from-absolute", "date", { "absint" })
fn("calendar-leap-year-p", "bool", { "year" })
fn("calendar-last-day-of-month", "int", { "month", "year" })

for _, n in ipairs({ "org-lookup-first", "org-lookup-last", "org-lookup-all" }) do
  custom(n, "any", function(g, d)
    local ek = g:pick({ "int", "str", "any" })
    local s = g:seq(ek, d, "list")
    local args = { g:expr(ek, d), s, g:lit("list") }
    if g:chance(0.3) then
      args[4] = g:fn2(ek, d)
    end
    return call_src(n, args)
  end)
end

-- Diary functions: date triples in each one's argument order, literal
-- numbers most of the time.
local function component(g, kind, d)
  if d > 0 and g:chance(0.1) then
    return g:expr("int", d - 1)
  end
  if kind == "month" then
    return g:pick({ g:month(), g:month(), g:month(), "t", "'(1 2 3)", "t" })
  elseif kind == "day" then
    return g:pick({ g:day(), g:day(), g:day(), "t" })
  elseif kind == "year" then
    return g:pick({ g:year(), g:year(), "t" })
  end
  return g:small(-5, 5)
end

local function triple(g, order, d, wild)
  local out = {}
  for i, k in ipairs(order) do
    local v = component(g, k, d)
    if not wild and v:find("[t']") then
      v = k == "month" and g:month() or k == "day" and g:day() or g:year()
    end
    out[i] = v
  end
  if g:chance(0.15) then
    out[1], out[3] = out[3], out[1]
  end
  return out
end

local MDY = { "month", "day", "year" }
local YMD = { "year", "month", "day" }

local DIARY = {
  ["diary-date"] = function(g, d)
    return triple(g, MDY, d, true)
  end,
  ["diary-block"] = function(g, d)
    return vim.list_extend(triple(g, MDY, d), triple(g, MDY, d))
  end,
  ["diary-cyclic"] = function(g, d)
    local args = { g:pick({ g:small(1, 30), "0", "-7", "365" }) }
    return vim.list_extend(args, triple(g, MDY, d))
  end,
  ["diary-anniversary"] = function(g, d)
    local t = triple(g, MDY, d)
    if g:chance(0.2) then
      t[3] = nil
    end
    return t
  end,
  ["diary-float"] = function(g)
    local args = {
      g:pick({ g:month(), "t", "'(1 6)" }),
      g:lit("dayname"),
      g:pick({ g:small(1, 5), g:small(-5, -1), "0" }),
    }
    if g:chance(0.3) then
      args[4] = g:day()
    end
    return args
  end,
  ["org-date"] = function(g, d)
    return triple(g, YMD, d)
  end,
  ["org-block"] = function(g, d)
    return vim.list_extend(triple(g, YMD, d), triple(g, YMD, d))
  end,
  ["org-cyclic"] = function(g, d)
    local args = { g:pick({ g:small(1, 30), "0" }) }
    return vim.list_extend(args, triple(g, YMD, d))
  end,
  ["org-anniversary"] = function(g, d)
    return triple(g, YMD, d)
  end,
  ["org-class"] = function(g, d)
    local args = vim.list_extend(triple(g, YMD, d), triple(g, YMD, d))
    args[7] = g:lit("dayname")
    if g.date_ok and g:chance(0.4) then
      for i = 8, 7 + g:int(1, 3) do
        args[i] = g:pick({ g:small(1, 53), "'holidays", '"Christmas"', g:small(1, 53) })
      end
    end
    return args
  end,
}

local DIARY_NAMES = vim.tbl_keys(DIARY)
table.sort(DIARY_NAMES)
for _, name in ipairs(DIARY_NAMES) do
  local args_of = DIARY[name]
  local prefix = name:sub(1, 4) == "org-"
  local entry = {
    name = name,
    ret = "any",
    diary = true,
    prefix = prefix,
    gen = function(g, d)
      local args = args_of(g, d)
      if name ~= "org-class" and g:chance(0.1) then
        args[#args + 1] = g:pick({ "nil", "'mark", '"face"' })
      end
      return call_src(name, args)
    end,
  }
  FUNCTIONS[#FUNCTIONS + 1] = entry
end

local GENERATED = {}
for _, e in ipairs(FUNCTIONS) do
  GENERATED[e.name] = true
end

local function returns(ret, want)
  if ret == want or want == "any" then
    return true
  end
  if want == "num" then
    return ret == "int" or ret == "flt" or ret == "chr"
  elseif want == "int" then
    return ret == "chr"
  elseif want == "seq" then
    return ret == "list" or ret == "vec" or ret == "str" or ret == "strlist" or ret == "intlist"
  elseif want == "list" then
    return ret == "strlist" or ret == "intlist"
  elseif want == "strish" or want == "strsym" or want == "strchr" then
    return ret == "str"
  end
  return false
end

function G:candidates(kind)
  local c = {}
  for _, e in ipairs(FUNCTIONS) do
    if
      returns(e.ret, kind)
      and (not e.diary or self.profile == "diary" or (e.prefix and self.profile == "prefix"))
      and (not e.hof or self.mult < 64)
    then
      c[#c + 1] = e
    end
  end
  return c
end

function G:restn()
  if self:chance(0.9) then
    return self:int(0, 3)
  end
  return self:int(4, 6)
end

local ALIAS = {
  strish = { "str", "str", "str", "list", "vec" },
  strsym = { "str", "str", "str", "sym" },
  strchr = { "str", "str", "chr" },
}

LITERAL.ellipsis = function(g)
  return g:pick({ "nil", '"..."', '"…"', '""', "t" })
end

function G:arg(k, d)
  local alias = ALIAS[k]
  if alias then
    k = self:pick(alias)
  end
  if not OWN[k] and self:chance(0.04) then
    k = "any"
  end
  return self:expr(k, d)
end

function G:call(kind, d)
  local cands = self:candidates(kind)
  if #cands == 0 then
    return nil
  end
  local e = self:pick(cands)
  if e.gen then
    return e.gen(self, d - 1)
  end
  local args = {}
  for _, k in ipairs(e.args) do
    args[#args + 1] = self:arg(k, d - 1)
  end
  if e.opt then
    for i = 1, self:int(0, #e.opt) do
      args[#args + 1] = self:arg(e.opt[i], d - 1)
    end
  end
  if e.rest then
    for _ = 1, self:restn() do
      args[#args + 1] = self:arg(e.rest, d - 1)
    end
  end
  if self:chance(0.02) then
    if not e.rest and #args == #e.args + (e.opt and #e.opt or 0) then
      args[#args + 1] = "nil"
    elseif #args > 0 then
      args[#args] = nil
    end
  end
  return call_src(e.name, args)
end

local LET_KINDS =
  { "int", "num", "str", "list", "any", "flt", "vec", "chr", "intlist", "strlist", "time" }
-- stylua: ignore
local HANDLERS = {
  "error", "arith-error", "wrong-type-argument", "args-out-of-range",
  "(wrong-type-argument args-out-of-range)", "overflow-error", "t", "(arith-error)",
  "wrong-number-of-arguments", "void-variable",
}

function G:special(kind, d)
  local r = self:int(1, 17)
  local loose = kind == "any" or kind == "bool" or kind == "list"
  if r <= 3 then
    local star = r == 3
    local n = self:int(1, 3)
    local binds, names = {}, {}
    for i = 1, n do
      local k = self:pick(LET_KINDS)
      local init = self:expr(k, d - 1)
      names[i] = { self:fresh(), k }
      binds[i] = "(" .. names[i][1] .. " " .. init .. ")"
      if star then
        self:push(names[i][1], k)
      end
    end
    if not star then
      for i = 1, n do
        self:push(names[i][1], names[i][2])
      end
    end
    local body = self:expr(kind, d - 1)
    if self:chance(0.2) then
      local v = names[self:int(1, n)]
      body = "(progn (setq " .. v[1] .. " " .. self:expr(v[2], d - 1) .. ") " .. body .. ")"
    end
    self:pop(n)
    return "("
      .. (star and "let*" or "let")
      .. " ("
      .. table.concat(binds, " ")
      .. ") "
      .. body
      .. ")"
  elseif r == 4 then
    return "(if "
      .. self:expr("bool", d - 1)
      .. " "
      .. self:expr(kind, d - 1)
      .. " "
      .. self:expr(kind, d - 1)
      .. ")"
  elseif r == 5 then
    return "(cond ("
      .. self:expr("bool", d - 1)
      .. " "
      .. self:expr(kind, d - 1)
      .. ") (t "
      .. self:expr(kind, d - 1)
      .. "))"
  elseif r == 6 then
    local which = self:pick({ "progn", "prog1", "prog2" })
    local a, b = self:expr("any", d - 1), self:expr(kind, d - 1)
    if which == "prog1" then
      return "(prog1 " .. b .. " " .. a .. ")"
    elseif which == "prog2" then
      return "(prog2 " .. a .. " " .. b .. " " .. self:expr("any", d - 1) .. ")"
    end
    return "(progn " .. a .. " " .. b .. ")"
  elseif r == 7 and loose then
    local which = self:pick({ "and", "or", "when", "unless" })
    return "(" .. which .. " " .. self:expr("bool", d - 1) .. " " .. self:expr(kind, d - 1) .. ")"
  elseif r == 8 and (kind == "any" or kind == "list") and self.mult < 64 then
    local ek = self:pick({ "int", "str", "any" })
    local seq, n = self:seq(ek, d - 1, "list")
    local acc, e = self:fresh(), self:fresh()
    return self:with_work(n, function()
      self:push(e, ek)
      local body = self:expr("any", d - 1)
      self:pop()
      return string.format(
        "(let ((%s nil)) (dolist (%s %s %s) (setq %s (cons %s %s))))",
        acc,
        e,
        seq,
        acc,
        acc,
        body,
        acc
      )
    end)
  elseif r == 9 and (kind == "any" or kind == "num" or kind == "int") and self.mult < 64 then
    local n = self:int(0, 8)
    local acc, i = self:fresh(), self:fresh()
    return self:with_work(n, function()
      self:push(i, "int")
      local body = self:expr("int", d - 1)
      self:pop()
      return string.format(
        "(let ((%s 0)) (dotimes (%s %d %s) (setq %s (+ %s %s))))",
        acc,
        i,
        n,
        acc,
        acc,
        acc,
        body
      )
    end)
  elseif r == 10 and kind == "any" then
    local v = self:fresh()
    local h = self:pick(HANDLERS)
    local body = self:expr("any", d - 1)
    local handler =
      self:pick({ "(list 'caught (car " .. v .. "))", v, "'handled", "(cdr " .. v .. ")" })
    local src = "(condition-case " .. v .. " " .. body .. " (" .. h .. " " .. handler .. ")"
    if self:chance(0.2) then
      src = src .. " (:success (list 'ok " .. v .. "))"
    end
    return src .. ")"
  elseif r == 11 and kind == "any" then
    return "(ignore-errors " .. self:expr("any", d - 1) .. ")"
  elseif r == 12 then
    local ek = self:pick({ "int", "str", "any" })
    local arg = self:expr(ek, d - 1)
    return "(funcall " .. self:lambda(1, kind, ek, d - 1) .. " " .. arg .. ")"
  elseif r == 13 and (kind == "any" or kind == "list") then
    return "`(a ," .. self:expr("any", d - 1) .. " ,@" .. self:expr("list", d - 1) .. " b)"
  elseif r == 14 then
    return "(let ((case-fold-search "
      .. self:pick({ "t", "nil" })
      .. ")) "
      .. self:expr(kind, d - 1)
      .. ")"
  elseif r == 15 and self.profile == "diary" then
    return "(let ((calendar-date-style '"
      .. self:pick({ "iso", "european", "american" })
      .. ")) "
      .. self:expr(kind, d - 1)
      .. ")"
  elseif r == 16 and (kind == "any" or kind == "list") then
    local n = self:int(0, 8)
    local i, acc = self:fresh(), self:fresh()
    return string.format(
      "(let ((%s 0) (%s nil)) (while (< %s %d) (setq %s (cons %s %s) %s (1+ %s))) %s)",
      i,
      acc,
      i,
      n,
      acc,
      i,
      acc,
      i,
      i,
      acc
    )
  elseif r == 17 then
    local v = {}
    for _, s in ipairs(self.scope) do
      if not s.fixed and in_scope_value(s.kind, kind) then
        v[#v + 1] = s
      end
    end
    if #v > 0 then
      local s = self:pick(v)
      return "(setq " .. s.name .. " " .. self:expr(s.kind, d - 1) .. ")"
    end
  end
  return nil
end

function G:leaf(kind)
  if self:chance(0.15) then
    local v = self:var_of(kind)
    if v then
      return v
    end
  end
  if kind == "bool" and self:chance(0.05) then
    return "case-fold-search"
  end
  if (kind == "flt" or kind == "num") and self:chance(0.03) then
    return self:pick({ "pi", "float-pi", "float-e" })
  end
  return self:lit(kind)
end

function G:expr(kind, d)
  if d <= 0 or self:chance(0.3) or OWN[kind] and kind ~= "time" and kind ~= "date" then
    return self:leaf(kind)
  end
  local r = self:int(1, 100)
  if r <= 10 then
    local v = self:var_of(kind)
    if v then
      return v
    end
  end
  if r <= 30 then
    local s = self:special(kind, d)
    if s then
      return s
    end
  end
  return self:call(kind, d) or self:leaf(kind)
end

-- A diary call naming the case's date (or a range around it) year
-- first, as XT-10 reads it.
function G:year_first_call()
  local m, d, y = unpack(self.today)
  local function ymd(dy)
    return string.format("%d %d %d", y + dy, m, d)
  end
  local r = self:int(1, 4)
  if r == 1 then
    return "(diary-date " .. ymd(0) .. ")"
  elseif r == 2 then
    return "(diary-anniversary " .. ymd(-self:int(0, 30)) .. ")"
  elseif r == 3 then
    return "(diary-cyclic " .. self:pick({ "1", "7", "365" }) .. " " .. ymd(-self:int(0, 3)) .. ")"
  end
  return "(diary-block " .. ymd(-self:int(0, 2)) .. " " .. ymd(self:int(0, 2)) .. ")"
end

local CYCLES = {
  "(let ((%s %s)) (nconc %s %s))",
  "(let ((%s %s)) (nconc (list 0) %s %s))",
  "(let ((%s %s)) (nconc %s (list %s)))",
}

function G:form()
  self.bigs = MAX_BIGNUMS
  self.mult = 1
  self.maxlen = MAX_LEN
  self.nvars = 0
  if self:chance(0.01) then
    local v = self:fresh()
    local items = {}
    for k = 1, self:int(1, 4) do
      items[k] = self:lit("int")
    end
    return string.format(self:pick(CYCLES), v, call_src("list", items), v, v)
  end
  if self.profile == "diary" and self.today and self:chance(0.1) then
    return self:year_first_call()
  end
  if self.profile == "diary" and self:chance(0.25) then
    local name = self:pick({
      "diary-date",
      "diary-anniversary",
      "diary-cyclic",
      "diary-block",
      self:pick(DIARY_NAMES),
    })
    for _, e in ipairs(FUNCTIONS) do
      if e.name == name then
        return e.gen(self, 0)
      end
    end
  end
  return self:expr("any", MAX_DEPTH)
end

-- Case headers: `date' and `entry' for the diary and prefix profiles.
local ENTRIES =
  { "Meeting", "Birthday %d", "%d%s anniversary", "100%", "x %s y", "", "Ünïcode", "%%" }

local function header_of(g)
  local h = { profile = g.profile, mode = "eval", case_fold = g:pick({ "t", "nil" }) }
  g.scope = {}
  g.date_ok = false
  g.today = nil
  if g.profile == "diary" or g.profile == "prefix" then
    if g:chance(0.8) then
      local y, m = g:int(1, 9999), g:int(1, 12)
      local last = ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
      if m == 2 and (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) then
        last = 29
      end
      local d = g:int(1, last)
      h.date = string.format("(%d %d %d)", m, d, y)
      g.today = { m, d, y }
      g.date_ok = true
    else
      h.date = g:pick({
        "(2 29 2023)",
        "(1 1 1000000)",
        "(13 1 2024)",
        "(1 1 0)",
        "(1 1 -5)",
        "(1.5 1 2024)",
        "(1 32 2024)",
        "(1 1 2024.0)",
        "(3 10 100000000000000000000)",
      })
    end
    h.entry = g:pick(ENTRIES)
    g:push("date", "date", true)
    g:push("entry", "str", true)
  end
  return h
end

-- XT-10: a top-level diary call of these with literal number arguments
-- (and t for diary-date) reads a triple year-first when its first value
-- is above 31, or t while its last is neither t nor above 31.
local XT10 = {
  ["diary-date"] = { n = 3, triples = { 1 }, t_ok = true },
  ["diary-anniversary"] = { n = 3, triples = { 1 } },
  ["diary-cyclic"] = { n = 4, triples = { 2 } },
  ["diary-block"] = { n = 6, triples = { 1, 4 } },
}

local function literal_number(tok)
  local s = tok:match("^[+-]?%d+%.?$") and tok
  if s then
    return tonumber((s:gsub("%.$", ""))) or 0, s
  end
  if
    tok:match("^[+-]?%d*%.?%d+e[+-]?%d+$")
    or tok:match("^[+-]?%d*%.%d+$")
    or tok:match("^[+-]?%d+%.?%d*e[+-]?%d+$")
  then
    return tonumber(tok), tok
  end
  local sign, kind = tok:match("^([+-]?)%d*%.?%d*e%+(%a+)$")
  if kind == "INF" then
    return sign == "-" and -math.huge or math.huge, tok
  elseif kind == "NaN" then
    return 0 / 0, tok
  end
  return nil
end

-- The year-first form of top-level diary form `src', or nil when XT-10
-- leaves it alone.
local function xt10_form(src)
  local name, rest = src:match("^%((diary%-[%a]+) (.*)%)$")
  local rule = name and XT10[name]
  if not rule or rest:find("[()'\"%[]") then
    return nil
  end
  local toks, vals = {}, {}
  for tok in rest:gmatch("%S+") do
    local v = literal_number(tok)
    if v == nil and not (rule.t_ok and tok == "t") then
      return nil
    end
    toks[#toks + 1] = tok
    vals[#vals + 1] = v == nil and "t" or v
  end
  if #toks ~= rule.n then
    return nil
  end
  local function above31(v)
    return type(v) == "number" and v > 31
  end
  local changed = false
  for _, i in ipairs(rule.triples) do
    local a, c = vals[i], vals[i + 2]
    local year_last = c == "t" or above31(c)
    if above31(a) or (a == "t" and not year_last) then
      toks[i], toks[i + 1], toks[i + 2] = toks[i + 1], toks[i + 2], toks[i]
      vals[i], vals[i + 1], vals[i + 2] = vals[i + 1], vals[i + 2], vals[i]
      changed = true
    end
  end
  return changed and ("(" .. name .. " " .. table.concat(toks, " ") .. ")") or nil
end

-- Classifier: a refusal passes when its code's precondition holds on
-- organ's trace.

local function walk(roots, visit)
  local seen, stack, n, count = {}, {}, 0, 0
  for i = #roots, 1, -1 do
    n = n + 1
    stack[n] = roots[i]
  end
  while n > 0 do
    local v = stack[n]
    stack[n] = nil
    n = n - 1
    if type(v) == "number" then
      if visit(v) then
        return true
      end
    elseif type(v) == "table" and not seen[v] then
      seen[v] = true
      count = count + 1
      if count > 100000 then
        return false
      end
      if visit(v) then
        return true
      end
      if v.k == "cons" then
        n = n + 1
        stack[n] = v.cdr
        n = n + 1
        stack[n] = v.car
      elseif v.k == "vec" then
        for i = v.n, 1, -1 do
          n = n + 1
          stack[n] = v[i]
        end
      end
    end
  end
  return false
end

local function args_of(frame)
  local t = {}
  for i = 1, frame.argv.n do
    t[i] = frame.argv[i]
  end
  return t
end

local function text_of(v)
  if type(v) ~= "table" then
    return nil
  elseif v.k == "str" then
    return v.s
  elseif v.k == "sym" then
    return v.name.s
  end
  return nil
end

local function any_char(roots, pred, ints)
  return walk(roots, function(v)
    if type(v) == "number" then
      return ints and v >= 0 and v <= 0x3FFFFF and pred(v)
    end
    local s = text_of(v)
    if s then
      for _, c in ipairs(codes(s)) do
        if pred(c) then
          return true
        end
      end
    end
    return false
  end)
end

local function varying_width(c)
  return c == 9 or (c < 32 and c ~= 10) or c == 127 or chars.cjk(c) or chars.composes(c)
end

local function is_nan(v)
  return type(v) == "table" and v.k == "flt" and v.x ~= v.x
end

local function is_num(v)
  return type(v) == "number" or (type(v) == "table" and (v.k == "flt" or v.k == "big"))
end

local REGEXP_ARGS = {
  ["split-string"] = { 2, 4 },
  ["string-trim"] = { 2, 3 },
  ["string-trim-left"] = { 2 },
  ["string-trim-right"] = { 2 },
}

-- Directives of `format' string `s': { conv, arg, width, prec, flags }.
local function directives(s)
  local out, i, n = {}, 1, 0
  while i <= #s do
    if s:byte(i) ~= 37 then
      i = i + 1
    else
      local f = i + 1
      local pos = s:match("^(%d+)%$", f)
      if pos then
        n = tonumber(pos) - 1
        f = f + #pos + 1
      end
      local flags = s:match("^[-+ #0]*", f)
      f = f + #flags
      local w = s:match("^%d*", f)
      f = f + #w
      local prec
      if s:sub(f, f) == "." then
        local p = s:match("^%d*", f + 1)
        prec = tonumber(p) or 0
        f = f + 1 + #p
      end
      local conv = s:sub(f, f)
      if conv == "" then
        break
      end
      if conv ~= "%" then
        n = n + 1
        out[#out + 1] =
          { conv = conv, arg = n, width = tonumber(w) or 0, prec = prec, flags = flags }
      end
      i = f + 1
    end
  end
  return out
end

local NUMERIC = {
  d = true,
  o = true,
  x = true,
  X = true,
  c = true,
  e = true,
  f = true,
  g = true,
  b = true,
  B = true,
  i = true,
}

local function format_frame(frames)
  for i = #frames, 1, -1 do
    local f = frames[i]
    if f.name == "format" or f.name == "error" or f.name == "user-error" then
      return f
    end
  end
end

-- Whether integer `v' lies in [-2^63, 2^64) and is not a double.
local function long_double_only(v)
  local s = V.int_to_string(v)
  local digits = s:gsub("^%-", "")
  local bound = s:sub(1, 1) == "-" and "9223372036854775808" or "18446744073709551615"
  if #digits > #bound or (#digits == #bound and digits > bound) then
    return false
  end
  return string.format("%.0f", tonumber(s)) ~= s
end

local function format_precision(f)
  local fmt = text_of(f.argv[1])
  if not fmt then
    return false
  end
  for _, dir in ipairs(directives(fmt)) do
    local a = f.argv[dir.arg + 1]
    if dir.prec and dir.prec > 99 then
      return true
    end
    if
      (dir.conv == "e" or dir.conv == "f" or dir.conv == "g")
      and type(a) == "table"
      and a.k == "big"
      and long_double_only(a)
    then
      return true
    end
    if (dir.conv == "b" or dir.conv == "B") and dir.prec then
      local neg = (type(a) == "number" and a < 0)
        or (
          type(a) == "table" and ((a.k == "flt" and a.x <= -1) or (a.k == "big" and a.n.sign < 0))
        )
      if neg then
        return true
      end
    end
    if dir.conv == "c" and dir.prec == 0 and dir.width > 0 and (a == 45 or a == 43 or a == 32) then
      return true
    end
  end
  return false
end

local function format_mismatch(f)
  local fmt = text_of(f.argv[1])
  if not fmt then
    return false
  end
  for _, dir in ipairs(directives(fmt)) do
    local a = f.argv[dir.arg + 1]
    if NUMERIC[dir.conv] and a ~= nil and not is_num(a) then
      return true
    end
    if dir.conv == "c" and type(a) == "table" then
      return true
    end
  end
  return false
end

local TIME_FNS = {
  ["format-time-string"] = 3,
  ["decode-time"] = 2,
  ["encode-time"] = 0,
  ["time-add"] = 0,
  ["time-subtract"] = 0,
  ["time-less-p"] = 0,
  ["time-equal-p"] = 0,
  ["float-time"] = 0,
  ["org-time-string-to-time"] = 0,
}

local function time_frame(frames)
  for i = #frames, 1, -1 do
    if TIME_FNS[frames[i].name] then
      return frames[i]
    end
  end
end

local Q_WALL = V.intern("wall")

local function has_zone_setting(f)
  return walk(args_of(f), function(v)
    return v == Q_WALL or (type(v) == "table" and v.k == "str")
  end)
end

local function has_huge(f)
  return walk(args_of(f), function(v)
    if type(v) == "number" then
      return math.abs(v) >= 2 ^ 30
    end
    return type(v) == "table" and (v.k == "big" or (v.k == "flt" and math.abs(v.x) >= 2 ^ 30))
  end)
end

local LOCALE_TIME = {}
for _, c in ipairs({ "a", "A", "b", "B", "h", "c", "x", "X", "p", "P", "r" }) do
  LOCALE_TIME[c] = true
end

-- Whether time format `fmt' has a directive with conversion `conv'
-- (after flags, width and an E or O modifier).
local function has_time_directive(fmt, test)
  local i = 1
  while i <= #fmt do
    local s, e, mod, conv = fmt:find("^%%[-_0^#+]*%d*([EO]?)(:*%a?)", i)
    if s then
      if test(conv, mod) then
        return true
      end
      i = e + 1
    else
      i = i + 1
    end
  end
  return false
end

local function nth_of(x, i)
  for _ = 1, i do
    x = type(x) == "table" and x.k == "cons" and x.cdr or nil
  end
  return type(x) == "table" and x.k == "cons" and x.car or nil
end

local function locale_ok(r, frames)
  local d = r.detail or ""
  local f = frames[#frames]
  if not f then
    return false
  end
  if d == "format-message" then
    local ff = format_frame(frames)
    local fmt = ff and text_of(ff.argv[1])
    return fmt ~= nil and fmt:find("[`']") ~= nil and ff.name ~= "format"
  elseif d == "Format specifier doesn't match argument type" then
    local ff = format_frame(frames)
    return ff ~= nil and format_mismatch(ff)
  elseif d == "truncate-string-ellipsis" then
    local e = f.name == "truncate-string-to-width" and f.argv[5]
    return e and e ~= V.NIL and not (type(e) == "table" and e.k == "str")
  end
  local tf = time_frame(frames)
  if not tf then
    return false
  end
  local fmt = tf.name == "format-time-string" and text_of(tf.argv[1])
  local c = d:match("^format%-time%-string %%(%a+)$")
  if c then
    return fmt
      and has_time_directive(fmt, function(conv, mod)
        return conv == c:sub(-1) and (LOCALE_TIME[conv] or mod ~= "")
      end)
  elseif d == "format-time-string %Z of UTC" then
    return fmt and has_time_directive(fmt, function(conv)
      return conv == "Z"
    end)
  elseif d == "format-time-string of non-ASCII text" then
    return fmt and fmt:find("[\128-\255]") ~= nil
  elseif d:match("^zone offset ") then
    return walk(args_of(tf), function(v)
      return (type(v) == "number" and math.abs(v) >= 90000) or (type(v) == "table" and v.k == "big")
    end)
  elseif d:match("^zone name") then
    return walk(args_of(tf), function(v)
      if
        type(v) == "table"
        and v.k == "cons"
        and type(v.car) == "number"
        and type(v.cdr) == "table"
        and v.cdr.k == "cons"
      then
        local name = v.cdr.car
        if type(name) ~= "table" or name.k ~= "str" then
          return true
        end
        local s = name.s
        return #s < 3 or #s > 64 or s:find("[^%w+%-]") ~= nil
      end
      return false
    end)
  elseif d == "time near the end of the time range" then
    return has_huge(tf)
  elseif d == "DST flag the zone does not use nearby" then
    local fields = tf.name == "encode-time" and tf.argv[1]
    local dst = type(fields) == "table" and fields.k == "cons" and nth_of(fields, 7)
    return dst == V.T or (dst ~= nil and dst ~= -1 and has_zone_setting(tf))
  end
  return has_zone_setting(tf)
end

local function content_key(v, depth)
  if type(v) ~= "table" then
    return "n" .. tostring(v)
  elseif v.k == "str" then
    return "s" .. v.s
  elseif v.k == "flt" then
    if v.x ~= v.x then
      return "fnan"
    end
    return "f" .. string.format("%.17g", v.x) .. ((v.x == 0 and 1 / v.x < 0) and "-" or "")
  elseif v.k == "big" then
    return "b" .. V.int_to_string(v)
  elseif v.k == "vec" and depth < 20 then
    local t = {}
    for i = 1, v.n do
      t[i] = content_key(v[i], depth + 1)
    end
    return "v[" .. table.concat(t, ",") .. "]"
  elseif v.k == "cons" and depth < 20 then
    return "c(" .. content_key(v.car, depth + 1) .. "." .. content_key(v.cdr, depth + 1) .. ")"
  elseif v.k == "sym" and not v.uninterned then
    return "y" .. v.name.s
  end
  return "o" .. tostring(v)
end

local function same_contents(f, conses)
  local by_key = {}
  return walk(args_of(f), function(v)
    if type(v) ~= "table" then
      return false
    end
    local k = v.k
    if k == "str" or k == "flt" or k == "big" or k == "vec" or (conses and k == "cons") then
      local key = content_key(v, 0)
      if key then
        local other = by_key[key]
        if other and other ~= v then
          return true
        end
        by_key[key] = v
      end
    end
    return false
  end)
end

local CASE_SPECIAL = { downcase = true, capitalize = true, ["upcase-initials"] = true }
local ISO_WRAPPERS =
  { ["org-date"] = true, ["org-block"] = true, ["org-cyclic"] = true, ["org-anniversary"] = true }

local function valid_date(v)
  local function nth(x, i)
    for _ = 1, i do
      x = type(x) == "table" and x.k == "cons" and x.cdr or nil
    end
    return type(x) == "table" and x.k == "cons" and x.car or nil
  end
  local m, d, y = nth(v, 0), nth(v, 1), nth(v, 2)
  if type(m) ~= "number" or type(d) ~= "number" or type(y) ~= "number" then
    return false
  end
  if m < 1 or m > 12 or y < 1 or y > 9999 or d < 1 then
    return false
  end
  local last = ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
  if m == 2 and y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then
    last = 29
  end
  return d <= last
end

local RECHECK = {}

RECHECK.nan = function(_, frames, value)
  local f = frames[#frames]
  return (f and f.nan) or walk(f and args_of(f) or { value }, is_nan)
end
local function has_props(roots)
  return walk(roots, function(v)
    return type(v) == "table" and v.k == "str" and v.props == true
  end)
end

RECHECK.width = function(_, frames)
  local f = frames[#frames]
  return f ~= nil and (any_char(args_of(f), varying_width, true) or has_props(args_of(f)))
end
RECHECK.regexp = function(_, frames)
  local f = frames[#frames]
  local which = f and REGEXP_ARGS[f.name]
  if not which then
    return false
  end
  for _, i in ipairs(which) do
    local s = text_of(f.argv[i] or V.NIL)
    if s and f.argv[i].k == "str" then
      if s:find("[%[%]%.%*%+%?%^%$\\]") then
        return true
      end
      for _, c in ipairs(codes(s)) do
        if f.fold and c >= 128 and chars.cased(c) then
          return true
        end
      end
    end
  end
  return false
end
RECHECK["case-special"] = function(_, frames)
  local f = frames[#frames]
  return f ~= nil
    and CASE_SPECIAL[f.name]
    and any_char({ f.argv[1] }, function(c)
      return c == 0x3A3
    end)
end
RECHECK.locale = function(r, frames)
  return locale_ok(r, frames)
end
RECHECK["eq-identity"] = function(_, frames)
  local f = frames[#frames]
  return f ~= nil and same_contents(f, TIME_FNS[f.name] ~= nil)
end
RECHECK.cycle = function(_, frames)
  local f = frames[#frames]
  local p = f and f.pre
  if type(p) == "function" then
    p = p()
  end
  return p == true
end
RECHECK.holidays = function(_, frames, _, g)
  local f = frames[#frames]
  if not f or f.name ~= "org-class" or f.argv.n < 8 then
    return false
  end
  for i = 8, f.argv.n do
    local s = f.argv[i]
    if s == V.intern("holidays") or text_of(s) and s.k == "str" then
      return true
    end
  end
  return not valid_date(g.date_value)
end
RECHECK.profile = function(_, frames, _, g)
  local f = frames[#frames]
  return g.profile == "prefix"
    and f ~= nil
    and (ISO_WRAPPERS[f.name] or (f.name == "org-class" and f.argv.n >= 8))
end
RECHECK.precision = function(_, frames)
  local ff = format_frame(frames)
  return ff ~= nil and format_precision(ff)
end
RECHECK.unprintable = function(_, frames, value)
  local f = frames[#frames]
  return walk(f and args_of(f) or { value }, function(v)
    return type(v) == "table" and (v.k == "fn" or (v.k == "str" and v.props == true))
  end)
end
RECHECK.charset = function(_, frames)
  local f = frames[#frames]
  return f ~= nil
    and walk(args_of(f), function(v)
      return type(v) == "number" and (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF))
    end)
end
RECHECK["function"] = function(r, frames)
  local f = frames[#frames]
  local name = r.detail
  return f ~= nil
    and name ~= nil
    and not B.SUBSET[name]
    and walk(args_of(f), function(v)
      return v == V.intern(name)
    end)
end
RECHECK["free-variable"] = function(r, frames)
  local f = frames[#frames]
  return r.detail == "org-timestamp-custom-formats"
    and f ~= nil
    and f.name == "org-time-stamp-format"
    and (f.argv[3] or V.NIL) ~= V.NIL
end

-- Entry checks for `cycle': the state a refusal's precondition is
-- about, before the builtin changes it.
local function shares(argv)
  local owner = {}
  for i = 1, argv.n do
    local hit = walk({ argv[i] }, function(v)
      if type(v) == "table" and (v.k == "cons" or v.k == "vec") then
        if owner[v] and owner[v] ~= i then
          return true
        end
        owner[v] = i
      end
      return false
    end)
    if hit then
      return true
    end
  end
  return false
end

local function list_len(x)
  local n = 0
  while type(x) == "table" and x.k == "cons" do
    n = n + 1
    x = x.cdr
  end
  return n
end

local PRE = {
  nconc = function(argv)
    return shares(argv)
  end,
  mapconcat = function(argv)
    local seq = argv[2]
    local n0 = list_len(seq)
    return function()
      return list_len(seq) < n0
    end
  end,
}

-- Runs

local function write_case(path, header, items)
  local lines = {
    "; profile: " .. header.profile,
    "; mode: eval",
    "; case_fold: " .. header.case_fold,
  }
  if header.date then
    lines[#lines + 1] = "; date: " .. header.date
    lines[#lines + 1] = "; entry: " .. header.entry
  end
  local out = { table.concat(lines, "\n") }
  for _, it in ipairs(items) do
    out[#out + 1] = it.src
  end
  local f = assert(io.open(path, "wb"))
  f:write(table.concat(out, "\n\n") .. "\n")
  f:close()
end

local function read_lines(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  local t = vim.split(text, "\n", { plain = true })
  if t[#t] == "" then
    t[#t] = nil
  end
  return t
end

--- Generate, evaluate and compare the fuzz forms; adds problems for
--- disagreements and returns the summary for the gate line.
function M.run(area, problems)
  local trace = area.trace()
  local missing = {}
  for name in pairs(B.SUBSET) do
    if not GENERATED[name] then
      missing[#missing + 1] = name
    end
  end
  table.sort(missing)
  if #missing > 0 then
    problems[#problems + 1] = "fuzz: builtins the generator never calls: "
      .. table.concat(missing, " ")
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local files, chunks = {}, {}
  for _, seed in ipairs(SEEDS) do
    for pi_, profile in ipairs(PROFILES) do
      local g = setmetatable({ rng = new_rng(seed * 100 + pi_), profile = profile }, G)
      local made = 0
      while made < FORMS do
        local header = header_of(g)
        local items = {}
        for _ = 1, math.min(CHUNK, FORMS - made) do
          local src = g:form()
          items[#items + 1] = { src = src }
          local alt = profile == "diary" and xt10_form(src)
          if alt then
            items[#items + 1] = { src = alt, shadow = true }
          end
          made = made + 1
        end
        local path = string.format("%s/fuzz-%d-%s-%04d.el", dir, seed, profile, made)
        write_case(path, header, items)
        files[#files + 1] = path
        chunks[#chunks + 1] = {
          path = path,
          seed = seed,
          profile = profile,
          header = header,
          items = items,
          gen = g,
        }
      end
    end
  end
  local list = dir .. "/cases.txt"
  vim.fn.writefile(files, list)
  local log = vim.fn.system({
    "env",
    "TZ=UTC",
    "LC_ALL=C",
    "timeout",
    "-k",
    "5",
    "900",
    "emacs",
    "--batch",
    "-Q",
    "-l",
    root .. "/tests/conformance/_collate.el",
    "-l",
    root .. "/tests/conformance/elisp/emacs.el",
    "--eval",
    string.format("(conformance-run %q %q nil)", list, dir),
  })
  if vim.v.shell_error ~= 0 then
    problems[#problems + 1] =
      string.format("fuzz: emacs failed (exit %d): %s", vim.v.shell_error, log:sub(1, 2000))
    vim.fn.delete(dir, "rf")
    return "emacs failed"
  end
  for name, f in pairs(PRE) do
    trace.pre[name] = f
  end
  local stats, total = {}, { forms = 0, agree = 0, xt10 = 0, refused = 0, disagree = 0 }
  local shown = 0
  for _, ch in ipairs(chunks) do
    local key = ch.seed .. " " .. ch.profile
    local st = stats[key]
    if not st then
      st = {
        seed = ch.seed,
        profile = ch.profile,
        forms = 0,
        agree = 0,
        xt10 = 0,
        refused = {},
        disagree = 0,
      }
      stats[key] = st
    end
    local want = read_lines(dir .. "/" .. ch.path:match("[^/]+$") .. ".out")
    local g = ch.gen
    g.profile = ch.profile
    g.date_value = ch.header.date and require("organ.elisp").read(ch.header.date).value
    local wi = 1
    want = want or {}
    for i, it in ipairs(ch.items) do
      if not it.shadow then
        st.forms = st.forms + 1
        trace.refusals = {}
        local line, r = area.eval_line(it.src, area.ctx_of(ch.header))
        local _, raw = line:gsub("\n", "")
        local emacs_line = table.concat(want, "\n", wi, math.min(wi + raw, #want))
        wi = wi + raw + 1
        local alt
        if ch.items[i + 1] and ch.items[i + 1].shadow then
          alt = want[wi]
          wi = wi + 1
        end
        local class
        if line == emacs_line then
          class = "agree"
        else
          if alt == line then
            class = "xt10"
          elseif r.kind == "refused" or line:match("^REFUSED ") then
            local code = line:match("^REFUSED (%S+)")
            local rec
            for k = #trace.refusals, 1, -1 do
              if trace.refusals[k].code == code then
                rec = trace.refusals[k]
                break
              end
            end
            local check = RECHECK[code]
            if rec and check and check(rec, rec.frames, r.value, g) then
              class = "refused"
              st.refused[code] = (st.refused[code] or 0) + 1
            end
          end
        end
        if class == "agree" then
          st.agree = st.agree + 1
        elseif class == "xt10" then
          st.xt10 = st.xt10 + 1
        elseif not class then
          st.disagree = st.disagree + 1
          shown = shown + 1
          if shown <= 20 then
            problems[#problems + 1] = string.format(
              "fuzz seed %d %s (%s): %s\n    emacs: %s\n    organ: %s",
              ch.seed,
              ch.profile,
              ch.path:match("[^/]+$"),
              it.src,
              tostring(emacs_line),
              line
            )
          end
        end
      end
    end
  end
  for name in pairs(PRE) do
    trace.pre[name] = nil
  end
  vim.fn.delete(dir, "rf")
  local keys = vim.tbl_keys(stats)
  table.sort(keys)
  local report = {}
  for _, k in ipairs(keys) do
    local st = stats[k]
    local n = 0
    local codes_ = {}
    for code, c in pairs(st.refused) do
      n = n + c
      codes_[#codes_ + 1] = code .. "=" .. c
    end
    table.sort(codes_)
    total.forms = total.forms + st.forms
    total.agree = total.agree + st.agree
    total.xt10 = total.xt10 + st.xt10
    total.refused = total.refused + n
    total.disagree = total.disagree + st.disagree
    report[#report + 1] = string.format(
      "  seed %d %-7s forms %d agree %d refused %d (%s) xt10 %d disagree %d",
      st.seed,
      st.profile,
      st.forms,
      st.agree,
      n,
      table.concat(codes_, " "),
      st.xt10,
      st.disagree
    )
  end
  if os.getenv("ORGAN_ELISP_FUZZ_STATS") then
    io.write(table.concat(report, "\n") .. "\n")
  end
  if shown > 20 then
    problems[#problems + 1] = string.format("fuzz: %d more disagreements", shown - 20)
  end
  return string.format(
    "%d seeds, %d forms, %d refused, %d XT-10, %d disagreement(s)",
    #SEEDS,
    total.forms,
    total.refused,
    total.xt10,
    total.disagree
  )
end

return M
