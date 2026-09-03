-- Unit tests for clock.report.render — pure org-table generation.
-- Run via: nvim --headless -l tests/clock_report_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local report = require("organ.clock.report")

-- 1. Renders a header row, one row per record, separator, and a TOTAL row.
do
  local rows = {
    { title = "Project Alpha", total_seconds = 3 * 3600 + 45 * 60 },
    { title = "Project Beta", total_seconds = 1 * 3600 + 20 * 60 },
    { title = "Misc", total_seconds = 15 * 60 },
  }
  local lines = report.render(rows, { from = "2026-04-20", to = "2026-04-26" })
  assert(#lines >= 5, "expected ≥5 lines; got " .. #lines)
  assert(lines[1]:match("^| Headline%s*| Time%s*|$"), "header: " .. lines[1])
  assert(lines[2]:match("^|%-+|%-+|$"), "separator: " .. lines[2])
  assert(lines[3]:match("Project Alpha"), "row 3: " .. lines[3])
  assert(lines[3]:match("3:45"), "duration in row 3: " .. lines[3])
  assert(lines[4]:match("Project Beta") and lines[4]:match("1:20"))
  assert(lines[5]:match("Misc") and lines[5]:match("0:15"))
  assert(lines[#lines]:match("TOTAL"), "TOTAL row: " .. lines[#lines])
  assert(lines[#lines]:match("5:20"), "total time: " .. lines[#lines])
end

-- 2. Empty rows → header + separator + TOTAL 0:00.
do
  local lines = report.render({}, { from = "2026-04-20", to = "2026-04-26" })
  assert(#lines >= 3, "expected ≥3 lines; got " .. #lines)
  assert(lines[#lines]:match("TOTAL.*0:00"), "TOTAL 0:00 row: " .. lines[#lines])
end

-- 3. Auto-grows duration column when totals exceed 99h.
do
  local rows = { { title = "Long", total_seconds = 100 * 3600 + 30 * 60 } }
  local lines = report.render(rows, { from = "2026-04-20", to = "2026-04-26" })
  assert(lines[3]:match("100:30"), "expected 100:30; got " .. lines[3])
end

-- 4. The default week range is computed on calendar days, so a DST
--    fall-back inside the week does not lose Monday.
do
  local saved_tz = vim.env.TZ
  vim.env.TZ = "America/New_York"
  -- Sunday 2026-11-01 23:30 EST; DST ended at 02:00 that morning.
  local sunday = os.time({ year = 2026, month = 11, day = 1, hour = 23, min = 30, sec = 0 })
  local from, to = require("organ.clock")._week_range(sunday)
  assert(from == "2026-10-26", "week starts Monday across fall-back; got " .. tostring(from))
  assert(to == "2026-11-01", "week ends Sunday; got " .. tostring(to))
  -- Spring-forward week: Sunday 2026-03-08 23:30 EDT.
  local spring = os.time({ year = 2026, month = 3, day = 8, hour = 23, min = 30, sec = 0 })
  from, to = require("organ.clock")._week_range(spring)
  assert(from == "2026-03-02" and to == "2026-03-08", "spring-forward week: " .. from .. ".." .. to)
  vim.env.TZ = saved_tz
end

io.write("clock report ok\n")
os.exit(0)
