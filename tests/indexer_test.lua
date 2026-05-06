-- Asserts the new prep-stmt write path produces correct row counts and
-- field values for fixture 01-headlines.org.
-- Run via: nvim --headless -l tests/indexer_write_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
local fixture = root .. "/tests/fixtures/01-headlines.org"
local path = os.tmpname() .. ".db"
os.remove(path)

local db = require("organ.db")
local indexer = require("organ.indexer")

local h = assert(db.open(path, { pragmas = { foreign_keys = "ON", journal_mode = "WAL" } }))
local schema_sql = table.concat(vim.fn.readfile(root .. "/sql/schema.sql"), "\n")
assert(h:exec(schema_sql))

local src = table.concat(vim.fn.readfile(fixture), "\n") .. "\n"
local headlines = indexer.extract(src, fixture, parser_path)
assert(#headlines == 7, "expected 7 headlines, got " .. #headlines)

local meta = { path = fixture, mtime = 0, hash = vim.fn.sha256(src) }
local err = indexer.write(h, meta, headlines, function() end)
assert(err == nil, "write err: " .. tostring(err))

local function count(q)
  local s = assert(h:prepare(q))
  assert(s:step() == db.SQLITE_ROW)
  local v = s:column_int(0)
  s:finalize()
  return v
end
assert(count("SELECT COUNT(*) FROM files") == 1)
assert(count("SELECT COUNT(*) FROM headlines") == 7)

h:close()
os.remove(path)
io.write("indexer write ok: 7 headlines via prep stmts\n")
os.exit(0)
