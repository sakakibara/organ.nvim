-- Extended Calc operators in TBLFM: scalar (abs/sqrt/exp/log/sin/...),
-- two-arg (pow/mod/min/max), and constants (pi/e).
-- Run via: nvim --headless -l tests/table_formula_extended_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local f = require("organ.table.formula")

local function close(a, b)
  return math.abs(a - b) < 1e-9
end

-- A 1-row, 1-col fake context. The expr never references cells.
local function eval_expr_only(src)
  local parsed = f.parse("$1=" .. src)
  return f.eval(parsed[1].expr, {
    rows = { { cells = {} } },
    current_row = 1,
    current_col = 1,
  })
end

-- The same, with `pi` / `e` bound to numbers.  Calc reads them as
-- symbols, so a caller that wants the number asks for it.
local function eval_bound(src, vars, radians)
  local parsed = f.parse("$1=" .. src)
  local bound = {}
  for name, x in pairs(vars) do
    bound[name] = require("organ.calc").from_float(x)
  end
  return f.eval(parsed[1].expr, {
    rows = { { cells = {} } },
    current_row = 1,
    current_col = 1,
    vars = bound,
    radians = radians,
  })
end

-- The same, in the angular mode a formula asks for with `;R`.
local function eval_radians(src)
  local parsed = f.parse("$1=" .. src)
  return f.eval(parsed[1].expr, {
    rows = { { cells = {} } },
    current_row = 1,
    current_col = 1,
    radians = true,
  })
end

assert(close(eval_expr_only("abs(-3)"), 3), "abs")
assert(close(eval_expr_only("sqrt(16)"), 4), "sqrt")
assert(close(eval_expr_only("ceil(2.1)"), 3), "ceil")
assert(close(eval_expr_only("floor(2.9)"), 2), "floor")
assert(close(eval_expr_only("round(2.5)"), 3), "round")
assert(close(eval_expr_only("sign(-5)"), -1), "sign")
assert(close(eval_expr_only("exp(0)"), 1), "exp")
assert(close(eval_bound("log(e)", { e = math.exp(1) }), 1), "log(e) = 1")
assert(close(eval_expr_only("log10(100)"), 2), "log10")
assert(close(eval_expr_only("log2(8)"), 3), "log2")
assert(close(eval_expr_only("sin(0)"), 0), "sin")
assert(close(eval_expr_only("cos(0)"), 1), "cos")
assert(close(eval_expr_only("sin(30)"), 0.5), "sin degrees")
assert(close(eval_expr_only("cos(60)"), 0.5), "cos degrees")
assert(close(eval_expr_only("tan(45)"), 1), "tan degrees")
assert(close(eval_expr_only("sind(90)"), 1), "sind degrees")
assert(close(eval_expr_only("cosd(180)"), -1), "cosd degrees")

assert(close(eval_expr_only("pow(2, 10)"), 1024), "pow")
assert(close(eval_expr_only("mod(7, 3)"), 1), "mod")
assert(close(eval_expr_only("min(3, 5)"), 3), "min")
assert(close(eval_expr_only("max(3, 5)"), 5), "max")
assert(close(eval_expr_only("atan2(1, 1)"), 45), "atan2 degrees")
assert(close(eval_radians("atan2(1, 1)"), math.pi / 4), "atan2 radians")

-- Calc keeps `pi` and `e` symbolic in a table formula, so that is what
-- a bare constant evaluates to; a caller binds the symbol for a number.
assert(f.format_value(eval_expr_only("pi")) == "pi", "pi const")
assert(f.format_value(eval_expr_only("e")) == "e", "e const")
assert(close(eval_bound("pi", { pi = math.pi }), math.pi), "pi bound")
assert(close(eval_bound("e", { e = math.exp(1) }), math.exp(1)), "e bound")

-- Aggregations still work over real cells.
do
  local parsed = f.parse("@3$3=vsum(@1$1..@1$3)")
  local rows = {
    { cells = { "1", "2", "3" } },
    { cells = {} },
    { cells = {} },
  }
  local v = f.eval(parsed[1].expr, { rows = rows, current_row = 3, current_col = 3 })
  assert(close(v, 6), "vsum still works; got " .. tostring(v))
end

-- Composition: scalar wraps an aggregation.
do
  local parsed = f.parse("@3$3=sqrt(vsum(@1$1..@1$3))")
  local rows = {
    { cells = { "1", "2", "3" } },
    { cells = {} },
    { cells = {} },
  }
  local v = f.eval(parsed[1].expr, { rows = rows, current_row = 3, current_col = 3 })
  assert(close(v, math.sqrt(6)), "sqrt(vsum(1..3)) = sqrt(6); got " .. tostring(v))
end

-- Trig with constants.  Calc leaves `sin(pi / 2)` standing because
-- `pi` is a symbol; bind it and the radian answer is 1.
assert(f.format_value(eval_radians("sin(pi/2)")) == "sin(pi / 2)", "sin(pi/2) stands")
assert(close(eval_bound("sin(pi/2)", { pi = math.pi }, true), 1), "sin(pi/2)")

io.write("table formula extended ok\n")
os.exit(0)
