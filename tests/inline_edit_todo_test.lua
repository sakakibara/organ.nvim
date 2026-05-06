-- tests/inline_edit_todo_test.lua
-- Run via: nvim --headless -l tests/inline_edit_todo_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  todo = { sequence = { "TODO", "NEXT", "|", "DONE", "CANCELLED" } },
})

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

----------------------------------------------------------------------
-- Inc on TODO keyword cycles forward.
do
  local b = mk_buf({ "* TODO Item" })
  press_at(b, 1, 3, "inc") -- on "T" of "TODO"
  assert_eq(get_line(b, 1), "* NEXT Item")
end

----------------------------------------------------------------------
-- Dec on TODO keyword cycles backward.
do
  local b = mk_buf({ "* NEXT Item" })
  press_at(b, 1, 3, "dec") -- on "N" of "NEXT"
  assert_eq(get_line(b, 1), "* TODO Item")
end

----------------------------------------------------------------------
-- Compute prev state directly (unit test for the helper).
do
  local todo = require("organ.todo")
  local seq = { "TODO", "NEXT", "|", "DONE", "CANCELLED" }
  -- Forward: nil -> TODO -> NEXT -> DONE -> CANCELLED -> nil
  -- Backward: nil -> CANCELLED -> DONE -> NEXT -> TODO -> nil
  assert_eq(todo._compute_prev_state(nil, seq), "CANCELLED")
  assert_eq(todo._compute_prev_state("CANCELLED", seq), "DONE")
  assert_eq(todo._compute_prev_state("DONE", seq), "NEXT")
  assert_eq(todo._compute_prev_state("NEXT", seq), "TODO")
  assert_eq(todo._compute_prev_state("TODO", seq), nil)
end

io.write("inline_edit todo ok\n")
