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

todo._now_for_test = nil
vim.fn.delete(tmp, "rf")
io.write("todo repeating ok\n")
os.exit(0)
