-- auto_watch_buffers: opening an .org buffer in an unwatched dir adds the dir.
-- Run via: nvim --headless -l tests/watcher_buffer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local other = tmp .. "/notes"
vim.fn.mkdir(other, "p")
local file = other .. "/x.org"
local fh = assert(io.open(file, "w"))
fh:write("* X\n")
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = {
    enabled = true,
    watch_dirs = {},
    auto_watch_buffers = true,
    delete_grace_ms = 500,
    rescan_interval_ms = 0,
    scan_batch_size = 50,
    ignore = {},
    use_polling = false,
    poll_interval_ms = 5000,
  },
})

assert(require("organ.watcher").is_watching(other) == false, "pre-condition")

vim.cmd("edit " .. vim.fn.fnameescape(file))

vim.wait(500, function()
  return require("organ.watcher").is_watching(other)
end, 20)

assert(require("organ.watcher").is_watching(other) == true, "BufReadPost did not add parent dir")

require("organ.watcher").stop()
vim.fn.delete(tmp, "rf")
io.write("watcher buffer ok\n")
os.exit(0)
