-- Drop a file inside a symlinked subdir of org_dir; assert it gets indexed.
-- Run via: nvim --headless -l tests/watcher_symlink_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local real = tmp .. "/elsewhere"
vim.fn.mkdir(real, "p")
-- Symlink elsewhere into org_dir/sub
vim.loop.fs_symlink(real, org_dir .. "/sub")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
require("organ.watcher").start({
  enabled = true,
  watch_dirs = {},
  auto_watch_buffers = false,
  delete_grace_ms = 500,
  rescan_interval_ms = 150,
  scan_batch_size = 50,
  ignore = {},
  use_polling = false,
  poll_interval_ms = 5000,
}, org_dir)

-- Wait for first rescan to discover the symlink and add a watcher.
vim.wait(2000, function()
  return require("organ.watcher").is_watching(org_dir .. "/sub")
end, 30)
assert(
  require("organ.watcher").is_watching(org_dir .. "/sub"),
  "rescan should have added an explicit watcher for the symlinked subdir"
)

-- Write through the symlinked path so fs_event sees the same canonical key
-- the watcher uses.
local file = org_dir .. "/sub/a.org"
local fh = assert(io.open(file, "w"))
fh:write("* InsideSym\n")
fh:close()

require("organ").drain_blocking(3000)
vim.wait(2000, function()
  local r = require("organ.query").headlines({ file = file })
  return r[1] and r[1].title == "InsideSym"
end, 50)

local rows = require("organ.query").headlines({ file = file })
assert(rows[1] and rows[1].title == "InsideSym", "expected InsideSym, got " .. vim.inspect(rows))

require("organ.watcher").stop()
vim.fn.delete(tmp, "rf")
io.write("watcher symlink ok\n")
os.exit(0)
