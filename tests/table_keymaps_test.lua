-- tests/table_keymaps_test.lua
-- Run via: nvim --headless -l tests/table_keymaps_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({})

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.bo[b].filetype = "org"

local function has_keymap(lhs, mode, bufnr)
  bufnr = bufnr or b
  local nvim_lhs = vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, false, true))
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
    if m.lhs == lhs or vim.fn.keytrans(m.lhsraw or m.lhs) == nvim_lhs then
      return m
    end
  end
  return nil
end

assert(has_keymap("<Tab>", "i"), "<Tab> insert mode")
assert(has_keymap("<Tab>", "n"), "<Tab> normal mode")
assert(has_keymap("<S-Tab>", "i"), "<S-Tab> insert mode")
assert(has_keymap("<S-Tab>", "n"), "<S-Tab> normal mode")

vim.api.nvim_buf_delete(b, { force = true })

-- <Tab> on a headline dispatches to fold.cycle (not feedkeys).
-- We verify this by intercepting fold.cycle and confirming it is called.
do
  local fold_called = false
  local fold_mod = require("organ.fold")
  local orig_cycle = fold_mod.cycle
  fold_mod.cycle = function(bufnr, line)
    fold_called = true
    orig_cycle(bufnr, line)
  end

  local bfold = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bfold)
  vim.bo[bfold].filetype = "org"
  vim.api.nvim_buf_set_lines(bfold, 0, -1, false, {
    "* Headline",
    "  body text",
    "* Other",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  -- Trigger the <Tab> normal-mode keymap callback directly.
  local km = has_keymap("<Tab>", "n", bfold)
  assert(km and km.callback, "<Tab> normal keymap should have callback")
  km.callback()

  fold_mod.cycle = orig_cycle
  vim.api.nvim_buf_delete(bfold, { force = true })

  assert(fold_called, "<Tab> on headline should dispatch to fold.cycle")
end

io.write("table keymaps ok\n")
