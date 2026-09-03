-- The table ftplugin maps normal-mode <Tab> after core's fold-cycle
-- map, so its off-table fallback IS the fold <Tab>.  It must dispatch
-- exactly like core.lua: run `fold.cycle` and feed the native key only
-- when cycle reports "not handled".  Drawer lines and (with
-- `fold.cycle_emulate_tab = false`) body lines are handled by cycle.
--
-- Run via: nvim --headless -l tests/ftplugin_table_tab_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  fold = { cycle_emulate_tab = false },
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
vim.fn.writefile(
  { "* H1", ":PROPERTIES:", ":ID: x", ":END:", "body line", "* H2" },
  dir .. "/a.org"
)
vim.cmd("edit " .. dir .. "/a.org")
if vim.bo.filetype ~= "org" then
  vim.bo.filetype = "org"
end
vim.wait(200)
local bufnr = vim.api.nvim_get_current_buf()

local tab = vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
local map
for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
  if m.lhs == tab or m.lhs == "<Tab>" then
    map = m
  end
end
check(
  "normal-mode <Tab> is the table map",
  map ~= nil and map.desc == "Next table cell",
  map and map.desc
)

vim.cmd("silent! %foldopen!")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
map.callback()
vim.wait(50)
check(
  "<Tab> on a drawer line closes the drawer",
  vim.fn.foldclosed(3) == 2,
  "foldclosed(3)=" .. vim.fn.foldclosed(3)
)

vim.cmd("silent! %foldopen!")
vim.api.nvim_win_set_cursor(0, { 5, 0 })
map.callback()
vim.wait(50)
check(
  "<Tab> on a body line folds the heading (cycle_emulate_tab = false)",
  vim.fn.foldclosed(5) == 1,
  "foldclosed(5)=" .. vim.fn.foldclosed(5)
)

vim.cmd("silent! %foldopen!")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
map.callback()
vim.wait(50)
check(
  "<Tab> on a heading folds it",
  vim.fn.foldclosed(2) == 1,
  "foldclosed(2)=" .. vim.fn.foldclosed(2)
)

vim.fn.delete(dir, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ftplugin_table_tab_test: PASS")
os.exit(0)
