-- The startup fold state (`#+STARTUP:` / `fold.folded`) closes every
-- drawer one tick after the ftplugin runs.  That deferred pass must
-- act on the window that shows the buffer it was scheduled for, not on
-- whichever window is current when the tick fires: opening two org
-- files in two splits must close a.org's drawer in a.org's window and
-- leave b.org's headings alone.
--
-- Run via: nvim --headless -l tests/fold_startup_drawer_window_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
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
  { "#+STARTUP: showall", "* A1", ":PROPERTIES:", ":ID: x", ":END:", "body a1" },
  dir .. "/a.org"
)
vim.fn.writefile({ "#+STARTUP: showall", "* B1", "* B2", "body b2", "more b2" }, dir .. "/b.org")

vim.cmd("edit " .. dir .. "/a.org")
if vim.bo.filetype ~= "org" then
  vim.bo.filetype = "org"
end
local WA = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
vim.cmd("edit " .. dir .. "/b.org")
if vim.bo.filetype ~= "org" then
  vim.bo.filetype = "org"
end
local B = vim.api.nvim_get_current_buf()
local WB = vim.api.nvim_get_current_win()
for _, w in ipairs({ WA, WB }) do
  vim.api.nvim_win_call(w, function()
    vim.cmd("silent! normal! zx")
  end)
end
-- Let the deferred startup-fold + drawer-close callbacks run with WB
-- focused.
vim.wait(200)

check("b.org's window is current", vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) == B)
local fc_b = vim.api.nvim_win_call(WB, function()
  return vim.fn.foldclosed(3)
end)
check("b.org: * B2 stays open in its window", fc_b == -1, "foldclosed(3)=" .. fc_b)
local fc_a = vim.api.nvim_win_call(WA, function()
  return vim.fn.foldclosed(4)
end)
check("a.org: drawer closed in its window", fc_a == 3, "foldclosed(4)=" .. fc_a)

vim.fn.delete(dir, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_startup_drawer_window_test: PASS")
os.exit(0)
