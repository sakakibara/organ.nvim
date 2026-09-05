-- Org files with a repeated tag / property key / clock start / ROAM alias
-- must index like Emacs does, not abort the file's whole write.
-- Run via: nvim --headless -l tests/indexer_duplicate_keys_test.lua

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

local indexer = require("organ.indexer")
local query = require("organ.query")
local db = require("organ.db")
local h = require("organ.runtime").db()

local n = 0
local function write_org(src)
  n = n + 1
  local path = string.format("%s/dup%d.org", tmp, n)
  local f = assert(io.open(path, "w"))
  f:write(src)
  f:close()
  indexer.index_file_sync(path)
  return require("organ.path").canonical(path) or path
end

local function first_row(path, opts)
  local rows = query.headlines(vim.tbl_extend("force", {
    file = path,
    order_by = { { "line_start", "asc" } },
  }, opts or {}))
  return rows, rows[1]
end

-- `:work:work:` -- Emacs `org-get-tags` returns ("work").
do
  local path = write_org("* Alpha :work:work:\n* Beta\n")
  local rows, alpha = first_row(path)
  assert(#rows == 2, "duplicate tag dropped the file: " .. #rows .. " rows")
  assert(#alpha.tags == 1 and alpha.tags[1] == "work", "tags = " .. vim.inspect(alpha.tags))
end

-- Two `:FOO:` lines in one drawer -- Emacs `org-entry-get` (and the
-- property matcher it backs) resolves to the LAST value.
do
  local path = write_org("* Alpha\n:PROPERTIES:\n:FOO: a\n:FOO: b\n:END:\n* Beta\n")
  local rows, alpha = first_row(path, { include_properties = true })
  assert(#rows == 2, "duplicate property dropped the file: " .. #rows .. " rows")
  assert(alpha.properties.FOO == "b", "FOO = " .. tostring(alpha.properties.FOO))
end

-- Two CLOCK lines sharing a start -- Emacs `org-clock-sum` counts both
-- (1:00 + 2:00 = 180 minutes).
do
  local path = write_org(
    "* Alpha\n:LOGBOOK:\n"
      .. "CLOCK: [2026-05-04 Mon 09:00]--[2026-05-04 Mon 10:00] =>  1:00\n"
      .. "CLOCK: [2026-05-04 Mon 09:00]--[2026-05-04 Mon 11:00] =>  2:00\n"
      .. ":END:\n* Beta\n"
  )
  local rows, alpha = first_row(path)
  assert(#rows == 2, "duplicate clock start dropped the file: " .. #rows .. " rows")
  local clocks = query.clock_entries({ headline_id = alpha.id, group_by = "headline" })
  assert(#clocks == 1, "expected one grouped clock row, got " .. #clocks)
  assert(clocks[1].total_seconds == 10800, "total = " .. tostring(clocks[1].total_seconds))
end

-- A repeated ROAM alias is one alias.
do
  local path =
    write_org('* Alpha\n:PROPERTIES:\n:ID: al-1\n:ROAM_ALIASES: "Same" "Same"\n:END:\n* Beta\n')
  local rows = first_row(path)
  assert(#rows == 2, "duplicate alias dropped the file: " .. #rows .. " rows")
  local s = assert(h:prepare("SELECT alias FROM aliases WHERE headline_id = 'al-1'"))
  local aliases = {}
  while s:step() == db.SQLITE_ROW do
    aliases[#aliases + 1] = s:column_text(0)
  end
  s:finalize()
  assert(#aliases == 1 and aliases[1] == "Same", "aliases = " .. vim.inspect(aliases))
end

-- Moving an `:ID:` headline to another file: the destination write must
-- claim the id rather than abort against the source file's stale row.
do
  local src = tmp .. "/move_src.org"
  local dst = tmp .. "/move_dst.org"
  local body = "* Movable\n:PROPERTIES:\n:ID: moved-1\n:END:\n"
  local f = assert(io.open(src, "w"))
  f:write(body)
  f:close()
  indexer.index_file_sync(src)

  f = assert(io.open(dst, "w"))
  f:write(body)
  f:close()
  indexer.index_file_sync(dst)

  local canon_dst = require("organ.path").canonical(dst) or dst
  local row = query.get_by_id("moved-1")
  assert(row, "id moved-1 resolves to nothing after the move")
  assert(row.file_path == canon_dst, "id resolves to " .. tostring(row.file_path))
  assert(#query.headlines({ file = canon_dst }) == 1, "destination file has no rows")
end

vim.fn.delete(tmp, "rf")
io.write("indexer duplicate keys ok\n")
os.exit(0)
