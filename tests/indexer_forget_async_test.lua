-- indexer.forget_async enqueues a delete op; once drained, file rows are gone.
-- Run via: nvim --headless -l tests/indexer_forget_async_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/x.org"
vim.fn.system({ "cp", root .. "/tests/fixtures/05-links.org", fixture })

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
require("organ").scan_blocking(org_dir, 5000)

local db = require("organ.db")
local function count(q)
  local s = assert(require("organ").db_handle():prepare(q))
  assert(s:step() == db.SQLITE_ROW)
  local v = s:column_int(0)
  s:finalize()
  return v
end

local canon_fixture = require("organ.path").canonical(fixture)

assert(count("SELECT COUNT(*) FROM files WHERE path = '" .. canon_fixture .. "'") == 1)

require("organ.indexer").forget_async(canon_fixture)
require("organ").drain_blocking(5000)

assert(count("SELECT COUNT(*) FROM files WHERE path = '" .. canon_fixture .. "'") == 0)

vim.fn.delete(tmp, "rf")
io.write("forget_async ok\n")
os.exit(0)
