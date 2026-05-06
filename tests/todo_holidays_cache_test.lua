-- holidays.is_holiday reads disk cache; cache miss returns false silently.
-- Run via: nvim --headless -l tests/todo_holidays_cache_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local hol = require("organ.holidays")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
hol._cache_dir = function()
  return tmp
end

-- Hand-write a Nager.Date-shape cache file for JP-2026.
local sample = "["
  .. '{"date":"2026-01-01","localName":"元日","name":"New Year\'s Day","countryCode":"JP"},'
  .. '{"date":"2026-05-05","localName":"こどもの日","name":"Children\'s Day","countryCode":"JP"}'
  .. "]"
local path = tmp .. "/JP-2026.json"
local fh = assert(io.open(path, "w"))
fh:write(sample)
fh:close()

-- Hits known holidays
assert(hol.is_holiday("JP", "2026-01-01") == true, "Jan 1 is a JP holiday")
assert(hol.is_holiday("JP", "2026-05-05") == true, "May 5 is a JP holiday")
assert(hol.is_holiday("JP", "2026-04-26") == false, "Apr 26 is not")

-- Cache miss → false silently
assert(hol.is_holiday("JP", "2027-01-01") == false, "2027 not cached → false")
assert(hol.is_holiday("US", "2026-07-04") == false, "US not cached → false")

-- Corrupted JSON → false (and presumably logs once; we just check return)
local bad = tmp .. "/XX-2026.json"
local fh2 = assert(io.open(bad, "w"))
fh2:write("not json")
fh2:close()
assert(hol.is_holiday("XX", "2026-01-01") == false, "corrupted cache → false")

vim.fn.delete(tmp, "rf")
io.write("todo holidays cache ok\n")
os.exit(0)
