-- Verify buffer-local keymaps are installed on agenda open.
-- Run via: nvim --headless -l tests/agenda_keymaps_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db_path = tmp .. "/km.db"
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
vim.fn.system({ "cp", root .. "/tests/fixtures/02-planning.org", org_dir .. "/02.org" })

require("organ").setup({
  db_path = db_path,
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
})
require("organ").scan_blocking(org_dir, 5000)

local agenda = require("organ.agenda")
local bufnr = agenda.open({ from = "2026-04-01", to = "2026-06-01" })

local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
local lhs = {}
for _, m in ipairs(maps) do
  lhs[m.lhs] = true
end

-- Defaults rebound o/v → gs/gv (vim's bare `o`/`v` shadow normal-mode
-- open-line / visual-mode); enforce the new keys.
for _, key in ipairs({ "<CR>", "gs", "gv", "r", "q", "j", "k", "/", "<Tab>", "g?" }) do
  -- Neovim normalises <CR> → \r in nvim_buf_get_keymap output on some versions;
  -- accept either form.
  local ok = lhs[key] or lhs[key:gsub("<CR>", "\r"):gsub("<Tab>", "\t")]
  assert(ok, "missing keymap: " .. key)
end

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(tmp, "rf")
io.write("agenda keymaps ok\n")
os.exit(0)
