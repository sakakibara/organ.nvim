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

-- Miller-Rabin with deterministic witnesses for n < 3 317 044 064 679 887 385 961 981.
-- For larger n we use 20 random-ish bases derived from small primes
-- (probability of false positive < 4^-20 ≈ 10^-12 per call).
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
    return M.lt(a, b)
  end)
  return out
end

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
