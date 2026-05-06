-- Unit tests for query.clock_entries with filters + group_by.
-- Run via: nvim --headless -l tests/query_clock_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  db_path = tmp .. "/q.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local h = require("organ").db_handle()
local db_mod = require("organ.db")

h:exec([[
  INSERT INTO files(path, mtime, hash, indexed) VALUES ('/x.org', 0, 'a', 0);
  INSERT INTO headlines(id, file_path, level, title, line_start, line_end)
    VALUES ('h1', '/x.org', 1, 'Alpha', 0, 5);
  INSERT INTO headlines(id, file_path, level, title, line_start, line_end)
    VALUES ('h2', '/x.org', 1, 'Beta',  6, 10);
]])

local function ts(y, mo, d, hh, mm)
  return os.time({ year = y, month = mo, day = d, hour = hh, min = mm, sec = 0 })
end
local s1 = ts(2026, 4, 25, 9, 0)
local e1 = ts(2026, 4, 25, 10, 0)
local s2 = ts(2026, 4, 26, 9, 0)
local e2 = ts(2026, 4, 26, 11, 0)
local s3 = ts(2026, 4, 26, 14, 0)
local e3 = ts(2026, 4, 26, 14, 30)
local stmt = h:prepare("INSERT INTO clock_entries VALUES (?, ?, ?, ?)")
local function ins(id, s, e)
  stmt:reset()
  stmt:bind_text(1, id)
  stmt:bind_int(2, s)
  stmt:bind_int(3, e)
  stmt:bind_int(4, e - s)
  stmt:step()
end
ins("h1", s1, e1)
ins("h1", s2, e2)
ins("h2", s3, e3)
stmt:finalize()

local query = require("organ.query")

-- 1. group_by = "headline" + date range covering both days.
do
  local rows = query.clock_entries({
    from = "2026-04-25",
    to = "2026-04-26",
    group_by = "headline",
  })
  assert(#rows == 2, "expected 2 rows; got " .. #rows)
  assert(rows[1].headline_id == "h1", "first row should be h1")
  assert(rows[1].total_seconds == 10800, "h1 total: " .. rows[1].total_seconds)
  assert(rows[2].headline_id == "h2")
  assert(rows[2].total_seconds == 1800)
end

-- 2. Date range narrows: only 2026-04-26 → h1=7200, h2=1800.
do
  local rows = query.clock_entries({
    from = "2026-04-26",
    to = "2026-04-26",
    group_by = "headline",
  })
  assert(#rows == 2)
  for _, r in ipairs(rows) do
    if r.headline_id == "h1" then
      assert(r.total_seconds == 7200)
    end
    if r.headline_id == "h2" then
      assert(r.total_seconds == 1800)
    end
  end
end

-- 3. headline_id filter narrows to one headline.
do
  local rows = query.clock_entries({
    from = "2026-04-25",
    to = "2026-04-26",
    headline_id = "h2",
    group_by = "headline",
  })
  assert(#rows == 1)
  assert(rows[1].headline_id == "h2")
end

-- 4. group_by = "day" returns rows per day.
do
  local rows = query.clock_entries({
    from = "2026-04-25",
    to = "2026-04-26",
    group_by = "day",
  })
  assert(#rows == 2, "expected 2 day rows; got " .. #rows)
end

-- 5. include_active toggles whether NULL-end rows count.
-- Anchor to today's day-start so timestamps are guaranteed within today
-- regardless of how close `now` is to midnight (the previous "now -
-- 1800" approach would underflow into yesterday during the first 30
-- minutes of a day, leaving no rows in the today-only query).
do
  local now_ts = os.time()
  local d = os.date("*t", now_ts)
  local day_start = os.time({
    year = d.year,
    month = d.month,
    day = d.day,
    hour = 0,
    min = 0,
    sec = 0,
  })
  -- Closed entry for h2 today: 10 minutes long, starting at 09:00 today.
  local closed_start = day_start + 9 * 3600
  local closed_end = closed_start + 600
  h:exec(
    string.format("INSERT INTO clock_entries VALUES ('h2', %d, %d, 600)", closed_start, closed_end)
  )
  -- Open clock for h2: started 10 minutes ago, no end.  If now < 10 min
  -- after midnight, anchor to day_start so it still falls inside today.
  local open_start = math.max(now_ts - 600, day_start)
  h:exec(string.format("INSERT INTO clock_entries VALUES ('h2', %d, NULL, NULL)", open_start))

  local rows1 = query.clock_entries({
    from = os.date("%Y-%m-%d"),
    to = os.date("%Y-%m-%d"),
    group_by = "headline",
    include_active = false,
  })
  local h2_no_active
  for _, r in ipairs(rows1) do
    if r.headline_id == "h2" then
      h2_no_active = r.total_seconds
    end
  end

  local rows2 = query.clock_entries({
    from = os.date("%Y-%m-%d"),
    to = os.date("%Y-%m-%d"),
    group_by = "headline",
    include_active = true,
  })
  local h2_with_active
  for _, r in ipairs(rows2) do
    if r.headline_id == "h2" then
      h2_with_active = r.total_seconds
    end
  end
  assert(
    h2_with_active and h2_no_active and h2_with_active > h2_no_active,
    "include_active should add the open-clock duration"
  )
end

vim.fn.delete(tmp, "rf")
io.write("query clock ok\n")
os.exit(0)
