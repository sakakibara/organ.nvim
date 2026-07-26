-- End-to-end: toggling a TODO with a filtered/aliased repeater bumps
-- the SCHEDULED line to the next filter-passing date.
-- Run via: nvim --headless -l tests/todo_repeating_filter_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { log_done = false },
})

local todo = require("organ.todo")
local function pin(date)
  todo._now_for_test = function()
    return date
  end
end

-- 1. [wd]: weekday-only repeater skips Sat/Sun.
local function write_file(path, contents)
  local f = assert(io.open(path, "w"))
  f:write(contents)
  f:close()
end

do
  local fixture = org_dir .. "/wd.org"
  write_file(
    fixture,
    [[* TODO Standup
  SCHEDULED: <2026-04-24 Fri +1d[wd]>
]]
  )
  pin("2026-04-25") -- Sat

  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  assert(todo.set(b, 1, "DONE") == nil)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local joined = table.concat(lines, "\n")
  assert(
    joined:find("<2026%-04%-27 Mon %+1d%[wd%]>"),
    "[wd] should bump Fri → Mon; got:\n" .. joined
  )
end

-- 2. [nth:1:mon]: first Monday of next month.
do
  local fixture = org_dir .. "/nth.org"
  write_file(
    fixture,
    [[* TODO Monthly review
  SCHEDULED: <2026-04-06 Mon +1m[nth:1:mon]>
]]
  )
  pin("2026-04-30")

  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  assert(todo.set(b, 1, "DONE") == nil)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local joined = table.concat(lines, "\n")
  -- +1m from Apr 6 = May 6 (Wed); filter [nth:1:mon] iterates forward to next
  -- 1st Monday, which in May 2026 is May 4 — but May 4 < May 6, so iteration
  -- continues into June.  June 2026: 1st Mon = June 1.
  assert(
    joined:find("<2026%-06%-01 Mon %+1m%[nth:1:mon%]>"),
    "[nth:1:mon] should land on June 1; got:\n" .. joined
  )
end

-- 3. [eom]: end of month.
do
  local fixture = org_dir .. "/eom.org"
  write_file(
    fixture,
    [[* TODO Pay rent
  SCHEDULED: <2026-03-31 Tue +1m[eom]>
]]
  )
  pin("2026-04-01")

  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  assert(todo.set(b, 1, "DONE") == nil)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local joined = table.concat(lines, "\n")
  -- +1m from Mar 31 = Apr 30 (clamped from 31 since April has 30 days),
  -- and Apr 30 IS the eom of April → stays at Apr 30.
  assert(
    joined:find("<2026%-04%-30 Thu %+1m%[eom%]>"),
    "[eom] should land on April 30; got:\n" .. joined
  )
end

-- 4. .+P/Q (habit): bump preserves the alarm half.
do
  local fixture = org_dir .. "/habit.org"
  write_file(
    fixture,
    [[* TODO Floss
  :PROPERTIES:
  :STYLE: habit
  :END:
  SCHEDULED: <2026-04-20 Mon .+1d/3d>
]]
  )
  pin("2026-04-25")

  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  assert(todo.set(b, 1, "DONE") == nil)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local joined = table.concat(lines, "\n")
  -- .+1d from "today" 2026-04-25 = 2026-04-26.  /3d preserved verbatim.
  assert(
    joined:find("<2026%-04%-26 Sun %.%+1d/3d>"),
    ".+1d/3d should bump and preserve /3d alarm; got:\n" .. joined
  )
end

vim.fn.delete(tmp, "rf")
io.write("todo repeating filter ok\n")
os.exit(0)
