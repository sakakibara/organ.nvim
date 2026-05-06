-- tests/structure_keymaps_test.lua
-- Run via: nvim --headless -l tests/structure_keymaps_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

require("organ").setup({})

-- Open a buffer with filetype=org and trigger the FileType autocmd.
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.bo[b].filetype = "org"

-- Neovim normalizes '<' in keymap lhs to '<lt>', so "<<" is stored as "<lt><lt>".
-- Compare both the raw form and the nvim-normalised form.
local function has_keymap(lhs)
  local nvim_form = lhs:gsub("<", "<lt>")
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
    if m.lhs == lhs or m.lhs == nvim_form then
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

assert(has_keymap("<<"), "<< default-installed")
assert(has_keymap(">>"), ">> default-installed")
assert(has_keymap("gK"), "gK default-installed")
assert(has_keymap("gJ"), "gJ default-installed")

-- Subcommands registered on :Org dispatcher.
local cmd = require("organ").cmd
for _, name in ipairs({
  "promote",
  "demote",
  "promote_headline",
  "demote_headline",
  "move_up",
  "move_down",
}) do
  assert(cmd(name), "subcommand `" .. name .. "` not registered on :Org")
end

-- desc set for which-key.
local p = has_keymap("<<")
assert(p and p.desc and p.desc ~= "", "<< has desc")

vim.api.nvim_buf_delete(b, { force = true })
io.write("structure keymaps ok\n")
