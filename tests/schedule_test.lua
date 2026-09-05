-- tests/schedule_test.lua
-- Unit tests for lua/organ/schedule.lua
-- Run via: nvim --headless -l tests/schedule_test.lua

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

-- 1. Set schedule on fresh headline — planning line inserted with SCHEDULED:.
do
  local b = mk_buf({ "* Task", "  body" })
  sched._set_planning(b, 1, "SCHEDULED", "2026-04-28")
  local lines = get_lines(b)
  assert_eq(lines[1], "* Task")
  assert_eq(lines[2], "  SCHEDULED: <2026-04-28 Tue>")
  assert_eq(lines[3], "  body")
  assert_eq(#lines, 3)
end

-- 2. Set schedule when planning line already has SCHEDULED — replaced in
--    place, keeping the indent the line already has (org-add-planning-info
--    edits from the line's own indentation; `planning_indent` only decides
--    where a FIRST planning line is written).
do
  local b = mk_buf({ "* Task", "SCHEDULED: <2026-01-01 Thu>", "  body" })
  sched._set_planning(b, 1, "SCHEDULED", "2026-04-28")
  local lines = get_lines(b)
  assert_eq(lines[2], "SCHEDULED: <2026-04-28 Tue>")
  assert_eq(#lines, 3, "no extra lines added")
end

-- 3. Set schedule when the planning line already has DEADLINE: one
--    planning line, the keyword being set first (Emacs
--    `org-add-planning-info`).
do
  local b = mk_buf({ "* Task", "DEADLINE: <2026-05-01 Fri>", "  body" })
  sched._set_planning(b, 1, "SCHEDULED", "2026-04-28")
  local lines = get_lines(b)
  assert_eq(lines[2], "SCHEDULED: <2026-04-28 Tue> DEADLINE: <2026-05-01 Fri>")
  assert_eq(lines[3], "  body")
  assert_eq(#lines, 3, "planning stays on one line")
end

-- 4. Cancel (callback nil) — no buffer change.
do
  local b = mk_buf({ "* Task", "  body" })
  local original = get_lines(b)
  -- Stub calendar.pick to call callback with nil synchronously.
  local calendar = require("organ.calendar")
  local real_pick = calendar.pick
  calendar.pick = function(opts, cb)
    cb(nil)
  end
  sched.set_schedule({ bufnr = b, line = 1 })
  calendar.pick = real_pick
  local after = get_lines(b)
  assert_eq(#after, #original, "line count unchanged after cancel")
  assert_eq(after[1], original[1])
  assert_eq(after[2], original[2])
end

-- 5. Cursor in body resolves to containing headline.
do
  local b = mk_buf({ "* Task", "  first body line", "  second body line" })
  -- Stub calendar to capture which headline line was used.
  local calendar = require("organ.calendar")
  local real_pick = calendar.pick
  local triggered = false
  calendar.pick = function(opts, cb)
    triggered = true
    cb("2026-04-28")
  end
  -- Call set_schedule from body line 3.
  sched.set_schedule({ bufnr = b, line = 3 })
  calendar.pick = real_pick
  assert(triggered, "calendar.pick should have been called")
  local lines = get_lines(b)
  -- Planning line should be at line 2.
  assert_eq(lines[2], "  SCHEDULED: <2026-04-28 Tue>", "planning line inserted at correct position")
end

-- 6. Re-setting a planning date keeps the existing repeater / warning
--    cookie (Emacs `org--deadline-or-schedule` re-appends it).
do
  local b = mk_buf({ "* Task", "DEADLINE: <2026-05-01 Fri +1w>" })
  sched._set_planning(b, 1, "DEADLINE", "2026-06-01")
  assert_eq(get_lines(b)[2], "DEADLINE: <2026-06-01 Mon +1w>", "repeater kept")

  b = mk_buf({ "* Task", "SCHEDULED: <2026-05-01 Fri 09:00 .+1d/3d>" })
  sched._set_planning(b, 1, "SCHEDULED", "2026-06-01", { start = "10:00" })
  assert_eq(get_lines(b)[2], "SCHEDULED: <2026-06-01 Mon 10:00 .+1d/3d>", "habit cookie kept")

  b = mk_buf({ "* Task", "DEADLINE: <2026-05-01 Fri ++1w -2d>" })
  sched._set_planning(b, 1, "DEADLINE", "2026-06-01")
  assert_eq(get_lines(b)[2], "DEADLINE: <2026-06-01 Mon ++1w -2d>", "warning period kept")

  b = mk_buf({ "* Task", "DEADLINE: <2026-05-01 Fri -2d>" })
  sched._set_planning(b, 1, "DEADLINE", "2026-06-01")
  assert_eq(get_lines(b)[2], "DEADLINE: <2026-06-01 Mon -2d>", "lone warning period kept")
end

-- 7. Scheduling removes CLOSED, keeps the other keywords (Emacs
--    `org--deadline-or-schedule` passes `'closed` to
--    `org-add-planning-info`).
do
  local b = mk_buf({
    "* DONE Keep",
    "CLOSED: [2026-05-04 Mon 12:00] DEADLINE: <2026-05-10 Sun>",
    "body",
  })
  sched._set_planning(b, 1, "SCHEDULED", "2026-05-06")
  local lines = get_lines(b)
  assert_eq(lines[2], "SCHEDULED: <2026-05-06 Wed> DEADLINE: <2026-05-10 Sun>", "CLOSED removed")
  assert_eq(lines[3], "body")
  assert_eq(#lines, 3)
end

io.write("schedule ok\n")
os.exit(0)
