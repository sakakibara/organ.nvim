-- Numbers (D3, D5a): the arithmetic, comparison, rounding, bitwise and
-- conversion builtins, ported from Emacs's data.c, floatfns.c and
-- bignum.c.
--
-- Integer arithmetic works on raw integers: a Lua number within
-- |n| <= 2^53 - 1 or an organ.calc.bn value beyond, and boxes a result
-- through make_int, which signals overflow-error past integer-width
-- (65536 bits) as Emacs's make_integer_mpz does.  Bignum limb work is
-- charged one step per 8 limb operations and each boxed limb 8 bytes.
-- Bitwise functions convert to two's complement base-2^24 chunks and
-- combine bytes through tables, never through the bit library.  Float
-- functions call libm through the FFI, as Emacs does.

local B = require("organ.elisp.builtins")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local bn = require("organ.calc.bn")
local ffi = require("ffi")
local printer = require("organ.elisp.printer")
local reader = require("organ.elisp.reader")

for _, decl in ipairs({
  "double pow(double, double);",
  "double sqrt(double);",
  "double exp(double);",
  "double log(double);",
  "double log10(double);",
  "double log2(double);",
  "double sin(double);",
  "double cos(double);",
  "double tan(double);",
  "double asin(double);",
  "double acos(double);",
  "double atan(double);",
  "double atan2(double, double);",
  "double floor(double);",
  "double ceil(double);",
  "double rint(double);",
  "double trunc(double);",
  "double fmod(double, double);",
}) do
  pcall(ffi.cdef, decl)
end
local C = ffi.C

local M = {}

local NIL, T = V.NIL, V.T
local wta = B.wta
local floor = math.floor

local MAXI = V.LUA_INT_MAX
local BASE = 1e7
local TWO24 = 16777216
local MASK24 = TWO24 - 1
local WIDTH = 65536
local LOG2_10 = math.log(10) / math.log(2)
local LN2 = math.log(2)
local HUGE = math.huge
local NEG_ZERO = -tonumber("0")

local Q_ARITH = V.intern("arith-error")
local Q_OVERFLOW = V.intern("overflow-error")
local Q_ARGS_RANGE = V.intern("args-out-of-range")

local NOM = "number-or-marker-p"
local IOM = "integer-or-marker-p"

local function arith_error()
  R.signal(Q_ARITH, NIL)
end

local function overflow()
  R.signal(Q_OVERFLOW, NIL)
end

-- Classification

local function is_int(v)
  return type(v) == "number" or (type(v) == "table" and v.k == "big")
end
M.is_int = is_int

local function is_float(v)
  return type(v) == "table" and v.k == "flt"
end
M.is_float = is_float

local function is_num(v)
  return type(v) == "number" or (type(v) == "table" and (v.k == "big" or v.k == "flt"))
end
M.is_num = is_num

local function check_num(v, pred)
  if is_num(v) then
    return v
  end
  wta(pred, v)
end

local function check_int(v, pred)
  if is_int(v) then
    return v
  end
  wta(pred, v)
end

local function check_float(v)
  if is_float(v) then
    return v
  end
  wta("floatp", v)
end

--- The raw integer of integer value `v`.
local function raw(v)
  if type(v) == "number" then
    return v
  end
  return v.n
end

local function tobn(x)
  if type(x) == "number" then
    return bn.from_int(x)
  end
  return x
end

local function sign(x)
  if type(x) == "number" then
    return x < 0 and -1 or (x > 0 and 1 or 0)
  end
  return bn.is_zero(x) and 0 or x.sign
end

local function is_zero(x)
  return x == 0 or (type(x) == "table" and bn.is_zero(x))
end

local function work(run, ops)
  run:step(1 + floor(ops / 8))
end

local BN_MAXI = bn.from_int(MAXI)

local function cmp_mag(a, b)
  if #a.d ~= #b.d then
    return #a.d < #b.d and -1 or 1
  end
  for i = #a.d, 1, -1 do
    if a.d[i] ~= b.d[i] then
      return a.d[i] < b.d[i] and -1 or 1
    end
  end
  return 0
end

--- A raw integer as a Lua number when it fits, else the bn itself.
local function shrink(b)
  if type(b) == "number" then
    return b + 0
  end
  local n = #b.d
  if n > 3 or (n == 3 and cmp_mag(b, BN_MAXI) > 0) then
    return b
  end
  local x = 0
  for i = n, 1, -1 do
    x = x * BASE + b.d[i]
  end
  return (b.sign < 0 and -x or x) + 0
end

-- Powers of two and integer width

local function bn_pow2(k)
  local result, base = bn.one(), bn.from_int(2)
  while k > 0 do
    if k % 2 == 1 then
      result = bn.mul(result, base)
    end
    k = floor(k / 2)
    if k > 0 then
      base = bn.mul(base, base)
    end
  end
  return result
end

local POW2_WIDTH

--- log2 of |b| for a nonzero bn, within about 1e-9.
local function log2_mag(b)
  local d, n = b.d, #b.d
  local m, k = 0, 0
  for i = n, math.max(1, n - 2), -1 do
    m = m * BASE + d[i]
    k = k + 1
  end
  return math.log(m) / LN2 + (n - k) * 7 * LOG2_10
end

--- Whether raw integer `x` needs more than integer-width bits.
local function too_wide(x)
  if type(x) == "number" or #x.d < 2800 then
    return false
  end
  local l = log2_mag(x)
  if l < WIDTH - 1e-6 then
    return false
  elseif l > WIDTH + 1e-6 then
    return true
  end
  POW2_WIDTH = POW2_WIDTH or bn_pow2(WIDTH)
  return cmp_mag(x, POW2_WIDTH) >= 0
end

--- Box raw integer `x` as Emacs's make_integer_mpz does.
local function make_int(run, x)
  x = shrink(x)
  if type(x) == "number" then
    return x
  end
  if too_wide(x) then
    overflow()
  end
  run:charge(8 * #x.d)
  return { k = "big", n = x }
end
M.make_int = make_int

-- Emacs's fixnum range [-2^61, 2^61 - 1], for identity and `ash' counts.
local BN_FIX_MAX = bn.sub(bn_pow2(61), bn.one())
local BN_FIX_MIN = bn.neg(bn_pow2(61))

--- Whether raw integer `x` is a fixnum in Emacs.
local function emacs_fixnum(x)
  if type(x) == "number" then
    return true
  end
  return bn.cmp(x, BN_FIX_MAX) <= 0 and bn.cmp(x, BN_FIX_MIN) >= 0
end
M.emacs_fixnum = emacs_fixnum

-- Raw integer arithmetic

local function iadd(run, a, b)
  if type(a) == "number" and type(b) == "number" then
    local s = a + b
    if s <= MAXI and s >= -MAXI then
      return s + 0
    end
  end
  local x, y = tobn(a), tobn(b)
  work(run, math.max(#x.d, #y.d))
  return shrink(bn.add(x, y))
end

local function isub(run, a, b)
  if type(a) == "number" and type(b) == "number" then
    local s = a - b
    if s <= MAXI and s >= -MAXI then
      return s + 0
    end
  end
  local x, y = tobn(a), tobn(b)
  work(run, math.max(#x.d, #y.d))
  return shrink(bn.sub(x, y))
end

local function ineg(x)
  if type(x) == "number" then
    return 0 - x
  end
  return shrink(bn.neg(x))
end

local function imul(run, a, b)
  if type(a) == "number" and type(b) == "number" then
    local p = a * b
    if p <= MAXI and p >= -MAXI then
      return p + 0
    end
  end
  local x, y = tobn(a), tobn(b)
  work(run, #x.d * #y.d)
  return shrink(bn.mul(x, y))
end

-- Magnitude of digit array `a` divided by the single limb `v`.
local function div_small(a, v)
  local q, r = {}, 0
  for i = #a, 1, -1 do
    local cur = r * BASE + a[i]
    local qi = floor(cur / v)
    q[i] = qi
    r = cur - qi * v
  end
  return q, r
end

local function trim(d)
  local n = #d
  while n > 1 and d[n] == 0 do
    d[n] = nil
    n = n - 1
  end
  return d
end

-- Truncated division of magnitudes (Knuth's algorithm D in base 10^7):
-- quotient and remainder digit arrays.
local function divmod_mag(a, b)
  local n, m = #b, #a
  if n == 1 then
    local q, r = div_small(a, b[1])
    return trim(q), { r }
  end
  local f = floor(BASE / (b[n] + 1))
  local u, v = {}, {}
  local carry = 0
  for i = 1, m do
    local p = a[i] * f + carry
    carry = floor(p / BASE)
    u[i] = p - carry * BASE
  end
  u[m + 1] = carry
  carry = 0
  for i = 1, n do
    local p = b[i] * f + carry
    carry = floor(p / BASE)
    v[i] = p - carry * BASE
  end
  local vn, vn1 = v[n], v[n - 1]
  local q = {}
  for j = m - n, 0, -1 do
    local top = u[j + n + 1] * BASE + u[j + n]
    local qhat = floor(top / vn)
    local rhat = top - qhat * vn
    while qhat >= BASE or qhat * vn1 > rhat * BASE + u[j + n - 1] do
      qhat = qhat - 1
      rhat = rhat + vn
      if rhat >= BASE then
        break
      end
    end
    local borrow, c = 0, 0
    for i = 1, n do
      local p = qhat * v[i] + c
      c = floor(p / BASE)
      local t = u[i + j] - (p - c * BASE) - borrow
      if t < 0 then
        u[i + j] = t + BASE
        borrow = 1
      else
        u[i + j] = t
        borrow = 0
      end
    end
    local t = u[j + n + 1] - c - borrow
    if t < 0 then
      qhat = qhat - 1
      c = 0
      for i = 1, n do
        local s = u[i + j] + v[i] + c
        if s >= BASE then
          u[i + j] = s - BASE
          c = 1
        else
          u[i + j] = s
          c = 0
        end
      end
      t = t + c + BASE
      if t >= BASE then
        t = t - BASE
      end
    end
    u[j + n + 1] = t
    q[j + 1] = qhat
  end
  if #q == 0 then
    q[1] = 0
  end
  local rem = {}
  for i = 1, n do
    rem[i] = u[i]
  end
  local r = div_small(trim(rem), f)
  return trim(q), trim(r)
end

--- Truncated quotient and remainder of raw integers, `b` nonzero.
local function idivmod(run, a, b)
  if type(a) == "number" and type(b) == "number" then
    local r = C.fmod(a, b)
    return ((a - r) / b) + 0, r + 0
  end
  local x, y = tobn(a), tobn(b)
  if cmp_mag(x, y) < 0 then
    return 0, a
  end
  work(run, #y.d * (#x.d - #y.d + 1))
  local qd, rd = divmod_mag(x.d, y.d)
  local q = bn.copy({ sign = x.sign * y.sign, d = qd })
  local r = bn.copy({ sign = x.sign, d = rd })
  if bn.is_zero(q) then
    q.sign = 1
  end
  if bn.is_zero(r) then
    r.sign = 1
  end
  return shrink(q), shrink(r)
end

local function is_odd(x)
  if type(x) == "number" then
    return x % 2 ~= 0
  end
  return x.d[1] % 2 ~= 0
end

local function iabs(x)
  return sign(x) < 0 and ineg(x) or x
end

local function icmp(a, b)
  if type(a) == "number" and type(b) == "number" then
    return a < b and -1 or (a > b and 1 or 0)
  end
  return bn.cmp(tobn(a), tobn(b))
end

--- Quotient of raw integers rounded as `mode` ("floor", "ceiling",
--- "round", "truncate"); `d` nonzero.
local function idiv_round(run, n, d, mode)
  local q, r = idivmod(run, n, d)
  if mode == "truncate" or is_zero(r) then
    return q
  end
  local neg_n, neg_d = sign(n) < 0, sign(d) < 0
  if mode == "floor" then
    if neg_n ~= neg_d then
      q = isub(run, q, 1)
    end
  elseif mode == "ceiling" then
    if neg_n == neg_d then
      q = iadd(run, q, 1)
    end
  else
    local abs_r = iabs(r)
    local abs_r1 = isub(run, iabs(d), abs_r)
    local c = icmp(abs_r1, abs_r)
    if c < 0 or (c == 0 and is_odd(q)) then
      q = (neg_d == (sign(r) < 0)) and iadd(run, q, 1) or isub(run, q, 1)
    end
  end
  return q
end

-- Conversions

--- A raw integer as the nearest double.
local function to_double(run, x)
  if type(x) == "number" then
    return x
  end
  local s = bn.to_string(x.sign < 0 and bn.neg(x) or x)
  run:step(1 + floor(#s / 64))
  local f = reader.decimal_float(s, "", "", false)
  return x.sign < 0 and -f or f
end

--- The double of number value `v`.
local function float_of(run, v)
  if type(v) == "number" then
    return v
  elseif v.k == "flt" then
    return v.x
  end
  return to_double(run, v.n)
end
M.float_of = float_of

--- The raw integer an integral double `x` equals.
local function dbl_to_raw(x)
  if x <= MAXI and x >= -MAXI then
    return x + 0
  end
  local m, e = math.frexp(x)
  return bn.mul(bn.from_int(m * 2 ^ 53), bn_pow2(e - 53))
end

--- Emacs's double_to_integer of an integral double.
local function dbl_to_int(run, x)
  if x ~= x or x == HUGE or x == -HUGE then
    overflow()
  end
  return make_int(run, dbl_to_raw(C.trunc(x)))
end

local function new_float(run, x)
  run:charge(16)
  return V.float(x)
end

local function signbit(x)
  if x ~= x then
    local buf = ffi.new("double[1]", x)
    local bytes = ffi.cast("unsigned char *", buf)
    return (ffi.abi("le") and bytes[7] or bytes[0]) >= 128
  end
  return x < 0 or (x == 0 and 1 / x < 0)
end

-- Comparison

-- Compare double `f` with raw integer `i` exactly: -1, 0, 1, or nil
-- when `f` is a NaN.
local function float_int_cmp(f, i)
  if f ~= f then
    return nil
  end
  if type(i) == "number" then
    return f < i and -1 or (f > i and 1 or 0)
  end
  if f == HUGE then
    return 1
  elseif f == -HUGE then
    return -1
  elseif f < 2 ^ 53 and f > -(2 ^ 53) then
    return i.sign > 0 and -1 or 1
  end
  return bn.cmp(tobn(dbl_to_raw(f)), i)
end

--- arithcompare of number values: -1, 0, 1, or nil when unordered.
local function num_cmp(a, b)
  local fa, fb = is_float(a), is_float(b)
  if fa and fb then
    local x, y = a.x, b.x
    if x < y then
      return -1
    elseif x > y then
      return 1
    elseif x == y then
      return 0
    end
    return nil
  elseif fa then
    return float_int_cmp(a.x, raw(b))
  elseif fb then
    local c = float_int_cmp(b.x, raw(a))
    return c and 0 - c
  end
  return icmp(raw(a), raw(b))
end
M.num_cmp = num_cmp

-- Bitwise

local AND_T, IOR_T, XOR_T

local function byte_tables()
  AND_T, IOR_T, XOR_T = {}, {}, {}
  for a = 0, 255 do
    for b = 0, 255 do
      local x, y, va, vo, vx, w = a, b, 0, 0, 0, 1
      for _ = 1, 8 do
        local p, q = x % 2, y % 2
        if p == 1 and q == 1 then
          va = va + w
        end
        if p == 1 or q == 1 then
          vo = vo + w
        end
        if p ~= q then
          vx = vx + w
        end
        x, y, w = (x - p) / 2, (y - q) / 2, w * 2
      end
      local k = a * 256 + b
      AND_T[k], IOR_T[k], XOR_T[k] = va, vo, vx
    end
  end
end

local function op24(tbl, x, y)
  local x0, y0 = x % 256, y % 256
  x, y = (x - x0) / 256, (y - y0) / 256
  local x1, y1 = x % 256, y % 256
  local x2, y2 = (x - x1) / 256, (y - y1) / 256
  return tbl[x0 * 256 + y0] + tbl[x1 * 256 + y1] * 256 + tbl[x2 * 256 + y2] * 65536
end

--- Base-2^24 chunks (least significant first) of non-negative raw `m`.
local function chunks_of(run, m)
  local c, n = {}, 0
  if type(m) == "number" then
    while m > 0 do
      local r = m % TWO24
      n = n + 1
      c[n] = r
      m = (m - r) / TWO24
    end
    return c, n
  end
  local d, len = {}, #m.d
  for i = 1, len do
    d[i] = m.d[i]
  end
  work(run, floor(len * len / 2))
  while len > 1 or d[1] ~= 0 do
    local r = 0
    for i = len, 1, -1 do
      local cur = r * BASE + d[i]
      local q = floor(cur / TWO24)
      r = cur - q * TWO24
      d[i] = q
    end
    n = n + 1
    c[n] = r
    while len > 1 and d[len] == 0 do
      len = len - 1
    end
  end
  return c, n
end

--- The non-negative raw integer of base-2^24 chunks c[1..n].
local function raw_of_chunks(run, c, n)
  while n > 0 and c[n] == 0 do
    n = n - 1
  end
  if n <= 2 then
    return (c[2] or 0) * TWO24 + (c[1] or 0)
  end
  work(run, floor(n * n / 2))
  local d, len = { 0 }, 1
  for i = n, 1, -1 do
    local carry = c[i]
    for j = 1, len do
      local p = d[j] * TWO24 + carry
      carry = floor(p / BASE)
      d[j] = p - carry * BASE
    end
    while carry > 0 do
      len = len + 1
      local q = floor(carry / BASE)
      d[len] = carry - q * BASE
      carry = q
    end
  end
  return shrink({ sign = 1, d = d })
end

-- Two's complement form of raw `x`: whether it is negative and the
-- chunks of x, or of -x - 1 when negative (the complemented bits).
local function twos(run, x)
  if sign(x) < 0 then
    return true, chunks_of(run, isub(run, ineg(x), 1))
  end
  return false, chunks_of(run, x)
end

local function from_twos(run, neg, c, n)
  local m = raw_of_chunks(run, c, n)
  if neg then
    return isub(run, ineg(m), 1)
  end
  return m
end

local AND, IOR, XOR = 5, 6, 7

local function ibitop(run, code, a, b)
  if not AND_T then
    byte_tables()
  end
  local na, ca, la = twos(run, a)
  local nb, cb, lb = twos(run, b)
  local tbl = code == AND and AND_T or (code == IOR and IOR_T or XOR_T)
  local nr
  if code == AND then
    nr = na and nb
  elseif code == IOR then
    nr = na or nb
  else
    nr = na ~= nb
  end
  local len = math.max(la, lb)
  work(run, len)
  local out = {}
  for i = 1, len do
    local x, y = ca[i] or 0, cb[i] or 0
    if na then
      x = MASK24 - x
    end
    if nb then
      y = MASK24 - y
    end
    local z = op24(tbl, x, y)
    out[i] = nr and (MASK24 - z) or z
  end
  return from_twos(run, nr, out, len)
end

-- Arithmetic driver (data.c's arith_driver)

local ADD, SUB, MUL, DIV = 1, 2, 3, 4

local function float_op(code, acc, x)
  if code == ADD then
    return acc + x
  elseif code == SUB then
    return acc - x
  elseif code == MUL then
    local p = acc * x
    -- LuaJIT multiplies integer-valued doubles as integers, losing -0.
    if p == 0 and signbit(acc) ~= signbit(x) then
      return NEG_ZERO
    end
    return p
  end
  return acc / x
end

-- floatop_arith_driver: argument i's double is `nxt`, and `acc` holds
-- the arguments before it (ignored when i is 1).
local function float_driver(run, code, argv, i, acc, nxt)
  acc = i == 1 and nxt or float_op(code, acc, nxt)
  for j = i + 1, argv.n do
    acc = float_op(code, acc, float_of(run, check_num(argv[j], NOM)))
  end
  return new_float(run, acc)
end

local function arith(run, code, argv, a)
  run:step(argv.n)
  if is_float(a) then
    return float_driver(run, code, argv, 1, nil, a.x)
  end
  local acc = raw(a)
  for i = 2, argv.n do
    local v = check_num(argv[i], NOM)
    if is_float(v) then
      if code >= AND then
        wta(IOM, v)
      end
      return float_driver(run, code, argv, i, to_double(run, acc), v.x)
    end
    local x = raw(v)
    if code == ADD then
      acc = iadd(run, acc, x)
    elseif code == SUB then
      acc = isub(run, acc, x)
    elseif code == MUL then
      acc = imul(run, acc, x)
    elseif code == DIV then
      if is_zero(x) then
        arith_error()
      end
      acc = idivmod(run, acc, x)
    else
      acc = ibitop(run, code, acc, x)
    end
  end
  return make_int(run, acc)
end

local define = B.define

define("+", function(run, argv)
  if argv.n == 0 then
    return 0
  end
  local a = check_num(argv[1], NOM)
  if argv.n == 1 then
    return a
  end
  return arith(run, ADD, argv, a)
end)

define("-", function(run, argv)
  if argv.n == 0 then
    return 0
  end
  local a = check_num(argv[1], NOM)
  if argv.n == 1 then
    if is_float(a) then
      return new_float(run, -a.x)
    end
    return make_int(run, ineg(raw(a)))
  end
  return arith(run, SUB, argv, a)
end)

define("*", function(run, argv)
  if argv.n == 0 then
    return 1
  end
  local a = check_num(argv[1], NOM)
  if argv.n == 1 then
    return a
  end
  return arith(run, MUL, argv, a)
end)

define("/", function(run, argv)
  local a = check_num(argv[1], NOM)
  if argv.n == 1 then
    if is_float(a) then
      return new_float(run, 1 / a.x)
    elseif a == 0 then
      arith_error()
    elseif a == 1 or a == -1 then
      return a
    end
    return 0
  end
  for i = 3, argv.n do
    if is_float(argv[i]) then
      run:step(argv.n)
      return float_driver(run, DIV, argv, 1, nil, float_of(run, a))
    end
  end
  return arith(run, DIV, argv, a)
end)

local function bitwise(name, code, empty)
  define(name, function(run, argv)
    if argv.n == 0 then
      return empty
    end
    local a = check_int(argv[1], IOM)
    if argv.n == 1 then
      return a
    end
    return arith(run, code, argv, a)
  end)
end

bitwise("logand", AND, -1)
bitwise("logior", IOR, 0)
bitwise("logxor", XOR, 0)

define("lognot", function(run, argv)
  local x = raw(check_int(argv[1], "integerp"))
  return make_int(run, isub(run, ineg(x), 1))
end)

define("%", function(run, argv)
  local x = raw(check_int(argv[1], IOM))
  local y = raw(check_int(argv[2], IOM))
  if is_zero(y) then
    arith_error()
  end
  local _, r = idivmod(run, x, y)
  return make_int(run, r)
end)

define("mod", function(run, argv)
  local x = check_num(argv[1], NOM)
  local y = check_num(argv[2], NOM)
  if is_float(x) or is_float(y) then
    local f1, f2 = float_of(run, x), float_of(run, y)
    f1 = C.fmod(f1, f2)
    if (f2 < 0 and f1 > 0) or (not (f2 < 0) and f1 < 0) then
      f1 = f1 + f2
    end
    return new_float(run, f1)
  end
  local a, b = raw(x), raw(y)
  if is_zero(b) then
    arith_error()
  end
  local _, r = idivmod(run, a, b)
  if not is_zero(r) and (sign(r) < 0) ~= (sign(b) < 0) then
    r = iadd(run, r, b)
  end
  return make_int(run, r)
end)

define("1+", function(run, argv)
  local x = check_num(argv[1], NOM)
  if is_float(x) then
    return new_float(run, 1.0 + x.x)
  end
  return make_int(run, iadd(run, raw(x), 1))
end)

define("1-", function(run, argv)
  local x = check_num(argv[1], NOM)
  if is_float(x) then
    return new_float(run, -1.0 + x.x)
  end
  return make_int(run, isub(run, raw(x), 1))
end)

define("abs", function(run, argv)
  local x = check_num(argv[1], "numberp")
  if is_float(x) then
    if signbit(x.x) then
      return new_float(run, -x.x)
    end
    return x
  end
  if sign(raw(x)) < 0 then
    return make_int(run, ineg(raw(x)))
  end
  return x
end)

local function minmax(want)
  return function(run, argv)
    run:step(argv.n)
    local acc = check_num(argv[1], NOM)
    for i = 2, argv.n do
      local v = check_num(argv[i], NOM)
      if num_cmp(v, acc) == want then
        acc = v
      elseif is_float(v) and v.x ~= v.x then
        return v
      end
    end
    return acc
  end
end

define("max", minmax(1))
define("min", minmax(-1))

define("float", function(run, argv)
  local x = check_num(argv[1], "numberp")
  if is_float(x) then
    return x
  end
  return new_float(run, to_double(run, raw(x)))
end)

-- Rounding (floatfns.c's rounding_driver)

local DBL_MAX_SCALE = 1074

-- double_integer_scale
local function scale_of(x)
  if x ~= x then
    return DBL_MAX_SCALE + 2
  elseif x == HUGE or x == -HUGE then
    return DBL_MAX_SCALE + 1
  elseif x == 0 then
    return DBL_MAX_SCALE
  end
  local _, e = math.frexp(x)
  return math.min(53 - e, DBL_MAX_SCALE)
end

-- The raw integer x * 2^s for a finite double x and scale s at least
-- scale_of(x), or for raw integer x and s >= 0.
local function scaled(run, v, s)
  local x
  if is_float(v) then
    local m, e = math.frexp(v.x)
    if v.x == 0 then
      return 0
    end
    x = m * 2 ^ 53
    s = s - (53 - e)
  else
    x = raw(v)
  end
  if s == 0 then
    return x
  end
  if s < 0 then
    return dbl_to_raw(x * 2 ^ s)
  end
  return imul(run, x, shrink(bn_pow2(s)))
end

local function rounding(name, mode, dround)
  define(name, function(run, argv)
    local n = check_num(argv[1], "numberp")
    local d = argv[2]
    if argv.n < 2 or d == NIL then
      if is_float(n) then
        return dbl_to_int(run, dround(n.x))
      end
      return n
    end
    d = check_num(d, "numberp")
    local dscale = 0
    if is_int(d) then
      if is_zero(raw(d)) then
        arith_error()
      end
      if is_int(n) then
        return make_int(run, idiv_round(run, raw(n), raw(d), mode))
      end
    else
      if d.x == 0 then
        arith_error()
      end
      dscale = scale_of(d.x)
    end
    local nscale = is_float(n) and scale_of(n.x) or 0
    if dscale == DBL_MAX_SCALE + 1 and nscale < dscale then
      return 0
    end
    if nscale > DBL_MAX_SCALE or dscale > DBL_MAX_SCALE then
      overflow()
    end
    local s = math.max(nscale, dscale)
    local q = idiv_round(run, scaled(run, n, s), scaled(run, d, s), mode)
    return make_int(run, q)
  end)
end

local function c_floor(x)
  return C.floor(x)
end

local function c_ceil(x)
  return C.ceil(x)
end

local function c_rint(x)
  return C.rint(x)
end

local function same(x)
  return x
end

rounding("floor", "floor", c_floor)
rounding("ceiling", "ceiling", c_ceil)
rounding("round", "round", c_rint)
rounding("truncate", "truncate", same)

local function float_rounding(name, fn)
  define(name, function(run, argv)
    return new_float(run, fn(check_float(argv[1]).x))
  end)
end

float_rounding("ffloor", c_floor)
float_rounding("fceiling", c_ceil)
float_rounding("fround", c_rint)
float_rounding("ftruncate", function(x)
  return C.trunc(x)
end)

-- Float functions

local function float_fn(name, fn)
  define(name, function(run, argv)
    return new_float(run, fn(float_of(run, check_num(argv[1], "numberp"))))
  end)
end

float_fn("sqrt", function(x)
  return C.sqrt(x)
end)
float_fn("exp", function(x)
  return C.exp(x)
end)
float_fn("sin", function(x)
  return C.sin(x)
end)
float_fn("cos", function(x)
  return C.cos(x)
end)
float_fn("tan", function(x)
  return C.tan(x)
end)
float_fn("asin", function(x)
  return C.asin(x)
end)
float_fn("acos", function(x)
  return C.acos(x)
end)

define("atan", function(run, argv)
  local y = float_of(run, check_num(argv[1], "numberp"))
  if argv.n < 2 or argv[2] == NIL then
    return new_float(run, C.atan(y))
  end
  return new_float(run, C.atan2(y, float_of(run, check_num(argv[2], "numberp"))))
end)

define("log", function(run, argv)
  local d = float_of(run, check_num(argv[1], "numberp"))
  if argv.n < 2 or argv[2] == NIL then
    return new_float(run, C.log(d))
  end
  local b = float_of(run, check_num(argv[2], "numberp"))
  if b == 10 then
    return new_float(run, C.log10(d))
  elseif b == 2 then
    return new_float(run, C.log2(d))
  end
  return new_float(run, C.log(d) / C.log(b))
end)

define("isnan", function(_, argv)
  local x = check_float(argv[1]).x
  return x ~= x and T or NIL
end)

-- expt

local function expt_integer(run, x, y)
  local xv, yv = raw(x), raw(y)
  if xv == 1 then
    return x
  elseif xv == 0 then
    return yv == 0 and 1 or x
  elseif xv == -1 then
    return is_odd(yv) and x or 1
  end
  if type(yv) ~= "number" or yv >= WIDTH then
    overflow()
  end
  local base = tobn(xv)
  local lg = log2_mag(base)
  if yv * lg > WIDTH + 1e-6 then
    overflow()
  end
  local result = bn.one()
  local e = yv
  while e > 0 do
    if e % 2 == 1 then
      work(run, #result.d * #base.d)
      result = bn.mul(result, base)
    end
    e = floor(e / 2)
    if e > 0 then
      work(run, #base.d * #base.d)
      base = bn.mul(base, base)
    end
  end
  return make_int(run, result)
end

define("expt", function(run, argv)
  local x = check_num(argv[1], "numberp")
  local y = check_num(argv[2], "numberp")
  if is_int(x) and is_int(y) and sign(raw(y)) >= 0 then
    return expt_integer(run, x, y)
  end
  return new_float(run, C.pow(float_of(run, x), float_of(run, y)))
end)

-- ash

-- Shift base-2^24 chunks c[1..n] left (s > 0) or right (s < 0).
local function shift_chunks(c, n, s)
  local out = {}
  if s >= 0 then
    local q, r = floor(s / 24), s % 24
    local f = 2 ^ r
    for i = 1, q do
      out[i] = 0
    end
    local carry = 0
    for i = 1, n do
      local v = c[i] * f + carry
      local lo = v % TWO24
      out[q + i] = lo
      carry = (v - lo) / TWO24
    end
    out[q + n + 1] = carry
    return out, q + n + 1
  end
  s = -s
  local q, r = floor(s / 24), s % 24
  local f = 2 ^ r
  local len = n - q
  for i = 1, len do
    local v = c[i + q]
    local lo = v % f
    local hi = c[i + q + 1] or 0
    out[i] = (v - lo) / f + (hi % f) * (TWO24 / f)
  end
  return out, math.max(len, 0)
end

define("ash", function(run, argv)
  local value = check_int(argv[1], "integerp")
  local count = check_int(argv[2], "integerp")
  local v, c = raw(value), raw(count)
  if not emacs_fixnum(c) then
    if is_zero(v) then
      return value
    end
    if sign(c) < 0 then
      return sign(v) < 0 and -1 or 0
    end
    overflow()
  end
  if c == 0 then
    return value
  end
  if sign(c) > 0 then
    if is_zero(v) then
      if type(c) ~= "number" or floor(c / 64) > 2147483646 then
        overflow()
      end
      return 0
    end
    if type(c) ~= "number" or c > WIDTH then
      overflow()
    end
    local m = iabs(v)
    if type(m) ~= "number" and log2_mag(m) + c > WIDTH + 1 then
      overflow()
    end
    local ch, n = chunks_of(run, m)
    if (n - 1) * 24 + select(2, math.frexp(ch[n])) + c > WIDTH then
      overflow()
    end
    work(run, n + floor(c / 24))
    local out, len = shift_chunks(ch, n, c)
    local r = raw_of_chunks(run, out, len)
    return make_int(run, sign(v) < 0 and ineg(r) or r)
  end
  local neg, ch, n = twos(run, v)
  if type(c) ~= "number" or -c >= n * 24 then
    return neg and -1 or 0
  end
  work(run, n)
  local out, len = shift_chunks(ch, n, c)
  return make_int(run, from_twos(run, neg, out, len))
end)

-- Comparisons

local function comparison(name, ok)
  define(name, function(run, argv)
    run:step(argv.n)
    for i = 2, argv.n do
      local a = check_num(argv[i - 1], NOM)
      local b = check_num(argv[i], NOM)
      if not ok(num_cmp(a, b)) then
        return NIL
      end
    end
    return T
  end)
end

comparison("=", function(c)
  return c == 0
end)
comparison("<", function(c)
  return c == -1
end)
comparison(">", function(c)
  return c == 1
end)
comparison("<=", function(c)
  return c == -1 or c == 0
end)
comparison(">=", function(c)
  return c == 1 or c == 0
end)

define("/=", function(_, argv)
  local a = check_num(argv[1], NOM)
  local b = check_num(argv[2], NOM)
  return num_cmp(a, b) == 0 and NIL or T
end)

define("zerop", function(_, argv)
  return num_cmp(0, check_num(argv[1], NOM)) == 0 and T or NIL
end)

-- Predicates

define("numberp", function(_, argv)
  return is_num(argv[1]) and T or NIL
end)

define("integerp", function(_, argv)
  return is_int(argv[1]) and T or NIL
end)

define("floatp", function(_, argv)
  return is_float(argv[1]) and T or NIL
end)

define("natnump", function(_, argv)
  local x = argv[1]
  return (is_int(x) and sign(raw(x)) >= 0) and T or NIL
end)

-- Number and string conversion

local function make_string(run, s)
  run:check_string(#s)
  run:charge(#s)
  return V.str(s)
end

define("number-to-string", function(run, argv)
  local x = argv[1]
  if type(x) == "number" then
    return make_string(run, string.format("%d", x))
  elseif is_float(x) then
    return make_string(run, printer.float_string(x.x))
  elseif is_int(x) then
    run:step(1 + floor(#x.n.d / 8))
    return make_string(run, bn.to_string(x.n))
  end
  wta("numberp", x)
end)

local function digit_value(c, base)
  local d
  if c >= 48 and c <= 57 then
    d = c - 48
  elseif c >= 97 and c <= 122 then
    d = c - 87
  elseif c >= 65 and c <= 90 then
    d = c - 55
  else
    return nil
  end
  return d < base and d or nil
end

define("string-to-number", function(run, argv)
  local str = argv[1]
  if not (type(str) == "table" and str.k == "str") then
    wta("stringp", str)
  end
  local base = 10
  local b = argv[2]
  if argv.n >= 2 and b ~= NIL then
    if not (is_int(b) and emacs_fixnum(raw(b))) then
      wta("fixnump", b)
    end
    if type(b) ~= "number" or b < 2 or b > 16 then
      R.signal(Q_ARGS_RANGE, V.list({ b }))
    end
    base = b
  end
  local s = str.s
  local i = 1
  while true do
    local c = s:byte(i)
    if c ~= 32 and c ~= 9 then
      break
    end
    i = i + 1
  end
  run:step(1 + floor((#s - i) / 64))
  s = s:sub(i)
  if base == 10 then
    local n = reader.scan_number(s)
    if not n then
      return 0
    end
    if n.float then
      local x = n.special or reader.decimal_float(n.int_part, n.frac, n.exp_digits, n.exp_neg)
      return new_float(run, n.neg and -x or x)
    end
    return reader.digits_to_int(run, n.int_part, n.neg, 10)
  end
  local c0 = s:byte(1)
  local neg = c0 == 45
  local j = (neg or c0 == 43) and 2 or 1
  local start = j
  while true do
    local c = s:byte(j)
    if not c or not digit_value(c, base) then
      break
    end
    j = j + 1
  end
  if j == start then
    return 0
  end
  return reader.digits_to_int(run, s:sub(start, j - 1), neg, base)
end)

return M
