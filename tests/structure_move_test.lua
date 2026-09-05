-- tests/structure_move_test.lua
-- Run via: nvim --headless -l tests/structure_move_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local structure = require("organ.structure")

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
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- move_subtree_up swaps with previous sibling, preserving body content.
do
  local b = mk_buf({
    "* A",
    "  body of A",
    "** A1",
    "* B",
    "  body of B",
  })
  local err = structure.move_subtree_up({ bufnr = b, line = 4 }) -- on B
  assert(err == nil, tostring(err))
  local out = get_lines(b)
  assert_eq(out[1], "* B")
  assert_eq(out[2], "  body of B")
  assert_eq(out[3], "* A")
  assert_eq(out[4], "  body of A")
  assert_eq(out[5], "** A1")
end

-- move_subtree_down swaps with next sibling.
do
  local b = mk_buf({
    "* A",
    "* B",
    "  body of B",
    "* C",
  })
  local err = structure.move_subtree_down({ bufnr = b, line = 1 }) -- on A, first sibling
  assert(err == nil, tostring(err))
  local out = get_lines(b)
  assert_eq(out[1], "* B")
  assert_eq(out[2], "  body of B")
  assert_eq(out[3], "* A")
  assert_eq(out[4], "* C")
end

-- move_subtree_up at first sibling errors.
do
  local b = mk_buf({ "* A", "* B" })
  local err = structure.move_subtree_up({ bufnr = b, line = 1 })
  assert(err and err:find("no previous sibling"), "got: " .. tostring(err))
  assert_eq(get_lines(b)[1], "* A", "buffer unchanged")
end

-- move_subtree_down at last sibling errors.
do
  local b = mk_buf({ "* A", "* B" })
  local err = structure.move_subtree_down({ bufnr = b, line = 2 })
  assert(err and err:find("no next sibling"), "got: " .. tostring(err))
  assert_eq(get_lines(b)[2], "* B")
end

-- move with sub-headlines preserves nested structure.
do
  local b = mk_buf({
    "* A",
    "** A1",
    "** A2",
    "* B",
    "** B1",
  })
  structure.move_subtree_up({ bufnr = b, line = 4 }) -- on B
  local out = get_lines(b)
  assert_eq(out[1], "* B")
  assert_eq(out[2], "** B1")
  assert_eq(out[3], "* A")
  assert_eq(out[4], "** A1")
  assert_eq(out[5], "** A2")
end

-- Blank lines between siblings survive the swap (one of the user-visible
-- bugs we're fixing: the separator used to collapse on each move).
do
  local b = mk_buf({
    "* A",
    "body A",
    "",
    "* B",
    "body B",
  })
  local err = structure.move_subtree_up({ bufnr = b, line = 4 }) -- on B
  assert(err == nil, tostring(err))
  local out = get_lines(b)
  assert_eq(out[1], "* B", "B moved to top")
  assert_eq(out[2], "body B")
  assert_eq(out[3], "", "blank separator preserved between B and A")
  assert_eq(out[4], "* A")
  assert_eq(out[5], "body A")
end

do
  local b = mk_buf({
    "* A",
    "body A",
    "",
    "* B",
    "body B",
  })
  local err = structure.move_subtree_down({ bufnr = b, line = 1 }) -- on A
  assert(err == nil, tostring(err))
  local out = get_lines(b)
  assert_eq(out[1], "* B")
  assert_eq(out[2], "body B")
  assert_eq(out[3], "", "blank separator preserved between B and A (move_down)")
  assert_eq(out[4], "* A")
  assert_eq(out[5], "body A")
end

-- Multi-line blank separator: 2 blanks between sections stay 2 blanks.
do
  local b = mk_buf({
    "* A",
    "body A",
    "",
    "",
    "* B",
    "body B",
  })
  structure.move_subtree_up({ bufnr = b, line = 5 })
  local out = get_lines(b)
  assert_eq(out[1], "* B")
  assert_eq(out[2], "body B")
  assert_eq(out[3], "", "first blank of multi-line separator preserved")
  assert_eq(out[4], "", "second blank of multi-line separator preserved")
  assert_eq(out[5], "* A")
  assert_eq(out[6], "body A")
end

-- Cursor follows the moved subtree (matches Emacs behavior).
do
  local b = mk_buf({
    "* A",
    "body A",
    "",
    "* B",
    "body B",
  })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 5, 2 }) -- on "body B"
  structure.move_subtree_down({ bufnr = b, line = 1 }) -- move A down
  -- A moved from line 1 to line 4 (after B + separator). Cursor was on
  -- line 5 (offset +4 from A's original line 1); should now be at
  -- line 4 + 4 = 8 ... but buffer only has 5 lines.  Cursor was inside
  -- B (the OTHER subtree, not the moved one) so it should NOT follow.
  -- Actually the doc says cursor follows the MOVED subtree.  Cursor
  -- was on B's body, not A.  So after the move, cursor stays where
  -- the moved subtree (A) went... wait, cursor wasn't on A.
  -- The follow_cursor logic uses `line` arg (1 = A.line).  After move,
  -- A is at line 4, so cursor goes to line 4 + (1 - 1) = 4.
  local pos = vim.api.nvim_win_get_cursor(0)
  assert_eq(pos[1], 4, "cursor at moved subtree's new headline (move_down)")
end

do
  local b = mk_buf({
    "* A",
    "body A",
    "",
    "* B",
    "body B line 1",
    "body B line 2",
  })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 6, 4 }) -- on "body B line 2"
  structure.move_subtree_up({ bufnr = b, line = 4 }) -- move B up; line=4 is B's heading
  -- B was at line 4 with 3 lines (heading + 2 body).
  -- After move: B at line 1 with same content.  Cursor was originally on
  -- line 4 (B's heading start passed in opts.line), so follows to line 1.
  local pos = vim.api.nvim_win_get_cursor(0)
  assert_eq(pos[1], 1, "cursor at moved subtree's new headline (move_up)")
end

-- A bare "**" line is body text, so it moves with its subtree.
do
  local b = mk_buf({ "* A", "** B", "**", "text", "** C", "after" })
  vim.api.nvim_set_current_buf(b)
  local err = structure.move_subtree_down({ bufnr = b, line = 2 })
  assert_eq(err, nil)
  local lines = get_lines(b)
  assert_eq(table.concat(lines, "\n"), "* A\n** C\nafter\n** B\n**\ntext", "bare ** moves with B")
end

-- promote_subtree on a bare "**" line acts on the enclosing headline.
do
  local b = mk_buf({ "* A", "** B", "**", "text", "** C" })
  vim.api.nvim_set_current_buf(b)
  local err = structure.promote_subtree({ bufnr = b, line = 3 })
  assert_eq(err, nil)
  local lines = get_lines(b)
  assert_eq(table.concat(lines, "\n"), "* A\n* B\n**\ntext\n** C", "B promoted, bare ** untouched")
end

-- Emacs `org-move-subtree-down` ends with `(goto-char ins-point)
-- (org-skip-whitespace) (move-to-column col)`: point lands on the moved
-- subtree's heading, whatever line of it point started on.  A cursor on
-- the subtree's trailing blank lines must not be carried past the moved
-- block onto the subtree that was displaced.
do
  local b = mk_buf({ "* A", "* B", "", "* C" })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local err = structure.move_subtree_up({ bufnr = b })
  assert_eq(err, nil)
  assert_eq(table.concat(get_lines(b), "\n"), "* B\n* A\n\n* C", "B moved above A")
  assert_eq(
    vim.api.nvim_win_get_cursor(0)[1],
    1,
    "cursor on the moved subtree's heading (move_up from trailing blank)"
  )
end

do
  local b = mk_buf({ "* A", "", "* B", "* C" })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local err = structure.move_subtree_down({ bufnr = b })
  assert_eq(err, nil)
  assert_eq(table.concat(get_lines(b), "\n"), "* B\n\n* A\n* C", "A moved below B")
  assert_eq(
    vim.api.nvim_win_get_cursor(0)[1],
    3,
    "cursor on the moved subtree's heading (move_down from trailing blank)"
  )
end

-- A cursor deep in the subtree's body lands on the heading too.
do
  local b = mk_buf({ "* A", "* B", "b1", "b2", "", "* C" })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 4, 1 })
  local err = structure.move_subtree_up({ bufnr = b })
  assert_eq(err, nil)
  local pos = vim.api.nvim_win_get_cursor(0)
  assert_eq(pos[1], 1, "cursor on the moved subtree's heading (move_up from body)")
  assert_eq(pos[2], 1, "column preserved")
end

io.write("structure move ok\n")
