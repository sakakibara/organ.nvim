-- :Org backlinks opens a backlinks buffer; accepts explicit id or cursor-based.
-- Run via: nvim --headless -l tests/orgbacklinks_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db_path = tmp .. "/ob.db"
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/05.org"
vim.fn.system({ "cp", root .. "/tests/fixtures/05-links.org", fixture })

require("organ").setup({
  db_path = db_path,
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
})
require("organ").scan_blocking(org_dir, 5000)

assert(vim.api.nvim_get_commands({}).Org, ":Org not registered")
assert(
  require("organ").cmd("backlinks"),
  "subcommand `backlinks` not registered in :Org dispatcher"
)

vim.cmd("Org backlinks alpha-id")
local bufnr = vim.api.nvim_get_current_buf()
assert(vim.bo[bufnr].filetype == "organ-backlinks")
local joined = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
assert(joined:find("Alpha", 1, true), joined)

vim.cmd("edit " .. vim.fn.fnameescape(fixture))
vim.bo.filetype = "org"
for lnum, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if line:match("^%* Alpha") then
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    break
  end
end
vim.cmd("Org backlinks")
local bufnr2 = vim.api.nvim_get_current_buf()
assert(
  vim.bo[bufnr2].filetype == "organ-backlinks",
  "expected organ-backlinks, got " .. vim.bo[bufnr2].filetype
)

vim.fn.delete(tmp, "rf")
io.write("OrgBacklinks ok\n")
os.exit(0)
