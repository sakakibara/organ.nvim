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

-- Time-field keymap routing through the actual installed buffer maps
-- (regression: the digit `3` collides with the 3-month-layout toggle;
-- in the time zone `3` must enter a digit, in the grid zone it must
-- still toggle the layout).
do
  local cal = require("organ.calendar")
  local bufnr = cal.pick({ time = true, initial = "2026-05-21" }, function() end)
  local function cb_for(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if m.lhs == lhs and m.callback then
        return m.callback
      end
    end
  end
  local function st()
    return vim.b[bufnr].organ_calendar
  end

  -- grid zone: `3` toggles three_months
  local before = st().three_months
  cb_for("3")()
  assert(st().three_months ~= before, "grid '3' should toggle three_months")

  -- enter time zone, type 14:30 (the '3' digit must work here)
  cb_for("<Tab>")()
  assert(st().zone == "time", "<Tab> should switch to time zone")
  cb_for("1")()
  cb_for("4")()
  cb_for("3")()
  cb_for("0")()
  local info = cal._time_to_info(st().time)
  assert(info and info.start == "14:30", "time-zone digits should build 14:30, got " .. vim.inspect(info))

  -- range via '-' then 16:00
  cb_for("-")()
  cb_for("1")()
  cb_for("6")()
  cb_for("0")()
  cb_for("0")()
  info = cal._time_to_info(st().time)
  assert(info and info.finish == "16:00", "range end should be 16:00, got " .. vim.inspect(info))

  -- 'x' clears back to date-only
  cb_for("x")()
  assert(cal._time_to_info(st().time) == nil, "'x' should clear to date-only")

  print("PASS  pick: time-field keymap routing (incl. '3' zone overload)")
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end
