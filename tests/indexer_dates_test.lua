-- Asserts the indexer populates scheduled_date / deadline_date / closed_date
-- correctly for fixture 04-dates.org.
-- Run via: nvim --headless -l tests/indexer_dates_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
local fixture = root .. "/tests/fixtures/04-dates.org"
local path = os.tmpname() .. ".db"
os.remove(path)

local db = require("organ.db")
local indexer = require("organ.indexer")

local h = assert(db.open(path, { pragmas = { foreign_keys = "ON", journal_mode = "WAL" } }))
local schema_sql = table.concat(vim.fn.readfile(root .. "/sql/schema.sql"), "\n")
assert(h:exec(schema_sql))

local src = table.concat(vim.fn.readfile(fixture), "\n") .. "\n"
local headlines = indexer.extract(src, fixture, parser_path)

-- Expected normalized dates, by headline title.
local expect = {
  ["Plain date"] = {
    scheduled_date = "2026-05-01",
    deadline_date = nil,
    closed_date = nil,
  },
  ["Date with time"] = {
    scheduled_date = "2026-05-01T14:00",
    deadline_date = nil,
    closed_date = nil,
  },
  ["Time range (take start)"] = {
    scheduled_date = "2026-05-01T14:00",
    deadline_date = nil,
    closed_date = nil,
  },
  ["Repeater"] = {
    scheduled_date = nil,
    deadline_date = "2026-05-01",
    closed_date = nil,
  },
  ["Inactive closed"] = {
    scheduled_date = nil,
    deadline_date = nil,
    closed_date = "2026-04-30T09:15",
  },
  ["Malformed"] = {
    scheduled_date = nil,
    deadline_date = nil,
    closed_date = nil,
  },
  ["All three fields"] = {
    scheduled_date = "2026-05-01",
    deadline_date = "2026-05-03T10:00",
    closed_date = "2026-04-29",
  },
}

local by_title = {}
for _, hl in ipairs(headlines) do
  by_title[hl.title] = hl
end

for title, exp in pairs(expect) do
  local hl = by_title[title]
  assert(hl, "missing headline: " .. title)
  for _, field in ipairs({ "scheduled_date", "deadline_date", "closed_date" }) do
    local got = hl[field]
    if exp[field] ~= got then
      io.stderr:write(
        string.format(
          "%s.%s: got %s, expected %s\n",
          title,
          field,
          tostring(got),
          tostring(exp[field])
        )
      )
      h:close()
      os.remove(path)
      os.exit(1)
    end
  end
end

-- Also verify write path persists the values.
local meta = { path = fixture, mtime = 0, hash = vim.fn.sha256(src) }
local err = indexer.write(h, meta, headlines, function() end)
assert(err == nil, tostring(err))

local s = assert(
  h:prepare("SELECT scheduled_date, deadline_date, closed_date FROM headlines WHERE title = ?")
)
s:bind_text(1, "Date with time")
assert(s:step() == db.SQLITE_ROW)
assert(s:column_text(0) == "2026-05-01T14:00")
s:finalize()

h:close()
os.remove(path)
io.write("indexer dates ok\n")
os.exit(0)
