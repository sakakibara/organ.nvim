-- The mtime fast path must never mark a row current for content that is
-- not on disk: an unsaved buffer's text, or a save landing in the same
-- wall-clock second as the previous index.
-- Run via: nvim --headless -l tests/indexer_freshness_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  org_dir = tmp,
  db_path = tmp .. "/organ.db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local queue = require("organ.queue")
local query = require("organ.query")
local indexer = require("organ.indexer")
local db = require("organ.db")

local function write_file(path, src)
  local f = assert(io.open(path, "w"))
  f:write(src)
  f:close()
end

local function index(path)
  queue.enqueue_background(path)
  assert(queue.drain_blocking(20000), "queue did not drain")
end

local function titles(path)
  local out = {}
  for _, r in ipairs(query.headlines({ file = path, order_by = { { "line_start", "asc" } } })) do
    out[#out + 1] = r.title
  end
  return table.concat(out, ",")
end

local function stored_mtime(path)
  local h = require("organ.runtime").db()
  local s = assert(h:prepare("SELECT mtime FROM files WHERE path = ?"))
  s:bind_text(1, require("organ.path").canonical(path) or path)
  local m
  if s:step() == db.SQLITE_ROW then
    m = s:column_int64(0)
  end
  s:finalize()
  return m
end

-- Indexing a dirty buffer stores buffer text, so the row must not be
-- stamped with the disk mtime -- otherwise the fast path refuses to
-- re-read the file that content never came from.
do
  local path = tmp .. "/dirty.org"
  write_file(path, "* Alpha\n* Beta\n")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* Alpha", "* Beta", "* TODO scratch idea" })

  index(path)
  assert(
    stored_mtime(path) == 0,
    "buffer-sourced row stamped mtime " .. tostring(stored_mtime(path))
  )

  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  vim.cmd("bwipeout!")
  index(path)
  assert(titles(path) == "Alpha,Beta", "unsaved text survived a reindex: " .. titles(path))
end

-- A rewrite inside the same second as the previous index must still be
-- picked up; the one-second mtime granularity cannot prove staleness.
do
  local path = tmp .. "/samesecond.org"
  write_file(path, "* V1a\n* V1b\n")
  index(path)
  write_file(path, "* V2a\n* V2b\n* V2c\n")
  index(path)
  assert(titles(path) == "V2a,V2b,V2c", "same-second rewrite skipped: " .. titles(path))
end

-- should_skip must not trust an mtime equal to the current second.
do
  local h = require("organ.runtime").db()
  local now = os.time()
  local ins = assert(
    h:prepare(
      "INSERT OR REPLACE INTO files(path, mtime, hash, indexed, extractor_version) "
        .. "VALUES (?, ?, ?, 0, ?)"
    )
  )
  ins:bind_text(1, "/nowhere-freshness.org")
  ins:bind_int64(2, now)
  ins:bind_text(3, "abc")
  ins:bind_text(4, indexer._extractor_version())
  assert(ins:step() == db.SQLITE_DONE)
  ins:finalize()

  assert(
    indexer.should_skip(h, "/nowhere-freshness.org", now, nil) == nil,
    "mtime in the current second must not skip"
  )
  assert(
    indexer.should_skip(h, "/nowhere-freshness.org", now - 5, "abc") == "hash",
    "hash skip still applies"
  )
end

vim.fn.delete(tmp, "rf")
io.write("indexer freshness ok\n")
os.exit(0)
