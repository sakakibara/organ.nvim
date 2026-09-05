-- Indexed paths are symlink-resolved, so the post-scan orphan prune has
-- to resolve the scanned root too; otherwise a file deleted from a
-- symlinked org dir keeps its headlines forever.
-- Run via: nvim --headless -l tests/scan_symlink_prune_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local base = vim.fn.tempname()
vim.fn.mkdir(base, "p")
base = vim.loop.fs_realpath(base)
vim.fn.mkdir(base .. "/real", "p")
assert(vim.loop.fs_symlink(base .. "/real", base .. "/link"), "symlink failed")

local org_dir = base .. "/link"

local function write_org(name, src)
  local f = assert(io.open(org_dir .. "/" .. name, "w"))
  f:write(src)
  f:close()
end

write_org("a.org", "* Alpha\n")
write_org("b.org", "* Beta\n")

local organ = require("organ")
organ.setup({
  org_dir = org_dir,
  db_path = base .. "/organ.db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local query = require("organ.query")
assert(organ.scan_blocking(org_dir, 20000), "first scan timed out")
assert(#query.headlines({}) == 2, "expected 2 headlines after the first scan")

os.remove(base .. "/real/b.org")
assert(organ.scan_blocking(org_dir, 20000), "second scan timed out")

local titles = {}
for _, r in ipairs(query.headlines({})) do
  titles[#titles + 1] = r.title
end
assert(#titles == 1 and titles[1] == "Alpha", "prune left " .. table.concat(titles, ","))

vim.fn.delete(base, "rf")
io.write("scan symlink prune ok\n")
os.exit(0)
