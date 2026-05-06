-- With use_polling = true, file changes are detected even when fs_event handles
-- are forcibly closed.
-- Run via: nvim --headless -l tests/watcher_polling_test.lua

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
  rescan_interval_ms = 0, -- disable rescan
  scan_batch_size = 50,
  ignore = {},
  use_polling = true,
  poll_interval_ms = 100,
}, org_dir)

require("organ").drain_blocking(3000)
vim.wait(2000, function()
  local r = require("organ.query").headlines({ file = file })
  return r[1] and r[1].title == "Alpha"
end, 30)

-- Force-close all fs_event handles. Polling must still detect changes.
for _, st in pairs(require("organ.watcher")._dirs) do
  pcall(function()
    st.handle:stop()
  end)
  pcall(function()
    st.handle:close()
  end)
end

fh = assert(io.open(file, "w"))
fh:write("* Beta\n")
fh:close()
local tm = os.time() + 5
vim.loop.fs_utime(file, tm, tm)

vim.wait(2000, function()
  local r = require("organ.query").headlines({ file = file })
  return r[1] and r[1].title == "Beta"
end, 50)
require("organ").drain_blocking(3000)

local rows = require("organ.query").headlines({ file = file })
assert(rows[1] and rows[1].title == "Beta", "expected Beta via polling, got " .. vim.inspect(rows))

require("organ.watcher").stop()
vim.fn.delete(tmp, "rf")
io.write("watcher polling ok\n")
os.exit(0)
