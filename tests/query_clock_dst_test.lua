-- A report window is bounded by the next local midnight, not by 86400
-- seconds: in America/New_York 2026-03-08 is 23h long and 2026-11-01 is
-- 25h long, and both clock reports and state-change reports have to
-- cover exactly their own day.
-- Run via: nvim --headless -l tests/query_clock_dst_test.lua

-- Set before any os.date call so the C library reads it fresh.
vim.uv.os_setenv("TZ", "America/New_York")

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
    VALUES ('spring', '/x.org', 1, 'Spring', 0, 1),
           ('fall',   '/x.org', 1, 'Fall',   2, 3);
]])

local function at(y, mo, d, hh, mm)
  return os.time({ year = y, month = mo, day = d, hour = hh, min = mm, sec = 0 })
end

-- Sanity: the runtime honors TZ, so the two boundary days really are
-- 23h and 25h long.
assert(at(2026, 3, 9, 0, 0) - at(2026, 3, 8, 0, 0) == 82800, "runtime honors TZ (spring forward)")
assert(at(2026, 11, 2, 0, 0) - at(2026, 11, 1, 0, 0) == 90000, "runtime honors TZ (fall back)")

local function add_clock(id, start_ts, seconds)
  local s = assert(h:prepare("INSERT INTO clock_entries VALUES (?, ?, ?, ?)"))
  s:bind_text(1, id)
  s:bind_int(2, start_ts)
  s:bind_int(3, start_ts + seconds)
  s:bind_int(4, seconds)
  assert(s:step() == require("organ.db").SQLITE_DONE)
  s:finalize()
end

local function add_state(id, ts)
  local s = assert(h:prepare("INSERT INTO state_changes VALUES (?, ?, ?, ?, ?)"))
  s:bind_text(1, id)
  s:bind_int(2, ts)
  s:bind_text(3, "TODO")
  s:bind_text(4, "DONE")
  s:bind_null(5)
  assert(s:step() == require("organ.db").SQLITE_DONE)
  s:finalize()
end

-- The hour just after the short day ends belongs to the next day only.
add_clock("spring", at(2026, 3, 9, 0, 30), 1800)
add_state("spring", at(2026, 3, 9, 0, 30))
-- The last half hour of the long day belongs to that day.
add_clock("fall", at(2026, 11, 1, 23, 30), 1800)
add_state("fall", at(2026, 11, 1, 23, 30))

local query = require("organ.query")

local function clock_ids(day)
  local out = {}
  for _, r in ipairs(query.clock_entries({ from = day, to = day, group_by = "headline" })) do
    out[#out + 1] = r.headline_id
  end
  table.sort(out)
  return table.concat(out, ",")
end

local function state_ids(day)
  local out = {}
  for _, r in ipairs(query.state_changes({ from = day, to = day })) do
    out[#out + 1] = r.headline_id
  end
  table.sort(out)
  return table.concat(out, ",")
end

assert(
  clock_ids("2026-03-08") == "",
  "spring-forward day pulled in the next day: " .. clock_ids("2026-03-08")
)
assert(clock_ids("2026-03-09") == "spring", "next day lost its clock: " .. clock_ids("2026-03-09"))
assert(
  clock_ids("2026-11-01") == "fall",
  "fall-back day lost its last hour: " .. clock_ids("2026-11-01")
)
assert(
  clock_ids("2026-11-02") == "",
  "fall-back day leaked into the next: " .. clock_ids("2026-11-02")
)

assert(state_ids("2026-03-08") == "", "state change leaked backwards: " .. state_ids("2026-03-08"))
assert(state_ids("2026-03-09") == "spring", "state change lost: " .. state_ids("2026-03-09"))
assert(
  state_ids("2026-11-01") == "fall",
  "state change lost on the long day: " .. state_ids("2026-11-01")
)
assert(state_ids("2026-11-02") == "", "state change leaked forwards: " .. state_ids("2026-11-02"))

vim.fn.delete(tmp, "rf")
io.write("query clock dst ok\n")
os.exit(0)
