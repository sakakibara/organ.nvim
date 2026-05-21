-- tests/calendar_pick_test.lua
-- Run via: nvim --headless -l tests/calendar_pick_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({})

local cal = require("organ.calendar")

local function press(key)
  local seq = vim.api.nvim_replace_termcodes(key, true, false, true)
  vim.api.nvim_feedkeys(seq, "x", false)
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

----------------------------------------------------------------------
-- Open with initial: state stored, cursor at selected day's row.
do
  local got
  cal.pick({ initial = "2026-04-26" }, function(iso)
    got = iso
  end)
  -- The pick window should be the current window; buffer state set.
  local b = vim.api.nvim_get_current_buf()
  local state = vim.b[b].organ_calendar
  assert(state, "state set")
  assert_eq(state.selected_iso, "2026-04-26")
  assert_eq(state.year, 2026)
  assert_eq(state.month, 4)
  -- Cancel to clean up.
  press("<Esc>")
  assert_eq(got, nil, "cancelled")
end

----------------------------------------------------------------------
-- h decrements selection by 1 day.
do
  local got
  cal.pick({ initial = "2026-04-26" }, function(iso)
    got = iso
  end)
  press("h")
  press("<CR>")
  assert_eq(got, "2026-04-25")
end

----------------------------------------------------------------------
-- l past month-end rolls into next month.
do
  local got
  cal.pick({ initial = "2026-04-30" }, function(iso)
    got = iso
  end)
  press("l")
  press("<CR>")
  assert_eq(got, "2026-05-01")
end

----------------------------------------------------------------------
-- <CR> calls callback with selected_iso once.
do
  local calls = 0
  local got
  cal.pick({ initial = "2026-04-15" }, function(iso)
    calls = calls + 1
    got = iso
  end)
  press("<CR>")
  assert_eq(calls, 1)
  assert_eq(got, "2026-04-15")
end

----------------------------------------------------------------------
-- <Esc> calls callback with nil once.
do
  local calls = 0
  local got = "unset" -- distinct from nil
  cal.pick({ initial = "2026-04-15" }, function(iso)
    calls = calls + 1
    got = iso
  end)
  press("<Esc>")
  assert_eq(calls, 1)
  assert_eq(got, nil)
end

----------------------------------------------------------------------
-- Window closes after confirm/cancel.
do
  cal.pick({ initial = "2026-04-15" }, function() end)
  local pre_win = vim.api.nvim_get_current_win()
  press("<CR>")
  -- The pick window should no longer be valid.
  assert(not vim.api.nvim_win_is_valid(pre_win), "window closed")
end

io.write("calendar pick ok\n")

-- opts.time: pick() seeds a time substate; _confirm fires callback with time_info
do
  local cal = require("organ.calendar")
  local got_iso, got_time, fired = nil, nil, false
  local bufnr = cal.pick({ time = true, initial = "2026-05-21" }, function(iso, time_info)
    got_iso = iso
    got_time = time_info
    fired = true
  end)
  local st = vim.b[bufnr].organ_calendar
  assert(st ~= nil, "pick: no calendar state")
  assert(st.time ~= nil, "pick: opts.time=true should seed a time substate")
  cal._time_digit(st.time, 1)
  cal._time_digit(st.time, 4)
  cal._time_digit(st.time, 3)
  cal._time_digit(st.time, 0)
  vim.b[bufnr].organ_calendar = st
  cal._confirm(bufnr)
  assert(fired, "pick: callback did not fire on confirm")
  assert(got_iso == "2026-05-21", "pick: wrong iso " .. tostring(got_iso))
  assert(got_time and got_time.start == "14:30", "pick: wrong time " .. vim.inspect(got_time))
  print("PASS  pick: opts.time seeds substate + callback receives time_info")
end

-- opts.time omitted: date-only, time_info nil
do
  local cal = require("organ.calendar")
  local got_time, fired = "sentinel", false
  local bufnr = cal.pick({ initial = "2026-05-21" }, function(_, time_info)
    got_time = time_info
    fired = true
  end)
  local st = vim.b[bufnr].organ_calendar
  assert(st.time == nil, "pick: no opts.time should not seed a time substate")
  cal._confirm(bufnr)
  assert(fired and got_time == nil, "pick: date-only callback should get nil time_info")
  print("PASS  pick: date-only callback gets nil time_info")
end
