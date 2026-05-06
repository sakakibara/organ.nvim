-- tests/agenda_block_foldexpr_test.lua
-- Run via: nvim --headless -l tests/agenda_block_foldexpr_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local agenda = require("organ.agenda")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "══ Today (3) ══",
  "  TODO Something  /a.org:1",
  "══ Stuck (0) ══",
  "  (nothing)",
})
vim.api.nvim_set_current_buf(bufnr)

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

assert_eq(agenda.foldexpr(1), ">1", "block header line is fold start")
-- `=` tells Neovim to inherit the previous line's fold level.  Per
-- `:h fold-expr`, that's the canonical way to mark "continuation".
assert_eq(agenda.foldexpr(2), "=", "content line inherits prev level")
assert_eq(agenda.foldexpr(3), ">1", "second block header is fold start")
assert_eq(agenda.foldexpr(4), "=", "content line inherits prev level")

io.write("agenda foldexpr ok\n")
