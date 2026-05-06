-- tests/inline_edit_keymaps_test.lua
-- Run via: nvim --headless -l tests/inline_edit_keymaps_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

require("organ").setup({})

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.bo[b].filetype = "org"

local function has_keymap(lhs)
  local nvim_lhs = vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, false, true))
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
    if m.lhs == lhs or m.lhs == nvim_lhs then
      return m
    end
  end
  return nil
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

assert(has_keymap("<C-a>"), "<C-a> default-installed in org buffer")
assert(has_keymap("<C-x>"), "<C-x> default-installed in org buffer")

local cmd = require("organ").cmd
assert(cmd("increment"), "OrgIncrement registered")
assert(cmd("decrement"), "OrgDecrement registered")

local p = has_keymap("<C-a>")
assert(p and p.desc and p.desc ~= "", "<C-a> has desc")

vim.api.nvim_buf_delete(b, { force = true })
io.write("inline_edit keymaps ok\n")
