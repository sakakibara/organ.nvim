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
--     + Pollard's rho) via M.is_prime / M.prime_factors.
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
--   integer  { kind = "int",   n = bignum (see organ/calc/bn.lua) }
--   rational { kind = "rat",   num = bignum, den = bignum (>0, gcd=1) }
--   float    { kind = "float", v = number }
--   unit     { kind = "unit",  v = numeric Calc value, dim = {…}, name = str }
--   symbol   { kind = "sym",   name = string }
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
local bn = require("organ.calc.bn")
local core = require("organ.calc.core")
local finance = require("organ.calc.finance")
local date = require("organ.calc.date")
local primes = require("organ.calc.primes")
local matrix = require("organ.calc.matrix")
local cas = require("organ.calc.cas")

-- organ.calc's public surface is assembled from the calc submodules.
-- The assert keeps two submodules from silently claiming the same name.
local function merge(src)
  for k, v in pairs(src) do
    assert(M[k] == nil, "organ.calc: duplicate member " .. k)
    M[k] = v
  end
end
merge(core)
merge(finance)
merge(date)
merge(primes)
merge(matrix)
merge(cas)

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
  zero = bn.zero,
  from_int = bn.from_int,
  from_string = bn.from_digits_string,
  to_string = bn.to_string,
  cmp = bn.cmp,
  add = bn.add,
  sub = bn.sub,
  mul = bn.mul,
  divmod = bn.divmod,
  gcd = bn.gcd,
  is_zero = bn.is_zero,
}

return M
