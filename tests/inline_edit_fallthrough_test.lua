-- tests/inline_edit_fallthrough_test.lua
-- Run via: nvim --headless -l tests/inline_edit_fallthrough_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function mk_buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function get_line(b, n)
  return vim.api.nvim_buf_get_lines(b, n - 1, n, false)[1]
end
local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- No fallback configured: built-in <C-a> increments a number in body text.
do
  require("organ").setup({})
  local inline = require("organ.inline_edit")
  local b = mk_buf({ "the answer is 41" })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 14 }) -- on "4"
  inline.dispatch("inc")
  assert_eq(get_line(b, 1), "the answer is 42", "built-in <C-a> ran")
end

-- User fallback configured: it's called instead of the built-in.
do
  local called = 0
  require("organ").setup({
    inline_edit = {
      fallback_increment = function()
        called = called + 1
      end,
      fallback_decrement = function()
        called = called + 100
      end,
    },
  })
  local inline = require("organ.inline_edit")
  local b = mk_buf({ "no number here just text" })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  inline.dispatch("inc")
  assert_eq(called, 1, "fallback_increment was called")
  inline.dispatch("dec")
  assert_eq(called, 101, "fallback_decrement was called")
end

io.write("inline_edit fallthrough ok\n")
