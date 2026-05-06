-- indexer.forget removes the file row and cascades to headlines/tags/properties/links.
-- Run via: nvim --headless -l tests/indexer_forget_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
local fixture = root .. "/tests/fixtures/05-links.org"
local path = os.tmpname() .. ".db"
os.remove(path)

local db = require("organ.db")
local indexer = require("organ.indexer")
local events = require("organ.events")

local h = assert(db.open(path, { pragmas = { foreign_keys = "ON", journal_mode = "WAL" } }))
local schema_sql = table.concat(vim.fn.readfile(root .. "/sql/schema.sql"), "\n")
assert(h:exec(schema_sql))

local src = table.concat(vim.fn.readfile(fixture), "\n") .. "\n"
local headlines = indexer.extract(src, fixture, parser_path)
local meta = { path = fixture, mtime = 0, hash = vim.fn.sha256(src) }
assert(indexer.write(h, meta, headlines, function() end) == nil)

local function count(q)
  local s = assert(h:prepare(q))
  assert(s:step() == db.SQLITE_ROW)
  local v = s:column_int(0)
  s:finalize()
  return v
end

assert(count("SELECT COUNT(*) FROM files") == 1)
assert(count("SELECT COUNT(*) FROM headlines") > 0)
assert(count("SELECT COUNT(*) FROM tags") >= 0)
assert(count("SELECT COUNT(*) FROM properties") > 0)
assert(count("SELECT COUNT(*) FROM links") > 0)

local seen
events.on("unindexed", function(p)
  seen = p
end)

assert(indexer.forget(h, fixture) == nil)

assert(count("SELECT COUNT(*) FROM files") == 0)
assert(count("SELECT COUNT(*) FROM headlines") == 0)
assert(count("SELECT COUNT(*) FROM tags") == 0)
assert(count("SELECT COUNT(*) FROM properties") == 0)
assert(count("SELECT COUNT(*) FROM links") == 0)
assert(seen and seen.path == fixture, "unindexed event payload")

events.clear("unindexed")
indexer.finalise_stmts(h)
h:close()
os.remove(path)
io.write("indexer forget ok\n")
os.exit(0)
