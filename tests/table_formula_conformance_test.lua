-- tests/table_formula_conformance_test.lua
-- Run via: nvim --headless -l tests/table_formula_conformance_test.lua
--
-- Where a table formula's answer has a shape, not just a value: whether
-- a result is exact, whether a constant stays symbolic, and what
-- happens where Calc leaves the reals.  Every expected string below is
-- Emacs's, read off `org-table-recalculate` over this same two-row
-- table, spelling included -- `floor(1.7)` is the integer 1, not the
-- float `1.`, and `arctan(1)` is 45 rather than `45.`.
--
-- Where Calc answers with a complex pair or a float past the range of
-- a double, organ has no such value.  It refuses: the buffer is left
-- byte for byte as the user wrote it and a message says why, which is
-- what `assert_refused` pins.  Writing `#ERROR` over the field, or a
-- real number that is not the answer, would both cost the user data.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")

local FIXTURE = {
  "| h1 | 2 |  |",
  "| x  | 3 |  |",
}

local function mk_buf(tblfm)
  local lines = vim.list_slice(FIXTURE, 1, #FIXTURE)
  lines[#lines + 1] = "#+TBLFM: " .. tblfm
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return b
end

local function get_lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

local function cells(line)
  local out = {}
  for c in line:gmatch("|([^|]*)") do
    out[#out + 1] = c:match("^%s*(.-)%s*$")
  end
  out[#out] = nil
  return out
end

local function assert_third(tblfm, want)
  local b = mk_buf(tblfm)
  assert(tab.eval_formulas(b), tblfm .. ": expected the formula to be applied")
  assert_eq(cells(get_lines(b)[1])[3], want, tblfm .. ":")
end

-- A refusal reports and changes nothing, so the fixture has to come
-- back byte for byte.
local function assert_refused(tblfm)
  local b = mk_buf(tblfm)
  assert_eq(tab.eval_formulas(b), false, tblfm .. ": expected a refusal")
  local lines = get_lines(b)
  assert_eq(#lines, #FIXTURE + 1, tblfm .. ": line count")
  for i, want in ipairs(FIXTURE) do
    assert_eq(lines[i], want, tblfm .. " line " .. i .. " must be byte-unchanged:")
  end
  assert_eq(lines[#lines], "#+TBLFM: " .. tblfm, tblfm .. ": formula line must be byte-unchanged:")
end

-- Rounding answers with an exact integer whatever the argument's
-- exactness -- float, rational or integer alike -- and `round` goes
-- half away from zero.

assert_third("$3=floor(tan(0.0))", "0")
assert_third("$3=floor(1.7)", "1")
assert_third("$3=floor(-1.7)", "-2")
assert_third("$3=ceil(1.2)", "2")
assert_third("$3=ceil(-1.2)", "-1")
assert_third("$3=trunc(1.7)", "1")
assert_third("$3=trunc(-1.7)", "-1")
assert_third("$3=round(2.5)", "3")
assert_third("$3=round(-2.5)", "-3")
assert_third("$3=round(3.5)", "4")
assert_third("$3=round(-3.5)", "-4")
assert_third("$3=round(2.4)", "2")
assert_third("$3=floor(1/3)", "0")
assert_third("$3=floor(-1/3)", "-1")
assert_third("$3=round(7/2)", "4")
assert_third("$3=round(-7/2)", "-4")
assert_third("$3=floor(sin(30))", "0")
assert_third("$3=round(sin(30))", "1")
assert_third("$3=floor(-0.0)", "0")
assert_third("$3=ceil(-0.5)", "0")

-- A Calc float carries twelve significant decimal digits, so the
-- integer a large one names is read off that decimal form: 1e30 is ten
-- to the thirtieth, not the value the binary double sits on.
assert_third("$3=floor(1e30)", "1" .. string.rep("0", 30))
assert_third("$3=round(1e300)", "1" .. string.rep("0", 300))
assert_third("$3=floor(9007199254740993.0)", "9007199254740000")
assert_third("$3=floor(1.5e10)", "15000000000")
assert_third("$3=round(1.23456789e15)", "1234567890000000")

-- `%` is not in that class: it keeps its arguments' inexactness.
assert_third("$3=5%3", "2")
assert_third("$3=5.5%3", "2.5")
assert_third("$3=7%2.5", "2.")
assert_third("$3=0.0%3", "0.")

-- Calc answers these with a complex pair, or with a float past the
-- range of a double.  organ has neither, so it declines.
assert_refused("$3=ln(-1)")
assert_refused("$3=ln(-4)")
assert_refused("$3=log(-1)")
assert_refused("$3=log10(-4)")
assert_refused("$3=(-4)^0.5")
assert_refused("$3=(-4)^(1/2)")
assert_refused("$3=(-8)^(1/3)")
assert_refused("$3=(-2.0)^0.5")
assert_refused("$3=sqrt(-4)")
assert_refused("$3=exp(1e3)")
assert_refused("$3=exp(1000)")
assert_refused("$3=cosh(1e3)")
assert_refused("$3=arcsin(2)")
assert_refused("$3=arccos(-2)")

-- A negative base with a whole exponent is real, and stays answered.
assert_third("$3=(-2)^2", "4")
assert_third("$3=(-2)^2.0", "4.")
assert_third("$3=(-2)^3", "-8")

-- The logarithm of zero has no answer for Calc either, and there the
-- call stands rather than refusing.
assert_third("$3=ln(0)", "ln(0)")
assert_third("$3=log10(0)", "log10(0)")

-- Calc's spellings of the inverse trig functions, in the formula's own
-- angular mode.  Exact at the three cardinal arguments when the
-- argument is exact; in Radians only the zero angle survives.
assert_third("$3=arcsin(1)", "90")
assert_third("$3=arcsin(-1)", "-90")
assert_third("$3=arcsin(0)", "0")
assert_third("$3=arccos(1)", "0")
assert_third("$3=arccos(0)", "90")
assert_third("$3=arccos(-1)", "180")
assert_third("$3=arctan(1)", "45")
assert_third("$3=arctan(-1)", "-45")
assert_third("$3=arctan(0)", "0")
assert_third("$3=arcsin(0.5)", "30.")
assert_third("$3=arccos(0.5)", "60.")
assert_third("$3=arcsin(1.0)", "90.")
assert_third("$3=arccos(-0.5)", "120.")
assert_third("$3=arctan(2)", "63.434949")
assert_third("$3=arcsin(0);R", "0")
assert_third("$3=arccos(1);R", "0")
assert_third("$3=arcsin(1);R", "1.5707963")
assert_third("$3=arctan(1);R", "0.78539816")
assert_third("$3=arcsin(0.5);R", "0.52359878")

-- `arctan2` reads both arguments, so it answers in the right quadrant,
-- and is a float even where its arguments are exact.
assert_third("$3=arctan2(1,1)", "45.")
assert_third("$3=arctan2(0,1)", "0.")
assert_third("$3=arctan2(1,0)", "90.")
assert_third("$3=arctan2(-1,0)", "-90.")
assert_third("$3=arctan2(1,-1)", "135.")
assert_third("$3=arctan2(-1,-1)", "-135.")

-- organ's own spellings answer as they always have, beside Calc's.
assert_third("$3=asin(0.5)", "30.")
assert_third("$3=acos(0.5)", "60.")
assert_third("$3=atan(1)", "45.")
assert_third("$3=atan2(1,-1)", "135.")
assert_third("$3=asin(sin(30))", "30.")

-- Where organ has no answer for one of its own functions, the call
-- stands -- which is what Calc prints for these anyway.
assert_third("$3=asin(2)", "asin(2)")
assert_third("$3=acos(-2)", "acos(-2)")
assert_third("$3=log2(-4)", "log2(-4)")
assert_third("$3=binomial(0.5,2)", "binomial(0.5, 2)")
assert_third("$3=factorial(0.5)", "factorial(0.5)")
assert_third("$3=factorial(-1)", "factorial(-1)")
assert_third("$3=cbrt(-8)", "-2.")
assert_third("$3=tanh(1e3)", "1.")

-- A reciprocal of zero keeps its form, the way `1/0` does.
assert_third("$3=(0)^(-1)", "0^-1")
assert_third("$3=(0.0)^(-1)", "0.^-1")

-- `pi` and `e` are symbols, so they carry through arithmetic instead of
-- collapsing to a float, and a function of one stands unevaluated.
assert_third("$3=pi", "pi")
assert_third("$3=e", "e")
assert_third("$3=pi*2", "2 pi")
assert_third("$3=2*pi", "2 pi")
assert_third("$3=pi/2", "pi / 2")
assert_third("$3=pi+1", "pi + 1")
assert_third("$3=pi-pi", "0")
assert_third("$3=pi^2", "pi^2")
assert_third("$3=e^2", "e^2")
assert_third("$3=sin(pi)", "sin(pi)")
assert_third("$3=sin(pi/2)", "sin(pi / 2)")
assert_third("$3=sin(pi/2);R", "sin(pi / 2)")
assert_third("$3=$1+pi", "h1 + pi")
assert_third("$3=max(pi,1)", "max(pi, 1)")
assert_third("$3=pi>1", "pi > 1")
assert_third("$3=if(1,pi,e)", "pi")
-- `;N` asks for a number, and a symbol is not one.
assert_third("$3=pi;N", "#ERROR")
assert_third("$3=e;N", "#ERROR")
-- A printf template reads the leading number of the text, which is none.
assert_third("$3=pi;%.3f", "0.000")

-- An exponent literal is a float, whatever its magnitude.
assert_third("$3=1e3", "1000.")
assert_third("$3=1.5e3", "1500.")
assert_third("$3=1e-3", "1e-3")
assert_third("$3=1e30", "1e30")
assert_third("$3=2e2", "200.")
assert_third("$3=1.0e3", "1000.")
assert_third("$3=1e3+1", "1001.")
assert_third("$3=1e3*2", "2000.")

-- Calc has no negative zero, so nothing it prints starts "-0.".
assert_third("$3=cos(180/2)*0;R%.3f", "0.000")
assert_third("$3=cos(90)*0", "0")
assert_third("$3=-0.0", "0.")
assert_third("$3=0.0*-1", "0.")
assert_third("$3=cos(90);%.3f", "0.000")

-- Everything above must not have disturbed the ordinary answers.
assert_third("$3=sin(30)", "0.5")
assert_third("$3=sin(180)", "0")
assert_third("$3=tan(90)", "tan(90)")
assert_third("$3=sin(30);R", "-0.98803162")
assert_third("$3=8/2*4", "1")
assert_third("$3=vsum(3,4)", "7")
assert_third("$3=8/0", "8/0")
assert_third("$3=(2*$1)/(4*$1)", "0.5 h1 / h1")
assert_third("$3=$1+$1/2", "3:2 h1")
assert_third("$3=sqrt($1*4)", "2 sqrt(h1)")
assert_third("$3=$1*2", "2 h1")
assert_third("$3=sqrt(4)", "2")

io.write("table formula conformance ok\n")
os.exit(0)
