-- format_active_ts(iso, time_info) -> org active timestamp string.
-- Run via: nvim --headless -l tests/schedule_time_format_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
local schedule = require("organ.schedule")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local fmt = schedule._format_active_ts

-- 2026-05-21 is a Thursday.
check("date-only", fmt("2026-05-21", nil) == "<2026-05-21 Thu>", fmt("2026-05-21", nil))
check(
  "single time",
  fmt("2026-05-21", { start = "14:30" }) == "<2026-05-21 Thu 14:30>",
  fmt("2026-05-21", { start = "14:30" })
)
check(
  "range",
  fmt("2026-05-21", { start = "14:30", finish = "16:00" }) == "<2026-05-21 Thu 14:30-16:00>",
  fmt("2026-05-21", { start = "14:30", finish = "16:00" })
)

-- Parse an existing <…> timestamp's time component into a prefill
-- table (or nil for date-only).
do
  local parse = schedule._parse_ts_time
  check("parse date-only", parse("<2026-05-21 Thu>") == nil)
  local single = parse("<2026-05-21 Thu 14:30>")
  check(
    "parse single",
    single and single.start == "14:30" and single.finish == nil,
    vim.inspect(single)
  )
  local range = parse("<2026-05-21 Thu 14:30-16:00>")
  check(
    "parse range",
    range and range.start == "14:30" and range.finish == "16:00",
    vim.inspect(range)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("schedule_time_format_test: PASS")
