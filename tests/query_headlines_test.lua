-- Exercises query.headlines against the 4 fixtures indexed via setup().
-- Run via: nvim --headless -l tests/query_headlines_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db_path = tmp .. "/q.db"
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
for _, name in ipairs({ "01-headlines.org", "02-planning.org", "03-properties.org", "04-dates.org" }) do
  vim.fn.system({ "cp", root .. "/tests/fixtures/" .. name, org_dir .. "/" .. name })
end

local organ = require("organ")
organ.setup({
  db_path = db_path,
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
})
organ.scan_blocking(org_dir, 5000)

local query = require("organ.query")

-- No filters: returns every headline across the four fixtures.
do
  local rows = query.headlines({})
  assert(#rows >= 20, "expected >=20 rows, got " .. #rows)
end

-- todo filter (shorthand array)
do
  local rows = query.headlines({ todo = { "TODO" }, order_by = { { "title", "asc" } } })
  for _, r in ipairs(rows) do
    assert(r.todo_state == "TODO", "got todo_state=" .. tostring(r.todo_state))
  end
  assert(#rows > 0)
end

-- exclude done
do
  local rows = query.headlines({ todo = { exclude = { "DONE", "CANCELLED" } } })
  for _, r in ipairs(rows) do
    assert(r.todo_state ~= "DONE" and r.todo_state ~= "CANCELLED")
  end
end

-- priority filter
do
  local rows = query.headlines({ priority = { "A" } })
  for _, r in ipairs(rows) do
    assert(r.priority == "A", "got priority=" .. tostring(r.priority))
  end
  assert(#rows >= 1)
end

-- scheduled window
do
  local rows = query.headlines({ scheduled = { from = "2026-04-25", to = "2026-04-25" } })
  for _, r in ipairs(rows) do
    assert(
      r.scheduled_date and r.scheduled_date:sub(1, 10) == "2026-04-25",
      "scheduled_date=" .. tostring(r.scheduled_date)
    )
  end
  assert(#rows >= 1)
end

-- tag any (shorthand)
do
  local rows = query.headlines({ tags = { "work" } })
  local any_has_work = false
  for _, r in ipairs(rows) do
    for _, t in ipairs(r.tags) do
      if t == "work" then
        any_has_work = true
        break
      end
    end
  end
  assert(any_has_work, "expected a row tagged 'work'")
end

-- tags are always populated as arrays
do
  local rows = query.headlines({})
  for _, r in ipairs(rows) do
    assert(type(r.tags) == "table", "tags should always be table")
  end
end

-- by_file filter
do
  local canon = require("organ.path").canonical(org_dir .. "/01-headlines.org")
  local rows = query.headlines({ file = org_dir .. "/01-headlines.org" })
  for _, r in ipairs(rows) do
    assert(r.file_path == canon)
  end
  assert(#rows == 7, "fixture 01 has 7 headlines; got " .. #rows)
end

-- limit + order_by
do
  local rows = query.headlines({ limit = 3, order_by = { { "title", "asc" } } })
  assert(#rows == 3)
  for i = 1, #rows - 1 do
    assert(rows[i].title <= rows[i + 1].title, "not sorted asc")
  end
end

-- level range
do
  local rows = query.headlines({ level = { min = 2, max = 3 } })
  for _, r in ipairs(rows) do
    assert(r.level >= 2 and r.level <= 3, "level=" .. r.level)
  end
end

-- include_properties
do
  local rows =
    query.headlines({ file = org_dir .. "/03-properties.org", include_properties = true })
  local any_has_props = false
  for _, r in ipairs(rows) do
    if type(r.properties) == "table" and next(r.properties) then
      any_has_props = true
      break
    end
  end
  assert(any_has_props, "expected at least one row with properties")
end

-- properties absent by default
do
  local rows = query.headlines({ file = org_dir .. "/03-properties.org" })
  for _, r in ipairs(rows) do
    assert(r.properties == nil, "properties should be nil without opt-in")
  end
end

vim.fn.delete(tmp, "rf")
io.write("query headlines ok\n")
os.exit(0)
