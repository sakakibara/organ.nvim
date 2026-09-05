-- The post-scan orphan prune must target the directory that was walked,
-- and match it as a literal prefix rather than a LIKE pattern.
-- Run via: nvim --headless -l tests/scan_prune_root_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local base = vim.fn.tempname()
vim.fn.mkdir(base, "p")
base = vim.loop.fs_realpath(base)
vim.fn.mkdir(base .. "/main", "p")
vim.fn.mkdir(base .. "/x_y", "p")
vim.fn.mkdir(base .. "/xzy", "p")

local function write_org(path, src)
  local f = assert(io.open(path, "w"))
  f:write(src)
  f:close()
end

write_org(base .. "/main/a.org", "* Alpha\n")
write_org(base .. "/main/b.org", "* Beta\n")
write_org(base .. "/x_y/c.org", "* Gamma\n")
write_org(base .. "/xzy/d.org", "* Delta\n")

local organ = require("organ")
organ.setup({
  org_dir = base .. "/main",
  db_path = base .. "/organ.db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local query = require("organ.query")

local function indexed(path)
  return #query.headlines({ file = path }) > 0
end

local function scan(dir)
  assert(organ.scan_blocking(dir, 20000), "scan_blocking timed out for " .. dir)
end

scan(base .. "/xzy")
assert(indexed(base .. "/xzy/d.org"), "d.org not indexed")

-- `_` is a LIKE wildcard: scanning x_y must not prune xzy's rows.
scan(base .. "/x_y")
assert(indexed(base .. "/x_y/c.org"), "c.org not indexed")
assert(indexed(base .. "/xzy/d.org"), "scanning x_y pruned xzy (LIKE wildcard)")

-- Scanning any directory other than org_dir must leave org_dir alone.
scan(base .. "/main")
assert(indexed(base .. "/main/a.org"), "a.org not indexed")
assert(indexed(base .. "/main/b.org"), "b.org not indexed")
scan(base .. "/xzy")
assert(indexed(base .. "/main/a.org"), "scanning xzy pruned org_dir rows")
assert(indexed(base .. "/main/b.org"), "scanning xzy pruned org_dir rows")

-- A file deleted from the walked directory is still pruned.
assert(vim.fn.delete(base .. "/main/b.org") == 0, "could not delete b.org")
scan(base .. "/main")
assert(indexed(base .. "/main/a.org"), "a.org pruned by mistake")
assert(not indexed(base .. "/main/b.org"), "deleted file kept its headlines")

vim.fn.delete(base, "rf")
io.write("scan prune root ok\n")
os.exit(0)
