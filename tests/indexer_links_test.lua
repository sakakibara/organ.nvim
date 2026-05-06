-- Index fixture 05 and assert the links table is correctly populated.
-- Run via: nvim --headless -l tests/indexer_links_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
local fixture = root .. "/tests/fixtures/05-links.org"
local path = os.tmpname() .. ".db"
os.remove(path)

local db = require("organ.db")
local indexer = require("organ.indexer")

local h = assert(db.open(path, { pragmas = { foreign_keys = "ON", journal_mode = "WAL" } }))
local schema_sql = table.concat(vim.fn.readfile(root .. "/sql/schema.sql"), "\n")
assert(h:exec(schema_sql))

local src = table.concat(vim.fn.readfile(fixture), "\n") .. "\n"
local headlines = indexer.extract(src, fixture, parser_path)

-- Every headline produced by extract() now carries a `links` array.
local links_by_title = {}
for _, hl in ipairs(headlines) do
  links_by_title[hl.title] = hl.links or {}
end

-- Alpha: two outbound (id:beta-id with desc, https://example.com without)
local a = links_by_title["Alpha"]
assert(a and #a == 2, "Alpha links = " .. tostring(a and #a))
assert(a[1].target == "id:beta-id" and a[1].description == "Beta")
assert(a[2].target == "https://example.com" and a[2].description == nil)

-- Beta: three outbound
local b = links_by_title["Beta"]
assert(b and #b == 3, "Beta links = " .. tostring(b and #b))

-- Gamma: no links
local g = links_by_title["Gamma Section"]
assert(g and #g == 0, "Gamma links = " .. tostring(g and #g))

-- write_body must persist the link rows.
local meta = { path = fixture, mtime = 0, hash = vim.fn.sha256(src) }
local err = indexer.write(h, meta, headlines, function() end)
assert(err == nil, tostring(err))

local function count(q, ...)
  local s = assert(h:prepare(q))
  for i = 1, select("#", ...) do
    s:bind_text(i, (select(i, ...)))
  end
  assert(s:step() == db.SQLITE_ROW)
  local v = s:column_int(0)
  s:finalize()
  return v
end

assert(count("SELECT COUNT(*) FROM links") == 5, "total links")
assert(count("SELECT COUNT(*) FROM links WHERE target_type='id'") == 2)
assert(count("SELECT COUNT(*) FROM links WHERE target_type='https'") == 1)
assert(count("SELECT COUNT(*) FROM links WHERE target_type='file'") == 1)
-- "*Gamma Section" → headline-search with stripped '*'. Or a bare URL via
-- resolve falls back to the scheme. For this fixture "*Gamma Section" is
-- classified as 'headline'.
assert(count("SELECT COUNT(*) FROM links WHERE target_type='headline'") == 1)

-- Description preserved on the "Beta" link.
local s = assert(h:prepare("SELECT description FROM links WHERE target = 'beta-id'"))
assert(s:step() == db.SQLITE_ROW)
assert(s:column_text(0) == "Beta")
s:finalize()

-- Cascade delete on re-index.
local err2 = indexer.write(h, meta, headlines, function() end)
assert(err2 == nil)
assert(
  count("SELECT COUNT(*) FROM links") == 5,
  "re-index should keep same row count, not duplicate"
)

h:close()
os.remove(path)
io.write("indexer links ok\n")
os.exit(0)
