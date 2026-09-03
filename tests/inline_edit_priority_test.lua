-- tests/inline_edit_priority_test.lua
-- Run via: nvim --headless -l tests/inline_edit_priority_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({})

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

-- Cycle A -> B -> C -> none -> A.
do
  local b = mk_buf({ "* TODO [#A] Task" })
  -- "[#A]" starts at col 9 (0-based 8); cursor on "A" (col 11).
  press_at(b, 1, 11, "inc")
  assert_eq(get_line(b, 1), "* TODO [#B] Task")
  press_at(b, 1, 11, "inc")
  assert_eq(get_line(b, 1), "* TODO [#C] Task")
  press_at(b, 1, 11, "inc")
  assert_eq(get_line(b, 1), "* TODO Task", "[#C] -> none removes cookie")
end

-- Reverse cycle on an existing cookie: A -> none -> ...
do
  local b = mk_buf({ "* TODO [#A] Task" })
  -- cursor on "A" of [#A]
  press_at(b, 1, 11, "dec")
  assert_eq(get_line(b, 1), "* TODO Task", "[#A] -> none on dec")
end

-- Cursor in headline title region (no priority cookie) cycles TODO,
-- NOT inserts a priority cookie.  Inserting silently was the bug:
-- pressing <C-a> on a heading was supposed to advance the TODO state
-- (Emacs `S-Right` on a heading), and the priority-insert path was
-- shadowing it.  To insert a cookie deliberately, use
-- inline_edit.set_priority or :Org set_property.
do
  require("organ").config.todo = { sequence = { "TODO", "NEXT", "WAIT", "|", "DONE" } }
  local b = mk_buf({ "* TODO Task" })
  press_at(b, 1, 8, "inc") -- col 8 = "T" of "Task"
  assert_eq(get_line(b, 1), "* NEXT Task", "<C-a> on title cycles TODO forward")
  press_at(b, 1, 8, "dec") -- back to TODO
  assert_eq(get_line(b, 1), "* TODO Task", "<C-x> on title cycles TODO backward")
end

-- Cursor on the TODO keyword itself also cycles TODO (covers both
-- the keyword-region and the title-region branches landing on the
-- same handler).
do
  local b = mk_buf({ "* TODO Task" })
  press_at(b, 1, 3, "inc") -- col 3 = "O" of "TODO"
  assert_eq(get_line(b, 1), "* NEXT Task", "<C-a> on TODO keyword cycles forward")
end

-- Boundary scan: cursor on `[`, `#`, the letter, `]`, AND the
-- trailing space all cycle the cookie.  Each call hits a different
-- branch of find_priority_at's range check.
do
  for _, col in ipairs({ 7, 8, 9, 10, 11 }) do
    -- "* TODO [#A] Task"
    --  0     6 7 8 9 10 11
    local b = mk_buf({ "* TODO [#A] Task" })
    press_at(b, 1, col, "inc")
    assert_eq(
      get_line(b, 1),
      "* TODO [#B] Task",
      "cursor at col " .. col .. " (cookie region) cycles priority"
    )
  end
end

-- B -> A on dec (skipped above: only A and C edges are tested).
do
  local b = mk_buf({ "* TODO [#B] Task" })
  press_at(b, 1, 11, "dec")
  assert_eq(get_line(b, 1), "* TODO [#A] Task", "B -> A on dec")
end

-- Multi-letter TODO keywords (NEXT) cycle from any title-region cursor.
do
  require("organ").config.todo = { sequence = { "TODO", "NEXT", "WAIT", "|", "DONE" } }
  local b = mk_buf({ "* NEXT Long task title" })
  -- col 8 = "L" of "Long" (deep in title region)
  press_at(b, 1, 8, "inc")
  assert_eq(get_line(b, 1), "* WAIT Long task title", "NEXT -> WAIT on inc")
end

-- Heading with NO TODO keyword: <C-a> on title region inserts the
-- first active TODO state (whatever todo.cycle does for a stateless
-- headline).  We assert that *something* changed and the title is
-- preserved — the exact keyword is governed by `todo.sequence`.
do
  require("organ").config.todo = { sequence = { "TODO", "NEXT", "|", "DONE" } }
  local b = mk_buf({ "* Plain headline" })
  press_at(b, 1, 5, "inc") -- in title region
  local line = get_line(b, 1)
  assert_eq(
    line:match("^%*%s+%a+%s+Plain headline$") ~= nil,
    true,
    "stateless headline got a TODO keyword inserted (got: " .. line .. ")"
  )
end

-- Heading with priority cookie AND title region: cursor on the
-- cookie cycles priority, cursor in title region cycles TODO.
do
  require("organ").config.todo = { sequence = { "TODO", "NEXT", "|", "DONE" } }
  local b = mk_buf({ "* TODO [#A] My task" })

  -- cursor on "M" of "My" (col 12, past the cookie + space)
  press_at(b, 1, 12, "inc")
  assert_eq(
    get_line(b, 1),
    "* NEXT [#A] My task",
    "title-region cursor cycles TODO, leaves priority alone"
  )

  -- now cursor on the priority letter (col 9) — cycles priority only
  press_at(b, 1, 9, "inc")
  assert_eq(
    get_line(b, 1),
    "* NEXT [#B] My task",
    "cookie-region cursor cycles priority, leaves TODO alone"
  )
end

-- The configured priority range governs cookie cycling, as it does
-- raise_priority / lower_priority.
do
  require("organ").config.priority = { highest = "A", lowest = "E" }
  local b = mk_buf({ "* TODO [#C] Task" })
  press_at(b, 1, 9, "inc")
  assert_eq(get_line(b, 1), "* TODO [#D] Task", "C -> D with lowest = E")
  press_at(b, 1, 9, "inc")
  assert_eq(get_line(b, 1), "* TODO [#E] Task", "D -> E")
  press_at(b, 1, 9, "inc")
  assert_eq(get_line(b, 1), "* TODO Task", "E -> none at lowest")
  b = mk_buf({ "* TODO [#E] Task" })
  press_at(b, 1, 9, "dec")
  assert_eq(get_line(b, 1), "* TODO [#D] Task", "E -> D on dec")
  b = mk_buf({ "* TODO [#A] Task" })
  press_at(b, 1, 9, "dec")
  assert_eq(get_line(b, 1), "* TODO Task", "A -> none at highest on dec")
  require("organ").config.priority = nil
end

-- Cursor in body text does NOT match priority context.
-- Verify by ensuring fallback runs (number increments).
do
  local b = mk_buf({ "  count is 5" })
  press_at(b, 1, 11, "inc") -- on "5"
  assert_eq(get_line(b, 1), "  count is 6", "fell through to <C-a>")
end

io.write("inline_edit priority ok\n")
