-- Indexer extracts CLOCK lines from LOGBOOK drawers into clock_entries.
-- Run via: nvim --headless -l tests/indexer_clock_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

local fixture = vim.fn.resolve(org_dir .. "/clocks.org")
local f = assert(io.open(fixture, "w"))
f:write([=[* Heading A
  :PROPERTIES:
  :ID:       hl-a
  :END:
  :LOGBOOK:
  CLOCK: [2026-04-25 Sat 09:00]--[2026-04-25 Sat 10:00] =>  1:00
  CLOCK: [2026-04-26 Sun 14:30]--[2026-04-26 Sun 15:45] =>  1:15
  :END:

* Heading B
  :PROPERTIES:
  :ID:       hl-b
  :END:
  :LOGBOOK:
  CLOCK: [2026-04-26 Sun 16:00]
  :END:
]=])
f:close()

require("organ").setup({
  db_path = tmp .. "/c.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
require("organ").scan_blocking(org_dir, 5000)

local h = require("organ").db_handle()
local db = require("organ.db")

-- 1. Heading A: 2 closed entries.
do
  local s = h:prepare(
    "SELECT start_ts, end_ts, duration_seconds FROM clock_entries WHERE headline_id = ? ORDER BY start_ts"
  )
  s:bind_text(1, "hl-a")
  local rows = {}
  while s:step() == db.SQLITE_ROW do
    rows[#rows + 1] = { s:column_int(0), s:column_int(1), s:column_int(2) }
  end
  s:finalize()
  assert(#rows == 2, "expected 2 rows for hl-a; got " .. #rows)
  assert(rows[1][3] == 3600, "first duration should be 1h; got " .. rows[1][3])
  assert(rows[2][3] == 75 * 60, "second duration should be 1h15m; got " .. rows[2][3])
end

-- 2. Heading B: 1 active entry (end_ts NULL).
do
  local s =
    h:prepare("SELECT start_ts, end_ts, duration_seconds FROM clock_entries WHERE headline_id = ?")
  s:bind_text(1, "hl-b")
  assert(s:step() == db.SQLITE_ROW)
  local start_ts = s:column_int(0)
  local end_ts_type = s:column_type(1)
  local dur_type = s:column_type(2)
  s:finalize()
  assert(end_ts_type == 5, "end_ts should be NULL; got type " .. end_ts_type)
  assert(dur_type == 5, "duration_seconds should be NULL")
  assert(start_ts > 0)
end

-- 3. Reindex after manual edit removes orphan rows.
do
  local lines = vim.fn.readfile(fixture)
  local out = {}
  for _, l in ipairs(lines) do
    if not l:match("CLOCK: %[2026%-04%-26 Sun 16:00%]") then
      out[#out + 1] = l
    end
  end
  vim.fn.writefile(out, fixture)
  require("organ").setup({
    db_path = tmp .. "/c.db",
    org_dir = org_dir,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    mtime_skip = false,
    hash_skip = false,
    watcher = { enabled = false },
  })
  require("organ").scan_blocking(org_dir, 5000)

  local h2 = require("organ").db_handle()
  local s = h2:prepare("SELECT COUNT(*) FROM clock_entries WHERE headline_id = ?")
  s:bind_text(1, "hl-b")
  assert(s:step() == db.SQLITE_ROW)
  local count = s:column_int(0)
  s:finalize()
  assert(count == 0, "hl-b should have 0 rows after reindex; got " .. count)
end

vim.fn.delete(tmp, "rf")
io.write("indexer clock ok\n")
os.exit(0)
