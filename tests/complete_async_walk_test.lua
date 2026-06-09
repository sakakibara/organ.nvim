-- The `[[file:` completion must NOT block the insert keystroke on a
-- recursive filesystem walk. The walk runs asynchronously (walk_async);
-- the picker is populated from its on_done, after the event loop ticks,
-- not synchronously inside maybe_open.
-- Run via: nvim --headless -l tests/complete_async_walk_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.opt.virtualedit = "onemore"

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/sub", "p")
for i = 1, 5 do
  vim.fn.writefile({ "x" }, tmp .. "/note" .. i .. ".txt")
end
vim.fn.writefile({ "y" }, tmp .. "/sub/deep.txt")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
})

-- walk_files / the async walk target getcwd().
vim.fn.chdir(tmp)

local complete = require("organ.complete")
local stub = require("organ.find.backend")._test_stub

local b = vim.api.nvim_create_buf(false, true)
local line = "[[file:note"
vim.api.nvim_buf_set_lines(b, 0, -1, false, { line })
vim.api.nvim_set_current_buf(b)
vim.api.nvim_win_set_cursor(0, { 1, #line })

stub.last = nil
complete.maybe_open(b)

-- Non-blocking: the keystroke must return without the picker having been
-- populated synchronously by the recursive walk.
assert(
  stub.last == nil,
  "file completion blocked the keystroke: picker fired synchronously inside maybe_open"
)

-- The async walk populates the picker after the event loop runs.
assert(
  vim.wait(3000, function()
    return stub.last ~= nil
  end, 10),
  "async walk never populated the picker"
)

local items = stub.last.items
assert(#items > 0, "expected file items from the async walk, got 0")
local found = false
for _, it in ipairs(items) do
  if (it.display or ""):find("note", 1, true) then
    found = true
    break
  end
end
assert(found, "expected matching note* files in the async walk results")

vim.fn.delete(tmp, "rf")
io.write("complete async walk ok\n")
os.exit(0)
