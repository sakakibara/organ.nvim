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
