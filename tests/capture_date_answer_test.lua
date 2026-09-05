-- Answers typed at the `%^t`-family capture date prompt.
--
-- Expected values were taken from `emacs --batch -Q -l org` driving
-- `org-read-date` and `org-insert-timestamp`, with today fixed at
-- 2026-09-05 (a Saturday).
-- Run via: nvim --headless -l tests/capture_date_answer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local ph = require("organ.capture.placeholder")

local NOW = os.time({ year = 2026, month = 9, day = 5, hour = 12, min = 0, sec = 0 })

local function stamp(answer, spec)
  local text, _, warnings = ph.expand(spec or "%^t", {
    now = NOW,
    prompts = { dates = { answer } },
  })
  return text, warnings or {}
end

-- 1. Forms org accepts, against what Emacs writes for them.
do
  local cases = {
    -- relative offsets
    { "+1w", "<2026-09-12 Sat>" },
    { "+2d", "<2026-09-07 Mon>" },
    { "-1w", "<2026-08-29 Sat>" },
    { "++3m", "<2026-12-05 Sat>" },
    { ".", "<2026-09-05 Sat>" },
    -- weekday name
    { "fri", "<2026-09-11 Fri>" },
    -- a bare day of month, still ahead this month
    { "25", "<2026-09-25 Fri>" },
    -- month/day ahead this year stays in it ...
    { "12/25", "<2026-12-25 Fri>" },
    -- ... one already past rolls forward a year
    { "3/4", "<2027-03-04 Thu>" },
    -- day-first dotted forms, with and without a year
    { "1.2.", "<2027-02-01 Mon>" },
    { "31.12.", "<2026-12-31 Thu>" },
    { "4.3.2026", "<2026-03-04 Wed>" },
    -- explicit and month-name forms
    { "2026-03-04", "<2026-03-04 Wed>" },
    { "sep 15", "<2026-09-15 Tue>" },
    { "15 sep", "<2026-09-15 Tue>" },
    -- times
    { "10:30", "<2026-09-05 Sat 10:30>" },
    { "wed 10:00", "<2026-09-09 Wed 10:00>" },
    -- ISO week dates; Sunday is 7, and 0 means the same day
    { "2026-W12-3", "<2026-03-18 Wed>" },
    { "2026-W01-1", "<2025-12-29 Mon>" },
    { "2026-W53-7", "<2027-01-03 Sun>" },
    { "2026-W01-0", "<2026-01-04 Sun>" },
  }
  for _, c in ipairs(cases) do
    local got, warnings = stamp(c[1])
    assert(got == c[2], ("%q -> %q, want %q"):format(c[1], got, c[2]))
    assert(#warnings == 0, ("%q warned unexpectedly"):format(c[1]))
  end
end

-- 2. A time range keeps both halves.  Emacs inserts the end verbatim
--    (`08:00-9:30`); we pad it, which parses the same and does not
--    depend on how the user happened to type it.
do
  assert(stamp("8:00-10:00") == "<2026-09-05 Sat 08:00-10:00>", stamp("8:00-10:00"))
  local got = stamp("2026-03-04 8:00-9:30")
  assert(got == "<2026-03-04 Wed 08:00-09:30>", got)
end

-- 3. An answer nothing recognises comes back verbatim and is reported,
--    never resolved.  Emacs quietly yields today for these, which is how
--    a wrong date used to be written while looking right.
do
  for _, answer in ipairs({ "tomorrow", "yesterday", "asdf", "??", "not a date" }) do
    local got, warnings = stamp(answer)
    assert(got == answer, ("%q -> %q, want it back verbatim"):format(answer, got))
    assert(#warnings == 1, ("%q produced %d warnings"):format(answer, #warnings))
    assert(
      not got:match("^[<%[]%d%d%d%d%-%d%d%-%d%d"),
      ("%q became a timestamp: %s"):format(answer, got)
    )
  end
  -- Emacs ignores a word it cannot read and keeps the weekday, so
  -- `last tuesday` silently means the NEXT one.  Reporting beats
  -- guessing which direction was meant.
  local got, warnings = stamp("next tuesday")
  assert(got == "next tuesday", got)
  assert(#warnings == 1)
end

-- 4. The placeholder letter still decides time and activeness.
do
  assert(stamp("+1w", "%^t") == "<2026-09-12 Sat>")
  assert(stamp("+1w", "%^T") == "<2026-09-12 Sat 12:00>")
  assert(stamp("+1w", "%^u") == "[2026-09-12 Sat]")
  assert(stamp("+1w", "%^U") == "[2026-09-12 Sat 12:00]")
  -- an answer carrying a time writes one even for the lowercase letter
  assert(stamp("10:30", "%^t") == "<2026-09-05 Sat 10:30>")
  assert(stamp("10:30", "%^u") == "[2026-09-05 Sat 10:30]")
end

-- 5. An empty answer means the default date and reports nothing.
do
  local got, warnings = stamp("")
  assert(got == "<2026-09-05 Sat>", ("empty -> %q"):format(got))
  assert(#warnings == 0)
end

io.write("capture date answer ok\n")
os.exit(0)
