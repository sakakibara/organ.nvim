-- Pure unit tests for the calendar time-field state machine
-- (M._time_* helpers).  No window needed.
-- Run via: nvim --headless -l tests/calendar_time_field_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
local cal = require("organ.calendar")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Constructor: empty (date-only)
do
  local t = cal._time_new(nil)
  check("new(nil): inactive", t.active == false)
  check("new(nil): focus start_h", t.focus == "start_h")
  check("new(nil): to_info nil", cal._time_to_info(t) == nil)
  check("new(nil): render --:--", cal._time_render(t, false) == "--:--")
end

-- Constructor: prefill single time
do
  local t = cal._time_new({ start = "14:30" })
  check("new(single): active", t.active == true)
  check("new(single): has_end false", t.has_end == false)
  local info = cal._time_to_info(t)
  check("new(single): to_info start", info and info.start == "14:30", vim.inspect(info))
  check("new(single): to_info finish nil", info and info.finish == nil)
  check("new(single): render", cal._time_render(t, false) == "14:30")
end

-- Constructor: prefill range
do
  local t = cal._time_new({ start = "09:00", finish = "11:30" })
  check("new(range): has_end true", t.has_end == true)
  local info = cal._time_to_info(t)
  check("new(range): to_info start", info and info.start == "09:00", vim.inspect(info))
  check("new(range): to_info finish", info and info.finish == "11:30", vim.inspect(info))
  check("new(range): render", cal._time_render(t, false) == "09:00-11:30")
end

-- Render with focus brackets (zone focused)
do
  local t = cal._time_new({ start = "14:30" })
  t.focus = "start_h"
  check("render focus start_h", cal._time_render(t, true) == "[14]:30")
  t.focus = "start_m"
  check("render focus start_m", cal._time_render(t, true) == "14:[30]")
end

-- Render inactive but zone-focused: brackets around the placeholder hh
do
  local t = cal._time_new(nil)
  check("render inactive focused", cal._time_render(t, true) == "[--]:--")
end

-- Digit accumulation: hour segment
do
  local t = cal._time_new(nil)
  cal._time_digit(t, 1) -- tens held, stay on start_h
  check("digit hour '1': tens held, still start_h", t.tens == 1 and t.focus == "start_h")
  cal._time_digit(t, 4) -- 14, commit, advance to minute
  check("digit hour '14': committed", t.start_h == 14 and t.active == true)
  check("digit hour '14': advanced to start_m", t.focus == "start_m" and t.tens == nil)
  cal._time_digit(t, 3) -- minute tens held
  check("digit min '3': tens held", t.tens == 3 and t.focus == "start_m")
  cal._time_digit(t, 0) -- 30, commit
  check("digit min '30': committed", t.start_m == 30 and t.tens == nil)
  local info = cal._time_to_info(t)
  check("digit -> 14:30", info and info.start == "14:30", vim.inspect(info))
end

-- Hour first-digit 3..9 commits as 0d and advances
do
  local t = cal._time_new(nil)
  cal._time_digit(t, 9)
  check("digit hour '9': committed 09, advanced", t.start_h == 9 and t.focus == "start_m")
end

-- Hour second digit that would exceed 23 is rejected
do
  local t = cal._time_new(nil)
  cal._time_digit(t, 2) -- tens=2
  cal._time_digit(t, 5) -- 25 invalid -> reject, tens still 2, still start_h
  check("digit hour '2','5': rejected", t.tens == 2 and t.focus == "start_h")
  cal._time_digit(t, 3) -- 23 ok
  check("digit hour '2','3': 23 committed", t.start_h == 23 and t.focus == "start_m")
end

-- Minute first-digit 6..9 commits as 0d
do
  local t = cal._time_new(nil)
  t.focus = "start_m"
  t.active = true
  cal._time_digit(t, 7)
  check("digit min '7': committed 07", t.start_m == 7)
end

-- Stepping: hour ±1 with wrap
do
  local t = cal._time_new({ start = "14:30" })
  t.focus = "start_h"
  cal._time_step(t, 1, 5)
  check("step hour +1 -> 15", t.start_h == 15)
  t.start_h = 23
  cal._time_step(t, 1, 5)
  check("step hour +1 wrap 23->0", t.start_h == 0)
  cal._time_step(t, -1, 5)
  check("step hour -1 wrap 0->23", t.start_h == 23)
end

-- Stepping: minute ±step (5) with wrap
do
  local t = cal._time_new({ start = "14:30" })
  t.focus = "start_m"
  cal._time_step(t, 1, 5)
  check("step min +1*5 -> 35", t.start_m == 35)
  t.start_m = 58
  cal._time_step(t, 1, 5)
  check("step min wrap 58 +5 -> 3", t.start_m == 3)
  cal._time_step(t, -1, 5)
  check("step min wrap 3 -5 -> 58", t.start_m == 58)
end

-- Stepping activates a previously-inactive field
do
  local t = cal._time_new(nil)
  t.focus = "start_h"
  cal._time_step(t, 1, 5)
  check("step activates field", t.active == true)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("calendar_time_field_test: PASS")
