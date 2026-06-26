-- tests/table_menu_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

require("organ").setup({})

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.bo[b].filetype = "org"
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "| a | b |", "| c | d |" })

local function has_keymap(lhs, mode)
  local nvim_lhs = vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, false, true))
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, mode)) do
    if m.lhs == lhs or vim.fn.keytrans(m.lhsraw or m.lhs) == nvim_lhs then
      return m
    end
  end
  return nil
end

assert(has_keymap("<LocalLeader>|", "n"), "menu keymap installed")

local cmd = require("organ").cmd
for _, path in ipairs({
  "table insert_row",
  "table insert_row_above",
  "table delete_row",
  "table move_row_up",
  "table move_row_down",
  "table insert_column",
  "table insert_column_left",
  "table delete_column",
  "table move_column_left",
  "table move_column_right",
  "table sort",
}) do
  assert(cmd(path), "subcommand `" .. path .. "` missing on :Org")
end

-- Menu invocation: stub vim.ui.select to pick "Insert row below".
vim.api.nvim_win_set_cursor(0, { 1, 3 })
local saved = vim.ui.select
vim.ui.select = function(items, _opts, cb)
  for i, item in ipairs(items) do
    if item:find("Insert row below") then
      cb(item, i)
      return
    end
  end
end
vim.cmd("normal! ,zt") -- assumes localleader = ","; this may vary
-- Bypass localleader complexity: directly invoke via the menu function.
-- Find the keymap callback and call it:
for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
  local nvim_lhs =
    vim.fn.keytrans(vim.api.nvim_replace_termcodes("<LocalLeader>|", true, false, true))
  if m.lhs == "<LocalLeader>|" or vim.fn.keytrans(m.lhsraw or m.lhs) == nvim_lhs then
    if m.callback then
      m.callback()
    end
    break
  end
end
vim.ui.select = saved

local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
assert(#lines == 3, "row inserted via menu; got " .. #lines .. " lines")

vim.api.nvim_buf_delete(b, { force = true })
io.write("table menu ok\n")
