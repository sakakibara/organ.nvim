-- Symbolic calculus over the formula AST: differentiation, expand,
-- factor, simplify, limits (direct substitution + L'Hopital fallback),
-- and antiderivative-table integration.
--
-- Nodes have a `kind` field per organ.table.formula. Functions operate
-- on AST in, AST out; eval is handled by formula.eval / formula.eval_calc.

local M = {}
local core = require("organ.calc.core")

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
-- variable to differentiate against -- typically `{ kind = "const",
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

-- Polynomial / algebraic manipulation. A pragmatic computer-algebra
-- subset:
--
--   M.expand(ast)  -- distribute multiplication over addition, lower
--                    powers to repeated multiplication when the
--                    exponent is a small non-negative literal.
--   M.factor(ast)  -- recognise a few patterns: difference of squares,
--                    common factor in a sum.
--   M.simplify(ast) -- repeated ast_simplify until fixpoint.
--
-- This is not a full CAS -- there's no canonical-form representation
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
      -- (a + b) * c -> a*c + b*c
      if L.kind == "binop" and (L.op == "+" or L.op == "-") then
        return ast_simplify(
          ast_bin(L.op, M.expand(ast_bin("*", L.left, R)), M.expand(ast_bin("*", L.right, R)))
        )
      end
      -- a * (b + c) -> a*b + a*c
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
  -- common factor in a sum: c*x + c*y -> c*(x+y)
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
--   2. L'Hopital fallback for f/g where both f(c)=0 and g(c)=0:
--      recurse on f'/g' and try again. Bounded depth to avoid loops.
--
-- This handles all the limit problems an org-table user is realistic
-- to write. Genuinely indeterminate forms beyond 0/0 (inf/inf, 0*inf,
-- inf-inf, 0^0, inf^0, 1^inf) need asymptotic analysis and are
-- NOT_IMPLEMENTED.

local function _eval_at(ast, var, c)
  local F = require("organ.table.formula")
  local ctx = { rows = {}, current_row = 1, current_col = 1, vars = { [var] = c } }
  local ok, v = pcall(F.eval_calc, ast, ctx)
  if not ok or core.is_inert(v) then
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
  -- 2. L'Hopital: f/g with f(c)=0 and g(c)=0 -> f'/g'
  if ast.kind == "binop" and ast.op == "/" then
    local num_v = _eval_at(ast.left, var, c)
    local den_v = _eval_at(ast.right, var, c)
    if num_v and den_v and core.sign(num_v) == 0 and core.sign(den_v) == 0 then
      local num_d = M.deriv_simplify(ast.left, var)
      local den_d = M.deriv_simplify(ast.right, var)
      return M.limit({ kind = "binop", op = "/", left = num_d, right = den_d }, var, c, _depth + 1)
    end
    if num_v and den_v then
      return core.div(num_v, den_v)
    end
  end
  return nil
end

-- Symbolic integration via a small antiderivative table. Handles:
--
--   integ(c)         = c * x
--   integ(x)         = x^2 / 2
--   integ(x^n)       = x^(n+1) / (n+1),   n ~= -1, n constant
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
    -- integral c dx = c * x
    return ast_bin("*", node, ast_const(var))
  end
  if ast_is_var(node, var) then
    -- integral x dx = x^2 / 2
    return ast_bin("/", ast_bin("^", node, ast_num(2)), ast_num(2))
  end
  if node.kind == "binop" then
    if node.op == "+" or node.op == "-" then
      return ast_bin(node.op, M.integ(node.left, var), M.integ(node.right, var))
    end
    if node.op == "*" then
      -- c * f -> c * integral(f).  f * c -> c * integral(f).
      if ast_is_constant_in(node.left, var) then
        return ast_bin("*", node.left, M.integ(node.right, var))
      end
      if ast_is_constant_in(node.right, var) then
        return ast_bin("*", node.right, M.integ(node.left, var))
      end
      error("calc.integ: integration by parts not implemented")
    end
    if node.op == "/" then
      -- 1/x -> ln(x)
      if node.left.kind == "num" and node.left.value == 1 and ast_is_var(node.right, var) then
        return ast_call("ln", { node.right })
      end
      -- f / c -> f integrated, divided by c
      if ast_is_constant_in(node.right, var) then
        return ast_bin("/", M.integ(node.left, var), node.right)
      end
      error("calc.integ: general 1/f not implemented (only 1/x recognised)")
    end
    if node.op == "^" then
      -- x^n -> x^(n+1) / (n+1) for constant n != -1
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

return M
