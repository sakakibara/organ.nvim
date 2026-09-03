-- tests/deadline_test.lua
-- Unit tests for :Org deadline (lua/organ/schedule.lua set_deadline path).
-- Run via: nvim --headless -l tests/deadline_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local sched = require("organ.schedule")

local function mk_buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function get_lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. "\n  expected: " .. tostring(b) .. "\n  got:      " .. tostring(a), 2)
  end
end

-- 1. Set deadline on fresh headline — canonical line inserted with DEADLINE:.
--    "DEADLINE:" padded to 10 cols -> one trailing space before timestamp.
do
  local b = mk_buf({ "* Task", "  body" })
  sched._set_planning(b, 1, "DEADLINE", "2026-05-01")
  local lines = get_lines(b)
  assert_eq(lines[1], "* Task")
  assert_eq(lines[2], "  DEADLINE: <2026-05-01 Fri>")
  assert_eq(lines[3], "  body")
  assert_eq(#lines, 3)
end

-- 2. Set deadline when planning line already has DEADLINE — canonical rewrite.
--    Indent normalised to adapt (level 1 -> 2 spaces).
do
  local b = mk_buf({ "* Task", "DEADLINE: <2026-01-01 Thu>", "  body" })
  sched._set_planning(b, 1, "DEADLINE", "2026-05-01")
  local lines = get_lines(b)
  assert_eq(lines[2], "  DEADLINE: <2026-05-01 Fri>")
  assert_eq(#lines, 3, "no extra lines added")
end

-- 3. Set deadline when the planning line already has SCHEDULED: one
--    planning line, the keyword being set first (Emacs
--    `org-add-planning-info`).
do
  local b = mk_buf({ "* Task", "SCHEDULED: <2026-04-28 Tue>", "  body" })
  sched._set_planning(b, 1, "DEADLINE", "2026-05-01")
  local lines = get_lines(b)
  assert_eq(lines[2], "  DEADLINE: <2026-05-01 Fri> SCHEDULED: <2026-04-28 Tue>")
  assert_eq(lines[3], "  body")
  assert_eq(#lines, 3, "planning stays on one line")
end

-- 4. Cancel (callback nil) — no buffer change.
do
  local b = mk_buf({ "* Task", "  body" })
  local original = get_lines(b)
  local calendar = require("organ.calendar")
  local real_pick = calendar.pick
  calendar.pick = function(opts, cb)
    cb(nil)
  end
  sched.set_deadline({ bufnr = b, line = 1 })
  calendar.pick = real_pick
  local after = get_lines(b)
  assert_eq(#after, #original, "line count unchanged after cancel")
  assert_eq(after[1], original[1])
  assert_eq(after[2], original[2])
end

-- 5. Cursor in body resolves to containing headline.
do
  local b = mk_buf({ "* Task", "  first body line", "  second body line" })
  local calendar = require("organ.calendar")
  local real_pick = calendar.pick
  local triggered = false
  calendar.pick = function(opts, cb)
    triggered = true
    cb("2026-05-01")
  end
  sched.set_deadline({ bufnr = b, line = 3 })
  calendar.pick = real_pick
  assert(triggered, "calendar.pick should have been called")
  local lines = get_lines(b)
  assert_eq(lines[2], "  DEADLINE: <2026-05-01 Fri>", "planning line inserted at correct position")
end

io.write("deadline ok\n")
os.exit(0)
