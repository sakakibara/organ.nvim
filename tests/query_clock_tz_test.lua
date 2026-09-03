-- query.clock_entries groups by the LOCAL calendar day, matching the
-- local-time window bounds. A clock started at 07:00 JST belongs to that
-- JST date even though it is still the previous day in UTC.
-- Run via: nvim --headless -l tests/query_clock_tz_test.lua

-- Set before any os.date call so the C library reads it fresh.
vim.uv.os_setenv("TZ", "Asia/Tokyo")

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
h:exec([[
  INSERT INTO files(path, mtime, hash, indexed) VALUES ('/x.org', 0, 'a', 0);
  INSERT INTO headlines(id, file_path, level, title, line_start, line_end)
    VALUES ('h1', '/x.org', 1, 'Alpha', 0, 5);
]])

local start = os.time({ year = 2026, month = 4, day = 26, hour = 7, min = 0, sec = 0 })
assert(os.date("!%Y-%m-%d", start) == "2026-04-25", "runtime honors TZ (UTC day is the 25th)")
local stmt = h:prepare("INSERT INTO clock_entries VALUES (?, ?, ?, ?)")
stmt:bind_text(1, "h1")
stmt:bind_int(2, start)
stmt:bind_int(3, start + 3600)
stmt:bind_int(4, 3600)
stmt:step()
stmt:finalize()

local query = require("organ.query")
for _, group_by in ipairs({ "day", "headline_day" }) do
  local rows = query.clock_entries({ from = "2026-04-26", to = "2026-04-26", group_by = group_by })
  assert(#rows == 1, group_by .. ": expected one bucket, got " .. #rows)
  assert(rows[1].day == "2026-04-26", group_by .. ": day = " .. tostring(rows[1].day))
  assert(rows[1].total_seconds == 3600, group_by .. ": total")
end

io.write("query clock tz ok\n")
os.exit(0)
