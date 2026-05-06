-- :Org watch start, :Org watch stop, :Org watch status exist and toggle the watcher.
-- Run via: nvim --headless -l tests/orgwatch_commands_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

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
    enabled = false,
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

assert(vim.api.nvim_get_commands({}).Org, ":Org dispatcher not registered")
local cmd = require("organ").cmd
assert(cmd("watch start"), "subcommand `watch_start` not registered on :Org")
assert(cmd("watch stop"), "subcommand `watch_stop` not registered on :Org")
assert(cmd("watch status"), "subcommand `watch_status` not registered on :Org")

local watcher = require("organ.watcher")
assert(#watcher.watched_dirs() == 0, "pre-condition: not watching")

vim.cmd("Org watch start")
assert(watcher.is_watching(org_dir), "OrgWatchStart did not start watcher")

vim.cmd("Org watch stop")
assert(#watcher.watched_dirs() == 0, "OrgWatchStop did not stop")

-- Status command must not throw.
vim.cmd("Org watch status")

vim.fn.delete(tmp, "rf")
io.write("orgwatch commands ok\n")
os.exit(0)
