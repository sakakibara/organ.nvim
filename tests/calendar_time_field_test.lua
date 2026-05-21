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

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("calendar_time_field_test: PASS")
