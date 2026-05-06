-- :checkhealth organ reports watcher state.
-- Run via: nvim --headless -l tests/watcher_health_test.lua

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

local health = require("organ.health")
assert(type(health.check) == "function", "health.check missing")

-- Capture the report. Neovim's vim.health functions are global side effects,
-- so we just call check and ensure it doesn't error.
local ok, err = pcall(health.check)
assert(ok, "health.check error: " .. tostring(err))

-- A simple structural assertion: the watcher state we expose should be valid.
local w = require("organ.watcher")
assert(type(w.watched_dirs) == "function")
assert(#w.watched_dirs() >= 1, "expected at least 1 watched dir (org_dir)")

require("organ.watcher").stop()
vim.fn.delete(tmp, "rf")
io.write("watcher health ok\n")
os.exit(0)
