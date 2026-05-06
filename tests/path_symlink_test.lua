-- End-to-end: a fixture indexed via one path form is queryable via the
-- equivalent canonical-different form, returning the same single row.
-- Specifically tests the macOS /var/folders/... ↔ /private/var/folders/...
-- collapse that the 3-candidate workaround in :Org backlinks used to handle.
-- Run via: nvim --headless -l tests/path_symlink_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local file = org_dir .. "/a.org"
local fh = assert(io.open(file, "w"))
fh:write("* Alpha\n")
fh:close()

require("organ").scan_blocking(org_dir, 5000)

-- Query via the path as written to disk.
local rows_raw = require("organ.query").headlines({ file = file })
assert(#rows_raw == 1, "via raw path: expected 1 row, got " .. #rows_raw)
assert(rows_raw[1].title == "Alpha")

-- Compute the canonical form (same as what canonical() produces).
local canonical_file = vim.loop.fs_realpath(file) or file
-- On macOS /var/... resolves to /private/var/...; the form differs from `file`.
-- On Linux they often match. Either way, querying via the canonical form must
-- still return the single row.
local rows_canon = require("organ.query").headlines({ file = canonical_file })
assert(#rows_canon == 1, "via canonical path: expected 1 row, got " .. #rows_canon)
assert(
  rows_canon[1].id == rows_raw[1].id,
  "raw and canonical queries should hit the SAME row, got "
    .. tostring(rows_raw[1].id)
    .. " vs "
    .. tostring(rows_canon[1].id)
)

-- And via a deliberately mangled form: strip /private/ prefix on macOS, or
-- prepend /private/ if running on a non-private path. This exercises the
-- canonical helper's symlink-resolution.
local mangled
if file:match("^/private/") then
  mangled = file:gsub("^/private", "")
else
  mangled = "/private" .. file
end
local rows_mangled = require("organ.query").headlines({ file = mangled })
-- Mangled form may or may not exist on disk; if it doesn't resolve via
-- fs_realpath, the canonical fallback returns the abs form which won't match
-- the indexed (resolved) row. So we only assert when the mangled form IS a
-- valid alternate path.
if vim.loop.fs_realpath(mangled) then
  assert(#rows_mangled == 1, "via mangled path: expected 1 row, got " .. #rows_mangled)
  assert(rows_mangled[1].id == rows_raw[1].id, "mangled query should hit the SAME row")
end

-- DB has exactly one files row.
local db = require("organ.db")
local h = require("organ").db_handle()
local s = assert(h:prepare("SELECT COUNT(*) FROM files"))
assert(s:step() == db.SQLITE_ROW)
local n = s:column_int(0)
s:finalize()
assert(n == 1, "expected 1 files row, got " .. n)

vim.fn.delete(tmp, "rf")
io.write("path symlink ok\n")
os.exit(0)
