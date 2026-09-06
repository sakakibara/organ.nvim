-- tests/table_formula_trig_test.lua
-- Run via: nvim --headless -l tests/table_formula_trig_test.lua
--
-- Calc's angular mode.  A table formula computes in Degrees unless it
-- carries `;R`, so `sin(30)` is 0.5 -- a plausible-looking radian answer
-- in that field is worse than no answer at all.  Expected values are
-- Emacs's, taken from
--   emacs --batch -Q -l org --eval '(org-table-recalculate t)'
-- over the same table, down to the spelling: Calc answers exactly at a
-- quadrant boundary (`sin(180)` is 0, not 1.2e-16) and keeps `tan(90)`
-- as the call, because the tangent has no value there.
--
-- `asin` / `acos` / `atan` / `atan2` are organ's, not Calc's: Emacs
-- leaves those calls unevaluated.  organ answers them, in the same
-- angular mode as the forward functions, so `asin(sin(30))` is 30.

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

-- `want` is $3 in the first data row; both rows carry the same formula.
local function assert_third(tblfm, want)
  local b = mk_buf(tblfm)
  assert(tab.eval_formulas(b), tblfm .. ": expected the formula to be applied")
  assert_eq(cells(get_lines(b)[1])[3], want, tblfm .. ":")
end

local function assert_refused(tblfm)
  local b = mk_buf(tblfm)
  assert_eq(tab.eval_formulas(b), false, tblfm .. ": expected a refusal")
  local lines = get_lines(b)
  assert_eq(#lines, #FIXTURE + 1, tblfm .. ": line count")
  for i, want in ipairs(FIXTURE) do
    assert_eq(lines[i], want, tblfm .. " line " .. i .. " must be byte-unchanged:")
  end
end

-- Degrees is the default.
assert_third("$3=sin(30)", "0.5")
assert_third("$3=cos(60)", "0.5")
assert_third("$3=tan(45)", "1.")
assert_third("$3=sin(45)", "0.70710678")
assert_third("$3=cos(45)", "0.70710678")
assert_third("$3=sin(-30)", "-0.5")
assert_third("$3=sin(1.5)", "0.026176948")
assert_third("$3=sin($2*15)", "0.5")

-- `;R` switches that formula to Radians, `;D` spells the default out,
-- and the last of the two wins.
assert_third("$3=sin(30);R", "-0.98803162")
assert_third("$3=cos(60);R", "-0.95241298")
assert_third("$3=tan(45);R", "1.6197752")
assert_third("$3=sin(30);D", "0.5")
assert_third("$3=cos(60);D", "0.5")
assert_third("$3=tan(45);D", "1.")
assert_third("$3=sin(30);RD", "0.5")
assert_third("$3=sin(30);DR", "-0.98803162")

-- Composes with the flags organ already had.
assert_third("$3=sin(30);N", "0.5")
assert_third("$3=sin(30);NR", "-0.98803162")
assert_third("$3=sin(30);RN", "-0.98803162")
assert_third("$3=sin(30);%.4f", "0.5000")
assert_third("$3=sin(30);D%.4f", "0.5000")
assert_third("$3=sin(30);R%.2f", "-0.99")
assert_third("$3=sin(30);N%.3f", "0.500")

-- At a quadrant boundary Calc has an exact answer, and gives it in the
-- argument's own exactness: an integer for an integer, a float for a
-- float.
assert_third("$3=sin(0)", "0")
assert_third("$3=sin(90)", "1")
assert_third("$3=sin(180)", "0")
assert_third("$3=sin(270)", "-1")
assert_third("$3=sin(360)", "0")
assert_third("$3=sin(-180)", "0")
assert_third("$3=cos(0)", "1")
assert_third("$3=cos(90)", "0")
assert_third("$3=cos(180)", "-1")
assert_third("$3=cos(270)", "0")
assert_third("$3=cos(-90)", "0")
assert_third("$3=tan(0)", "0")
assert_third("$3=tan(180)", "0")
assert_third("$3=tan(360)", "0")
assert_third("$3=sin(180/2)", "1")
assert_third("$3=cos(180/2)", "0")
assert_third("$3=sin(90.0)", "1.")
assert_third("$3=sin(180.0)", "0.")
assert_third("$3=cos(90.0)", "0.")
assert_third("$3=tan(180.0)", "0.")
assert_third("$3=sin(90)+cos(90)", "1")

-- The tangent has no value at an odd multiple of 90 degrees, so Calc
-- keeps the call rather than answering with the 1.6e16 a trip through
-- radians would produce.
assert_third("$3=tan(90)", "tan(90)")
assert_third("$3=tan(270)", "tan(270)")
assert_third("$3=tan(-90)", "tan(-90)")
assert_third("$3=tan(450)", "tan(450)")
assert_third("$3=tan(180/2)", "tan(90)")
assert_third("$3=tan(90.0)", "tan(90.)")

-- Radians keeps its own exact point at zero.
assert_third("$3=sin(0);R", "0")
assert_third("$3=cos(0);R", "1")
assert_third("$3=tan(0);R", "0")
assert_third("$3=sin(0.0);R", "0.")
assert_third("$3=cos(0.0);R", "1.")

-- Hyperbolics ignore the angular mode.
assert_third("$3=sinh(1)", "1.1752012")
assert_third("$3=cosh(1)", "1.5430806")
assert_third("$3=tanh(1)", "0.76159416")
assert_third("$3=sinh(1);R", "1.1752012")

-- organ's own degree spellings keep working, in either mode.
assert_third("$3=sind(30)", "0.5")
assert_third("$3=cosd(60)", "0.5")
assert_third("$3=tand(45)", "1.")
assert_third("$3=sind(30);R", "0.5")
assert_third("$3=cosd(180)", "-1")
assert_third("$3=sind(180)", "0")
assert_third("$3=tand(90)", "tand(90)")

-- The inverses answer in the formula's angular mode, so they invert the
-- forward functions.  Emacs leaves every one of these unevaluated.
assert_third("$3=asin(0.5)", "30.")
assert_third("$3=acos(0.5)", "60.")
assert_third("$3=atan(1)", "45.")
assert_third("$3=atan2(1,1)", "45.")
assert_third("$3=asin(sin(30))", "30.")
assert_third("$3=asin(0.5);R", "0.52359878")
assert_third("$3=acos(0.5);R", "1.0471976")
assert_third("$3=atan(1);R", "0.78539816")
assert_third("$3=atan2(1,1);R", "0.78539816")
assert_third("$3=asin(0.5);D", "30.")

-- gcd and lcm take a float that happens to be whole.  gcd answers with
-- an integer either way; lcm keeps a float argument's inexactness.
assert_third("$3=gcd(2.0,6)", "2")
assert_third("$3=gcd(4.0,6.0)", "2")
assert_third("$3=gcd(6,2.0)", "2")
assert_third("$3=gcd(-4.0,6)", "2")
assert_third("$3=gcd(0.0,5)", "5")
assert_third("$3=gcd(4,6)", "2")
assert_third("$3=lcm(2.0,3.0)", "6.")
assert_third("$3=lcm(2,3.0)", "6.")
assert_third("$3=lcm(4.0,6)", "12.")
assert_third("$3=lcm(-4.0,6)", "12.")
assert_third("$3=lcm(0.0,5)", "0.")
assert_third("$3=lcm(0,5)", "0")
assert_third("$3=lcm(4,6)", "12")
-- A fractional argument has no answer, so Calc keeps the call.
assert_third("$3=gcd(2.5,6)", "gcd(2.5, 6)")
assert_third("$3=lcm(2.5,4)", "lcm(2.5, 4)")

-- Zero divides everything, so it answers with the other argument
-- whether or not that one is whole.  `lcm(0, 0)` is the exception: a
-- quotient over zero, which Calc keeps as the call.
assert_third("$3=gcd(2.5,0)", "2.5")
assert_third("$3=gcd(0,2.5)", "2.5")
assert_third("$3=gcd(-2.5,0)", "2.5")
assert_third("$3=gcd(1/3,0)", "0.33333333")
assert_third("$3=gcd(0,0)", "0")
assert_third("$3=lcm(2.5,0)", "0.")
assert_third("$3=lcm(0,2.5)", "0.")
assert_third("$3=lcm(0,0)", "lcm(0, 0)")

-- Calc answers `sqrt(-2.5)` with the complex pair `(0., 1.5811388)`.
-- organ has no complex tower, so it refuses and leaves the field alone
-- rather than writing a real number that is not the answer.
assert_refused("$3=sqrt(-2.5)")
assert_refused("$3=sqrt(-4)")

-- Everything the angular mode must not have disturbed.
assert_third("$3=8/2*4", "1")
assert_third("$3=vsum(3,4)", "7")
assert_third("$3=8/0", "8/0")
assert_third("$3=(2*$1)/(4*$1)", "0.5 h1 / h1")
assert_third("$3=$1+$1/2", "3:2 h1")
assert_third("$3=sqrt($1*4)", "2 sqrt(h1)")
assert_third("$3=$1*2", "2 h1")

io.write("table formula trig ok\n")
