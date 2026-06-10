-- Financial functions: pmt/fv/pv/npv/irr. Excel sign convention (outflows
-- negative, inflows positive). Computed as Lua doubles and returned as Calc
-- floats -- financial workloads almost never need bignum, and exact rational
-- arithmetic over (1 + rate)^nper is typically not what users want anyway.

local M = {}
local core = require("organ.calc.core")

local function _f(v)
  return core._to_float(v)
end

-- Periodic-payment formula. PMT = -pv * rate * (1+rate)^nper /
-- ((1+rate)^nper - 1).  Rate=0 short-circuits to -pv / nper.
function M.pmt(rate, nper, pv, fv, when)
  local r, n = _f(rate), _f(nper)
  local pv_v = pv ~= nil and _f(pv) or 0
  local fv_v = fv ~= nil and _f(fv) or 0
  local due = when and _f(when) or 0 -- 0 = end of period, 1 = beginning
  if r == 0 then
    return core.from_float(-(pv_v + fv_v) / n)
  end
  local k = (1 + r) ^ n
  local pmt = -(pv_v * k + fv_v) * r / ((k - 1) * (1 + r * due))
  return core.from_float(pmt)
end

-- Future value: FV = -(pv * (1+r)^n + pmt * ((1+r)^n - 1) / r).
function M.fv(rate, nper, pmt, pv, when)
  local r, n = _f(rate), _f(nper)
  local pmt_v = pmt ~= nil and _f(pmt) or 0
  local pv_v = pv ~= nil and _f(pv) or 0
  local due = when and _f(when) or 0
  if r == 0 then
    return core.from_float(-(pv_v + pmt_v * n))
  end
  local k = (1 + r) ^ n
  local fv = -(pv_v * k + pmt_v * (1 + r * due) * (k - 1) / r)
  return core.from_float(fv)
end

-- Present value: PV = -(fv + pmt * ((1+r)^n - 1) / r) / (1+r)^n.
function M.pv(rate, nper, pmt, fv, when)
  local r, n = _f(rate), _f(nper)
  local pmt_v = pmt ~= nil and _f(pmt) or 0
  local fv_v = fv ~= nil and _f(fv) or 0
  local due = when and _f(when) or 0
  if r == 0 then
    return core.from_float(-(fv_v + pmt_v * n))
  end
  local k = (1 + r) ^ n
  local pv = -(fv_v + pmt_v * (1 + r * due) * (k - 1) / r) / k
  return core.from_float(pv)
end

-- NPV = sum(cf[t] / (1+rate)^t) for t=1..N.  Cashflows is a list of
-- Calc values; the result is a Calc float.
function M.npv(rate, cashflows)
  local r = _f(rate)
  local sum = 0
  for t, cf in ipairs(cashflows) do
    sum = sum + _f(cf) / (1 + r) ^ t
  end
  return core.from_float(sum)
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
      return core.from_float(r)
    end
    local fd = dnpv(r)
    if fd == 0 then
      break
    end
    local r_new = r - f / fd
    if math.abs(r_new - r) < 1e-12 then
      return core.from_float(r_new)
    end
    r = r_new
  end
  error("calc.irr: did not converge")
end

return M
