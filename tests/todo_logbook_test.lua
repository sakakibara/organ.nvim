-- log_done = "note" inserts a LOGBOOK entry on active→done after prompting.
-- Run via: nvim --headless -l tests/todo_logbook_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write("* TODO Heading\n  body\n")
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { log_done = "note", log_drawer = "LOGBOOK" },
})

-- Mock vim.ui.input to return a canned note synchronously.
vim.ui.input = function(_opts, cb)
  cb("first attempt failed")
end

local todo = require("organ.todo")
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)

assert(todo.set(b, 1, "DONE") == nil)
local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
local joined = table.concat(lines, "\n")

assert(joined:find(":LOGBOOK:", 1, true), "expected :LOGBOOK: drawer; got:\n" .. joined)
assert(joined:find(":END:", 1, true), "expected :END: drawer close")
assert(joined:find('- State "DONE"', 1, true), "expected state-change line")
assert(joined:find('from "TODO"', 1, true), "expected from-state in entry")
assert(joined:find("first attempt failed", 1, true), "expected note text")
-- "\\\\" is the literal two-char marker in org files (one backslash escaped in Lua source).
assert(joined:find("\\\\", 1, true), "expected line continuation marker")

-- Cancelled prompt → no LOGBOOK entry written
local fixture2 = org_dir .. "/y.org"
fh = assert(io.open(fixture2, "w"))
fh:write("* TODO Another\n")
fh:close()
local b2 = vim.fn.bufadd(fixture2)
vim.fn.bufload(b2)
vim.ui.input = function(_opts, cb)
  cb(nil)
end -- user cancelled

assert(todo.set(b2, 1, "DONE") == nil)
local joined2 = table.concat(vim.api.nvim_buf_get_lines(b2, 0, -1, false), "\n")
assert(
  not joined2:find(":LOGBOOK:", 1, true),
  "cancelled note should leave no drawer; got:\n" .. joined2
)
-- CLOSED: line still present from the "time" half of "note" mode
assert(joined2:find("CLOSED:", 1, true), "CLOSED still added even when note cancelled")

vim.fn.delete(tmp, "rf")
io.write("todo logbook ok\n")
os.exit(0)
