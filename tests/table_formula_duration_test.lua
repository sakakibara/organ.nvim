-- tests/table_formula_duration_test.lua
-- Run via: nvim --headless -l tests/table_formula_duration_test.lua
--
-- The duration flags `;T`, `;t`, `;U`, the mode string after a
-- formula's last `;`, and empty fields in `;N` ranges.  Expected values
-- are Emacs's, taken from
--   emacs --batch -Q -l org --eval '(org-table-recalculate t)'
-- over the same table; tests/conformance/tables holds the cases where
-- organ and Emacs agree.  This file pins what organ refuses although
-- Emacs writes a value, and leaves every field as the user wrote it.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")
local formula = require("organ.table.formula")
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

local function check(row, tblfm, want)
  local ok, lines, message = run({ row, "#+TBLFM: " .. tblfm })
  assert(ok, tblfm .. ": refused: " .. tostring(message))
  local got = vim.trim(lines[1]:match("([^|]*)|%s*$"))
  if got ~= want then
    error(string.format("%s over %s: expected %q got %q", tblfm, row, want, got))
  end
end

local function refused(row, tblfm)
  local ok, lines, message = run({ row, "#+TBLFM: " .. tblfm })
  assert(ok == false, tblfm .. ": expected a refusal")
  assert(message and message:find("^TBLFM: "), tblfm .. ": expected a message")
  assert(lines[1] == row, tblfm .. ": the row must be byte-unchanged, got " .. lines[1])
end

-- The mode string: flag letters anywhere after the last `;` are flags.
local function mode(tblfm)
  return formula.parse(tblfm)[1]
end
assert(mode("$3=$1;%d items").duration == "hours")
assert(mode("$3=$1;%d items").fmt == "%d iems")
assert(mode("$3=$1;Tt").duration == "hours")
assert(mode("$3=$1;tT").duration == "hh:mm:ss")
assert(mode("$3=$1;UT").duration == "hh:mm:ss")
assert(mode("$3=$1;TU").duration == "hh:mm")
assert(mode("$3=$1;TN").numeric == true)
assert(mode("$3=$1;%d Nm").fmt == "%d m")
assert(mode("$3=$1;T;N").expr.kind == "error", "a `;` left in the expression")
assert(mode("$3=$1;N;T").duration == "hh:mm:ss")

-- Values Emacs writes, where the conformance cases do not reach.
check("| 1:30 | 2 | |", "$3=$1+$2;T", "01:30:02")
check("| 59:59:59 | 0 | |", "$3=$1+$2*1.5;T", "59:59:59")
check("| 0:00:01 | 0 | |", "$3=$1/2;T", "00:00:00")
check("| 0:00:01 | 0 | |", "$3=-$1/2;T", "-00:00:00")
check("| 1:30 | 2 | |", "$3=$1;U", "01:30")
check("| 2501999792983:36:31 | 0 | |", "$3=$1;T", "2501999792983:36:31")
check("| 1:30:59 | 2 | |", "$3=$1;U", "01:30")
check("| 1:30 | 2 | |", "$3=$1;t", "1.50")
check("| 1:20 | 2 | |", "$3=$1;t", "1.33")
check("| -1 | 0 | |", "$3=$1;t%.1f", "-0.0")
check("| -1 | 0 | |", "$3=$1;t%d", "0")
check("| 1:00 | 0 | |", "$3=$1;t%s", "1.0")
check("| 1:30 | 0 | |", "$3=$1;T%s", "1")
check("| 1:30 | 0 | |", "$3=$1;T%5.2f", "1.00")
-- A single empty reference reads 0 under `;N` and the duration flags;
-- an empty field in a range drops out.
check("| 1 |  | |", "$3=$2;N", "0")
check("| 1 |  | |", "$3=$2;T", "00:00:00")
check("| 1 |  | 2 | |", "$4=vmean($1..$3);N", "1.5")
check("| 1:00 |  | 2:00 | |", "$4=vmean($1..$3);T", "01:30:00")
check("| 1 |  | 2 | |", "$4=vcount($1..$3);N", "2")

-- Refused where Emacs writes a value.
local ROW = "| 1:30 | 2 | |"
-- Flags organ does not implement, inside a template too: `E` and `u`
-- (`;%.2f EUR`, `;%.0f Euro`), and the precision flags.
refused(ROW, "$3=$1+$2;%.2f EUR")
refused(ROW, "$3=$1+$2;%.0f Euro")
refused(ROW, "$3=$1+$2;p3T")
-- What is left after the flags has to be a template with one
-- conversion; Emacs writes `#ERROR` here, the expression `$1;%d` being a
-- syntax error.
refused(ROW, "$3=$1;%d;x")
-- organ has no vector literal (Emacs: 00:00:00).
refused(ROW, "$3=[$1,$2];T")
-- A colon beside `@#` builds a literal in Emacs (02:30:00).
refused(ROW, "$3=@#:30;T")
-- Integers and seconds past 2^53 (Emacs: 27777777777777777:46:39 and
-- 149999999999999993009:29:36).
refused("| 99999999999999999999 | 1 | |", "$3=$1;T")
refused("| 9007199254740992 | 1 | |", "$3=$1;T")
refused(ROW, "$3=$1*1e20;T")
refused("| 2501999792983:36:32 | 1 | |", "$3=$1;T")
-- A fraction mixed with a float (Emacs: 00:00).
refused("| 2.5 | 2 | |", "$3=$1+1:2;U")

-- Refused where Emacs signals: an answer that is not a number.
refused(ROW, "$3=$1/0;T")
refused(ROW, "$3=x+$1;t")
refused(ROW, "$3=$1+;U")
refused("| 1e999 | 2 | |", "$3=$1;T")

-- `;t` prints the binary hours as C's %.2f does (Emacs: 54 s is 0.01).
check("| 0:00:54 | 1 | |", "$3=$1;t", "0.01")
check("| 0:01:30 | 1 | |", "$3=$1;t", "0.03")

-- A second argument. Calc rounds an integer to itself and returns
-- other one-argument calls unevaluated; organ refuses the second-argument
-- forms it does not compute (Emacs: round(0.333, 1) is 0.3, log(7, 3)
-- 1.7712437, sign(7, 3) 3).
check("| 7 | 1 | |", "$3=round($1, 1)", "7")
check("| 7 | 1 | |", "$3=trunc($1, -1)", "7")
check("| 7 | 3 | |", "$3=abs($1, $2)", "abs(7, 3)")
check("| 7 | 3 | |", "$3=sin($1, 1)", "sin(7, 1)")
refused("| 0.333 | 1 | |", "$3=round($1, 1)")
refused("| 1:3 | 1 | |", "$3=round($1, 1)")
refused("| 7 | 3 | |", "$3=log($1, $2)")
refused("| 7 | 3 | |", "$3=sign($1, $2)")
refused("| 7 | 3 | |", "$3=not($1, $2)")
refused("| 7:3 | 1 | |", "$3=abs($1, 1)")

io.write("table formula duration ok\n")
