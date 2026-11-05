-- Elisp values.
--
-- An integer is a Lua number when |n| <= 2^53 - 1 and a bignum box
-- { k = "big", n = <organ.calc.bn> } beyond.  Every other value is a table
-- tagged by `k`: "sym" { name = <string box> }, "str" { s = <UTF-8>,
-- props = true|nil }, "flt" { x = <number>, nan_neg = true|false|nil },
-- "cons" { car, cdr }, "vec" { n = <count>, [1..n] }, "fn" (see
-- organ.elisp.eval).  A NaN's sign is `nan_neg`, set only where it does
-- not depend on the platform (a NaN read from text, or `abs`); nil means
-- the platform decides it, and `x`'s own sign bit is never consulted.
-- Symbols are interned per name unless `uninterned`; `nil` is the empty
-- list.

local bn = require("organ.calc.bn")
local ffi = require("ffi")

local M = {}

M.LUA_INT_MAX = 9007199254740991

local symbols = setmetatable({}, { __mode = "v" })

local function str(s, props)
  return { k = "str", s = s, props = props }
end
M.str = str

function M.intern(name)
  local sym = symbols[name]
  if not sym then
    sym = { k = "sym", name = str(name) }
    symbols[name] = sym
  end
  return sym
end

--- A fresh uninterned symbol (make-symbol), as macros bind.
function M.make_symbol(name)
  return { k = "sym", name = str(name), uninterned = true }
end

function M.is_keyword(v)
  return type(v) == "table" and v.k == "sym" and not v.uninterned and v.name.s:byte(1) == 58
end

M.NIL = M.intern("nil")
M.T = M.intern("t")

function M.cons(a, b)
  return { k = "cons", car = a, cdr = b }
end

function M.float(x)
  return { k = "flt", x = x }
end

local nan_bits = ffi.new("union { uint64_t u; double d; }")

--- A NaN whose sign bit is `neg`, as Emacs reads `0.0e+NaN`.
function M.nan(neg)
  nan_bits.u = neg and 0xFFF8000000000000ULL or 0x7FF8000000000000ULL
  return { k = "flt", x = nan_bits.d, nan_neg = neg }
end

function M.list(items, n)
  local out = M.NIL
  for i = n or #items, 1, -1 do
    out = { k = "cons", car = items[i], cdr = out }
  end
  return out
end

local BN_LUA_INT_MAX = bn.from_int(M.LUA_INT_MAX)

--- The integer a bignum stands for: a Lua number when it fits.
function M.int_from_bn(b)
  if bn.is_zero(b) then
    return 0
  end
  local mag = b.sign < 0 and bn.neg(b) or b
  if bn.cmp(mag, BN_LUA_INT_MAX) <= 0 then
    local n = 0
    for i = #b.d, 1, -1 do
      n = n * 1e7 + b.d[i]
    end
    return b.sign < 0 and -n or n
  end
  return { k = "big", n = b }
end

function M.int_to_string(v)
  if type(v) == "number" then
    return string.format("%d", v)
  end
  return bn.to_string(v.n)
end

-- UTF-8

--- Decode the character at byte `i` of `s`: code point and next byte
--- index, or nil when the bytes there are not well-formed UTF-8 of a
--- Unicode scalar value.
function M.utf8_next(s, i)
  local b = s:byte(i)
  if not b then
    return nil
  end
  if b < 0x80 then
    return b, i + 1
  end
  local n, cp, min
  if b >= 0xF0 and b <= 0xF4 then
    n, cp, min = 3, b - 0xF0, 0x10000
  elseif b >= 0xE0 and b <= 0xEF then
    n, cp, min = 2, b - 0xE0, 0x800
  elseif b >= 0xC2 and b <= 0xDF then
    n, cp, min = 1, b - 0xC0, 0x80
  else
    return nil
  end
  for j = i + 1, i + n do
    local c = s:byte(j)
    if not c or c < 0x80 or c > 0xBF then
      return nil
    end
    cp = cp * 64 + (c - 0x80)
  end
  if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
    return nil
  end
  return cp, i + n + 1
end

function M.utf8_valid(s)
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    if b < 0x80 then
      i = i + 1
    else
      local _, j = M.utf8_next(s, i)
      if not j then
        return false, i
      end
      i = j
    end
  end
  return true
end

function M.utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 4096),
      0x80 + math.floor(cp / 64) % 64,
      0x80 + cp % 64
    )
  end
  return string.char(
    0xF0 + math.floor(cp / 262144),
    0x80 + math.floor(cp / 4096) % 64,
    0x80 + math.floor(cp / 64) % 64,
    0x80 + cp % 64
  )
end

--- Number of characters in the well-formed UTF-8 string `s`.
function M.utf8_len(s)
  local _, cont = s:gsub("[\128-\191]", "")
  return #s - cont
end

function M.is_scalar(cp)
  return cp >= 0 and cp <= 0x10FFFF and not (cp >= 0xD800 and cp <= 0xDFFF)
end

return M
