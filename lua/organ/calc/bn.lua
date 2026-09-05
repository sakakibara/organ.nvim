-- Arbitrary-precision signed integers.
--
-- A bignum is { sign = 1|-1, d = { lsb-digit, ..., msb-digit } } where each
-- digit is a base-10^7 limb. Zero is { sign = 1, d = { 0 } }. Base 10^7
-- keeps the product of two digits within Lua's exact-int range (2^53), so
-- multiplication never loses precision and decimal printing is
-- straightforward.

local M = {}

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

local function bn_digits(b)
  local top, n = b.d[#b.d], 0
  while top >= 1 do
    top = math.floor(top / 10)
    n = n + 1
  end
  return (#b.d - 1) * BASE_DIGITS + math.max(n, 1)
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

local function bn_one()
  return bn_from_int(1)
end

local function bn_mod(a, m)
  return (select(2, bn_divmod(a, m)))
end

-- Modular multiplication for bignums via long multiplication then mod.
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

M.zero = bn_zero
M.one = bn_one
M.from_int = bn_from_int
M.from_digits_string = bn_from_digits_string
M.to_string = bn_to_string
M.digits = bn_digits
M.cmp = bn_cmp
M.is_zero = bn_is_zero
M.neg = bn_neg
M.copy = bn_copy
M.add = bn_add
M.sub = bn_sub
M.mul = bn_mul
M.divmod = bn_divmod
M.gcd = bn_gcd
M.mod = bn_mod
M.mod_mul = bn_mod_mul
M.mod_pow = bn_mod_pow

return M
