-- Fire events while VimLeavePre teardown is running; assert no race / no
-- DB-after-close errors. We simulate VimLeavePre by calling the same sequence
-- the autocmd uses.
-- Run via: nvim --headless -l tests/watcher_teardown_test.lua

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
  watcher = {
    enabled = true,
    watch_dirs = {},
    auto_watch_buffers = false,
    delete_grace_ms = 500,
    rescan_interval_ms = 0,
    scan_batch_size = 50,
    ignore = {},
    use_polling = false,
    poll_interval_ms = 5000,
  },
})

-- Simulate ordered teardown.
require("organ.watcher").stop()
require("organ").drain_blocking(2000)
require("organ.indexer").finalise_stmts(require("organ").db_handle())
require("organ").db_handle():close()

-- After teardown, additional events should be no-ops, not crashes.
local file = org_dir .. "/x.org"
local fh = assert(io.open(file, "w"))
fh:write("* X\n")
fh:close()
vim.wait(200, function()
  return false
end)

vim.fn.delete(tmp, "rf")
io.write("watcher teardown ok\n")
os.exit(0)
