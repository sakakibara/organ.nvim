-- Regression test for the `s` / `d` (schedule / deadline) crash:
--
--   E5108: ...calendar.lua:286: attempt to call field 'load_calendar'
--   (a nil value)
--
-- The calendar UI calls `holidays.load_calendar(country)` to highlight
-- holiday dates in the date-picker grid, but the holidays module didn't
-- export that function. Pressing `s` in the agenda crashed every time
-- when `todo.default_country` was set.
--
-- Asserts:
--   1. M.load_calendar exists and is callable
--   2. Returns {} for an unknown country (no cache files)
--   3. Returns the cached entries when a cache file exists
--   4. Concatenates entries across multiple cached years for the same country
--   5. Skips files that don't match the `<country>-<year>.json` prefix

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local h = require("organ.holidays")

-- Redirect cache to a tempdir
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
h._cache_dir = function()
  return tmp
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ": " .. detail or ""))
  end
end

check("load_calendar exists and is callable", type(h.load_calendar) == "function")

-- 2. Unknown country, empty cache dir → empty array
local r = h.load_calendar("XX")
check("returns empty array when no cache files exist for country", type(r) == "table" and #r == 0)

-- 3. Single cached year → returns its entries
local fh = io.open(tmp .. "/JP-2026.json", "w")
fh:write('[{"date":"2026-01-01","name":"New Year"},{"date":"2026-05-05","name":"Children\'s Day"}]')
fh:close()

r = h.load_calendar("JP")
check("returns entries from a single cached year (count=2)", #r == 2, "got #r=" .. #r)
local dates = {}
for _, e in ipairs(r) do
  dates[e.date] = e.name
end
check(
  "entry shape preserved (date + name fields)",
  dates["2026-01-01"] == "New Year" and dates["2026-05-05"] == "Children's Day"
)

-- 4. Multiple cached years → concatenated
local fh2 = io.open(tmp .. "/JP-2027.json", "w")
fh2:write('[{"date":"2027-01-01","name":"New Year"}]')
fh2:close()
r = h.load_calendar("JP")
check("concatenates entries across years (count=3)", #r == 3, "got #r=" .. #r)

-- 5. Files that don't match prefix are skipped
local fh3 = io.open(tmp .. "/US-2026.json", "w")
fh3:write('[{"date":"2026-07-04","name":"Independence Day"}]')
fh3:close()
r = h.load_calendar("JP")
check("doesn't include entries from other countries", #r == 3, "got #r=" .. #r)
r = h.load_calendar("US")
check("returns US entries when querying US", #r == 1, "got #r=" .. #r)

-- 6. Empty cache file (`[]`) doesn't crash
local fh4 = io.open(tmp .. "/FR-2026.json", "w")
fh4:write("[]")
fh4:close()
r = h.load_calendar("FR")
check("empty cache array returns empty result without error", #r == 0)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("holidays_load_calendar_test: PASS")
