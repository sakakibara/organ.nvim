-- todo.log_into_drawer = false: state-change entries appear as bare list items
-- after the planning block, never inside a :LOGBOOK: drawer.
-- Run via: nvim --headless -l tests/todo_log_into_drawer_false_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write("* TODO Heading\n  body line\n")
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = {
    log_done = "note",
    log_drawer = "LOGBOOK",
    log_into_drawer = false,
  },
})

vim.ui.input = function(_opts, cb)
  cb("done by hand")
end

local todo = require("organ.todo")
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)
assert(todo.set(b, 1, "DONE") == nil)

local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
local joined = table.concat(lines, "\n")

assert(
  not joined:find(":LOGBOOK:", 1, true),
  "log_into_drawer=false should not create a drawer; got:\n" .. joined
)
assert(
  joined:find('- State "DONE"', 1, true),
  "expected bare state-change list item; got:\n" .. joined
)
assert(joined:find("done by hand", 1, true), "expected note text")

-- The state line should sit directly after the planning (CLOSED) line and
-- BEFORE the body, mirroring Emacs `org-log-into-drawer = nil` placement.
local state_idx, body_idx
for i, ln in ipairs(lines) do
  if ln:match("^%- State") and not state_idx then
    state_idx = i
  end
  if ln == "  body line" and not body_idx then
    body_idx = i
  end
end
assert(state_idx and body_idx, "expected both state line and body in buffer; lines:\n" .. joined)
assert(state_idx < body_idx, "state line " .. state_idx .. " should precede body " .. body_idx)

vim.fn.delete(tmp, "rf")
io.write("todo log_into_drawer=false ok\n")
os.exit(0)
