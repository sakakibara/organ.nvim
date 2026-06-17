-- tests/property_keymaps_test.lua
-- Run via: nvim --headless -l tests/property_keymaps_test.lua

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

assert(has_keymap("<LocalLeader>ps"), "<LocalLeader>ps default-installed")
assert(has_keymap("<LocalLeader>pd"), "<LocalLeader>pd default-installed")

local cmd = require("organ").cmd
assert(cmd("set_property"), "OrgSetProperty registered")
assert(cmd("delete_property"), "OrgDeleteProperty registered")

local p = has_keymap("<LocalLeader>ps")
assert(p and p.desc and p.desc ~= "", "<LocalLeader>ps has desc")

vim.api.nvim_buf_delete(b, { force = true })

-- Smoke test of interactive flow with stubbed UI.
local prop = require("organ.property")
local b2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "* A" })
local saved_input = vim.ui.input
local responses = { "ID", "abc-123" }
vim.ui.input = function(_, cb)
  cb(table.remove(responses, 1))
end
prop.set_interactive(b2, 1)
vim.ui.input = saved_input
local lines = vim.api.nvim_buf_get_lines(b2, 0, -1, false)
assert(
  lines[3] == "  :ID:       abc-123",
  "set_interactive wrote   :ID:       abc-123, got: " .. tostring(lines[3])
)

io.write("property keymaps ok\n")
