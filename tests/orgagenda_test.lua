-- :Org agenda command exists and opens an agenda buffer.
-- Run via: nvim --headless -l tests/orgagenda_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

-- Headless: auto-pick the first choice from any vim.ui.select prompt
-- (OrgAgenda's view dispatcher uses one).
vim.ui.select = function(choices, _opts, on_choice)
  on_choice(choices[1])
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db_path = tmp .. "/o.db"
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
vim.fn.system({ "cp", root .. "/tests/fixtures/02-planning.org", org_dir .. "/02.org" })

require("organ").setup({
  db_path = db_path,
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  agenda = {
    default_view = {
      from = "2026-04-01",
      to = "2026-06-01",
      types = { "scheduled", "deadline" },
      include_overdue = true,
      group_by = "day",
    },
    refresh_debounce_ms = 30,
  },
})
require("organ").scan_blocking(org_dir, 5000)

assert(vim.api.nvim_get_commands({}).Org, ":Org dispatcher not registered")
assert(require("organ").cmd("agenda"), "subcommand `agenda` not registered on :Org")

-- Invoke :Org agenda and verify we end up in a buffer with filetype=organ-agenda.
vim.cmd("Org agenda")
local bufnr = vim.api.nvim_get_current_buf()
assert(
  vim.bo[bufnr].filetype == "organ-agenda",
  "expected filetype=organ-agenda, got " .. vim.bo[bufnr].filetype
)
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
assert(#lines > 0, "agenda buffer empty")

-- :Org agenda with a saved view name
local organ = require("organ")
organ.config.agenda.views = {
  custom = { from = "2026-04-01", to = "2026-05-01", types = { "scheduled" } },
}
vim.cmd("Org agenda custom")
local bufnr2 = vim.api.nvim_get_current_buf()
assert(vim.bo[bufnr2].filetype == "organ-agenda")

vim.fn.delete(tmp, "rf")
io.write("OrgAgenda ok\n")
os.exit(0)
