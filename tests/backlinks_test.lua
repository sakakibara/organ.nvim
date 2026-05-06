-- Backlinks buffer: open, refresh, filetype, event-driven re-render, keymaps.
-- Run via: nvim --headless -l tests/backlinks_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db_path = tmp .. "/bl.db"
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
vim.fn.system({ "cp", root .. "/tests/fixtures/05-links.org", org_dir .. "/05.org" })

require("organ").setup({
  db_path = db_path,
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  backlinks = { refresh_debounce_ms = 30 },
})
require("organ").scan_blocking(org_dir, 5000)

local backlinks = require("organ.backlinks")
local events = require("organ.events")

-- Alpha's id is "alpha-id"; Beta links to Alpha via [[id:alpha-id]].
local bufnr = backlinks.open("alpha-id")
assert(type(bufnr) == "number" and bufnr > 0)

assert(vim.bo[bufnr].filetype == "organ-backlinks", "filetype=" .. tostring(vim.bo[bufnr].filetype))
assert(vim.bo[bufnr].buftype == "nofile")
assert(vim.bo[bufnr].modifiable == false)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local joined = table.concat(lines, "\n")
assert(joined:find("Backlink", 1, true), "no header line:\n" .. joined)
assert(joined:find("Alpha", 1, true), "target title missing:\n" .. joined)
assert(joined:find("Beta", 1, true), "source title missing:\n" .. joined)

-- Event-driven refresh: simulating an "indexed" re-renders.
events.emit("indexed", { path = org_dir .. "/05.org", n_headlines = 3 })
vim.wait(200, function()
  return false
end)
assert(vim.api.nvim_buf_line_count(bufnr) > 0)

-- Skipped event should NOT trigger a refresh.
local orig_refresh = backlinks.refresh
local refresh_calls = 0
backlinks.refresh = function(...)
  refresh_calls = refresh_calls + 1
  return orig_refresh(...)
end
events.emit("indexed", { path = org_dir .. "/05.org", skipped = "mtime" })
vim.wait(100, function()
  return false
end)
assert(refresh_calls == 0, "skipped event should not trigger refresh")
backlinks.refresh = orig_refresh

-- Keymap presence.
local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
local lhs = {}
for _, m in ipairs(maps) do
  lhs[m.lhs] = true
end
-- Defaults rebound o/v → gs/gv (vim shadow guard).
for _, key in ipairs({ "<CR>", "gs", "gv", "r", "q", "g?" }) do
  local ok = lhs[key] or lhs[key:gsub("<CR>", "\r")]
  assert(ok, "missing keymap: " .. key)
end

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(tmp, "rf")
io.write("backlinks ok\n")
os.exit(0)
