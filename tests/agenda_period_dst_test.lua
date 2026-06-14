-- Agenda period navigation must not slide a day across a fall-back DST
-- boundary. 2025-11-02 is the US "clocks back" day (25h long in
-- America/New_York); midnight-anchored date math landed
-- add_days(2025-11-02, 1) on 2025-11-02 instead of 2025-11-03. The
-- noon-anchored dates.add_days / dates.days_diff are immune.
-- Run via: nvim --headless -l tests/agenda_period_dst_test.lua

-- Set before any os.date call so glibc reads it fresh.
vim.uv.os_setenv("TZ", "America/New_York")

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local dates = require("organ.agenda.dates")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

-- Sanity: the runtime honors TZ, so 2025-11-03 really is EST (post fall-back).
check(
  os.date("%z", os.time({ year = 2025, month = 11, day = 3, hour = 12 })) == "-0500",
  "runtime honors TZ (EST after fall-back)"
)

-- Crossing into / spanning the 25h day: the original bug case.
check(dates.add_days("2025-11-02", 1) == "2025-11-03", "add_days advances one day across fall-back")
check(
  dates.add_days("2025-11-01", 2) == "2025-11-03",
  "add_days advances two days spanning fall-back"
)
check(dates.add_days("2025-11-03", -1) == "2025-11-02", "add_days steps back across fall-back")

-- Span identity used by shift_period: a 7-day inclusive window stays 7.
check(
  dates.days_diff("2025-11-02", "2025-11-08") + 1 == 7,
  "inclusive week span across fall-back is 7"
)

-- Forward then back by the same period restores the window exactly.
do
  local from, to = "2025-10-26", "2025-11-01" -- spans the boundary
  local span = dates.days_diff(from, to) + 1
  local f2, t2 = dates.add_days(from, span), dates.add_days(to, span)
  check(
    dates.add_days(f2, -span) == from and dates.add_days(t2, -span) == to,
    "forward + back period shift is identity across DST"
  )
end

-- Unparseable input is returned unchanged (preserves the prior contract).
check(dates.add_days("not-a-date", 1) == "not-a-date", "add_days passes through unparseable input")

print("agenda_period_dst_test: PASS")
