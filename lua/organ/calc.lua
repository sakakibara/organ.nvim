-- Native Emacs Calc port for org-table formulas.
--
-- IMPLEMENTED (this module):
--   - Arbitrary-precision integers (bignum) and rationals.
--   - IEEE-754 floats with mixed-type promotion rules (int + float → float,
--     rat + float → float; int / int that doesn't divide cleanly → rat).
--   - Comparison, logical (and / or / not), conditional (`if(c, a, b)`).
--   - Math functions: sqrt, cbrt, exp, ln, log, log10, log2, sin, cos,
--     tan, asin, acos, atan, atan2, sinh, cosh, tanh, gcd, lcm, factorial,
--     binomial, abs, sign, ceil, floor, round, trunc.
--   - Aggregations over numeric vectors: vsum, vmean, vmedian, vmax, vmin,
--     vsdev, vvar, vproduct, vcount, vlen, vmaxabs.
--   - Units: SI base + common derived + decimal prefixes; dimensional
--     analysis on `+`/`-`; conversion via `convert(v, "km")`.
--   - Symbolic simplification of literal expressions: x+0=x, x*1=x,
--     x*0=0, x-x=0, x/x=1, double-negation.
--   - Financial: pmt, fv, pv, npv, irr (with Excel sign convention,
--     end- vs beginning-of-period due flag, IRR via Newton-Raphson).
--   - Big-integer primality (Miller-Rabin) + factoring (trial division
--     + Pollard's rho) via M.is_prime / M.factor.
--   - Matrix algebra: det, inv, LU, transpose, add/sub/mul. Elements
--     are Calc values, so integer-matrix det is exact.
--   - Matrix eigenvalues via power iteration + deflation (best for
--     symmetric matrices; M.eigenvalues, M.dominant_eig).
--   - Symbolic differentiation: M.deriv / M.deriv_simplify operating
--     over the formula.lua AST. Handles polynomial, rational, trig
--     (sin / cos / tan), exp, ln, sqrt; constant exponents only.
--   - Date arithmetic: M.date / M.date_from_string / M.date_to_string;
--     M.date_add_days, M.date_add_months, M.date_diff, M.date_cmp,
--     M.date_year / month / day / weekday. Proleptic Gregorian.
--   - Limits: M.limit(ast, var, c) — direct substitution with
--     L'Hôpital fallback for 0/0 forms.
--   - Symbolic integration via antiderivative table: polynomials,
--     1/x → ln, sin/cos/exp; constant factors and sums. NOT YET:
--     integration by parts, substitution / chain-rule inverse.
--   - Polynomial / algebraic manipulation: M.expand distributes
--     multiplication over addition (and lowers small literal-int
--     exponents to repeated multiplication); M.factor recognises
--     difference-of-squares and shared common factor in sums;
--     M.simplify iterates ast_simplify to fixpoint.
--
-- NOT YET IMPLEMENTED — TODO before considering Calc parity complete:
--   - Indeterminate forms beyond 0/0 (∞/∞, 0·∞, 0^0, etc.).
--   - Integration by parts; chain-rule inverse / u-substitution.
--   - Full polynomial CAS (general factor, like-term collection,
--     canonical-form representation, simplify(x^2 - y^2) by
--     equivalence rather than pattern).
--   - QR algorithm for general (non-symmetric) eigenvalues; SVD.
-- See `M.NOT_IMPLEMENTED` for the runtime registry exposed to callers.
--
-- Calc value kinds:
--
--   integer  { kind = "int",   n = bignum }
--   rational { kind = "rat",   num = bignum, den = bignum (>0, gcd=1) }
--   float    { kind = "float", v = number }
--   unit     { kind = "unit",  v = numeric Calc value, dim = {…}, name = str }
--   symbol   { kind = "sym",   name = string }
--
-- A bignum is { sign = 1|-1, d = { lsb-digit, …, msb-digit } } where each
-- digit is a base-10^7 limb. Zero is { sign = 1, d = { 0 } }. Base
-- 10^7 keeps the product of two digits within Lua's exact-int range
-- (2^53), so multiplication never loses precision and decimal printing
-- is straightforward.
--
-- Public API:
--
--   M.from_string(s)   parse "0", "-42", "1/3", "12.5"
--   M.from_int(n)      from a Lua integer (must be exact, |n| < 2^53)
--   M.to_string(v)     "42" / "-1/3" / "0"
--   M.to_number(v)     best-effort Lua double
--   M.is_calc(v)       predicate
--   M.is_int(v)        v is an exact integer
--   M.add/sub/mul/div  arithmetic; promotes to rational as needed
--   M.pow(v, n)        integer exponent only (non-integer falls back to float)
--   M.mod(a, b)        integer mod (errors on rationals)
--   M.neg(v)
--   M.abs(v)
--   M.sign(v)          → -1 / 0 / 1
--   M.cmp(a, b)        → -1 / 0 / 1
--   M.eq, lt, le, gt, ge

local M = {}

-- ---------------------------------------------------------------------------
-- Bignum primitives.

local BASE = 10 ^ 7
local BASE_DIGITS = 7

local function bn_zero()
  return { sign = 1, d = { 0 } }
end

local function bn_normalize(b)
  while #b.d > 1 and b.d[#b.d] == 0 do
    b.d[#b.d] = nil
  end
  if #b.d == 1 and b.d[1] == 0 then
    b.sign = 1
  end
  return b
end

local function bn_copy(b)
  local d = {}
  for i = 1, #b.d do
    d[i] = b.d[i]
  end
  return { sign = b.sign, d = d }
end

local function bn_from_int(n)
  if n == 0 then
    return bn_zero()
  end
  local sign = n < 0 and -1 or 1
  n = math.abs(n)
  local d = {}
  while n > 0 do
    d[#d + 1] = n % BASE
    n = math.floor(n / BASE)
  end
  return { sign = sign, d = d }
end

local function bn_from_digits_string(s)
  -- s is a (possibly empty) string of decimal digits, no sign.
  if s == "" then
    return bn_zero()
  end
  local d = {}
  local i = #s
  while i > 0 do
    local lo = math.max(1, i - BASE_DIGITS + 1)
    d[#d + 1] = tonumber(s:sub(lo, i))
    i = lo - 1
  end
  return bn_normalize({ sign = 1, d = d })
end

local function bn_to_string(b)
  local out = {}
  for i = #b.d, 1, -1 do
    if i == #b.d then
      out[#out + 1] = tostring(b.d[i])
    else
      out[#out + 1] = string.format("%0" .. BASE_DIGITS .. "d", b.d[i])
    end
  end
  local s = table.concat(out)
  if b.sign < 0 and s ~= "0" then
    s = "-" .. s
  end
  return s
end

-- Compare magnitudes only (sign ignored). -1 / 0 / 1.
local function bn_cmp_mag(a, b)
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

local function bn_cmp(a, b)
  if a.sign ~= b.sign then
    return a.sign < b.sign and -1 or 1
  end
  local mag = bn_cmp_mag(a, b)
  return a.sign < 0 and -mag or mag
end

local function bn_is_zero(b)
  return #b.d == 1 and b.d[1] == 0
end

local function bn_neg(b)
  if bn_is_zero(b) then
    return bn_zero()
  end
  return {
    sign = -b.sign,
    d = (function()
      local d = {}
      for i = 1, #b.d do
        d[i] = b.d[i]
      end
      return d
    end)(),
  }
end

-- Magnitude addition (a + b, both treated as positive).
local function bn_add_mag(a, b)
  local d = {}
  local carry = 0
  local n = math.max(#a.d, #b.d)
  for i = 1, n do
    local s = (a.d[i] or 0) + (b.d[i] or 0) + carry
    if s >= BASE then
      carry = 1
      d[i] = s - BASE
    else
      carry = 0
      d[i] = s
    end
  end
  if carry > 0 then
    d[#d + 1] = carry
  end
  return { sign = 1, d = d }
end

-- Magnitude subtraction (a - b, requires |a| >= |b|; result is non-negative).
local function bn_sub_mag(a, b)
  local d = {}
  local borrow = 0
  for i = 1, #a.d do
    local s = a.d[i] - (b.d[i] or 0) - borrow
    if s < 0 then
      borrow = 1
      d[i] = s + BASE
    else
      borrow = 0
      d[i] = s
    end
  end
  return bn_normalize({ sign = 1, d = d })
end

local function bn_add(a, b)
  if a.sign == b.sign then
    local r = bn_add_mag(a, b)
    r.sign = a.sign
    return r
  end
  local mag = bn_cmp_mag(a, b)
  if mag == 0 then
    return bn_zero()
  end
  if mag > 0 then
    local r = bn_sub_mag(a, b)
    r.sign = a.sign
    return r
  else
    local r = bn_sub_mag(b, a)
    r.sign = b.sign
    return r
  end
end

local function bn_sub(a, b)
  return bn_add(a, bn_neg(b))
end

local function bn_mul(a, b)
  local d = {}
  for i = 1, #a.d + #b.d do
    d[i] = 0
  end
  for i = 1, #a.d do
    local carry = 0
    for j = 1, #b.d do
      local p = a.d[i] * b.d[j] + d[i + j - 1] + carry
      carry = math.floor(p / BASE)
      d[i + j - 1] = p - carry * BASE
    end
    if carry > 0 then
      d[i + #b.d] = d[i + #b.d] + carry
    end
  end
  local r = bn_normalize({ sign = a.sign * b.sign, d = d })
  if bn_is_zero(r) then
    r.sign = 1
  end
  return r
end

-- Division by a single-digit divisor. Used internally by long division.
local function bn_divmod_single(a, divisor)
  if divisor == 0 then
    error("calc: division by zero")
  end
  local q = {}
  local r = 0
  for i = #a.d, 1, -1 do
    local cur = r * BASE + a.d[i]
    q[i] = math.floor(cur / divisor)
    r = cur - q[i] * divisor
  end
  return bn_normalize({ sign = 1, d = q }), r
end

-- General divmod via shifted long division.
local function bn_divmod(a, b)
  if bn_is_zero(b) then
    error("calc: division by zero")
  end
  local cmp_mag = bn_cmp_mag(a, b)
  if cmp_mag < 0 then
    return bn_zero(), bn_copy(a)
  end
  if #b.d == 1 then
    local q, r = bn_divmod_single(a, b.d[1])
    q.sign = a.sign * b.sign
    if bn_is_zero(q) then
      q.sign = 1
    end
    local rem = bn_from_int(r)
    rem.sign = bn_is_zero(rem) and 1 or a.sign
    return q, rem
  end
  -- Long division by trial: shift b leftward and binary-search the limb digit.
  local n_a = #a.d
  local n_b = #b.d
  local quot_d = {}
  for i = 1, n_a - n_b + 1 do
    quot_d[i] = 0
  end
  local rem = bn_copy(a)
  rem.sign = 1
  local pos_b = bn_copy(b)
  pos_b.sign = 1
  for shift = n_a - n_b, 0, -1 do
    -- Build b * BASE^shift.
    local sb = { sign = 1, d = {} }
    for _ = 1, shift do
      sb.d[#sb.d + 1] = 0
    end
    for i = 1, n_b do
      sb.d[#sb.d + 1] = pos_b.d[i]
    end
    local lo, hi = 0, BASE - 1
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      local trial = bn_mul(sb, bn_from_int(mid))
      if bn_cmp_mag(trial, rem) <= 0 then
        lo = mid
      else
        hi = mid - 1
      end
    end
    if lo > 0 then
      rem = bn_sub_mag(rem, bn_mul(sb, bn_from_int(lo)))
    end
    quot_d[shift + 1] = lo
  end
  local quot = bn_normalize({ sign = a.sign * b.sign, d = quot_d })
  if bn_is_zero(quot) then
    quot.sign = 1
  end
  rem = bn_normalize(rem)
  rem.sign = bn_is_zero(rem) and 1 or a.sign
  return quot, rem
end

local function bn_gcd(a, b)
  a = bn_copy(a)
  b = bn_copy(b)
  a.sign = 1
  b.sign = 1
  while not bn_is_zero(b) do
    local _, r = bn_divmod(a, b)
    a = b
    b = r
  end
  return a
end

-- ---------------------------------------------------------------------------
-- Public Calc-value API.

local function is_int(v)
  return type(v) == "table" and v.kind == "int"
end
local function is_rat(v)
  return type(v) == "table" and v.kind == "rat"
end
local function is_float(v)
  return type(v) == "table" and v.kind == "float"
end
local function is_unit(v)
  return type(v) == "table" and v.kind == "unit"
end
local function is_sym(v)
  return type(v) == "table" and v.kind == "sym"
end

local function is_numeric(v)
  return is_int(v) or is_rat(v) or is_float(v)
end

function M.is_calc(v)
  return is_int(v) or is_rat(v) or is_float(v) or is_unit(v) or is_sym(v)
end
function M.is_int(v)
  return is_int(v)
end
function M.is_float(v)
  return is_float(v)
end
function M.is_exact(v)
  return is_int(v) or is_rat(v)
end
function M.is_unit(v)
  return is_unit(v)
end
function M.is_symbol(v)
  return is_sym(v)
end

local function new_int(b)
  return { kind = "int", n = b }
end

local function reduce_rat(num, den)
  if bn_is_zero(num) then
    return new_int(bn_zero())
  end
  if den.sign < 0 then
    num = bn_neg(num)
    den = bn_neg(den)
  end
  local g = bn_gcd(num, den)
  if not (bn_is_zero(g) or (#g.d == 1 and g.d[1] == 1)) then
    num = (bn_divmod(num, g))
    den = (bn_divmod(den, g))
  end
  if #den.d == 1 and den.d[1] == 1 then
    return new_int(num)
  end
  return { kind = "rat", num = num, den = den }
end

local function as_rat_parts(v)
  if is_int(v) then
    return v.n, bn_from_int(1)
  end
  return v.num, v.den
end

function M.from_int(n)
  if n ~= math.floor(n) or math.abs(n) > 2 ^ 53 then
    error("calc.from_int: " .. tostring(n) .. " is not an exact integer")
  end
  return new_int(bn_from_int(n))
end

function M.from_float(x)
  if x ~= x then
    error("calc.from_float: NaN")
  end
  return { kind = "float", v = x }
end

function M.from_number(x)
  if x ~= x or x == math.huge or x == -math.huge then
    error("calc.from_number: non-finite " .. tostring(x))
  end
  if x == math.floor(x) and math.abs(x) < 2 ^ 53 then
    return new_int(bn_from_int(x))
  end
  return M.from_float(x)
end

function M.from_string(s)
  s = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then
    error("calc.from_string: empty input")
  end
  local sign = 1
  if s:sub(1, 1) == "-" then
    sign = -1
    s = s:sub(2)
  elseif s:sub(1, 1) == "+" then
    s = s:sub(2)
  end
  local num_s, den_s = s:match("^(%d+)/(%d+)$")
  if num_s then
    local num = bn_from_digits_string(num_s)
    local den = bn_from_digits_string(den_s)
    if bn_is_zero(den) then
      error("calc.from_string: division by zero in " .. s)
    end
    num.sign = sign
    return reduce_rat(num, den)
  end
  -- Scientific notation: 1.5e3, 6.022e23, 1E-2
  local sci_mant, sci_exp = s:match("^([%d%.]+)[eE]([+%-]?%d+)$")
  if sci_mant then
    local mant = M.from_string(sci_mant)
    if sign == -1 then
      mant = M.neg(mant)
    end
    local exp = tonumber(sci_exp)
    if exp >= 0 then
      return M.mul(mant, M.pow(M.from_int(10), exp))
    else
      return M.div(mant, M.pow(M.from_int(10), -exp))
    end
  end
  local int_part, frac_part = s:match("^(%d+)%.(%d*)$")
  if int_part then
    -- 12.5 → 125 / 10
    local digits = int_part .. frac_part
    local num = bn_from_digits_string(digits)
    local den_str = "1" .. string.rep("0", #frac_part)
    local den = bn_from_digits_string(den_str)
    num.sign = sign
    return reduce_rat(num, den)
  end
  local dec_only = s:match("^%.(%d+)$")
  if dec_only then
    local num = bn_from_digits_string(dec_only)
    local den = bn_from_digits_string("1" .. string.rep("0", #dec_only))
    num.sign = sign
    return reduce_rat(num, den)
  end
  if s:match("^%d+$") then
    local n = bn_from_digits_string(s)
    n.sign = sign
    return new_int(n)
  end
  error("calc.from_string: cannot parse " .. tostring(s))
end

local function format_float(x)
  if x == math.floor(x) and math.abs(x) < 1e15 then
    return tostring(math.floor(x))
  end
  return string.format("%g", x)
end

function M.to_string(v)
  if is_int(v) then
    return bn_to_string(v.n)
  end
  if is_rat(v) then
    return bn_to_string(v.num) .. "/" .. bn_to_string(v.den)
  end
  if is_float(v) then
    return format_float(v.v)
  end
  if is_unit(v) then
    return M.to_string(v.v) .. " " .. v.name
  end
  if is_sym(v) then
    return v.name
  end
  error("calc.to_string: not a Calc value")
end

function M.to_number(v)
  if is_int(v) then
    return tonumber(bn_to_string(v.n))
  end
  if is_rat(v) then
    return tonumber(bn_to_string(v.num)) / tonumber(bn_to_string(v.den))
  end
  if is_float(v) then
    return v.v
  end
  if is_unit(v) then
    local u = M.units()[v.name]
    local factor = u and u.factor or 1
    -- Internal value is stored in base SI; display in the unit's scale.
    return M.to_number(v.v) / factor
  end
  error("calc.to_number: not a numeric Calc value")
end

local function to_float_value(v)
  if is_float(v) then
    return v.v
  end
  if is_int(v) or is_rat(v) then
    return M.to_number(v)
  end
  error("calc: cannot coerce to float")
end

function M.neg(v)
  if is_int(v) then
    return new_int(bn_neg(v.n))
  end
  if is_rat(v) then
    return reduce_rat(bn_neg(v.num), v.den)
  end
  if is_float(v) then
    return M.from_float(-v.v)
  end
  if is_unit(v) then
    return { kind = "unit", v = M.neg(v.v), dim = v.dim, name = v.name }
  end
  error("calc.neg: not numeric")
end

function M.abs(v)
  if is_int(v) then
    local n = bn_copy(v.n)
    n.sign = 1
    return new_int(n)
  end
  if is_rat(v) then
    local num = bn_copy(v.num)
    num.sign = 1
    return reduce_rat(num, v.den)
  end
  if is_float(v) then
    return M.from_float(math.abs(v.v))
  end
  if is_unit(v) then
    return { kind = "unit", v = M.abs(v.v), dim = v.dim, name = v.name }
  end
  error("calc.abs: not numeric")
end

function M.sign(v)
  if is_int(v) then
    if bn_is_zero(v.n) then
      return 0
    end
    return v.n.sign
  end
  if is_rat(v) then
    if bn_is_zero(v.num) then
      return 0
    end
    return v.num.sign
  end
  if is_float(v) then
    if v.v == 0 then
      return 0
    end
    return v.v < 0 and -1 or 1
  end
  if is_unit(v) then
    return M.sign(v.v)
  end
  error("calc.sign: not numeric")
end

-- Promote to a common kind for binary ops: int + int → int; if either
-- side is float → float; else (some rational, no float) → rat.
local function any_float(a, b)
  return is_float(a) or is_float(b)
end

function M.cmp(a, b)
  if any_float(a, b) then
    local av, bv = to_float_value(a), to_float_value(b)
    if av < bv then
      return -1
    end
    if av > bv then
      return 1
    end
    return 0
  end
  local an, ad = as_rat_parts(a)
  local bn, bd = as_rat_parts(b)
  return bn_cmp(bn_mul(an, bd), bn_mul(bn, ad))
end

function M.eq(a, b)
  return M.cmp(a, b) == 0
end
function M.lt(a, b)
  return M.cmp(a, b) < 0
end
function M.le(a, b)
  return M.cmp(a, b) <= 0
end
function M.gt(a, b)
  return M.cmp(a, b) > 0
end
function M.ge(a, b)
  return M.cmp(a, b) >= 0
end

local function unit_op(op, a, b)
  -- Forward through units. + / -: dimensions must match.
  local av = is_unit(a) and a.v or a
  local bv = is_unit(b) and b.v or b
  if op == "add" or op == "sub" then
    if not (is_unit(a) and is_unit(b)) or not M._dims_eq(a.dim, b.dim) then
      error("calc: dimension mismatch in " .. op)
    end
    local r = (op == "add") and M.add(av, bv) or M.sub(av, bv)
    return { kind = "unit", v = r, dim = a.dim, name = a.name }
  end
  if op == "mul" then
    local dim = M._dims_combine((is_unit(a) and a.dim) or {}, (is_unit(b) and b.dim) or {}, 1)
    local r = M.mul(av, bv)
    if M._dims_zero(dim) then
      return r
    end
    return { kind = "unit", v = r, dim = dim, name = M._dim_string(dim) }
  end
  if op == "div" then
    local dim = M._dims_combine((is_unit(a) and a.dim) or {}, (is_unit(b) and b.dim) or {}, -1)
    local r = M.div(av, bv)
    if M._dims_zero(dim) then
      return r
    end
    return { kind = "unit", v = r, dim = dim, name = M._dim_string(dim) }
  end
  error("calc: unsupported unit op " .. op)
end

function M.add(a, b)
  if is_unit(a) or is_unit(b) then
    return unit_op("add", a, b)
  end
  if any_float(a, b) then
    return M.from_float(to_float_value(a) + to_float_value(b))
  end
  if is_int(a) and is_int(b) then
    return new_int(bn_add(a.n, b.n))
  end
  local an, ad = as_rat_parts(a)
  local bn, bd = as_rat_parts(b)
  return reduce_rat(bn_add(bn_mul(an, bd), bn_mul(bn, ad)), bn_mul(ad, bd))
end

function M.sub(a, b)
  if is_unit(a) or is_unit(b) then
    return unit_op("sub", a, b)
  end
  return M.add(a, M.neg(b))
end

function M.mul(a, b)
  if is_unit(a) or is_unit(b) then
    return unit_op("mul", a, b)
  end
  if any_float(a, b) then
    return M.from_float(to_float_value(a) * to_float_value(b))
  end
  if is_int(a) and is_int(b) then
    return new_int(bn_mul(a.n, b.n))
  end
  local an, ad = as_rat_parts(a)
  local bn, bd = as_rat_parts(b)
  return reduce_rat(bn_mul(an, bn), bn_mul(ad, bd))
end

function M.div(a, b)
  if is_unit(a) or is_unit(b) then
    return unit_op("div", a, b)
  end
  if any_float(a, b) then
    local bv = to_float_value(b)
    if bv == 0 then
      error("calc: division by zero")
    end
    return M.from_float(to_float_value(a) / bv)
  end
  local bn, bd = as_rat_parts(b)
  if bn_is_zero(bn) then
    error("calc: division by zero")
  end
  local an, ad = as_rat_parts(a)
  return reduce_rat(bn_mul(an, bd), bn_mul(ad, bn))
end

function M.mod(a, b)
  if any_float(a, b) then
    local bv = to_float_value(b)
    if bv == 0 then
      error("calc: modulo by zero")
    end
    return M.from_float(to_float_value(a) % bv)
  end
  if not (is_int(a) and is_int(b)) then
    error("calc.mod: integers or floats only")
  end
  if bn_is_zero(b.n) then
    error("calc: modulo by zero")
  end
  local _, r = bn_divmod(a.n, b.n)
  return new_int(r)
end

function M.pow(v, n)
  -- Float exponent → float result.
  if (type(n) == "table" and is_float(n)) or is_float(v) then
    return M.from_float(to_float_value(v) ^ to_float_value(n))
  end
  -- Integer exponent: exact arithmetic.
  if type(n) == "table" then
    if is_int(n) then
      n = tonumber(bn_to_string(n.n))
    elseif is_rat(n) then
      -- Rational exponent → drop to float.
      return M.from_float(to_float_value(v) ^ to_float_value(n))
    end
    if not n or n ~= math.floor(n) then
      error("calc.pow: exponent out of range")
    end
  end
  if n < 0 then
    return M.div(M.from_int(1), M.pow(v, -n))
  end
  if n == 0 then
    return M.from_int(1)
  end
  local result = M.from_int(1)
  local base = v
  while n > 0 do
    if n % 2 == 1 then
      result = M.mul(result, base)
    end
    base = M.mul(base, base)
    n = math.floor(n / 2)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Math functions. Most return float — they're transcendental or
-- generally produce irrational results. sqrt of a perfect square stays
-- exact.

local function as_float(v)
  return to_float_value(v)
end

function M.sqrt(v)
  if is_int(v) and v.n.sign >= 0 then
    -- Integer square root via Newton's method; check for perfect square.
    local x = M.from_float(math.sqrt(M.to_number(v)))
    local guess = M.from_int(math.floor(M.to_number(x)))
    -- One Newton refinement; then check exactness.
    if not bn_is_zero(v.n) then
      guess = M.div(M.add(guess, M.div(v, guess)), M.from_int(2))
      if M.is_int(guess) and M.eq(M.mul(guess, guess), v) then
        return guess
      end
    else
      return M.from_int(0)
    end
  end
  return M.from_float(math.sqrt(as_float(v)))
end

function M.cbrt(v)
  return M.from_float(as_float(v) ^ (1 / 3))
end
function M.exp(v)
  return M.from_float(math.exp(as_float(v)))
end
function M.ln(v)
  return M.from_float(math.log(as_float(v)))
end
function M.log10(v)
  return M.from_float(math.log(as_float(v)) / math.log(10))
end
function M.log2(v)
  return M.from_float(math.log(as_float(v)) / math.log(2))
end
function M.log(v, base)
  if base == nil then
    return M.ln(v)
  end
  return M.from_float(math.log(as_float(v)) / math.log(as_float(base)))
end
function M.sin(v)
  return M.from_float(math.sin(as_float(v)))
end
function M.cos(v)
  return M.from_float(math.cos(as_float(v)))
end
function M.tan(v)
  return M.from_float(math.tan(as_float(v)))
end
function M.asin(v)
  return M.from_float(math.asin(as_float(v)))
end
function M.acos(v)
  return M.from_float(math.acos(as_float(v)))
end
function M.atan(v)
  return M.from_float(math.atan(as_float(v)))
end
function M.atan2(y, x)
  return M.from_float(math.atan(as_float(y), as_float(x)))
end
function M.sinh(v)
  local x = as_float(v)
  return M.from_float((math.exp(x) - math.exp(-x)) / 2)
end
function M.cosh(v)
  local x = as_float(v)
  return M.from_float((math.exp(x) + math.exp(-x)) / 2)
end
function M.tanh(v)
  local x = as_float(v)
  local e1 = math.exp(x)
  local e2 = math.exp(-x)
  return M.from_float((e1 - e2) / (e1 + e2))
end

function M.ceil(v)
  if is_int(v) then
    return v
  end
  if is_rat(v) then
    local q, r = bn_divmod(v.num, v.den)
    if bn_is_zero(r) or v.num.sign < 0 then
      return new_int(q)
    end
    return new_int(bn_add(q, bn_from_int(1)))
  end
  return M.from_float(math.ceil(as_float(v)))
end

function M.floor(v)
  if is_int(v) then
    return v
  end
  if is_rat(v) then
    local q, r = bn_divmod(v.num, v.den)
    if bn_is_zero(r) or v.num.sign > 0 then
      return new_int(q)
    end
    return new_int(bn_sub(q, bn_from_int(1)))
  end
  return M.from_float(math.floor(as_float(v)))
end

function M.trunc(v)
  if is_int(v) then
    return v
  end
  if is_rat(v) then
    return new_int((bn_divmod(v.num, v.den)))
  end
  local x = as_float(v)
  return M.from_float(x >= 0 and math.floor(x) or math.ceil(x))
end

function M.round(v)
  if is_int(v) then
    return v
  end
  if is_rat(v) then
    -- round half away from zero
    local doubled = bn_mul(v.num, bn_from_int(2))
    doubled.sign = math.abs(doubled.sign)
    local q, _ = bn_divmod(doubled, v.den)
    local sign = v.num.sign
    -- Adjust sign and halve.
    local r = (bn_divmod(bn_add(q, bn_from_int(1)), bn_from_int(2)))
    r.sign = sign
    return new_int(r)
  end
  local x = as_float(v)
  return M.from_float(x >= 0 and math.floor(x + 0.5) or -math.floor(-x + 0.5))
end

function M.gcd(a, b)
  if not (is_int(a) and is_int(b)) then
    error("calc.gcd: integers only")
  end
  return new_int(bn_gcd(a.n, b.n))
end

function M.lcm(a, b)
  if not (is_int(a) and is_int(b)) then
    error("calc.lcm: integers only")
  end
  if bn_is_zero(a.n) or bn_is_zero(b.n) then
    return M.from_int(0)
  end
  local g = bn_gcd(a.n, b.n)
  local p = bn_mul(a.n, b.n)
  p.sign = 1
  return new_int((bn_divmod(p, g)))
end

function M.factorial(n)
  if not is_int(n) or n.n.sign < 0 then
    error("calc.factorial: non-negative integer required")
  end
  local k = tonumber(bn_to_string(n.n))
  if not k then
    error("calc.factorial: too big to enumerate")
  end
  local r = M.from_int(1)
  for i = 2, k do
    r = M.mul(r, M.from_int(i))
  end
  return r
end

function M.binomial(n, k)
  if not (is_int(n) and is_int(k)) then
    error("calc.binomial: integers only")
  end
  if M.lt(k, M.from_int(0)) or M.gt(k, n) then
    return M.from_int(0)
  end
  -- C(n,k) = n! / (k! * (n-k)!), computed via the multiplicative form
  local nn = tonumber(bn_to_string(n.n))
  local kk = tonumber(bn_to_string(k.n))
  if not (nn and kk) then
    error("calc.binomial: argument too large")
  end
  if kk > nn - kk then
    kk = nn - kk
  end
  local r = M.from_int(1)
  for i = 1, kk do
    r = M.mul(r, M.from_int(nn - i + 1))
    r = M.div(r, M.from_int(i))
  end
  return r
end

-- ---------------------------------------------------------------------------
-- Logical and conditional. 0 is false; everything else is true (Calc style).

function M.is_true(v)
  if is_numeric(v) then
    return M.sign(v) ~= 0
  end
  return false
end

function M.lnot(v)
  return M.is_true(v) and M.from_int(0) or M.from_int(1)
end
function M.land(a, b)
  return (M.is_true(a) and M.is_true(b)) and M.from_int(1) or M.from_int(0)
end
function M.lor(a, b)
  return (M.is_true(a) or M.is_true(b)) and M.from_int(1) or M.from_int(0)
end

function M.ifte(cond, then_v, else_v)
  return M.is_true(cond) and then_v or else_v
end

-- ---------------------------------------------------------------------------
-- Aggregations. Argument is a list of Calc values; result is a Calc value
-- (or nil when the input is empty and the aggregation has no zero).

local function _vec_or_error(vs, name)
  if type(vs) ~= "table" or vs.kind then
    error("calc." .. name .. ": expected a list of Calc values")
  end
end

function M.vsum(vs)
  _vec_or_error(vs, "vsum")
  local s = M.from_int(0)
  for _, v in ipairs(vs) do
    s = M.add(s, v)
  end
  return s
end

function M.vproduct(vs)
  _vec_or_error(vs, "vproduct")
  local s = M.from_int(1)
  for _, v in ipairs(vs) do
    s = M.mul(s, v)
  end
  return s
end

function M.vmean(vs)
  _vec_or_error(vs, "vmean")
  if #vs == 0 then
    return nil
  end
  return M.div(M.vsum(vs), M.from_int(#vs))
end

function M.vmax(vs)
  _vec_or_error(vs, "vmax")
  if #vs == 0 then
    return nil
  end
  local m = vs[1]
  for i = 2, #vs do
    if M.gt(vs[i], m) then
      m = vs[i]
    end
  end
  return m
end

function M.vmin(vs)
  _vec_or_error(vs, "vmin")
  if #vs == 0 then
    return nil
  end
  local m = vs[1]
  for i = 2, #vs do
    if M.lt(vs[i], m) then
      m = vs[i]
    end
  end
  return m
end

function M.vmaxabs(vs)
  _vec_or_error(vs, "vmaxabs")
  if #vs == 0 then
    return nil
  end
  local m = M.abs(vs[1])
  for i = 2, #vs do
    local a = M.abs(vs[i])
    if M.gt(a, m) then
      m = a
    end
  end
  return m
end

function M.vlen(vs)
  _vec_or_error(vs, "vlen")
  return M.from_int(#vs)
end
M.vcount = M.vlen

function M.vmedian(vs)
  _vec_or_error(vs, "vmedian")
  if #vs == 0 then
    return nil
  end
  local sorted = {}
  for i, v in ipairs(vs) do
    sorted[i] = v
  end
  table.sort(sorted, function(a, b)
    return M.lt(a, b)
  end)
  local n = #sorted
  if n % 2 == 1 then
    return sorted[(n + 1) / 2]
  end
  return M.div(M.add(sorted[n / 2], sorted[n / 2 + 1]), M.from_int(2))
end

function M.vvar(vs)
  _vec_or_error(vs, "vvar")
  if #vs < 2 then
    return nil
  end
  local mean = M.vmean(vs)
  local sum = M.from_int(0)
  for _, v in ipairs(vs) do
    local d = M.sub(v, mean)
    sum = M.add(sum, M.mul(d, d))
  end
  -- sample variance: divide by N-1
  return M.div(sum, M.from_int(#vs - 1))
end

function M.vsdev(vs)
  local var = M.vvar(vs)
  if var == nil then
    return nil
  end
  return M.sqrt(var)
end

-- ---------------------------------------------------------------------------
-- Units. SI base + decimal prefixes + common derived. Each unit table
-- entry maps name → {factor, dim} where factor is a Lua number scaling
-- value-in-this-unit to value-in-base-SI, and dim is a {axis = power}
-- map over the seven SI base axes.

local DIM_AXES = { "m", "kg", "s", "A", "K", "mol", "cd" }

local function dim_zero()
  local d = {}
  for _, a in ipairs(DIM_AXES) do
    d[a] = 0
  end
  return d
end

local function dim_copy(d)
  local out = dim_zero()
  for k, v in pairs(d or {}) do
    out[k] = v
  end
  return out
end

function M._dims_eq(a, b)
  for _, ax in ipairs(DIM_AXES) do
    if (a and a[ax] or 0) ~= (b and b[ax] or 0) then
      return false
    end
  end
  return true
end

function M._dims_zero(d)
  for _, ax in ipairs(DIM_AXES) do
    if (d and d[ax] or 0) ~= 0 then
      return false
    end
  end
  return true
end

function M._dims_combine(a, b, sign_b)
  local out = dim_copy(a)
  for _, ax in ipairs(DIM_AXES) do
    out[ax] = (out[ax] or 0) + (sign_b * (b[ax] or 0))
  end
  return out
end

function M._dim_string(d)
  local parts_pos, parts_neg = {}, {}
  for _, ax in ipairs(DIM_AXES) do
    local p = d[ax] or 0
    if p > 0 then
      parts_pos[#parts_pos + 1] = (p == 1) and ax or (ax .. "^" .. p)
    elseif p < 0 then
      parts_neg[#parts_neg + 1] = (p == -1) and ax or (ax .. "^" .. -p)
    end
  end
  local s = #parts_pos > 0 and table.concat(parts_pos, "·") or "1"
  if #parts_neg > 0 then
    s = s .. "/" .. table.concat(parts_neg, "·")
  end
  return s
end

local function dim(spec)
  local d = dim_zero()
  for ax, p in pairs(spec) do
    d[ax] = p
  end
  return d
end

local UNITS = {}
local function add_unit(name, factor, dimspec)
  UNITS[name] = { factor = factor, dim = dim(dimspec) }
end

-- SI base units (factor = 1).
add_unit("m", 1, { m = 1 })
add_unit("kg", 1, { kg = 1 })
add_unit("g", 1e-3, { kg = 1 })
add_unit("s", 1, { s = 1 })
add_unit("A", 1, { A = 1 })
add_unit("K", 1, { K = 1 })
add_unit("mol", 1, { mol = 1 })
add_unit("cd", 1, { cd = 1 })

-- Derived (selected — the ones that matter for org tables).
add_unit("Hz", 1, { s = -1 })
add_unit("N", 1, { kg = 1, m = 1, s = -2 })
add_unit("Pa", 1, { kg = 1, m = -1, s = -2 })
add_unit("J", 1, { kg = 1, m = 2, s = -2 })
add_unit("W", 1, { kg = 1, m = 2, s = -3 })
add_unit("C", 1, { A = 1, s = 1 })
add_unit("V", 1, { kg = 1, m = 2, s = -3, A = -1 })
add_unit("ohm", 1, { kg = 1, m = 2, s = -3, A = -2 })
add_unit("F", 1, { kg = -1, m = -2, s = 4, A = 2 })
add_unit("L", 1e-3, { m = 3 })

-- Time conventions.
add_unit("min", 60, { s = 1 })
add_unit("hr", 3600, { s = 1 })
add_unit("h", 3600, { s = 1 })
add_unit("day", 86400, { s = 1 })
add_unit("yr", 31557600, { s = 1 }) -- Julian year

-- Length conventions (non-prefixable; the prefix sweep below handles km, mm…).
add_unit("in", 0.0254, { m = 1 })
add_unit("ft", 0.3048, { m = 1 })
add_unit("yd", 0.9144, { m = 1 })
add_unit("mi", 1609.344, { m = 1 })

-- Mass conventions.
add_unit("lb", 0.45359237, { kg = 1 })
add_unit("oz", 0.028349523125, { kg = 1 })
add_unit("t", 1000, { kg = 1 })

-- Decimal prefix sweep over a curated set of base units. Done inline
-- so prefixed names like km, mg, mL, kHz appear in the table.
local PREFIXES = {
  Y = 1e24,
  Z = 1e21,
  E = 1e18,
  P = 1e15,
  T = 1e12,
  G = 1e9,
  M = 1e6,
  k = 1e3,
  h = 1e2,
  da = 10,
  d = 0.1,
  c = 0.01,
  m = 0.001,
  u = 1e-6,
  n = 1e-9,
  p = 1e-12,
  f = 1e-15,
  a = 1e-18,
}
for _, base in ipairs({
  "m",
  "g",
  "s",
  "A",
  "K",
  "mol",
  "cd",
  "Hz",
  "N",
  "Pa",
  "J",
  "W",
  "C",
  "V",
  "ohm",
  "F",
  "L",
}) do
  for prefix, factor in pairs(PREFIXES) do
    local name = prefix .. base
    if UNITS[name] == nil then
      local b = UNITS[base]
      add_unit(name, factor * b.factor, b.dim)
    end
  end
end

function M.units()
  return UNITS
end

-- Build a unit-typed Calc value. Internally `v` is stored in BASE SI
-- (multiplied by the unit's factor) so arithmetic between values in
-- different scales of the same dimension is just numeric add/sub.
-- The `name` field records the user's preferred display unit.
function M.with_unit(v, name)
  local u = UNITS[name]
  if not u then
    error("calc: unknown unit " .. name)
  end
  if not is_numeric(v) then
    error("calc: unit attached to non-numeric")
  end
  local base_v = u.factor == 1 and v or M.mul(v, M.from_float(u.factor))
  return { kind = "unit", v = base_v, dim = u.dim, name = name }
end

function M.convert(v, target)
  if not is_unit(v) then
    error("calc.convert: source must have a unit")
  end
  local u = UNITS[target]
  if not u then
    error("calc.convert: unknown unit " .. target)
  end
  if not M._dims_eq(v.dim, u.dim) then
    error(
      "calc.convert: incompatible dimensions: "
        .. M._dim_string(v.dim)
        .. " → "
        .. M._dim_string(u.dim)
    )
  end
  -- Internal stays in base SI; just relabel the display unit.
  return { kind = "unit", v = v.v, dim = u.dim, name = target }
end

-- ---------------------------------------------------------------------------
-- Symbolic. Bare variables (`x`, `y`) and a small set of simplification
-- rules so that literal expressions like `x + 0`, `0 * y`, `x - x`
-- reduce to a numeric or symbolic atom rather than crashing the
-- evaluator.

function M.sym(name)
  return { kind = "sym", name = name }
end

local function is_zero_calc(v)
  return is_numeric(v) and M.sign(v) == 0
end
local function is_one_calc(v)
  return is_int(v) and #v.n.d == 1 and v.n.d[1] == 1 and v.n.sign == 1
end

local function sym_eq(a, b)
  return is_sym(a) and is_sym(b) and a.name == b.name
end

-- Try to simplify a binary op result. Returns the simplified value or
-- nil if no rule applies (caller should handle the general case).
function M.simplify_binop(op, a, b)
  if op == "+" then
    if is_zero_calc(a) then
      return b
    end
    if is_zero_calc(b) then
      return a
    end
    if sym_eq(a, b) then
      -- x + x = 2*x : keep as Mul of int * sym, but we don't have that
      -- node type. Leave for the evaluator.
    end
    return nil
  end
  if op == "-" then
    if is_zero_calc(b) then
      return a
    end
    if sym_eq(a, b) then
      return M.from_int(0)
    end
    return nil
  end
  if op == "*" then
    if is_zero_calc(a) or is_zero_calc(b) then
      return M.from_int(0)
    end
    if is_one_calc(a) then
      return b
    end
    if is_one_calc(b) then
      return a
    end
    return nil
  end
  if op == "/" then
    if is_zero_calc(a) and not is_zero_calc(b) then
      return M.from_int(0)
    end
    if is_one_calc(b) then
      return a
    end
    if sym_eq(a, b) then
      return M.from_int(1)
    end
    return nil
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Financial functions. Sign convention: outflows negative, inflows
-- positive (Excel / spreadsheet convention). Computed as Lua doubles
-- and returned as Calc floats — financial workloads almost never need
-- bignum, and exact rational arithmetic over (1 + rate)^nper is
-- typically not what users want anyway.

local function _f(v)
  return to_float_value(v)
end

-- Periodic-payment formula. PMT = -pv * rate * (1+rate)^nper /
-- ((1+rate)^nper - 1).  Rate=0 short-circuits to -pv / nper.
function M.pmt(rate, nper, pv, fv, when)
  local r, n = _f(rate), _f(nper)
  local pv_v = pv ~= nil and _f(pv) or 0
  local fv_v = fv ~= nil and _f(fv) or 0
  local due = when and _f(when) or 0 -- 0 = end of period, 1 = beginning
  if r == 0 then
    return M.from_float(-(pv_v + fv_v) / n)
  end
  local k = (1 + r) ^ n
  local pmt = -(pv_v * k + fv_v) * r / ((k - 1) * (1 + r * due))
  return M.from_float(pmt)
end

-- Future value: FV = -(pv * (1+r)^n + pmt * ((1+r)^n - 1) / r).
function M.fv(rate, nper, pmt, pv, when)
  local r, n = _f(rate), _f(nper)
  local pmt_v = pmt ~= nil and _f(pmt) or 0
  local pv_v = pv ~= nil and _f(pv) or 0
  local due = when and _f(when) or 0
  if r == 0 then
    return M.from_float(-(pv_v + pmt_v * n))
  end
  local k = (1 + r) ^ n
  local fv = -(pv_v * k + pmt_v * (1 + r * due) * (k - 1) / r)
  return M.from_float(fv)
end

-- Present value: PV = -(fv + pmt * ((1+r)^n - 1) / r) / (1+r)^n.
function M.pv(rate, nper, pmt, fv, when)
  local r, n = _f(rate), _f(nper)
  local pmt_v = pmt ~= nil and _f(pmt) or 0
  local fv_v = fv ~= nil and _f(fv) or 0
  local due = when and _f(when) or 0
  if r == 0 then
    return M.from_float(-(fv_v + pmt_v * n))
  end
  local k = (1 + r) ^ n
  local pv = -(fv_v + pmt_v * (1 + r * due) * (k - 1) / r) / k
  return M.from_float(pv)
end

-- NPV = sum(cf[t] / (1+rate)^t) for t=1..N.  Cashflows is a list of
-- Calc values; the result is a Calc float.
function M.npv(rate, cashflows)
  local r = _f(rate)
  local sum = 0
  for t, cf in ipairs(cashflows) do
    sum = sum + _f(cf) / (1 + r) ^ t
  end
  return M.from_float(sum)
end

-- IRR: solve NPV(r) = 0 using Newton-Raphson. Cashflows include the
-- initial outflow at t=0 (typically negative), then inflows at t=1..N.
function M.irr(cashflows, guess)
  local r = guess and _f(guess) or 0.1
  local n = #cashflows
  local function npv(rate)
    local s = 0
    for t = 1, n do
      s = s + _f(cashflows[t]) / (1 + rate) ^ (t - 1)
    end
    return s
  end
  local function dnpv(rate)
    local s = 0
    for t = 2, n do
      s = s - (t - 1) * _f(cashflows[t]) / (1 + rate) ^ t
    end
    return s
  end
  for _ = 1, 100 do
    local f = npv(r)
    if math.abs(f) < 1e-10 then
      return M.from_float(r)
    end
    local fd = dnpv(r)
    if fd == 0 then
      break
    end
    local r_new = r - f / fd
    if math.abs(r_new - r) < 1e-12 then
      return M.from_float(r_new)
    end
    r = r_new
  end
  error("calc.irr: did not converge")
end

-- ---------------------------------------------------------------------------
-- Big-integer primality and factoring. Trial division first (fast for
-- small primes); Miller-Rabin probabilistic test; Pollard's rho for
-- large composites.

local SMALL_PRIMES = {
  2,
  3,
  5,
  7,
  11,
  13,
  17,
  19,
  23,
  29,
  31,
  37,
  41,
  43,
  47,
  53,
  59,
  61,
  67,
  71,
  73,
  79,
  83,
  89,
  97,
  101,
  103,
  107,
  109,
  113,
}

local function bn_one()
  return bn_from_int(1)
end

-- Modular multiplication for bignums via long multiplication then mod.
local function bn_mod(a, m)
  return (select(2, bn_divmod(a, m)))
end

local function bn_mod_mul(a, b, m)
  return bn_mod(bn_mul(a, b), m)
end

local function bn_mod_pow(base, exp, m)
  local result = bn_one()
  base = bn_mod(base, m)
  -- exp is treated as a non-negative bignum; iterate via bit shifts.
  local e = bn_copy(exp)
  e.sign = 1
  while not bn_is_zero(e) do
    -- low bit of e: e mod 2
    local _, r = bn_divmod(e, bn_from_int(2))
    if not bn_is_zero(r) then
      result = bn_mod_mul(result, base, m)
    end
    base = bn_mod_mul(base, base, m)
    e = (bn_divmod(e, bn_from_int(2)))
  end
  return result
end

-- Miller-Rabin with deterministic witnesses for n < 3 317 044 064 679 887 385 961 981.
-- For larger n we use 20 random-ish bases derived from small primes
-- (probability of false positive < 4^-20 ≈ 10^-12 per call).
local function miller_rabin(n)
  if bn_cmp(n, bn_from_int(2)) < 0 then
    return false
  end
  for _, p in ipairs({ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 }) do
    local pp = bn_from_int(p)
    if bn_cmp(n, pp) == 0 then
      return true
    end
    local _, r = bn_divmod(n, pp)
    if bn_is_zero(r) then
      return false
    end
  end
  -- write n-1 as d * 2^s
  local d = bn_sub(n, bn_one())
  local s = 0
  while true do
    local q, r = bn_divmod(d, bn_from_int(2))
    if not bn_is_zero(r) then
      break
    end
    d = q
    s = s + 1
  end
  for _, a in ipairs({ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 }) do
    local x = bn_mod_pow(bn_from_int(a), d, n)
    if not (bn_cmp(x, bn_one()) == 0 or bn_cmp(x, bn_sub(n, bn_one())) == 0) then
      local composite = true
      for _ = 1, s - 1 do
        x = bn_mod_mul(x, x, n)
        if bn_cmp(x, bn_sub(n, bn_one())) == 0 then
          composite = false
          break
        end
      end
      if composite then
        return false
      end
    end
  end
  return true
end

function M.is_prime(v)
  if not is_int(v) then
    error("calc.is_prime: integer required")
  end
  return miller_rabin(v.n)
end

-- Pollard's rho factoring with cycle detection. Returns a non-trivial
-- factor of `n` (assumed composite, > 1, not prime).
local function pollard_rho(n)
  if bn_is_zero(bn_mod(n, bn_from_int(2))) then
    return bn_from_int(2)
  end
  local one = bn_one()
  local two = bn_from_int(2)
  for c_seed = 1, 100 do
    local c = bn_from_int(c_seed)
    local x = bn_from_int(2)
    local y = bn_from_int(2)
    local d = one
    while bn_cmp(d, one) == 0 do
      x = bn_mod(bn_add(bn_mod_mul(x, x, n), c), n)
      y = bn_mod(bn_add(bn_mod_mul(y, y, n), c), n)
      y = bn_mod(bn_add(bn_mod_mul(y, y, n), c), n)
      local diff = bn_sub(x, y)
      diff.sign = 1
      d = bn_gcd(diff, n)
    end
    if bn_cmp(d, n) ~= 0 then
      return d
    end
  end
  error("calc.factor: pollard rho failed")
end

-- Return the prime factorisation of `v` as a sorted list of Calc-int
-- factors (with multiplicity). E.g. prime_factors(12) -> {2, 2, 3}.
function M.prime_factors(v)
  if not is_int(v) then
    error("calc.factor: integer required")
  end
  local n = bn_copy(v.n)
  n.sign = 1
  if bn_cmp(n, bn_one()) <= 0 then
    return {}
  end
  local out = {}
  -- Trial division by small primes for speed.
  for _, p in ipairs(SMALL_PRIMES) do
    local pp = bn_from_int(p)
    while bn_cmp(n, pp) >= 0 do
      local q, r = bn_divmod(n, pp)
      if not bn_is_zero(r) then
        break
      end
      out[#out + 1] = new_int(pp)
      n = q
    end
    if bn_cmp(n, bn_one()) == 0 then
      return out
    end
  end
  -- Recursive factor via primality test + rho.
  local function recurse(m)
    if bn_cmp(m, bn_one()) == 0 then
      return
    end
    if miller_rabin(m) then
      out[#out + 1] = new_int(m)
      return
    end
    local d = pollard_rho(m)
    recurse(d)
    recurse((bn_divmod(m, d)))
  end
  recurse(n)
  table.sort(out, function(a, b)
    return M.lt(a, b)
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- Matrix linear algebra. A matrix is { kind = "mat", rows = R, cols = C,
-- d = { [r] = { [c] = Calc } } } — element type is Calc, so determinants
-- of integer matrices stay exact.

local function is_mat(v)
  return type(v) == "table" and v.kind == "mat"
end
function M.is_matrix(v)
  return is_mat(v)
end

local function mat_from_table(t)
  -- t is a list of lists of (Calc value | Lua number).
  local rows = #t
  if rows == 0 then
    error("calc.matrix: empty")
  end
  local cols = #t[1]
  local d = {}
  for i = 1, rows do
    if #t[i] ~= cols then
      error("calc.matrix: ragged rows")
    end
    d[i] = {}
    for j = 1, cols do
      local x = t[i][j]
      if type(x) == "number" then
        d[i][j] = M.from_number(x)
      elseif M.is_calc(x) then
        d[i][j] = x
      else
        error("calc.matrix: non-numeric cell at [" .. i .. "," .. j .. "]")
      end
    end
  end
  return { kind = "mat", rows = rows, cols = cols, d = d }
end

function M.matrix(t)
  return mat_from_table(t)
end

local function mat_copy(a)
  local d = {}
  for i = 1, a.rows do
    d[i] = {}
    for j = 1, a.cols do
      d[i][j] = a.d[i][j]
    end
  end
  return { kind = "mat", rows = a.rows, cols = a.cols, d = d }
end

function M.transpose(a)
  if not is_mat(a) then
    error("calc.transpose: matrix required")
  end
  local d = {}
  for i = 1, a.cols do
    d[i] = {}
    for j = 1, a.rows do
      d[i][j] = a.d[j][i]
    end
  end
  return { kind = "mat", rows = a.cols, cols = a.rows, d = d }
end

function M.mat_add(a, b)
  if not (is_mat(a) and is_mat(b)) then
    error("calc.mat_add: matrices")
  end
  if a.rows ~= b.rows or a.cols ~= b.cols then
    error("calc.mat_add: shape mismatch")
  end
  local d = {}
  for i = 1, a.rows do
    d[i] = {}
    for j = 1, a.cols do
      d[i][j] = M.add(a.d[i][j], b.d[i][j])
    end
  end
  return { kind = "mat", rows = a.rows, cols = a.cols, d = d }
end

function M.mat_sub(a, b)
  if not (is_mat(a) and is_mat(b)) then
    error("calc.mat_sub: matrices")
  end
  if a.rows ~= b.rows or a.cols ~= b.cols then
    error("calc.mat_sub: shape mismatch")
  end
  local d = {}
  for i = 1, a.rows do
    d[i] = {}
    for j = 1, a.cols do
      d[i][j] = M.sub(a.d[i][j], b.d[i][j])
    end
  end
  return { kind = "mat", rows = a.rows, cols = a.cols, d = d }
end

function M.mat_mul(a, b)
  if not (is_mat(a) and is_mat(b)) then
    error("calc.mat_mul: matrices")
  end
  if a.cols ~= b.rows then
    error("calc.mat_mul: shape mismatch (" .. a.cols .. " vs " .. b.rows .. ")")
  end
  local d = {}
  for i = 1, a.rows do
    d[i] = {}
    for j = 1, b.cols do
      local s = M.from_int(0)
      for k = 1, a.cols do
        s = M.add(s, M.mul(a.d[i][k], b.d[k][j]))
      end
      d[i][j] = s
    end
  end
  return { kind = "mat", rows = a.rows, cols = b.cols, d = d }
end

-- LU decomposition via Doolittle with partial pivoting. Returns L, U,
-- and a permutation as a list of row indices, plus the parity of the
-- permutation (+1 / -1) for det.
local function lu_decompose(a)
  if a.rows ~= a.cols then
    error("calc.lu: square matrix required")
  end
  local n = a.rows
  local U = mat_copy(a)
  local L = mat_copy(a)
  for i = 1, n do
    for j = 1, n do
      L.d[i][j] = (i == j) and M.from_int(1) or M.from_int(0)
    end
  end
  local perm = {}
  for i = 1, n do
    perm[i] = i
  end
  local sign = 1
  for k = 1, n do
    -- partial pivot: pick row with largest |U[i][k]| for numerical stability
    local max_i, max_v = k, M.abs(U.d[k][k])
    for i = k + 1, n do
      local v = M.abs(U.d[i][k])
      if M.gt(v, max_v) then
        max_i, max_v = i, v
      end
    end
    if M.sign(max_v) == 0 then
      return nil, "singular"
    end
    if max_i ~= k then
      U.d[k], U.d[max_i] = U.d[max_i], U.d[k]
      perm[k], perm[max_i] = perm[max_i], perm[k]
      sign = -sign
      -- Swap the already-computed L below the diagonal too.
      for j = 1, k - 1 do
        L.d[k][j], L.d[max_i][j] = L.d[max_i][j], L.d[k][j]
      end
    end
    for i = k + 1, n do
      local factor = M.div(U.d[i][k], U.d[k][k])
      L.d[i][k] = factor
      for j = k, n do
        U.d[i][j] = M.sub(U.d[i][j], M.mul(factor, U.d[k][j]))
      end
    end
  end
  return { L = L, U = U, perm = perm, sign = sign }
end

function M.lu(a)
  if not is_mat(a) then
    error("calc.lu: matrix required")
  end
  return lu_decompose(a)
end

function M.det(a)
  if not is_mat(a) then
    error("calc.det: matrix required")
  end
  if a.rows ~= a.cols then
    error("calc.det: square matrix required")
  end
  local lu, err = lu_decompose(a)
  if not lu then
    if err == "singular" then
      return M.from_int(0)
    end
    error("calc.det: " .. err)
  end
  local d = M.from_int(lu.sign)
  for i = 1, a.rows do
    d = M.mul(d, lu.U.d[i][i])
  end
  return d
end

function M.inv(a)
  if not is_mat(a) then
    error("calc.inv: matrix required")
  end
  if a.rows ~= a.cols then
    error("calc.inv: square matrix required")
  end
  local n = a.rows
  -- Build [A | I], do Gauss-Jordan, read [I | A^-1].
  local m = {}
  for i = 1, n do
    m[i] = {}
    for j = 1, n do
      m[i][j] = a.d[i][j]
    end
    for j = 1, n do
      m[i][n + j] = (i == j) and M.from_int(1) or M.from_int(0)
    end
  end
  for k = 1, n do
    local max_i, max_v = k, M.abs(m[k][k])
    for i = k + 1, n do
      local v = M.abs(m[i][k])
      if M.gt(v, max_v) then
        max_i, max_v = i, v
      end
    end
    if M.sign(max_v) == 0 then
      error("calc.inv: singular matrix")
    end
    if max_i ~= k then
      m[k], m[max_i] = m[max_i], m[k]
    end
    local pivot = m[k][k]
    for j = 1, 2 * n do
      m[k][j] = M.div(m[k][j], pivot)
    end
    for i = 1, n do
      if i ~= k and M.sign(m[i][k]) ~= 0 then
        local factor = m[i][k]
        for j = 1, 2 * n do
          m[i][j] = M.sub(m[i][j], M.mul(factor, m[k][j]))
        end
      end
    end
  end
  local d = {}
  for i = 1, n do
    d[i] = {}
    for j = 1, n do
      d[i][j] = m[i][n + j]
    end
  end
  return { kind = "mat", rows = n, cols = n, d = d }
end

-- ---------------------------------------------------------------------------
-- Eigenvalues. Power iteration + deflation. Works reliably for
-- symmetric matrices with distinct real eigenvalues; for general
-- matrices the spectrum may have complex eigenvalues that this
-- routine cannot recover. A QR-with-shifts implementation would
-- handle the general case (NOT_IMPLEMENTED).

local function vec_dot(u, w, n)
  local s = M.from_int(0)
  for i = 1, n do
    s = M.add(s, M.mul(u[i], w[i]))
  end
  return s
end

local function vec_norm(v, n)
  return M.sqrt(vec_dot(v, v, n))
end

local function vec_scale(v, s, n)
  local out = {}
  for i = 1, n do
    out[i] = M.div(v[i], s)
  end
  return out
end

local function mat_vec(A, v, n)
  local out = {}
  for i = 1, n do
    local s = M.from_int(0)
    for j = 1, n do
      s = M.add(s, M.mul(A.d[i][j], v[j]))
    end
    out[i] = s
  end
  return out
end

-- Subtract λ·v·v^T from a square matrix (symmetric deflation).
local function deflate(A, lambda, v, n)
  local d = {}
  for i = 1, n do
    d[i] = {}
    for j = 1, n do
      d[i][j] = M.sub(A.d[i][j], M.mul(M.mul(lambda, v[i]), v[j]))
    end
  end
  return { kind = "mat", rows = n, cols = n, d = d }
end

local function power_iteration(A, n, max_iter, tol)
  max_iter = max_iter or 500
  tol = tol or 1e-10
  -- Deterministic starting vector to keep tests reproducible.
  local v = {}
  for i = 1, n do
    v[i] = M.from_float((i % 2 == 0) and 1.0 or 0.5)
  end
  local nv = vec_norm(v, n)
  if M.sign(nv) == 0 then
    v[1] = M.from_int(1)
    nv = M.from_int(1)
  end
  v = vec_scale(v, nv, n)
  local lambda = M.from_int(0)
  for _ = 1, max_iter do
    local Av = mat_vec(A, v, n)
    local new_lambda = vec_dot(v, Av, n) -- Rayleigh quotient
    local nrm = vec_norm(Av, n)
    if M.sign(nrm) == 0 then
      return lambda, v
    end
    local v_new = vec_scale(Av, nrm, n)
    if math.abs(M.to_number(M.sub(new_lambda, lambda))) < tol then
      return new_lambda, v_new
    end
    lambda = new_lambda
    v = v_new
  end
  return lambda, v
end

-- Returns up to `count` eigenvalues (default: all). Best for symmetric
-- matrices; general matrices produce only real eigenvalues with this
-- approach.
function M.eigenvalues(A, count)
  if not is_mat(A) then
    error("calc.eigenvalues: matrix required")
  end
  if A.rows ~= A.cols then
    error("calc.eigenvalues: square matrix required")
  end
  local n = A.rows
  count = count or n
  local eigs = {}
  local A_def = mat_copy(A)
  for _ = 1, count do
    local lambda, v = power_iteration(A_def, n)
    eigs[#eigs + 1] = lambda
    A_def = deflate(A_def, lambda, v, n)
  end
  return eigs
end

-- Convenience: just the dominant eigenvalue + its eigenvector.
function M.dominant_eig(A)
  if not is_mat(A) then
    error("calc.dominant_eig: matrix required")
  end
  if A.rows ~= A.cols then
    error("calc.dominant_eig: square matrix required")
  end
  return power_iteration(A, A.rows)
end

-- ---------------------------------------------------------------------------
-- Symbolic differentiation. Pattern matches on the formula AST shape
-- defined in `lua/organ/table/formula.lua`: nodes have a `kind` field
-- and operator/function children.
--
-- d/dvar of:
--   constant       0
--   var            1   (when matching the requested variable)
--   other-var      0
--   a + b          d(a) + d(b)
--   a - b          d(a) - d(b)
--   -a             -d(a)
--   a * b          a * d(b) + b * d(a)
--   a / b          (b * d(a) - a * d(b)) / b^2
--   a ^ n          n * a^(n-1) * d(a)        (n constant in `var`)
--   sin(u)         cos(u) * d(u)
--   cos(u)         -sin(u) * d(u)
--   tan(u)         (1 / cos(u)^2) * d(u)
--   exp(u)         exp(u) * d(u)
--   ln(u)          d(u) / u
--
-- The result is an AST in the same shape; downstream consumers can
-- evaluate it via formula.eval / formula.eval_calc.

local function ast_num(n)
  return { kind = "num", value = n }
end
local function ast_const(name)
  return { kind = "const", name = name }
end
local function ast_neg(a)
  return { kind = "unop", op = "-", arg = a }
end
local function ast_bin(op, a, b)
  return { kind = "binop", op = op, left = a, right = b }
end
local function ast_call(name, args)
  return { kind = "call", name = name, args = args, arg = args[1] }
end

local function ast_is_zero(a)
  return a.kind == "num" and a.value == 0
end
local function ast_is_one(a)
  return a.kind == "num" and a.value == 1
end

-- Light simplification: collapses a + 0, a * 1, a * 0, etc.
local function ast_simplify(a)
  if not a or not a.kind then
    return a
  end
  if a.kind == "binop" then
    a.left = ast_simplify(a.left)
    a.right = ast_simplify(a.right)
    if a.op == "+" then
      if ast_is_zero(a.left) then
        return a.right
      end
      if ast_is_zero(a.right) then
        return a.left
      end
    elseif a.op == "-" then
      if ast_is_zero(a.right) then
        return a.left
      end
      if ast_is_zero(a.left) then
        return ast_neg(a.right)
      end
    elseif a.op == "*" then
      if ast_is_zero(a.left) or ast_is_zero(a.right) then
        return ast_num(0)
      end
      if ast_is_one(a.left) then
        return a.right
      end
      if ast_is_one(a.right) then
        return a.left
      end
    elseif a.op == "/" then
      if ast_is_zero(a.left) then
        return ast_num(0)
      end
      if ast_is_one(a.right) then
        return a.left
      end
    elseif a.op == "^" then
      if ast_is_zero(a.right) then
        return ast_num(1)
      end
      if ast_is_one(a.right) then
        return a.left
      end
      if ast_is_zero(a.left) then
        return ast_num(0)
      end
    end
  end
  if a.kind == "unop" and a.op == "-" then
    a.arg = ast_simplify(a.arg)
    if a.arg.kind == "unop" and a.arg.op == "-" then
      return a.arg.arg
    end
    if ast_is_zero(a.arg) then
      return ast_num(0)
    end
  end
  return a
end

-- Build d/dvar of `node`. `var` is the AST node representing the
-- variable to differentiate against — typically `{ kind = "const",
-- name = "x" }` for a bare-symbol formula.
function M.deriv(node, var)
  if not node or not node.kind then
    error("calc.deriv: invalid AST")
  end
  local function d(n)
    return M.deriv(n, var)
  end
  local function is_var(a)
    return a.kind == "const" and a.name == var
  end
  if node.kind == "num" then
    return ast_num(0)
  end
  if node.kind == "const" then
    return is_var(node) and ast_num(1) or ast_num(0)
  end
  if node.kind == "ref" then
    -- Cell references are constants w.r.t. symbolic var.
    return ast_num(0)
  end
  if node.kind == "unop" and node.op == "-" then
    return ast_neg(d(node.arg))
  end
  if node.kind == "binop" then
    local a, b = node.left, node.right
    if node.op == "+" then
      return ast_bin("+", d(a), d(b))
    end
    if node.op == "-" then
      return ast_bin("-", d(a), d(b))
    end
    if node.op == "*" then
      return ast_bin("+", ast_bin("*", a, d(b)), ast_bin("*", b, d(a)))
    end
    if node.op == "/" then
      local num = ast_bin("-", ast_bin("*", b, d(a)), ast_bin("*", a, d(b)))
      local den = ast_bin("^", b, ast_num(2))
      return ast_bin("/", num, den)
    end
    if node.op == "^" then
      -- Constant exponent: power rule.
      if b.kind == "num" then
        local n = b.value
        local power = ast_bin("^", a, ast_num(n - 1))
        return ast_bin("*", ast_bin("*", ast_num(n), power), d(a))
      end
      -- Variable exponent: logarithmic differentiation.
      --   y = u^v
      --   ln y = v * ln u
      --   y' / y = v' * ln u + v * u' / u
      --   y' = u^v * (v' * ln u + v * u' / u)
      local du, dv = d(a), d(b)
      local term1 = ast_bin("*", dv, ast_call("ln", { a }))
      local term2 = ast_bin("*", b, ast_bin("/", du, a))
      return ast_bin("*", node, ast_bin("+", term1, term2))
    end
  end
  if node.kind == "call" then
    local args = node.args or { node.arg }
    local u = args[1]
    local du = d(u)
    if node.name == "sin" then
      return ast_bin("*", ast_call("cos", { u }), du)
    end
    if node.name == "cos" then
      return ast_bin("*", ast_neg(ast_call("sin", { u })), du)
    end
    if node.name == "tan" then
      return ast_bin("/", du, ast_bin("^", ast_call("cos", { u }), ast_num(2)))
    end
    if node.name == "exp" then
      return ast_bin("*", ast_call("exp", { u }), du)
    end
    if node.name == "ln" or node.name == "log" then
      return ast_bin("/", du, u)
    end
    if node.name == "sqrt" then
      -- d/dx sqrt(u) = du / (2 * sqrt(u))
      return ast_bin("/", du, ast_bin("*", ast_num(2), ast_call("sqrt", { u })))
    end
    error("calc.deriv: unsupported function `" .. node.name .. "`")
  end
  error("calc.deriv: unknown AST kind `" .. tostring(node.kind) .. "`")
end

-- Apply ast_simplify post-deriv. Public helper.
function M.deriv_simplify(node, var)
  return ast_simplify(M.deriv(node, var))
end

M._ast_simplify = ast_simplify

-- ---------------------------------------------------------------------------
-- Polynomial / algebraic manipulation. A pragmatic computer-algebra
-- subset:
--
--   M.expand(ast)  — distribute multiplication over addition, lower
--                    powers to repeated multiplication when the
--                    exponent is a small non-negative literal.
--   M.factor(ast)  — recognise a few patterns: difference of squares,
--                    common factor in a sum.
--   M.simplify(ast) — repeated ast_simplify until fixpoint.
--
-- This is not a full CAS — there's no canonical-form representation
-- and no like-term combination. (`expand((x+1)*(x-1))` produces a
-- correct but un-collected `x*x + (-1)*x + 1*x + (-1)`. Pair with a
-- numerical evaluator at a known point if you need to verify
-- equivalence.)

local function _ast_eq(a, b)
  if a == b then
    return true
  end
  if not (a and b) then
    return false
  end
  if a.kind ~= b.kind then
    return false
  end
  if a.kind == "num" then
    return a.value == b.value
  end
  if a.kind == "const" then
    return a.name == b.name
  end
  if a.kind == "ref" then
    return a.row == b.row and a.col == b.col
  end
  if a.kind == "unop" then
    return a.op == b.op and _ast_eq(a.arg, b.arg)
  end
  if a.kind == "binop" then
    return a.op == b.op and _ast_eq(a.left, b.left) and _ast_eq(a.right, b.right)
  end
  if a.kind == "call" then
    if a.name ~= b.name then
      return false
    end
    local aa, bb = a.args or { a.arg }, b.args or { b.arg }
    if #aa ~= #bb then
      return false
    end
    for i = 1, #aa do
      if not _ast_eq(aa[i], bb[i]) then
        return false
      end
    end
    return true
  end
  return false
end

function M.expand(node)
  if not node or not node.kind then
    return node
  end
  if node.kind == "binop" then
    local L = M.expand(node.left)
    local R = M.expand(node.right)
    if node.op == "*" then
      -- (a + b) * c → a*c + b*c
      if L.kind == "binop" and (L.op == "+" or L.op == "-") then
        return ast_simplify(
          ast_bin(L.op, M.expand(ast_bin("*", L.left, R)), M.expand(ast_bin("*", L.right, R)))
        )
      end
      -- a * (b + c) → a*b + a*c
      if R.kind == "binop" and (R.op == "+" or R.op == "-") then
        return ast_simplify(
          ast_bin(R.op, M.expand(ast_bin("*", L, R.left)), M.expand(ast_bin("*", L, R.right)))
        )
      end
      return ast_bin("*", L, R)
    end
    if node.op == "^" and R.kind == "num" then
      local n = R.value
      if n == math.floor(n) and n >= 0 and n <= 8 then
        if n == 0 then
          return ast_num(1)
        end
        if n == 1 then
          return L
        end
        local out = L
        for _ = 2, n do
          out = M.expand(ast_bin("*", out, L))
        end
        return out
      end
    end
    return ast_bin(node.op, L, R)
  end
  if node.kind == "unop" then
    return ast_simplify({ kind = "unop", op = node.op, arg = M.expand(node.arg) })
  end
  if node.kind == "call" then
    local args = {}
    for i, a in ipairs(node.args or { node.arg }) do
      args[i] = M.expand(a)
    end
    return ast_call(node.name, args)
  end
  return node
end

-- factor(a^2 - b^2) = (a - b) * (a + b). factor(c*x + c*y) = c*(x + y)
-- when c is a literal common factor.
function M.factor(node)
  if not node or node.kind ~= "binop" then
    return node
  end
  if
    node.op == "-"
    and node.left.kind == "binop"
    and node.left.op == "^"
    and node.right.kind == "binop"
    and node.right.op == "^"
    and node.left.right.kind == "num"
    and node.left.right.value == 2
    and node.right.right.kind == "num"
    and node.right.right.value == 2
  then
    local a, b = node.left.left, node.right.left
    return ast_bin("*", ast_bin("-", a, b), ast_bin("+", a, b))
  end
  -- common factor in a sum: c*x + c*y → c*(x+y)
  if
    (node.op == "+" or node.op == "-")
    and node.left.kind == "binop"
    and node.left.op == "*"
    and node.right.kind == "binop"
    and node.right.op == "*"
    and _ast_eq(node.left.left, node.right.left)
  then
    return ast_bin("*", node.left.left, ast_bin(node.op, node.left.right, node.right.right))
  end
  return node
end

function M.simplify(node)
  -- Apply ast_simplify until fixpoint (max 16 iterations as a guard).
  for _ = 1, 16 do
    local next_node = ast_simplify(node)
    if _ast_eq(next_node, node) then
      return next_node
    end
    node = next_node
  end
  return node
end

-- ---------------------------------------------------------------------------
-- Limits. Two strategies, in order:
--
--   1. Direct substitution: bind the variable to its target and try to
--      evaluate. If the result is finite (no 0/0 or div-by-zero), return.
--   2. L'Hôpital fallback for f/g where both f(c)=0 and g(c)=0:
--      recurse on f'/g' and try again. Bounded depth to avoid loops.
--
-- This handles all the limit problems an org-table user is realistic
-- to write. Genuinely indeterminate forms beyond 0/0 (∞/∞, 0·∞, ∞-∞,
-- 0^0, ∞^0, 1^∞) need asymptotic analysis and are NOT_IMPLEMENTED.

local function _eval_at(ast, var, c)
  local F = require("organ.table.formula")
  local ctx = { rows = {}, current_row = 1, current_col = 1, vars = { [var] = c } }
  local ok, v = pcall(F.eval_calc, ast, ctx)
  if not ok then
    return nil
  end
  return v
end

function M.limit(ast, var, c, _depth)
  _depth = _depth or 0
  if _depth > 8 then
    return _eval_at(ast, var, c)
  end
  -- 1. Try direct substitution.
  local v = _eval_at(ast, var, c)
  if v ~= nil then
    return v
  end
  -- 2. L'Hôpital: f/g with f(c)=0 and g(c)=0 → f'/g'
  if ast.kind == "binop" and ast.op == "/" then
    local num_v = _eval_at(ast.left, var, c)
    local den_v = _eval_at(ast.right, var, c)
    if num_v and den_v and M.sign(num_v) == 0 and M.sign(den_v) == 0 then
      local num_d = M.deriv_simplify(ast.left, var)
      local den_d = M.deriv_simplify(ast.right, var)
      return M.limit({ kind = "binop", op = "/", left = num_d, right = den_d }, var, c, _depth + 1)
    end
    if num_v and den_v then
      return M.div(num_v, den_v)
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Symbolic integration via a small antiderivative table. Handles:
--
--   integ(c)         = c * x
--   integ(x)         = x^2 / 2
--   integ(x^n)       = x^(n+1) / (n+1),   n ≠ -1, n constant
--   integ(1/x)       = ln(x)
--   integ(sin(x))    = -cos(x)
--   integ(cos(x))    = sin(x)
--   integ(exp(x))    = exp(x)
--   integ(a + b)     = integ(a) + integ(b)
--   integ(a - b)     = integ(a) - integ(b)
--   integ(c * f)     = c * integ(f)        (c constant in var)
--   integ(f(g) * g') = pattern recognition for chain inverse: NOT YET
--   integ-by-parts   = NOT YET
--
-- Constant of integration is omitted (caller can add it if needed).

local function ast_is_constant_in(node, var)
  if node.kind == "num" then
    return true
  end
  if node.kind == "const" then
    return node.name ~= var
  end
  if node.kind == "ref" then
    return true
  end
  if node.kind == "unop" then
    return ast_is_constant_in(node.arg, var)
  end
  if node.kind == "binop" then
    return ast_is_constant_in(node.left, var) and ast_is_constant_in(node.right, var)
  end
  if node.kind == "call" then
    for _, a in ipairs(node.args or {}) do
      if not ast_is_constant_in(a, var) then
        return false
      end
    end
    return true
  end
  return false
end

local function ast_is_var(node, var)
  return node.kind == "const" and node.name == var
end

function M.integ(node, var)
  if ast_is_constant_in(node, var) then
    -- ∫ c dx = c * x
    return ast_bin("*", node, ast_const(var))
  end
  if ast_is_var(node, var) then
    -- ∫ x dx = x^2 / 2
    return ast_bin("/", ast_bin("^", node, ast_num(2)), ast_num(2))
  end
  if node.kind == "binop" then
    if node.op == "+" or node.op == "-" then
      return ast_bin(node.op, M.integ(node.left, var), M.integ(node.right, var))
    end
    if node.op == "*" then
      -- c * f → c * ∫f.  f * c → c * ∫f.
      if ast_is_constant_in(node.left, var) then
        return ast_bin("*", node.left, M.integ(node.right, var))
      end
      if ast_is_constant_in(node.right, var) then
        return ast_bin("*", node.right, M.integ(node.left, var))
      end
      error("calc.integ: integration by parts not implemented")
    end
    if node.op == "/" then
      -- 1/x → ln(x)
      if node.left.kind == "num" and node.left.value == 1 and ast_is_var(node.right, var) then
        return ast_call("ln", { node.right })
      end
      -- f / c → f integrated, divided by c
      if ast_is_constant_in(node.right, var) then
        return ast_bin("/", M.integ(node.left, var), node.right)
      end
      error("calc.integ: general 1/f not implemented (only 1/x recognised)")
    end
    if node.op == "^" then
      -- x^n → x^(n+1) / (n+1) for constant n != -1
      if ast_is_var(node.left, var) and ast_is_constant_in(node.right, var) then
        if node.right.kind == "num" then
          local n = node.right.value
          if n == -1 then
            return ast_call("ln", { node.left })
          end
          return ast_bin("/", ast_bin("^", node.left, ast_num(n + 1)), ast_num(n + 1))
        end
      end
      error("calc.integ: ∫x^n only supported with literal-num exponent")
    end
  end
  if node.kind == "unop" and node.op == "-" then
    return ast_neg(M.integ(node.arg, var))
  end
  if node.kind == "call" then
    local args = node.args or { node.arg }
    if #args == 1 and ast_is_var(args[1], var) then
      if node.name == "sin" then
        return ast_neg(ast_call("cos", { args[1] }))
      end
      if node.name == "cos" then
        return ast_call("sin", { args[1] })
      end
      if node.name == "exp" then
        return ast_call("exp", { args[1] })
      end
    end
  end
  error("calc.integ: cannot integrate `" .. (node.kind or "?") .. "`")
end

function M.integ_simplify(node, var)
  return ast_simplify(M.integ(node, var))
end

-- ---------------------------------------------------------------------------
-- Date / time. Stored internally as days since 1970-01-01 (Unix epoch
-- date) for the date part, plus an optional fractional-day component
-- for time. Conversion uses Howard Hinnant's proleptic-Gregorian
-- algorithm, which works for all years (no Y2K-style limits).
--
-- Calc values: { kind = "date", days = N } or
--              { kind = "date", days = N, frac = 0..1 } for datetimes.

local function _is_leap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local function days_from_civil(y, m, d)
  -- Hinnant: shifts month so March = 1, then computes days from a
  -- 400-year era starting at 0000-03-01.
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor((y >= 0 and y or y - 399) / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468 -- offset so 1970-01-01 = 0
end

local function civil_from_days(z)
  z = z + 719468
  local era = math.floor((z >= 0 and z or z - 146096) / 146097)
  local doe = z - era * 146097
  local yoe = math.floor(
    (doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365
  )
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  y = y + (m <= 2 and 1 or 0)
  return y, m, d
end

local function is_date(v)
  return type(v) == "table" and v.kind == "date"
end
function M.is_date(v)
  return is_date(v)
end

function M.date(y, m, d)
  if not (y and m and d) then
    error("calc.date: y, m, d required")
  end
  if m < 1 or m > 12 then
    error("calc.date: month out of range")
  end
  return { kind = "date", days = days_from_civil(y, m, d) }
end

function M.date_from_string(s)
  -- ISO 8601 date: YYYY-MM-DD, optionally with T...
  local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if not y then
    error("calc.date_from_string: bad ISO format: " .. s)
  end
  return M.date(tonumber(y), tonumber(m), tonumber(d))
end

function M.date_to_string(v)
  if not is_date(v) then
    error("calc.date_to_string: date required")
  end
  local y, m, d = civil_from_days(v.days)
  return string.format("%04d-%02d-%02d", y, m, d)
end

function M.date_year(v)
  return ({ civil_from_days(v.days) })[1]
end
function M.date_month(v)
  return ({ civil_from_days(v.days) })[2]
end
function M.date_day(v)
  return ({ civil_from_days(v.days) })[3]
end

-- 0 = Sunday, 1 = Monday, …, 6 = Saturday.
function M.date_weekday(v)
  if not is_date(v) then
    error("calc.date_weekday: date required")
  end
  return (v.days + 4) % 7 -- 1970-01-01 was a Thursday → +4 to align Sun=0
end

local function _to_int_lua(n)
  if type(n) == "number" then
    return math.floor(n)
  end
  if is_int(n) then
    return tonumber(bn_to_string(n.n))
  end
  if is_rat(n) then
    return math.floor(M.to_number(n))
  end
  if is_float(n) then
    return math.floor(n.v)
  end
  error("calc.date_add: integer days required")
end

function M.date_add_days(d, n)
  if not is_date(d) then
    error("calc.date_add_days: date required")
  end
  return { kind = "date", days = d.days + _to_int_lua(n) }
end

function M.date_sub_days(d, n)
  return M.date_add_days(d, -_to_int_lua(n))
end

-- Difference a - b in (integer) days.
function M.date_diff(a, b)
  if not (is_date(a) and is_date(b)) then
    error("calc.date_diff: two dates required")
  end
  return M.from_int(a.days - b.days)
end

function M.date_cmp(a, b)
  if not (is_date(a) and is_date(b)) then
    error("calc.date_cmp: two dates required")
  end
  if a.days < b.days then
    return -1
  end
  if a.days > b.days then
    return 1
  end
  return 0
end

function M.date_add_months(d, n)
  if not is_date(d) then
    error("calc.date_add_months: date required")
  end
  local y, m, day = civil_from_days(d.days)
  local total = m + _to_int_lua(n) - 1
  local years_offset = math.floor(total / 12)
  local new_m = (total % 12) + 1
  local new_y = y + years_offset
  -- Clamp day to last-day-of-target-month if overflow.
  local last_day = DAYS_IN_MONTH[new_m] or 31
  if new_m == 2 and _is_leap(new_y) then
    last_day = 29
  end
  if day > last_day then
    day = last_day
  end
  return M.date(new_y, new_m, day)
end

function M.date_today()
  -- Use os.date if available; falls back to Unix-epoch days via os.time.
  local t = os.date("*t")
  return M.date(t.year, t.month, t.day)
end

local DAYS_IN_MONTH_PRIVATE = DAYS_IN_MONTH or { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
DAYS_IN_MONTH = DAYS_IN_MONTH_PRIVATE

-- ---------------------------------------------------------------------------
-- Future-work registry — runtime-discoverable list of "not yet
-- implemented" Calc capabilities. Keep in sync with the module header.

M.NOT_IMPLEMENTED = {
  integration_advanced = "integration by parts; chain-rule inverse / u-substitution",
  limit_advanced = "indeterminate forms beyond 0/0",
  cas_full = "general factor / collect / canonical form for arbitrary expressions",
  matrix_qr = "QR algorithm for general (non-symmetric) eigenvalues, SVD",
}

-- Internal exposure for tests / sister modules.
M._bn = {
  zero = bn_zero,
  from_int = bn_from_int,
  from_string = bn_from_digits_string,
  to_string = bn_to_string,
  cmp = bn_cmp,
  add = bn_add,
  sub = bn_sub,
  mul = bn_mul,
  divmod = bn_divmod,
  gcd = bn_gcd,
  is_zero = bn_is_zero,
}

return M
