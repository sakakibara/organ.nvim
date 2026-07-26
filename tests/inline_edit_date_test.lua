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

-- Hour ±1, no day rollover.
do
  local b = mk_buf({ "  <2026-04-26 Sun 23:30>" })
  press_at(b, 1, 19, "inc") -- on hour "23"
  assert_eq(get_line(b, 1), "  <2026-04-26 Sun 00:30>", "hour 23 -> 00 same day")
end

-- Minute ±1, no hour rollover.
do
  local b = mk_buf({ "  <2026-04-26 Sun 23:30>" })
  press_at(b, 1, 22, "inc") -- on minute "30"
  assert_eq(get_line(b, 1), "  <2026-04-26 Sun 23:31>", "minute +1")
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
