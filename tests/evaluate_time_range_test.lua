-- organ.timestamp: `:Org evaluate_time_range` (Emacs
-- org-evaluate-time-range, C-c C-y).  Every expected string is what real
-- Emacs 30 / org 9.7.11 echoes or inserts for the same line, checked with
--   emacs --batch -Q -l org --eval '(org-evaluate-time-range)'
-- before it was encoded here.  Note the trailing space Emacs's
-- `org-make-tdiff-string` leaves on the echoed phrase.
--
-- Run via: nvim --headless -l tests/evaluate_time_range_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local timestamp = require("organ.timestamp")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function evaluated(label, text, want_text, want_compact)
  local b = mkbuf({ text })
  local res, why = timestamp.evaluate_range(b, 1)
  check(
    label,
    res ~= nil and res.text == want_text and res.compact == want_compact,
    why or (res and ("[" .. res.text .. "] [" .. res.compact .. "]"))
  )
end

-- 1. Emacs's phrasing: only the non-zero units, pluralised, each
-- followed by a space.
evaluated(
  "hours and minutes",
  "<2026-01-01 Thu 10:00>--<2026-01-01 Thu 12:30>",
  "2 hours 30 minutes ",
  "02:30"
)
evaluated(
  "days, hours and minutes",
  "<2026-01-01 Thu 10:00>--<2026-01-03 Sat 12:30>",
  "2 days 2 hours 30 minutes ",
  "2d 02:30"
)
evaluated(
  "a singular unit drops the `s`",
  "<2026-01-01 Thu 10:00>--<2026-01-01 Thu 11:00>",
  "1 hour ",
  "01:00"
)

-- 2. With no clock time in either stamp, the difference is whole days.
evaluated("date-only stamps give whole days", "<2026-01-01 Thu>--<2026-01-05 Mon>", "4 days ", "4d")
evaluated("a longer date-only span", "<2026-01-01 Thu>--<2026-02-15 Sun>", "45 days ", "45d")

-- 3. Inactive stamps work, and a backwards range reports the absolute
-- difference (only the inserted form carries the sign).
evaluated(
  "a backwards range reports its magnitude",
  "[2026-01-01 Thu 10:00]--[2026-01-01 Thu 09:00]",
  "1 hour ",
  "- 01:00"
)

-- 4. A zero-length range yields the empty phrase.
evaluated(
  "an empty span yields no units",
  "<2026-01-01 Thu 10:00>--<2026-01-01 Thu 10:00>",
  "",
  "00:00"
)

-- 5. The range need not start the line, and a single dash is accepted.
evaluated(
  "a range mid-line is found",
  "some text <2026-01-01 Thu 10:00>--<2026-01-01 Thu 11:00> tail",
  "1 hour ",
  "01:00"
)
evaluated(
  "a single-dash range is accepted",
  "<2026-01-01 Thu 10:00>-<2026-01-01 Thu 12:30>",
  "2 hours 30 minutes ",
  "02:30"
)

-- 6. Out-of-range fields normalise the way org-encode-time does, so a
-- malformed stamp still yields a duration instead of an error.
evaluated(
  "a malformed month / day normalises",
  "<2026-13-45 Thu>--<2026-01-05 Mon>",
  "405 days ",
  "- 405d"
)

-- 7. Lines with no range refuse.  A same-stamp time range
-- (`<date h:mm-h:mm>`) is not a range for this command in Emacs either.
for _, text in ipairs({ "no range here", "<2026-01-01 Thu 10:00-12:30>", "" }) do
  local b = mkbuf({ text })
  local res, why = timestamp.evaluate_range(b, 1)
  check(
    ("no range in [%s]"):format(text),
    res == nil and why == "not at a timestamp range, and none found in current line",
    tostring(why)
  )
end

-- 8. The insert form writes the compact duration after the range, and
-- replaces one it wrote earlier rather than appending a second.
do
  local b = mkbuf({ "<2026-01-01 Thu 10:00>--<2026-01-01 Thu 12:30>" })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local cmd = require("organ").cmd("evaluate_time_range")
  cmd.fn({ bang = true, args = "", fargs = {} })
  local first = vim.api.nvim_buf_get_lines(b, 0, -1, false)[1]
  cmd.fn({ bang = true, args = "", fargs = {} })
  local second = vim.api.nvim_buf_get_lines(b, 0, -1, false)[1]
  check(
    "the duration is inserted after the range",
    first == "<2026-01-01 Thu 10:00>--<2026-01-01 Thu 12:30> 02:30",
    first
  )
  check("re-running replaces rather than appends", second == first, second)
end

-- 9. On a CLOCK line, Emacs recomputes the `=>` sum instead of echoing.
do
  local b = mkbuf({ "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 12:30] =>  9:99" })
  local sum = timestamp.update_clock_sum(b, 1)
  check(
    "a CLOCK line has its sum recomputed",
    sum == " 2:30"
      and vim.api.nvim_buf_get_lines(b, 0, -1, false)[1]
        == "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 12:30] =>  2:30",
    vim.api.nvim_buf_get_lines(b, 0, -1, false)[1]
  )
end
do
  local b = mkbuf({ "not a clock line" })
  check("a non-CLOCK line is left to the range path", timestamp.update_clock_sum(b, 1) == nil)
end

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\nevaluate_time_range: all checks passed")
