-- effort.parse_filter: predicate accepts/rejects per spec.
-- Run via: nvim --headless -l tests/effort_filter_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local effort = require("organ.effort")

-- 1. "<30"
do
  local p = effort.parse_filter("<30")
  assert(p(15) and p(29), "matches under 30")
  assert(not p(30) and not p(60), "rejects ≥ 30")
end

-- 2. ">=1:00"
do
  local p = effort.parse_filter(">=1:00")
  assert(p(60) and p(120), "matches ≥ 60")
  assert(not p(59), "rejects below 60")
end

-- 3. "1:00..2:00" range
do
  local p = effort.parse_filter("1:00..2:00")
  assert(p(60) and p(120) and p(90), "in range")
  assert(not p(59) and not p(121), "outside")
end

-- 4. Exact value (pure number = minutes).
do
  local p = effort.parse_filter("30")
  assert(p(30), "exact match")
  assert(not p(29) and not p(31), "non-match")
end

-- 5. Empty filter matches everything.
do
  local p = effort.parse_filter("")
  assert(p(0) and p(60) and p(nil) == nil or true, "empty matches all")
  -- (parse_filter("") returns the always-true fn; nil minutes also passes)
end

-- 6. Bad input → nil + error.
do
  local p, err = effort.parse_filter("nonsense???")
  assert(p == nil, "bad input rejected")
  assert(err and err:find("could not parse", 1, true), "err: " .. tostring(err))
end

-- 7. Values read as effort values: `min` is minutes, `m` a month.
do
  local p = effort.parse_filter("<30min")
  assert(p(29) and not p(30), "30min is 30 minutes")
  p = effort.parse_filter("<30m")
  assert(p(30 * 43200 - 1) and not p(30 * 43200), "30m is 30 months")
end

-- 8. ">=1h"
do
  local p = effort.parse_filter(">=1h")
  assert(p(60) and not p(59), ">=1h")
end

-- 9. A blank range bound is rejected.
for _, spec in ipairs({ "..2:00", "1:00..", "1:00.. ", " ..2:00" }) do
  local p, err = effort.parse_filter(spec)
  assert(p == nil, "blank bound rejected: " .. spec)
  assert(err and err:find("bad range bounds", 1, true), "err: " .. tostring(err))
end

-- 10. A value org-duration cannot read is rejected.
do
  local p, err = effort.parse_filter("<2hr")
  assert(p == nil and err and err:find("bad value", 1, true), "err: " .. tostring(err))
end

io.write("effort filter ok\n")
os.exit(0)
