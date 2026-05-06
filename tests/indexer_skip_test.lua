-- Assert indexer.should_skip returns 'mtime' when stored mtime matches and
-- 'hash' when content hash matches, else nil.
-- Run via: nvim --headless -l tests/indexer_skip_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local db = require("organ.db")
local indexer = require("organ.indexer")

local path = os.tmpname() .. ".db"
os.remove(path)
local h = assert(db.open(path, { pragmas = { foreign_keys = "ON" } }))
local schema_sql = table.concat(vim.fn.readfile(root .. "/sql/schema.sql"), "\n")
assert(h:exec(schema_sql))

-- Nothing stored yet → no skip.
local r = indexer.should_skip(h, "/nowhere.org", 42, "abc")
assert(r == nil, "fresh DB skip = " .. tostring(r))

-- Store mtime=42, hash="abc", extractor_version=current (so the
-- mtime/hash skip path is reachable — a NULL or stale version
-- would correctly invalidate, which is the new fast-fail behavior
-- and is asserted in the dedicated test below).
local current_version = indexer._extractor_version()
local ins = assert(
  h:prepare(
    "INSERT INTO files(path, mtime, hash, indexed, extractor_version) " .. "VALUES (?, ?, ?, 0, ?)"
  )
)
ins:bind_text(1, "/nowhere.org")
ins:bind_int(2, 42)
ins:bind_text(3, "abc")
ins:bind_text(4, current_version)
assert(ins:step() == db.SQLITE_DONE)
ins:finalize()

-- Same mtime → mtime skip.
assert(indexer.should_skip(h, "/nowhere.org", 42, "anything") == "mtime")
-- Different mtime, same hash → hash skip.
assert(indexer.should_skip(h, "/nowhere.org", 99, "abc") == "hash")
-- Different both → no skip.
assert(indexer.should_skip(h, "/nowhere.org", 99, "xyz") == nil)

-- Stale extractor_version invalidates the skip path even when mtime
-- AND hash both match — this is the auto-rescan-on-parser-change
-- behavior: when our extract pipeline updates underneath the user,
-- their cached rows reroll transparently on the next scan.
local stale =
  h:prepare("UPDATE files SET extractor_version = 'previous-version-stamp' WHERE path = ?")
stale:bind_text(1, "/nowhere.org")
assert(stale:step() == db.SQLITE_DONE)
stale:finalize()
assert(
  indexer.should_skip(h, "/nowhere.org", 42, "abc") == nil,
  "stale extractor_version should force re-extract"
)

h:close()
os.remove(path)
io.write("indexer skip ok\n")
os.exit(0)
