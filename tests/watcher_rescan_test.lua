-- Simulate a missed fs_event by stopping the handle, mutating the file,
-- and asserting the next periodic rescan picks it up.
-- Run via: nvim --headless -l tests/watcher_rescan_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local file = org_dir .. "/a.org"

local fh = assert(io.open(file, "w"))
fh:write("* Alpha\n")
fh:close()

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

require("organ").drain_blocking(3000)
vim.wait(2000, function()
  local r = require("organ.query").headlines({ file = file })
  return r[1] and r[1].title == "Alpha"
end, 30)

-- Pause the watcher to simulate missed events.
for _, st in pairs(require("organ.watcher")._dirs) do
  pcall(function()
    st.handle:stop()
  end)
end

-- Mutate while watcher is paused.
fh = assert(io.open(file, "w"))
fh:write("* Beta\n")
fh:close()
-- Bump mtime to ensure should_skip sees the change.
local tm = os.time() + 5
vim.loop.fs_utime(file, tm, tm)

-- Wait for at least one rescan tick + drain.
vim.wait(500, function()
  return false
end)
require("organ").drain_blocking(3000)

local rows = require("organ.query").headlines({ file = file })
assert(rows[1] and rows[1].title == "Beta", "expected Beta after rescan, got " .. vim.inspect(rows))

require("organ.watcher").stop()
vim.fn.delete(tmp, "rf")
io.write("watcher rescan ok\n")
os.exit(0)
