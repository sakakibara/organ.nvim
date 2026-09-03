-- A SCHEDULED with a repeater bumps the date instead of transitioning state.
-- Run via: nvim --headless -l tests/todo_repeating_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write([[* TODO Habit
  SCHEDULED: <2026-04-13 Mon +1w>
  body line
]])
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { log_done = "time" },
})

-- Pin "today" by mocking the os.date call we use for bumping inside repeater
-- (the public bump takes now_yyyy_mm_dd; todo._apply needs to inject it).
-- For this test we set the test seam.
local todo = require("organ.todo")
todo._now_for_test = function()
  return "2026-04-26"
end

local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)
assert(todo.set(b, 1, "DONE") == nil)

local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
local joined = table.concat(lines, "\n")

-- State stays TODO (not DONE).
assert(lines[1] == "* TODO Habit", "expected stay-TODO; got: " .. lines[1])
-- SCHEDULED bumped one week from 2026-04-13 → 2026-04-20.
assert(
  joined:find("<2026%-04%-20 Mon %+1w>"),
  "expected SCHEDULED bumped to 2026-04-20; got:\n" .. joined
)
-- LAST_REPEAT property added under :PROPERTIES:
assert(joined:find("LAST_REPEAT:%s+%["), "expected LAST_REPEAT property")
-- No CLOSED line (state didn't transition to done)
assert(
  not joined:find("CLOSED:", 1, true),
  "expected no CLOSED on repeating task; got:\n" .. joined
)

-- Every active repeater timestamp in the entry is bumped, wherever it sits
-- (Emacs `org-auto-repeat-maybe` walks the whole entry).
local case_n = 0
local function repeat_case(body, now)
  case_n = case_n + 1
  local path = org_dir .. "/case" .. case_n .. ".org"
  local h = assert(io.open(path, "w"))
  h:write(body)
  h:close()
  todo._now_for_test = function()
    return now
  end
  local cb = vim.fn.bufadd(path)
  vim.fn.bufload(cb)
  assert(todo.set(cb, 1, "DONE") == nil)
  local ls = vim.api.nvim_buf_get_lines(cb, 0, -1, false)
  return ls[1], table.concat(ls, "\n")
end

do
  local head, j = repeat_case(
    "* TODO Task\nSCHEDULED: <2026-05-01 Fri +1w> DEADLINE: <2026-05-02 Sat +1w>\n",
    "2026-05-04"
  )
  assert(head == "* TODO Task", "same-line planning: stays TODO; got " .. head)
  assert(j:find("<2026-05-08 Fri +1w>", 1, true), "same-line SCHEDULED bumped; got:\n" .. j)
  assert(j:find("<2026-05-09 Sat +1w>", 1, true), "same-line DEADLINE bumped; got:\n" .. j)
end

do
  local _, j = repeat_case(
    "* TODO Task\nDEADLINE: <2026-05-02 Sat +1w> SCHEDULED: <2026-05-01 Fri +1w>\n",
    "2026-05-04"
  )
  assert(j:find("<2026-05-08 Fri +1w>", 1, true), "reversed order: SCHEDULED bumped; got:\n" .. j)
  assert(j:find("<2026-05-09 Sat +1w>", 1, true), "reversed order: DEADLINE bumped; got:\n" .. j)
end

do
  local head, j = repeat_case("* TODO Task\nbody <2026-05-01 Fri +1w> text\n", "2026-05-04")
  assert(head == "* TODO Task", "plain body repeater: stays TODO; got " .. head)
  assert(j:find("body <2026-05-08 Fri +1w> text", 1, true), "plain body ts bumped; got:\n" .. j)
  assert(j:find("LAST_REPEAT:%s+%["), "plain body repeater: LAST_REPEAT written")
end

do
  local head, j = repeat_case("* TODO Task\nSCHEDULED: <2026-05-04 Mon 10:00 +2h>\n", "2026-05-04")
  assert(head == "* TODO Task", "hourly repeater: stays TODO; got " .. head)
  assert(j:find("<2026-05-04 Mon 12:00 +2h>", 1, true), "hourly repeater bumped; got:\n" .. j)
end

do
  local head, j = repeat_case("* TODO Meeting <2026-05-01 Fri +1w>\n  body\n", "2026-05-04")
  assert(head == "* TODO Meeting <2026-05-08 Fri +1w>", "headline repeater bumped; got " .. head)
  assert(j:find("LAST_REPEAT:%s+%["), "headline repeater: LAST_REPEAT written; got:\n" .. j)
  assert(not j:find("CLOSED:", 1, true), "headline repeater: no CLOSED; got:\n" .. j)
end

do
  local head, j = repeat_case("* TODO Zero\nSCHEDULED: <2026-05-01 Fri +0d>\n", "2026-05-04")
  assert(head == "* DONE Zero", "zero repeater completes the entry; got " .. head)
  assert(j:find("<2026-05-01 Fri +0d>", 1, true), "zero repeater left untouched; got:\n" .. j)
  assert(j:find("CLOSED:", 1, true), "zero repeater: CLOSED written; got:\n" .. j)
  assert(not j:find("LAST_REPEAT", 1, true), "zero repeater: no LAST_REPEAT; got:\n" .. j)
end

todo._now_for_test = nil
vim.fn.delete(tmp, "rf")
io.write("todo repeating ok\n")
os.exit(0)
