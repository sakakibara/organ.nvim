-- tests/table_formula_fraction_test.lua
-- Run via: nvim --headless -l tests/table_formula_fraction_test.lua
--
-- Calc fractions (`1:2`) in fields and formulas.  Expected values are
-- Emacs's, taken from
--   emacs --batch -Q -l org --eval '(org-table-recalculate t)'
-- over the same table.  Where organ's exact arithmetic is not Calc's,
-- the recalculation is refused and every field stays as the user wrote
-- it.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")
local notify = require("organ.notify")

local function run(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  local message
  local saved = notify.error
  notify.error = function(msg)
    message = msg
  end
  local ok = tab.eval_formulas(b)
  notify.error = saved
  return ok, vim.api.nvim_buf_get_lines(b, 0, -1, false), message
end

local function result(row, formula)
  local ok, lines, message = run({ row, "#+TBLFM: " .. formula })
  assert(ok, formula .. ": refused: " .. tostring(message))
  return vim.trim(lines[1]:match("([^|]*)|%s*$"))
end

local function check(row, formula, want)
  local got = result(row, formula)
  if got ~= want then
    error(string.format("%s over %s: expected %q got %q", formula, row, want, got))
  end
end

local ROW = "| 1:2 | -1:3 | 4:2 | 0:5 | 3 | 1.5 | |"

check(ROW, "$7=$1+$2", "1:6")
check(ROW, "$7=$1/$2", "-3:2")
check(ROW, "$7=$5/$1", "6")
check(ROW, "$7=$1/0", "1:2 / 0")
check(ROW, "$7=-($1/0)", "-1:2 / 0")
check(ROW, "$7=$1^-2", "4")
check(ROW, "$7=$2^3", "-1:27")
check(ROW, "$7=$3+$1", "5:2")
check(ROW, "$7=round($2)", "0")
check(ROW, "$7=floor(-5:3)", "-2")
check(ROW, "$7=vsum($1..$5)", "31:6")
check(ROW, "$7=vmin($1..$5)", "-1:3")
check(ROW, "$7=vlen($1..$5)", "5")
check(ROW, "$7=if($1<$2,$1,$2)", "-1:3")
check(ROW, "$7=if($1,$6,2)", "1.5")
check(ROW, "$7=123456789012345678901:3*3", "123456789012345678901")
check(ROW, "$7=1:2:3", "5:3")
check(ROW, "$7=1:0", "#ERROR")
check(ROW, "$7=1:-2", "#ERROR")
check(ROW, "$7=1:2;N", "1:2")
check(ROW, "$7=$1;%.2f", "1.00")
check(ROW, "$7=-1:2;%.2f", "-1.00")
check(ROW, "$7=$1+$5;%.2f", "7.00")
check(ROW, "$7=1:2/0;N", "#ERROR")
-- A colon beside a field reference is text Calc cannot read either.
check(ROW, "$7=$1:2", "#ERROR")
-- Without a fraction, a quotient is the float Calc's Fraction mode off
-- gives, from a slash field too.
check(ROW, "$7=3/4", "0.75")
check("| 1/2 | 1/2 | |", "$3=vsum($1..$2)", "1.")
check("| 4/2 | | |", "$3=$1", "2")

-- Refused, with the fields left as they were: mixing a fraction with a
-- float, functions outside organ's exact set, and a colon beside `@#`.
local REFUSED = {
  { "$7=$1+$6", "+() of a fraction" },
  { "$7=$1<$6", "<() of a fraction" },
  { "$7=1:3*3.0", "*() of a fraction" },
  { "$7=1:2+2^-1", "+() of a fraction" },
  { "$7=vsum($1..$6)", "vsum() of a fraction" },
  { "$7=sqrt(1:4)", "sqrt() of a fraction" },
  { "$7=4^(1:2)", "^() of a fraction" },
  { "$7=$1%2", "%() of a fraction" },
  { "$7=vmean($1..$2)", "vmean() of a fraction" },
  { "$7=vmedian($1..$2)", "vmedian() of a fraction" },
  { "$7=min($1,$2)", "min() of a fraction" },
  { "$7=foo($1)", "foo() of a fraction" },
  { "$7=if($6,$1,2)", "if() of a fraction" },
  { "$7=@#:2", "':' next to '@#' or '$#'" },
  { "$7=2:$#", "':' next to '@#' or '$#'" },
}

for _, case in ipairs(REFUSED) do
  local before = { ROW, "#+TBLFM: " .. case[1] }
  local ok, lines, message = run(before)
  assert(not ok, case[1] .. ": expected a refusal")
  assert(vim.deep_equal(lines, before), case[1] .. ": the table changed")
  assert(
    message and message:find(case[2], 1, true),
    case[1] .. ": expected " .. case[2] .. " in " .. tostring(message)
  )
end

print("OK table_formula_fraction_test")
