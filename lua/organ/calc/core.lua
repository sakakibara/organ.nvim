-- Calc value tower: value kinds int/rat/float/unit/symbol, construction,
-- arithmetic with type promotion, math functions, vector aggregations,
-- units with dimensional analysis, and symbolic simplification.

local M = {}
local bn = require("organ.calc.bn")

local dims_eq, dims_zero, dims_combine, dim_string

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
local function is_expr(v)
  return type(v) == "table" and v.kind == "expr"
end
local function is_fn(v)
  return type(v) == "table" and v.kind == "fn"
end

local function is_numeric(v)
  return is_int(v) or is_rat(v) or is_float(v)
end

local function is_symbolic(v)
  return is_sym(v) or is_expr(v) or is_fn(v)
end

-- A quotient or remainder over a zero divisor. Calc keeps the form
-- instead of answering, and rewrites nothing built on top of one, so
-- `8/0 - 8/0` stays spelled out rather than collapsing to 0.
local function is_inert(v)
  return is_expr(v) and v.inert == true
end

function M.is_calc(v)
  return is_numeric(v) or is_unit(v) or is_symbolic(v)
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
function M.is_symbolic(v)
  return is_symbolic(v)
end
function M.is_inert(v)
  return is_inert(v)
end
function M.is_whole(v)
  return is_int(v) or (is_float(v) and v.v == math.floor(v.v))
end

-- Operations that have no symbolic answer organ is prepared to spell.
-- Raised as a string so organ.table.formula reports a refusal and
-- leaves the user's fields alone instead of writing #ERROR.
M.SYMBOLIC = "calc: no symbolic "

function M.symbolic_refusal(what)
  error(M.SYMBOLIC .. what, 0)
end

local sym_add, sym_sub, sym_mul, sym_div, sym_pow, sym_neg, sym_mod
local inert_quotient

local function new_int(b)
  return { kind = "int", n = b }
end

local function reduce_rat(num, den)
  if bn.is_zero(num) then
    return new_int(bn.zero())
  end
  if den.sign < 0 then
    num = bn.neg(num)
    den = bn.neg(den)
  end
  local g = bn.gcd(num, den)
  if not (bn.is_zero(g) or (#g.d == 1 and g.d[1] == 1)) then
    num = (bn.divmod(num, g))
    den = (bn.divmod(den, g))
  end
  if #den.d == 1 and den.d[1] == 1 then
    return new_int(num)
  end
  return { kind = "rat", num = num, den = den }
end

local function as_rat_parts(v)
  if is_int(v) then
    return v.n, bn.from_int(1)
  end
  return v.num, v.den
end

function M.from_int(n)
  if n ~= math.floor(n) or math.abs(n) > 2 ^ 53 then
    error("calc.from_int: " .. tostring(n) .. " is not an exact integer")
  end
  return new_int(bn.from_int(n))
end

function M.from_float(x)
  if x ~= x then
    error("calc.from_float: NaN")
  end
  -- Calc's floats run to a five-digit exponent, so it answers where a
  -- double has already saturated. organ declines instead of storing an
  -- infinity that would print as a number.
  if x == math.huge or x == -math.huge then
    error(M.OVERFLOW, 0)
  end
  return { kind = "float", v = x }
end

function M.from_number(x)
  if x ~= x or x == math.huge or x == -math.huge then
    error("calc.from_number: non-finite " .. tostring(x))
  end
  if x == math.floor(x) and math.abs(x) < 2 ^ 53 then
    return new_int(bn.from_int(x))
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
    local num = bn.from_digits_string(num_s)
    local den = bn.from_digits_string(den_s)
    if bn.is_zero(den) then
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
    -- 12.5 -> 125 / 10
    local digits = int_part .. frac_part
    local num = bn.from_digits_string(digits)
    local den_str = "1" .. string.rep("0", #frac_part)
    local den = bn.from_digits_string(den_str)
    num.sign = sign
    return reduce_rat(num, den)
  end
  local dec_only = s:match("^%.(%d+)$")
  if dec_only then
    local num = bn.from_digits_string(dec_only)
    local den = bn.from_digits_string("1" .. string.rep("0", #dec_only))
    num.sign = sign
    return reduce_rat(num, den)
  end
  if s:match("^%d+$") then
    local n = bn.from_digits_string(s)
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
    return bn.to_string(v.n)
  end
  if is_rat(v) then
    return bn.to_string(v.num) .. "/" .. bn.to_string(v.den)
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
  if is_symbolic(v) then
    return M.render_expr(v, M.to_string)
  end
  error("calc.to_string: not a Calc value")
end

function M.to_number(v)
  if is_int(v) then
    return tonumber(bn.to_string(v.n))
  end
  if is_rat(v) then
    return tonumber(bn.to_string(v.num)) / tonumber(bn.to_string(v.den))
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
  if is_symbolic(v) then
    return sym_neg(v)
  end
  if is_int(v) then
    return new_int(bn.neg(v.n))
  end
  if is_rat(v) then
    return reduce_rat(bn.neg(v.num), v.den)
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
    local n = bn.copy(v.n)
    n.sign = 1
    return new_int(n)
  end
  if is_rat(v) then
    local num = bn.copy(v.num)
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
  if is_symbolic(v) then
    M.symbolic_refusal("sign")
  end
  if is_int(v) then
    if bn.is_zero(v.n) then
      return 0
    end
    return v.n.sign
  end
  if is_rat(v) then
    if bn.is_zero(v.num) then
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

-- Promote to a common kind for binary ops: int + int -> int; if either
-- side is float -> float; else (some rational, no float) -> rat.
local function any_float(a, b)
  return is_float(a) or is_float(b)
end

function M.cmp(a, b)
  if is_symbolic(a) or is_symbolic(b) then
    M.symbolic_refusal("comparison")
  end
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
  local bnum, bd = as_rat_parts(b)
  return bn.cmp(bn.mul(an, bd), bn.mul(bnum, ad))
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
    if not (is_unit(a) and is_unit(b)) or not dims_eq(a.dim, b.dim) then
      error("calc: dimension mismatch in " .. op)
    end
    local r = (op == "add") and M.add(av, bv) or M.sub(av, bv)
    return { kind = "unit", v = r, dim = a.dim, name = a.name }
  end
  if op == "mul" then
    local dim = dims_combine((is_unit(a) and a.dim) or {}, (is_unit(b) and b.dim) or {}, 1)
    local r = M.mul(av, bv)
    if dims_zero(dim) then
      return r
    end
    return { kind = "unit", v = r, dim = dim, name = dim_string(dim) }
  end
  if op == "div" then
    local dim = dims_combine((is_unit(a) and a.dim) or {}, (is_unit(b) and b.dim) or {}, -1)
    local r = M.div(av, bv)
    if dims_zero(dim) then
      return r
    end
    return { kind = "unit", v = r, dim = dim, name = dim_string(dim) }
  end
  error("calc: unsupported unit op " .. op)
end

-- Exact integers are capped where Emacs caps them: `integer-width`
-- defaults to 65536 bits -- 19729 decimal digits -- and Calc signals an
-- arithmetic overflow past it. Unbounded, `$1^$2` over two
-- ordinary-looking cells squares its way to a six-figure digit count
-- and wedges the editor with no way to interrupt it.
M.OVERFLOW = "calc: arithmetic overflow"

local MAX_DIGITS = 19729

-- A product has at least (digits a + digits b - 1) digits, so the
-- refusal lands before the multiplication rather than after it.
local function mul_checked(a, b)
  if bn.digits(a) + bn.digits(b) - 1 > MAX_DIGITS then
    error(M.OVERFLOW, 0)
  end
  return bn.mul(a, b)
end

function M.add(a, b)
  if is_symbolic(a) or is_symbolic(b) then
    return sym_add(a, b)
  end
  if is_unit(a) or is_unit(b) then
    return unit_op("add", a, b)
  end
  if any_float(a, b) then
    return M.from_float(to_float_value(a) + to_float_value(b))
  end
  if is_int(a) and is_int(b) then
    return new_int(bn.add(a.n, b.n))
  end
  local an, ad = as_rat_parts(a)
  local bnum, bd = as_rat_parts(b)
  return reduce_rat(bn.add(mul_checked(an, bd), mul_checked(bnum, ad)), mul_checked(ad, bd))
end

function M.sub(a, b)
  if is_symbolic(a) or is_symbolic(b) then
    return sym_sub(a, b)
  end
  if is_unit(a) or is_unit(b) then
    return unit_op("sub", a, b)
  end
  return M.add(a, M.neg(b))
end

function M.mul(a, b)
  if is_symbolic(a) or is_symbolic(b) then
    return sym_mul(a, b)
  end
  if is_unit(a) or is_unit(b) then
    return unit_op("mul", a, b)
  end
  if any_float(a, b) then
    return M.from_float(to_float_value(a) * to_float_value(b))
  end
  if is_int(a) and is_int(b) then
    return new_int(mul_checked(a.n, b.n))
  end
  local an, ad = as_rat_parts(a)
  local bnum, bd = as_rat_parts(b)
  return reduce_rat(mul_checked(an, bnum), mul_checked(ad, bd))
end

function M.div(a, b)
  if is_symbolic(a) or is_symbolic(b) then
    return sym_div(a, b)
  end
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
  local bnum, bd = as_rat_parts(b)
  if bn.is_zero(bnum) then
    error("calc: division by zero")
  end
  local an, ad = as_rat_parts(a)
  return reduce_rat(bn.mul(an, bd), bn.mul(ad, bnum))
end

function M.mod(a, b)
  if is_symbolic(a) or is_symbolic(b) then
    return sym_mod(a, b)
  end
  if is_numeric(b) and M.sign(b) == 0 then
    return sym_mod(a, b)
  end
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
  if bn.is_zero(b.n) then
    error("calc: modulo by zero")
  end
  local _, r = bn.divmod(a.n, b.n)
  if not bn.is_zero(r) and r.sign ~= b.n.sign then
    r = bn.add(r, b.n)
  end
  return new_int(r)
end

function M.pow(v, n)
  if is_symbolic(v) or is_symbolic(n) then
    return sym_pow(v, n)
  end
  -- A reciprocal of zero, so the form stands the way `1/0` does.
  if type(n) == "table" and M.sign(v) == 0 and M.sign(n) < 0 then
    return inert_quotient("^", v, n)
  end
  -- Float exponent -> float result.
  if (type(n) == "table" and is_float(n)) or is_float(v) then
    return M.from_float(to_float_value(v) ^ to_float_value(n))
  end
  -- Integer exponent: exact arithmetic.
  if type(n) == "table" then
    if is_int(n) then
      n = tonumber(bn.to_string(n.n))
    elseif is_rat(n) then
      -- Rational exponent -> drop to float.
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
  -- The squaring is skipped once no bits are left: with an integer
  -- cap in force, one gratuitous square of an already-final base is
  -- the difference between a result and an overflow.
  while n > 0 do
    if n % 2 == 1 then
      result = M.mul(result, base)
    end
    n = math.floor(n / 2)
    if n > 0 then
      base = M.mul(base, base)
    end
  end
  return result
end

-- Math functions. Most return float -- they're transcendental or
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
    if not bn.is_zero(v.n) then
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

-- The real cube root, which a negative base has and `x ^ (1/3)` does
-- not.
function M.cbrt(v)
  local x = as_float(v)
  if x < 0 then
    return M.from_float(-((-x) ^ (1 / 3)))
  end
  return M.from_float(x ^ (1 / 3))
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
  return M.from_float(math.atan2(as_float(y), as_float(x)))
end
function M.sinh(v)
  local x = as_float(v)
  return M.from_float((math.exp(x) - math.exp(-x)) / 2)
end
function M.cosh(v)
  local x = as_float(v)
  return M.from_float((math.exp(x) + math.exp(-x)) / 2)
end
-- Folded around zero so a large argument saturates at +/-1 instead of
-- dividing one overflowed exponential by another.
function M.tanh(v)
  local x = as_float(v)
  local e = math.exp(-2 * math.abs(x))
  local t = (1 - e) / (1 + e)
  return M.from_float(x < 0 and -t or t)
end

-- The exact integer an integral float names. A Calc float carries
-- twelve significant decimal digits, so the integer is read off that
-- decimal form rather than off the wider binary double organ holds it
-- in: 1e30 is ten to the thirtieth, not the 1000000000000000019...
-- the double happens to sit on.
local function exact_from_float(x)
  if x == 0 then
    return new_int(bn.zero())
  end
  local lead, rest, e = string.format("%.11e", math.abs(x)):match("^(%d)%.(%d+)e([%+%-]%d+)$")
  if not lead then
    error(M.OVERFLOW, 0)
  end
  local digits, exp = lead .. rest, tonumber(e)
  if exp >= #digits - 1 then
    digits = digits .. string.rep("0", exp - #digits + 1)
  else
    digits = digits:sub(1, exp + 1)
  end
  local n = bn.from_digits_string(digits)
  n.sign = x < 0 and -1 or 1
  return new_int(n)
end

function M.ceil(v)
  if is_int(v) then
    return v
  end
  if is_rat(v) then
    local q, r = bn.divmod(v.num, v.den)
    if bn.is_zero(r) or v.num.sign < 0 then
      return new_int(q)
    end
    return new_int(bn.add(q, bn.from_int(1)))
  end
  return exact_from_float(math.ceil(as_float(v)))
end

function M.floor(v)
  if is_int(v) then
    return v
  end
  if is_rat(v) then
    local q, r = bn.divmod(v.num, v.den)
    if bn.is_zero(r) or v.num.sign > 0 then
      return new_int(q)
    end
    return new_int(bn.sub(q, bn.from_int(1)))
  end
  return exact_from_float(math.floor(as_float(v)))
end

function M.trunc(v)
  if is_int(v) then
    return v
  end
  if is_rat(v) then
    return new_int((bn.divmod(v.num, v.den)))
  end
  local x = as_float(v)
  return exact_from_float(x >= 0 and math.floor(x) or math.ceil(x))
end

function M.round(v)
  if is_int(v) then
    return v
  end
  if is_rat(v) then
    -- round half away from zero
    local doubled = bn.mul(v.num, bn.from_int(2))
    doubled.sign = math.abs(doubled.sign)
    local q, _ = bn.divmod(doubled, v.den)
    local sign = v.num.sign
    -- Adjust sign and halve.
    local r = (bn.divmod(bn.add(q, bn.from_int(1)), bn.from_int(2)))
    r.sign = sign
    return new_int(r)
  end
  local x = as_float(v)
  return exact_from_float(x >= 0 and math.floor(x + 0.5) or -math.floor(-x + 0.5))
end

-- A float that happens to be whole counts as the integer it names.
local function whole_digits(v, who)
  if is_int(v) then
    return v.n
  end
  if is_float(v) and v.v == math.floor(v.v) and math.abs(v.v) <= 2 ^ 53 then
    return bn.from_int(v.v)
  end
  error("calc." .. who .. ": integers only")
end

-- Zero divides everything, so the other argument is the answer whether
-- or not it is whole.
function M.gcd(a, b)
  if M.sign(a) == 0 then
    return M.abs(b)
  end
  if M.sign(b) == 0 then
    return M.abs(a)
  end
  return new_int(bn.gcd(whole_digits(a, "gcd"), whole_digits(b, "gcd")))
end

-- gcd is exact whatever it was handed; lcm carries a float argument's
-- inexactness into the result.
function M.lcm(a, b)
  local inexact = is_float(a) or is_float(b)
  local r
  if M.sign(a) == 0 or M.sign(b) == 0 then
    r = M.from_int(0)
  else
    local x, y = whole_digits(a, "lcm"), whole_digits(b, "lcm")
    local g = bn.gcd(x, y)
    local p = bn.mul(x, y)
    p.sign = 1
    r = new_int((bn.divmod(p, g)))
  end
  if inexact then
    return M.from_float(M.to_number(r))
  end
  return r
end

function M.factorial(n)
  if not is_int(n) or n.n.sign < 0 then
    error("calc.factorial: non-negative integer required")
  end
  local k = tonumber(bn.to_string(n.n))
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
  local nn = tonumber(bn.to_string(n.n))
  local kk = tonumber(bn.to_string(k.n))
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

-- Units. SI base + decimal prefixes + common derived. Each unit table
-- entry maps name -> {factor, dim} where factor is a Lua number scaling
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

dims_eq = function(a, b)
  for _, ax in ipairs(DIM_AXES) do
    if (a and a[ax] or 0) ~= (b and b[ax] or 0) then
      return false
    end
  end
  return true
end

dims_zero = function(d)
  for _, ax in ipairs(DIM_AXES) do
    if (d and d[ax] or 0) ~= 0 then
      return false
    end
  end
  return true
end

dims_combine = function(a, b, sign_b)
  local out = dim_copy(a)
  for _, ax in ipairs(DIM_AXES) do
    out[ax] = (out[ax] or 0) + (sign_b * (b[ax] or 0))
  end
  return out
end

dim_string = function(d)
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

-- Derived (selected -- the ones that matter for org tables).
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

-- Length conventions (non-prefixable; the prefix sweep below handles km, mm...).
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
  if not dims_eq(v.dim, u.dim) then
    error(
      "calc.convert: incompatible dimensions: " .. dim_string(v.dim) .. " → " .. dim_string(u.dim)
    )
  end
  -- Internal stays in base SI; just relabel the display unit.
  return { kind = "unit", v = v.v, dim = u.dim, name = target }
end

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

-- Symbolic expressions: one operator over Calc values, built by the
-- arithmetic entry points whenever an operand is symbolic. Construction
-- applies Calc's local rewrites (distribute a numeric factor over a
-- sum, collect like terms and equal bases, fold an adjacent constant),
-- so an expression prints the way Calc prints it.

local function expr(op, left, right)
  local inert = is_inert(left) or is_inert(right) or nil
  return { kind = "expr", op = op, left = left, right = right, inert = inert }
end

-- Calc answers a zero-divisor quotient or remainder with the form
-- itself. It is a value like any other -- it renders, and it composes --
-- but nothing rewrites it, so `8/0 - 8/0` is not 0.
function inert_quotient(op, a, b)
  local v = expr(op, a, b)
  v.inert = true
  return v
end

-- The positive counterpart of a negative term, or nil: a negative
-- number, or a zero-divisor quotient with a negative numerator.
local function negative_term(v)
  if is_numeric(v) and M.sign(v) < 0 then
    return M.neg(v)
  end
  if is_inert(v) and v.op == "/" and is_numeric(v.left) and M.sign(v.left) < 0 then
    return inert_quotient("/", M.neg(v.left), v.right)
  end
  return nil
end

local function no_units(a, b)
  if is_unit(a) or is_unit(b) then
    M.symbolic_refusal("arithmetic on units")
  end
end

local function is_minus_one(v)
  return is_int(v) and #v.n.d == 1 and v.n.d[1] == 1 and v.n.sign == -1
end

local function same(a, b)
  if is_sym(a) and is_sym(b) then
    return a.name == b.name
  end
  if is_fn(a) and is_fn(b) then
    if a.name ~= b.name or #a.args ~= #b.args then
      return false
    end
    for i = 1, #a.args do
      if not same(a.args[i], b.args[i]) then
        return false
      end
    end
    return true
  end
  if is_expr(a) and is_expr(b) then
    if a.op ~= b.op or not same(a.left, b.left) then
      return false
    end
    return (a.right == nil and b.right == nil)
      or (a.right ~= nil and b.right ~= nil and same(a.right, b.right))
  end
  if is_numeric(a) and is_numeric(b) then
    return a.kind == b.kind and M.cmp(a, b) == 0
  end
  return false
end

-- A term as (coefficient, base), so `2 x`, `-x` and `x / 2` all collect
-- against `x`.
local function term_parts(v)
  if is_expr(v) and v.op == "*" and is_numeric(v.left) then
    return v.left, v.right
  end
  if is_expr(v) and v.op == "/" and is_numeric(v.right) and not is_zero_calc(v.right) then
    return M.div(M.from_int(1), v.right), v.left
  end
  if is_expr(v) and v.op == "neg" then
    return M.from_int(-1), v.left
  end
  return M.from_int(1), v
end

-- Calc collects `2 x` against `x` but leaves `(x + 1) + (x + 1)` spelled
-- out, so a base that is itself a sum does not count as a like term.
local function like_terms(a, b)
  if not (is_symbolic(a) and is_symbolic(b)) then
    return nil
  end
  if is_inert(a) or is_inert(b) then
    return nil
  end
  local ca, base_a = term_parts(a)
  local cb, base_b = term_parts(b)
  if is_expr(base_a) and (base_a.op == "+" or base_a.op == "-") then
    return nil
  end
  if same(base_a, base_b) then
    return ca, cb, base_a
  end
  return nil
end

function sym_add(a, b)
  no_units(a, b)
  if not (is_symbolic(a) or is_symbolic(b)) then
    return M.add(a, b)
  end
  if is_zero_calc(a) then
    return b
  end
  if is_zero_calc(b) then
    return a
  end
  local positive_b = negative_term(b)
  if positive_b then
    return sym_sub(a, positive_b)
  end
  local positive_a = negative_term(a)
  if positive_a then
    return sym_sub(b, positive_a)
  end
  if is_expr(b) and b.op == "neg" then
    return sym_sub(a, b.left)
  end
  if is_expr(a) and a.op == "neg" then
    return sym_sub(b, a.left)
  end
  local ca, cb, base = like_terms(a, b)
  if base then
    return sym_mul(M.add(ca, cb), base)
  end
  if is_expr(b) and b.op == "+" then
    return sym_add(sym_add(a, b.left), b.right)
  end
  if is_expr(b) and b.op == "-" then
    return sym_sub(sym_add(a, b.left), b.right)
  end
  if is_numeric(b) and is_expr(a) and is_numeric(a.right) then
    if a.op == "+" then
      return sym_add(a.left, M.add(a.right, b))
    end
    if a.op == "-" then
      return sym_sub(a.left, M.sub(a.right, b))
    end
  end
  return expr("+", a, b)
end

function sym_sub(a, b)
  no_units(a, b)
  if not (is_symbolic(a) or is_symbolic(b)) then
    return M.sub(a, b)
  end
  if is_zero_calc(b) then
    return a
  end
  if is_zero_calc(a) then
    return sym_neg(b)
  end
  local positive = negative_term(b)
  if positive then
    return sym_add(a, positive)
  end
  if is_expr(b) and b.op == "+" then
    return sym_sub(sym_sub(a, b.left), b.right)
  end
  if is_expr(b) and b.op == "-" then
    return sym_add(a, sym_neg(b))
  end
  if is_expr(b) and b.op == "neg" then
    return sym_add(a, b.left)
  end
  local ca, cb, base = like_terms(a, b)
  if base then
    return sym_mul(M.sub(ca, cb), base)
  end
  if is_numeric(b) and is_expr(a) and is_numeric(a.right) then
    if a.op == "+" then
      return sym_add(a.left, M.sub(a.right, b))
    end
    if a.op == "-" then
      return sym_sub(a.left, M.add(a.right, b))
    end
  end
  return expr("-", a, b)
end

function sym_mul(a, b)
  no_units(a, b)
  if not (is_symbolic(a) or is_symbolic(b)) then
    return M.mul(a, b)
  end
  -- A float zero or one keeps its inexactness: Calc writes `0.`, not `0`.
  if is_zero_calc(a) then
    return a
  end
  if is_zero_calc(b) then
    return b
  end
  if is_numeric(a) and M.cmp(a, M.from_int(1)) == 0 then
    return b
  end
  if is_numeric(b) and M.cmp(b, M.from_int(1)) == 0 then
    return a
  end
  if is_inert(a) or is_inert(b) then
    return expr("*", a, b)
  end
  if is_minus_one(a) then
    return sym_neg(b)
  end
  if is_minus_one(b) then
    return sym_neg(a)
  end
  if same(a, b) then
    return sym_pow(a, M.from_int(2))
  end
  if is_expr(a) and a.op == "neg" then
    return sym_neg(sym_mul(a.left, b))
  end
  if is_expr(b) and b.op == "neg" then
    return sym_neg(sym_mul(a, b.left))
  end
  local ea = is_expr(a) and a.op == "^" and is_numeric(a.right) and a
  local eb = is_expr(b) and b.op == "^" and is_numeric(b.right) and b
  if ea and eb and same(ea.left, eb.left) then
    return sym_pow(ea.left, M.add(ea.right, eb.right))
  end
  if ea and same(ea.left, b) then
    return sym_pow(b, M.add(ea.right, M.from_int(1)))
  end
  if eb and same(eb.left, a) then
    return sym_pow(a, M.add(eb.right, M.from_int(1)))
  end
  if is_numeric(b) then
    return sym_mul(b, a)
  end
  if is_numeric(a) and is_expr(b) then
    if b.op == "+" then
      return sym_add(sym_mul(a, b.left), sym_mul(a, b.right))
    end
    if b.op == "-" then
      return sym_sub(sym_mul(a, b.left), sym_mul(a, b.right))
    end
    if b.op == "*" and is_numeric(b.left) then
      return sym_mul(M.mul(a, b.left), b.right)
    end
    if b.op == "/" then
      return sym_div(sym_mul(a, b.left), b.right)
    end
    if b.op == "neg" then
      return sym_neg(sym_mul(a, b.left))
    end
  end
  return expr("*", a, b)
end

function sym_div(a, b)
  no_units(a, b)
  if not (is_symbolic(a) or is_symbolic(b)) then
    return M.fdiv(a, b)
  end
  if is_numeric(b) and is_zero_calc(b) then
    return inert_quotient("/", a, b)
  end
  if is_one_calc(b) then
    return a
  end
  if is_inert(a) then
    return expr("/", a, b)
  end
  if same(a, b) then
    return M.from_int(1)
  end
  if is_zero_calc(a) then
    return M.from_int(0)
  end
  -- Calc carries a quotient's sign in a numeric denominator: -(x/2) is
  -- x/-2. A symbolic denominator keeps the minus outside instead.
  if is_expr(a) and a.op == "neg" then
    if is_numeric(b) then
      return sym_div(a.left, sym_neg(b))
    end
    return sym_neg(sym_div(a.left, b))
  end
  if is_expr(b) and b.op == "neg" then
    return sym_neg(sym_div(a, b.left))
  end
  if is_numeric(b) and not is_zero_calc(b) and is_expr(a) then
    if a.op == "+" then
      return sym_add(sym_div(a.left, b), sym_div(a.right, b))
    end
    if a.op == "-" then
      return sym_sub(sym_div(a.left, b), sym_div(a.right, b))
    end
    if a.op == "*" and is_numeric(a.left) then
      return sym_mul(M.fdiv(a.left, b), a.right)
    end
    if a.op == "/" and is_numeric(a.right) then
      return sym_div(a.left, M.mul(a.right, b))
    end
  end
  if
    is_numeric(a)
    and is_expr(b)
    and b.op == "*"
    and is_numeric(b.left)
    and not is_zero_calc(b.left)
  then
    return sym_div(M.fdiv(a, b.left), b.right)
  end
  if
    is_expr(a)
    and a.op == "*"
    and is_numeric(a.left)
    and is_expr(b)
    and b.op == "*"
    and is_numeric(b.left)
    and not is_zero_calc(b.left)
  then
    return expr("/", sym_mul(M.fdiv(a.left, b.left), a.right), b.right)
  end
  return expr("/", a, b)
end

function sym_pow(a, b)
  no_units(a, b)
  if not (is_symbolic(a) or is_symbolic(b)) then
    return M.pow(a, b)
  end
  if is_numeric(b) then
    if is_zero_calc(b) then
      return M.from_int(1)
    end
    if is_one_calc(b) then
      return a
    end
  end
  if is_inert(a) or is_inert(b) then
    return expr("^", a, b)
  end
  if is_fn(a) and a.name == "sqrt" and #a.args == 1 and is_numeric(b) then
    return sym_pow(a.args[1], M.fdiv(b, M.from_int(2)))
  end
  if is_numeric(b) then
    if is_expr(a) and a.op == "^" and is_numeric(a.right) then
      return sym_pow(a.left, M.mul(a.right, b))
    end
    if is_expr(a) and a.op == "*" and is_numeric(a.left) then
      return sym_mul(M.pow(a.left, b), sym_pow(a.right, b))
    end
    if is_expr(a) and a.op == "neg" and is_int(b) then
      local raised = sym_pow(a.left, b)
      return is_zero_calc(M.mod(b, M.from_int(2))) and raised or sym_neg(raised)
    end
  end
  return expr("^", a, b)
end

function sym_mod(a, b)
  no_units(a, b)
  if is_numeric(b) and is_zero_calc(b) then
    return inert_quotient("%", a, b)
  end
  if not (is_symbolic(a) or is_symbolic(b)) then
    return M.mod(a, b)
  end
  return expr("%", a, b)
end

-- Division as a table formula sees it: Calc's Fraction mode is off
-- there, so an exact quotient that does not divide evenly comes back as
-- a float, and a zero divisor keeps the form instead of raising.
function M.fdiv(a, b)
  if is_numeric(b) and is_zero_calc(b) then
    return inert_quotient("/", a, b)
  end
  local q = M.div(a, b)
  if is_rat(q) then
    return M.from_float(M.to_number(q))
  end
  return q
end

-- Calc answers a function it cannot evaluate with the call itself, and
-- goes on simplifying around it. Only three reach back inside: a
-- positive numeric factor comes out from under a square root, `abs`
-- drops a sign and a nested `abs`, and `sign` hands one back.
function M.sym_call(name, args)
  local u = args[1]
  if #args == 1 and is_symbolic(u) then
    if name == "sqrt" then
      if is_expr(u) and u.op == "*" and is_numeric(u.left) and M.sign(u.left) > 0 then
        return sym_mul(M.sqrt(u.left), M.sym_call("sqrt", { u.right }))
      end
      if is_expr(u) and u.op == "/" and is_numeric(u.right) and M.sign(u.right) > 0 then
        return sym_div(M.sym_call("sqrt", { u.left }), M.sqrt(u.right))
      end
      if
        is_expr(u)
        and u.op == "/"
        and is_numeric(u.left)
        and M.sign(u.left) > 0
        and not is_one_calc(u.left)
      then
        return sym_mul(M.sqrt(u.left), M.sym_call("sqrt", { sym_div(M.from_int(1), u.right) }))
      end
    elseif name == "abs" then
      if is_expr(u) and u.op == "neg" then
        return M.sym_call("abs", { u.left })
      end
      if is_expr(u) and u.op == "*" and is_numeric(u.left) and M.sign(u.left) < 0 then
        return M.sym_call("abs", { sym_mul(M.neg(u.left), u.right) })
      end
      if is_fn(u) and u.name == "abs" then
        return u
      end
    elseif name == "sign" then
      if is_expr(u) and u.op == "neg" then
        return sym_neg(M.sym_call("sign", { u.left }))
      end
    end
  end
  return { kind = "fn", name = name, args = args }
end

-- Comparisons over a symbol keep their form. Calc spells equality with
-- a single `=`.
local CMP_SPELLING = {
  ["<"] = "<",
  ["<="] = "<=",
  [">"] = ">",
  [">="] = ">=",
  ["=="] = "=",
  ["!="] = "!=",
}

function M.sym_cmp(op, a, b)
  local spelling = CMP_SPELLING[op]
  if not spelling then
    error("calc.sym_cmp: unknown comparison '" .. tostring(op) .. "'")
  end
  return expr(spelling, a, b)
end

function sym_neg(v)
  if not is_symbolic(v) then
    return M.neg(v)
  end
  if is_expr(v) then
    if is_inert(v) and v.op == "/" then
      return inert_quotient("/", sym_neg(v.left), v.right)
    end
    if v.op == "neg" then
      return v.left
    end
    if v.op == "+" then
      return sym_sub(sym_neg(v.left), v.right)
    end
    if v.op == "-" then
      return sym_sub(v.right, v.left)
    end
    if v.op == "*" and is_numeric(v.left) then
      return sym_mul(M.neg(v.left), v.right)
    end
    if v.op == "/" and is_numeric(v.right) then
      return sym_div(v.left, sym_neg(v.right))
    end
  end
  return expr("neg", v)
end

-- Calc's spelling: a product is a space, a sum keeps the operand order
-- it was built in, and only a lower-binding operand takes parentheses.
-- `number_text` renders numeric leaves, so a caller can pick org's
-- field formatting over M.to_string's.
local PRECEDENCE = {
  ["<"] = 0,
  ["<="] = 0,
  [">"] = 0,
  [">="] = 0,
  ["="] = 0,
  ["!="] = 0,
  ["+"] = 1,
  ["-"] = 1,
  ["*"] = 2,
  ["/"] = 2,
  ["%"] = 2,
  neg = 3,
  ["^"] = 4,
}

-- Whether a product's last factor is a bare variable, which decides
-- whether the next factor can follow it as juxtaposition.
local function trailing_symbol(node)
  if is_sym(node) then
    return true
  end
  return is_expr(node) and node.op == "*" and trailing_symbol(node.right)
end

function M.render_expr(v, number_text)
  local function render(node, outer)
    if is_sym(node) then
      return node.name
    end
    if is_fn(node) then
      local parts = {}
      for i, arg in ipairs(node.args) do
        parts[i] = render(arg, 0)
      end
      return node.name .. "(" .. table.concat(parts, ", ") .. ")"
    end
    if not is_expr(node) then
      return number_text(node)
    end
    local prec = PRECEDENCE[node.op]
    local text
    if node.op == "neg" then
      text = "-" .. render(node.left, prec)
    elseif node.op == "^" then
      local base = render(node.left, prec + 1)
      -- `-3^h1` would read back as -(3^h1), so a negative base keeps its
      -- parentheses.
      if is_numeric(node.left) and M.sign(node.left) < 0 then
        base = "(" .. base .. ")"
      end
      text = base .. "^" .. render(node.right, prec)
    elseif node.op == "*" then
      -- A remainder or a zero-divisor quotient inside a product reads as
      -- one term, so it keeps its parentheses on the left too.
      local grouped = is_inert(node.left) or (is_expr(node.left) and node.left.op == "%")
      local left = render(node.left, grouped and prec + 1 or prec)
      -- Only a collected coefficient is exact enough to be worth Calc's
      -- own `3:2` spelling; every other fraction has already floated.
      if is_rat(node.left) then
        left = bn.to_string(node.left.num) .. ":" .. bn.to_string(node.left.den)
      end
      local right = render(node.right, prec + 1)
      -- `h1 (h1 + 1)` would read as a function call, so Calc spells that
      -- one product with a `*`.
      local sep = (trailing_symbol(node.left) and right:sub(1, 1) == "(") and "*" or " "
      text = left .. sep .. right
    elseif node.op == "%" then
      -- A remainder's divisor binds like a product, so only a quotient
      -- or another remainder needs parentheses there.
      local tight = is_expr(node.right) and node.right.op == "*"
      text = render(node.left, prec) .. " % " .. render(node.right, tight and prec or prec + 1)
    elseif node.op == "/" and M.is_whole(node.left) and is_int(node.right) then
      -- Calc writes a quotient of two whole numbers the way it writes a
      -- fraction -- `8/0`, no spaces -- and spaces every other one out.
      text = render(node.left, prec) .. "/" .. render(node.right, prec + 1)
    else
      text = render(node.left, prec) .. " " .. node.op .. " " .. render(node.right, prec + 1)
    end
    if prec < outer then
      return "(" .. text .. ")"
    end
    return text
  end
  return render(v, 0)
end

-- Internal bridges for the sibling calc modules (not public API).
M._new_int = new_int
M._to_float = to_float_value
M._is_rat = is_rat

return M
