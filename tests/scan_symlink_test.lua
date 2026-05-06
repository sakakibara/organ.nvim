-- :Org scan now follows symlinked subdirs (regression test for the gap
-- surfaced by the path canonicalisation work).
-- Run via: nvim --headless -l tests/scan_symlink_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local real = tmp .. "/elsewhere"
vim.fn.mkdir(real, "p")
-- Symlink elsewhere into org_dir/sub.
vim.loop.fs_symlink(real, org_dir .. "/sub")

-- Drop a file inside the symlinked dir.
local file_via_link = org_dir .. "/sub/a.org"
local fh = assert(io.open(file_via_link, "w"))
fh:write("* InsideSymScan\n")
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false }, -- isolate from watcher; this tests scan only
})

require("organ").scan_blocking(org_dir, 5000)

-- Query via the symlink path; canonical form will collapse to the realpath.
local rows = require("organ.query").headlines({ file = file_via_link })
assert(#rows == 1, "expected 1 row from symlinked-subdir scan, got " .. #rows)
assert(rows[1].title == "InsideSymScan", "expected InsideSymScan, got " .. tostring(rows[1].title))

vim.fn.delete(tmp, "rf")
io.write("scan symlink ok\n")
os.exit(0)
