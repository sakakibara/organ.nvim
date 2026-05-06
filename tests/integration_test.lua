-- Assert setup() opens a DB via db.lua, registers autocmds/commands, and
-- that scan_dir indexes all fixture files via the queue.
-- Run via: nvim --headless -l tests/integration_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
-- In headless -l mode rtp changes don't trigger plugin/ sourcing.  Load
-- plugin/organ.lua explicitly so :Org* commands are registered (same as a
-- real Neovim session where rtp is set before startup).
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/org", "p")
local db_path = tmp .. "/test.db"
local org_dir = tmp .. "/org"

for _, name in ipairs({ "01-headlines.org", "02-planning.org", "03-properties.org" }) do
  vim.fn.system({ "cp", root .. "/tests/fixtures/" .. name, org_dir .. "/" .. name })
end

local organ = require("organ")
organ.setup({
  db_path = db_path,
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
})

-- Autocmd.
local autos = vim.api.nvim_get_autocmds({ group = "organ", event = "BufWritePost" })
assert(#autos > 0 and autos[1].pattern == "*.org", "BufWritePost autocmd missing")

-- Subcommands.
assert(vim.api.nvim_get_commands({}).Org, ":Org dispatcher missing")
local cmd = require("organ").cmd
for _, n in ipairs({ "index", "scan", "status" }) do
  assert(cmd(n), "subcommand `" .. n .. "` missing on :Org")
end

-- Blocking scan via public helper.
organ.scan_blocking(org_dir, 10000)

-- Query via db.lua.
local db = require("organ.db")
local h = assert(db.open(db_path))
local function count(q)
  local s = assert(h:prepare(q))
  assert(s:step() == db.SQLITE_ROW)
  local v = s:column_int(0)
  s:finalize()
  return v
end
local hc = count("SELECT COUNT(*) FROM headlines")
local fc = count("SELECT COUNT(*) FROM files")
assert(hc == 14 and fc == 3, string.format("expected 14 headlines / 3 files, got %d / %d", hc, fc))
h:close()

vim.fn.delete(tmp, "rf")
io.write("integration ok\n")
os.exit(0)
