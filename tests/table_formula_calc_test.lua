-- Calc-backed evaluator: comparison, logical, conditional, exponent,
-- new aggregations, exact rational arithmetic.
-- Run via: nvim --headless -l tests/table_formula_calc_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local F = require("organ.table.formula")
local C = require("organ.calc")

local function eval_expr(s, ctx)
  ctx = ctx or { rows = {}, current_row = 1, current_col = 1 }
  local parsed = F.parse("$1 = " .. s)
  return F.eval(parsed[1].expr, ctx)
end

local function eval_calc_expr(s, ctx)
  ctx = ctx or { rows = {}, current_row = 1, current_col = 1 }
  local parsed = F.parse("$1 = " .. s)
  return F.eval_calc(parsed[1].expr, ctx)
end

local function close(a, b)
  return math.abs(a - b) < 1e-12
end

-- comparison operators

assert(eval_expr("1 < 2") == 1, "1 < 2")
assert(eval_expr("2 < 1") == 0, "2 < 1")
assert(eval_expr("1 <= 1") == 1, "1 <= 1")
assert(eval_expr("3 > 2") == 1, "3 > 2")
assert(eval_expr("3 >= 3") == 1, "3 >= 3")
assert(eval_expr("4 == 4") == 1, "4 == 4")
assert(eval_expr("4 == 5") == 0, "4 == 5")
assert(eval_expr("4 != 5") == 1, "4 != 5")

-- comparison with arithmetic in operands (precedence: comparison below additive)
assert(eval_expr("1 + 2 < 3 + 4") == 1, "1+2 < 3+4")
assert(eval_expr("2 * 3 == 6") == 1, "2*3 == 6")

-- exponent

assert(eval_expr("2 ^ 10") == 1024, "2 ^ 10")
assert(eval_expr("2 ^ 3 ^ 2") == 512, "right-assoc: 2 ^ (3^2)")
-- unary minus binds looser than ^ (matches Lua / Calc / Python convention).
assert(eval_expr("-2 ^ 2") == -4, "-2^2 = -(2^2) = -4")

-- conditional (if)

assert(eval_expr("if(1, 2, 3)") == 2, "if true → then-branch")
assert(eval_expr("if(0, 2, 3)") == 3, "if false → else-branch")
assert(eval_expr("if(2 > 1, 100, 200)") == 100)
assert(eval_expr("if(0, 1/0, 42)") == 42, "else branch evaluated only — no div-by-zero error")

-- logical (and / or / not)

assert(eval_expr("and(1, 1)") == 1)
assert(eval_expr("and(1, 0)") == 0)
assert(eval_expr("or(0, 0)") == 0)
assert(eval_expr("or(0, 5)") == 1)
assert(eval_expr("not(0)") == 1)
assert(eval_expr("not(5)") == 0)

-- exact rational arithmetic, surfaced via eval_calc

do
  local v = eval_calc_expr("1/3 + 1/3 + 1/3")
  -- The parser tokenizes "1/3" as 1 then division by 3 — gives a rational.
  assert(C.eq(v, C.from_int(1)), "1/3 + 1/3 + 1/3 should equal 1 exactly; got " .. C.to_string(v))
end

do
  local v = eval_calc_expr("2 ^ 64")
  assert(C.to_string(v) == "18446744073709551616", "2^64 exact: got " .. C.to_string(v))
end

-- new aggregations: vmedian, vsdev, vvar, vproduct, vmaxabs

do
  -- Build a table with cells in column 1, rows 1..5.
  local rows = {
    { cells = { "1" } },
    { cells = { "2" } },
    { cells = { "3" } },
    { cells = { "4" } },
    { cells = { "5" } },
  }
  local ctx = { rows = rows, current_row = 1, current_col = 1 }

  assert(eval_expr("vmedian(@1..@5)", ctx) == 3, "median 1..5")
  assert(eval_expr("vproduct(@1..@5)", ctx) == 120, "product 1..5")

  local var = eval_expr("vvar(@1..@5)", ctx)
  assert(close(var, 2.5), "var 1..5 = 2.5; got " .. tostring(var))

  local sdev = eval_expr("vsdev(@1..@5)", ctx)
  assert(close(sdev, math.sqrt(2.5)), "sdev: got " .. tostring(sdev))
end

do
  local rows = {
    { cells = { "-5" } },
    { cells = { "3" } },
    { cells = { "-1" } },
  }
  local ctx = { rows = rows, current_row = 1, current_col = 1 }
  assert(eval_expr("vmaxabs(@1..@3)", ctx) == 5, "max-abs of {-5,3,-1} = 5")
end

-- new scalar functions: cbrt, sinh, cosh, tanh, factorial, ln, trunc

assert(close(eval_expr("cbrt(27)"), 3))
assert(close(eval_expr("sinh(0)"), 0))
assert(close(eval_expr("cosh(0)"), 1))
assert(close(eval_expr("tanh(0)"), 0))
assert(eval_expr("factorial(5)") == 120)
assert(close(eval_expr("ln(e)"), 1))
assert(eval_expr("trunc(3/2)") == 1)
assert(eval_expr("trunc(-3/2)") == -1)

-- new binary functions: gcd, lcm, binomial

assert(eval_expr("gcd(12, 18)") == 6)
assert(eval_expr("lcm(4, 6)") == 12)
assert(eval_expr("binomial(5, 2)") == 10)
assert(eval_expr("binomial(10, 0)") == 1)

io.write("table formula calc ok\n")
os.exit(0)
