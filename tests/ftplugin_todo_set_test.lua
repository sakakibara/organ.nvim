-- The "pick TODO state" menu offers the buffer's EFFECTIVE keywords:
-- `#+TODO:` directives win over `todo.sequence`, and `(t)`/`!`/`@`
-- annotations are stripped so the picked keyword is written bare.
--
-- Run via: nvim --headless -l tests/ftplugin_todo_set_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO(t)", "NEXT(n)", "|", "DONE(d)" } },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "* foo" }, dir .. "/a.org")
vim.cmd("edit " .. dir .. "/a.org")
if vim.bo.filetype ~= "org" then
  vim.bo.filetype = "org"
end
vim.wait(50)
local bufnr = vim.api.nvim_get_current_buf()

local offered
vim.ui.select = function(items, _opts, cb)
  offered = items
  cb(items[2])
end
local map
for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
  if m.desc == "Pick TODO state from menu" then
    map = m
  end
end
check("todo set keymap installed", map ~= nil)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
map.callback()
check(
  "menu offers bare keywords from an annotated todo.sequence",
  vim.deep_equal(offered, { "(none)", "TODO", "NEXT", "DONE" }),
  vim.inspect(offered)
)
local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
check("picking writes the bare keyword", line == "* TODO foo", line)

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "#+TODO: WAIT | FIXED", "* bar" })
offered = nil
vim.api.nvim_win_set_cursor(0, { 2, 0 })
map.callback()
check(
  "menu offers the buffer's #+TODO keywords",
  vim.deep_equal(offered, { "(none)", "WAIT", "FIXED" }),
  vim.inspect(offered)
)
line = vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1]
check("picking a #+TODO keyword writes it", line == "* WAIT bar", line)

vim.fn.delete(dir, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ftplugin_todo_set_test: PASS")
os.exit(0)
