-- End-to-end: drop a fresh .org file into a watched dir; assert it gets indexed.
-- Modify it; assert it gets re-indexed. Delete it; assert it gets unindexed
-- after the grace period.
-- Run via: nvim --headless -l tests/watcher_event_test.lua

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

-- Start the watcher manually with explicit options for this test.
require("organ.watcher").start({
  enabled = true,
  watch_dirs = {},
  auto_watch_buffers = false,
  delete_grace_ms = 200,
  rescan_interval_ms = 0,
  scan_batch_size = 50,
  ignore = {},
  use_polling = false,
  poll_interval_ms = 5000,
}, org_dir)

local file = org_dir .. "/a.org"

-- Write
local fh = assert(io.open(file, "w"))
fh:write("* Alpha\n  Body line.\n")
fh:close()

require("organ").drain_blocking(3000)
vim.wait(2000, function()
  return require("organ.query").headlines({ file = file })[1] ~= nil
end, 50)

local rows = require("organ.query").headlines({ file = file })
assert(
  rows[1] and rows[1].title == "Alpha",
  "expected Alpha after write, got " .. vim.inspect(rows)
)

-- Modify
fh = assert(io.open(file, "w"))
fh:write("* Beta\n  Different body.\n")
fh:close()
-- Bump mtime to force should_skip to re-index even if the original mtime is in
-- the same second.
local tm = os.time() + 5
vim.loop.fs_utime(file, tm, tm)

require("organ").drain_blocking(3000)
vim.wait(2000, function()
  local r = require("organ.query").headlines({ file = file })
  return r[1] and r[1].title == "Beta"
end, 50)

local rows2 = require("organ.query").headlines({ file = file })
assert(
  rows2[1] and rows2[1].title == "Beta",
  "expected Beta after modify, got " .. vim.inspect(rows2)
)

-- Delete
os.remove(file)

require("organ").drain_blocking(3000)
vim.wait(2000, function()
  return #require("organ.query").headlines({ file = file }) == 0
end, 50)

assert(
  #require("organ.query").headlines({ file = file }) == 0,
  "expected no rows after delete + grace"
)

require("organ.watcher").stop()
vim.fn.delete(tmp, "rf")
io.write("watcher event ok\n")
os.exit(0)
