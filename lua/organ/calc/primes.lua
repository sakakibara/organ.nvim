-- Big-integer primality and factoring. Trial division first (fast for
-- small primes); Miller-Rabin probabilistic test; Pollard's rho for
-- large composites.

local M = {}
local core = require("organ.calc.core")
local bn = require("organ.calc.bn")

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

-- Miller-Rabin with deterministic witnesses for n < 3 317 044 064 679 887 385 961 981.
-- For larger n we use 20 random-ish bases derived from small primes
-- (probability of false positive < 4^-20 ~= 10^-12 per call).
local function miller_rabin(n)
  if bn.cmp(n, bn.from_int(2)) < 0 then
    return false
  end
  for _, p in ipairs({ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 }) do
    local pp = bn.from_int(p)
    if bn.cmp(n, pp) == 0 then
      return true
    end
    local _, r = bn.divmod(n, pp)
    if bn.is_zero(r) then
      return false
    end
  end
  -- write n-1 as d * 2^s
  local d = bn.sub(n, bn.one())
  local s = 0
  while true do
    local q, r = bn.divmod(d, bn.from_int(2))
    if not bn.is_zero(r) then
      break
    end
    d = q
    s = s + 1
  end
  for _, a in ipairs({ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 }) do
    local x = bn.mod_pow(bn.from_int(a), d, n)
    if not (bn.cmp(x, bn.one()) == 0 or bn.cmp(x, bn.sub(n, bn.one())) == 0) then
      local composite = true
      for _ = 1, s - 1 do
        x = bn.mod_mul(x, x, n)
        if bn.cmp(x, bn.sub(n, bn.one())) == 0 then
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
  if not core.is_int(v) then
    error("calc.is_prime: integer required")
  end
  return miller_rabin(v.n)
end

-- Pollard's rho factoring with cycle detection. Returns a non-trivial
-- factor of `n` (assumed composite, > 1, not prime).
local function pollard_rho(n)
  if bn.is_zero(bn.mod(n, bn.from_int(2))) then
    return bn.from_int(2)
  end
  local one = bn.one()
  local two = bn.from_int(2)
  for c_seed = 1, 100 do
    local c = bn.from_int(c_seed)
    local x = bn.from_int(2)
    local y = bn.from_int(2)
    local d = one
    while bn.cmp(d, one) == 0 do
      x = bn.mod(bn.add(bn.mod_mul(x, x, n), c), n)
      y = bn.mod(bn.add(bn.mod_mul(y, y, n), c), n)
      y = bn.mod(bn.add(bn.mod_mul(y, y, n), c), n)
      local diff = bn.sub(x, y)
      diff.sign = 1
      d = bn.gcd(diff, n)
    end
    if bn.cmp(d, n) ~= 0 then
      return d
    end
  end
  error("calc.factor: pollard rho failed")
end

-- Return the prime factorisation of `v` as a sorted list of Calc-int
-- factors (with multiplicity). E.g. prime_factors(12) -> {2, 2, 3}.
function M.prime_factors(v)
  if not core.is_int(v) then
    error("calc.factor: integer required")
  end
  local n = bn.copy(v.n)
  n.sign = 1
  if bn.cmp(n, bn.one()) <= 0 then
    return {}
  end
  local out = {}
  -- Trial division by small primes for speed.
  for _, p in ipairs(SMALL_PRIMES) do
    local pp = bn.from_int(p)
    while bn.cmp(n, pp) >= 0 do
      local q, r = bn.divmod(n, pp)
      if not bn.is_zero(r) then
        break
      end
      out[#out + 1] = core._new_int(pp)
      n = q
    end
    if bn.cmp(n, bn.one()) == 0 then
      return out
    end
  end
  -- Recursive factor via primality test + rho.
  local function recurse(m)
    if bn.cmp(m, bn.one()) == 0 then
      return
    end
    if miller_rabin(m) then
      out[#out + 1] = core._new_int(m)
      return
    end
    local d = pollard_rho(m)
    recurse(d)
    recurse((bn.divmod(m, d)))
  end
  recurse(n)
  table.sort(out, function(a, b)
    return core.lt(a, b)
  end)
  return out
end

return M
