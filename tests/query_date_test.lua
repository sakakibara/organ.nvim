-- Unit tests for query.parse_date.
-- Run via: nvim --headless -l tests/query_date_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local query = require("organ.query")

-- Override "now" to make tests deterministic: 2026-04-23 (Thu).
query._now = function()
  return os.time({ year = 2026, month = 4, day = 23, hour = 12 })
end

local cases = {
  -- ISO passthrough
  { "2024-01-15", "2024-01-15" },
  { "2024-01-15T14:00", "2024-01-15T14:00" },

  -- Relative
  { "today", "2026-04-23" },
  { "+1d", "2026-04-24" },
  { "-1d", "2026-04-22" },
  { "+7d", "2026-04-30" },
  { "-1w", "2026-04-16" },
  { "+1w", "2026-04-30" },
  { "+1m", "2026-05-23" },
  { "+1y", "2027-04-23" },

  -- Unix timestamp (number)
  { 1776893927, os.date("!%Y-%m-%d", 1776893927) },
}

for _, c in ipairs(cases) do
  local input, expected = c[1], c[2]
  local got = query.parse_date(input)
  if got ~= expected then
    io.stderr:write(
      string.format(
        "parse_date(%s) = %s, expected %s\n",
        tostring(input),
        tostring(got),
        tostring(expected)
      )
    )
    os.exit(1)
  end
end

-- nil and unparseable inputs
assert(query.parse_date(nil) == nil)
assert(query.parse_date("not a date") == nil)

io.write("query date parse ok\n")
os.exit(0)
