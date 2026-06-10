-- Matrix linear algebra. A matrix is { kind = "mat", rows = R, cols = C,
-- d = { [r] = { [c] = Calc } } } -- element type is Calc, so determinants
-- of integer matrices stay exact.

local M = {}
local core = require("organ.calc.core")

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
        d[i][j] = core.from_number(x)
      elseif core.is_calc(x) then
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
      d[i][j] = core.add(a.d[i][j], b.d[i][j])
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
      d[i][j] = core.sub(a.d[i][j], b.d[i][j])
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
      local s = core.from_int(0)
      for k = 1, a.cols do
        s = core.add(s, core.mul(a.d[i][k], b.d[k][j]))
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
      L.d[i][j] = (i == j) and core.from_int(1) or core.from_int(0)
    end
  end
  local perm = {}
  for i = 1, n do
    perm[i] = i
  end
  local sign = 1
  for k = 1, n do
    -- partial pivot: pick row with largest |U[i][k]| for numerical stability
    local max_i, max_v = k, core.abs(U.d[k][k])
    for i = k + 1, n do
      local v = core.abs(U.d[i][k])
      if core.gt(v, max_v) then
        max_i, max_v = i, v
      end
    end
    if core.sign(max_v) == 0 then
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
      local factor = core.div(U.d[i][k], U.d[k][k])
      L.d[i][k] = factor
      for j = k, n do
        U.d[i][j] = core.sub(U.d[i][j], core.mul(factor, U.d[k][j]))
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
      return core.from_int(0)
    end
    error("calc.det: " .. err)
  end
  local d = core.from_int(lu.sign)
  for i = 1, a.rows do
    d = core.mul(d, lu.U.d[i][i])
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
      m[i][n + j] = (i == j) and core.from_int(1) or core.from_int(0)
    end
  end
  for k = 1, n do
    local max_i, max_v = k, core.abs(m[k][k])
    for i = k + 1, n do
      local v = core.abs(m[i][k])
      if core.gt(v, max_v) then
        max_i, max_v = i, v
      end
    end
    if core.sign(max_v) == 0 then
      error("calc.inv: singular matrix")
    end
    if max_i ~= k then
      m[k], m[max_i] = m[max_i], m[k]
    end
    local pivot = m[k][k]
    for j = 1, 2 * n do
      m[k][j] = core.div(m[k][j], pivot)
    end
    for i = 1, n do
      if i ~= k and core.sign(m[i][k]) ~= 0 then
        local factor = m[i][k]
        for j = 1, 2 * n do
          m[i][j] = core.sub(m[i][j], core.mul(factor, m[k][j]))
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
  local s = core.from_int(0)
  for i = 1, n do
    s = core.add(s, core.mul(u[i], w[i]))
  end
  return s
end

local function vec_norm(v, n)
  return core.sqrt(vec_dot(v, v, n))
end

local function vec_scale(v, s, n)
  local out = {}
  for i = 1, n do
    out[i] = core.div(v[i], s)
  end
  return out
end

local function mat_vec(A, v, n)
  local out = {}
  for i = 1, n do
    local s = core.from_int(0)
    for j = 1, n do
      s = core.add(s, core.mul(A.d[i][j], v[j]))
    end
    out[i] = s
  end
  return out
end

-- Subtract lambda*v*v^T from a square matrix (symmetric deflation).
local function deflate(A, lambda, v, n)
  local d = {}
  for i = 1, n do
    d[i] = {}
    for j = 1, n do
      d[i][j] = core.sub(A.d[i][j], core.mul(core.mul(lambda, v[i]), v[j]))
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
    v[i] = core.from_float((i % 2 == 0) and 1.0 or 0.5)
  end
  local nv = vec_norm(v, n)
  if core.sign(nv) == 0 then
    v[1] = core.from_int(1)
    nv = core.from_int(1)
  end
  v = vec_scale(v, nv, n)
  local lambda = core.from_int(0)
  for _ = 1, max_iter do
    local Av = mat_vec(A, v, n)
    local new_lambda = vec_dot(v, Av, n) -- Rayleigh quotient
    local nrm = vec_norm(Av, n)
    if core.sign(nrm) == 0 then
      return lambda, v
    end
    local v_new = vec_scale(Av, nrm, n)
    if math.abs(core.to_number(core.sub(new_lambda, lambda))) < tol then
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

return M
