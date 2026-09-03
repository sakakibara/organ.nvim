-- tests/inline_edit_date_test.lua
-- Run via: nvim --headless -l tests/inline_edit_date_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local inline = require("organ.inline_edit")

local function mk_buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function get_line(b, n)
  return vim.api.nvim_buf_get_lines(b, n - 1, n, false)[1]
end

local function press_at(b, line, col, direction)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { line, col })
  inline.dispatch(direction)
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- Day inc/dec.
do
  local b = mk_buf({ "* TODO X", "  SCHEDULED: <2026-04-26 Sun>" })
  -- Cursor on "26" (zero-based col 22: "  SCHEDULED: <" is 14 chars, then "2026-04-" is 8 more = col 22).
  press_at(b, 2, 22, "inc")
  assert_eq(get_line(b, 2), "  SCHEDULED: <2026-04-27 Mon>", "day +1, weekday recomputed")
  press_at(b, 2, 22, "dec")
  assert_eq(get_line(b, 2), "  SCHEDULED: <2026-04-26 Sun>", "day -1")
end

-- Month inc rolls year on Dec.
do
  local b = mk_buf({ "  <2026-12-15>" })
  -- Cursor on "12" (col 8).
  press_at(b, 1, 8, "inc")
  assert_eq(get_line(b, 1), "  <2027-01-15 Fri>", "month rollover into next year, weekday added")
end

-- Month inc clamps day to last day of new month.
do
  local b = mk_buf({ "  <2026-01-31>" })
  press_at(b, 1, 8, "inc") -- on month "01"
  assert_eq(get_line(b, 1), "  <2026-02-28 Sat>", "Jan-31 +month -> Feb-28 (2026 not leap)")
end

-- Year inc / Feb 29 clamp.
do
  local b = mk_buf({ "  <2024-02-29>" }) -- 2024 leap
  press_at(b, 1, 5, "inc") -- on year "2024"
  assert_eq(get_line(b, 1), "  <2025-02-28 Fri>", "year +1 clamps Feb 29 to Feb 28 (2025 not leap)")
end

-- Hour +1 carries into the next day (Emacs `org-timestamp-change`).
do
  local b = mk_buf({ "  <2026-04-26 Sun 23:30>" })
  press_at(b, 1, 19, "inc") -- on hour "23"
  assert_eq(get_line(b, 1), "  <2026-04-27 Mon 00:30>", "hour 23 -> 00 next day")
end

-- Hour -1 at 00:xx borrows from the previous day.
do
  local b = mk_buf({ "  <2024-01-01 Mon 00:00>" })
  press_at(b, 1, 18, "dec")
  assert_eq(get_line(b, 1), "  <2023-12-31 Sun 23:00>", "hour 00 -> 23 previous day")
end

-- Minute +1.
do
  local b = mk_buf({ "  <2026-04-26 Sun 23:30>" })
  press_at(b, 1, 22, "inc") -- on minute "30"
  assert_eq(get_line(b, 1), "  <2026-04-26 Sun 23:31>", "minute +1")
end

-- Minute +1 carries into the hour, and through midnight into the day.
do
  local b = mk_buf({ "  <2024-01-01 Mon 10:59>" })
  press_at(b, 1, 21, "inc")
  assert_eq(get_line(b, 1), "  <2024-01-01 Mon 11:00>", "10:59 -> 11:00")
  local c = mk_buf({ "  [2024-01-01 Mon 23:59]" })
  press_at(c, 1, 21, "inc")
  assert_eq(get_line(c, 1), "  [2024-01-02 Tue 00:00]", "23:59 -> next day 00:00")
end

-- Time ranges: shifting the start moves the end by the same amount;
-- the end is shifted alone and wraps modulo 24h without touching the
-- date.
do
  local line = "<2024-01-01 Mon 10:00-12:00>"
  local b = mk_buf({ line })
  press_at(b, 1, 16, "inc") -- start hour
  assert_eq(get_line(b, 1), "<2024-01-01 Mon 11:00-13:00>", "start hour +1 shifts both")
  b = mk_buf({ line })
  press_at(b, 1, 19, "dec") -- start minute
  assert_eq(get_line(b, 1), "<2024-01-01 Mon 09:59-11:59>", "start minute -1 shifts both")
  b = mk_buf({ line })
  press_at(b, 1, 22, "inc") -- end hour
  assert_eq(get_line(b, 1), "<2024-01-01 Mon 10:00-13:00>", "end hour +1 shifts end only")
  b = mk_buf({ line })
  press_at(b, 1, 25, "inc") -- end minute
  assert_eq(get_line(b, 1), "<2024-01-01 Mon 10:00-12:01>", "end minute +1 shifts end only")
  b = mk_buf({ "<2024-01-01 Mon 10:00-12:59>" })
  press_at(b, 1, 26, "inc")
  assert_eq(get_line(b, 1), "<2024-01-01 Mon 10:00-13:00>", "end minute carries into end hour")
  b = mk_buf({ "<2024-01-01 Mon 10:00-23:59>" })
  press_at(b, 1, 26, "inc")
  assert_eq(get_line(b, 1), "<2024-01-01 Mon 10:00-00:00>", "end wraps without a day change")
  b = mk_buf({ "<2024-01-01 Mon 23:59-23:59>" })
  press_at(b, 1, 19, "inc")
  assert_eq(get_line(b, 1), "<2024-01-02 Tue 00:00-00:00>", "start carry moves the day")
  b = mk_buf({ "<2024-01-01 Mon 10:00-12:00>" })
  press_at(b, 1, 9, "inc") -- day
  assert_eq(get_line(b, 1), "<2024-01-02 Tue 10:00-12:00>", "day shift keeps the range")
end

-- Inactive timestamp brackets preserved.
do
  local b = mk_buf({ "  [2026-04-26 Sun]" })
  press_at(b, 1, 11, "inc") -- on day "26"
  assert_eq(get_line(b, 1), "  [2026-04-27 Mon]", "[ ] brackets preserved")
end

-- Repeater suffix preserved on day shift.
do
  local b = mk_buf({ "  <2026-04-26 Sun +1w>" })
  press_at(b, 1, 11, "inc")
  assert_eq(get_line(b, 1), "  <2026-04-27 Mon +1w>", "+1w repeater preserved")
end

-- Cursor on weekday name shifts day.
do
  local b = mk_buf({ "  <2026-04-26 Sun>" })
  press_at(b, 1, 15, "inc") -- on "Sun"
  assert_eq(get_line(b, 1), "  <2026-04-27 Mon>", "weekday position triggers day shift")
end

io.write("inline_edit date ok\n")
