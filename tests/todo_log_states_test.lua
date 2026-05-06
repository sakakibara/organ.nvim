-- todo.log_states: per-destination-state logging policy fires a LOGBOOK
-- entry on transitions INTO the configured state.
-- Run via: nvim --headless -l tests/todo_log_states_test.lua

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
  todo = {
    log_done = nil, -- legacy active→done logging off
    log_drawer = "LOGBOOK",
    log_states = { WAITING = "time", HOLD = "note" },
  },
})

local todo = require("organ.todo")

-- Case 1: TODO → WAITING with log_states.WAITING = "time" → time-only entry.
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)
assert(todo.set(b, 1, "WAITING") == nil)
local joined = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
assert(joined:find(":LOGBOOK:", 1, true), "expected LOGBOOK drawer; got:\n" .. joined)
assert(
  joined:find('- State "WAITING"', 1, true),
  "expected state-change line for WAITING; got:\n" .. joined
)
assert(joined:find('from "TODO"', 1, true), "expected from-state TODO")

-- Case 2: WAITING → HOLD with log_states.HOLD = "note" → prompt path.
vim.ui.input = function(_opts, cb)
  cb("hold reason")
end
assert(todo.set(b, 1, "HOLD") == nil)
joined = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
assert(joined:find('- State "HOLD"', 1, true), "expected HOLD entry")
assert(joined:find("hold reason", 1, true), "expected note text")

-- Case 3: HOLD → DONE with no log_states.DONE and log_done = nil → no new entry.
local before_count = 0
for _, ln in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
  if ln:match("^%- State") then
    before_count = before_count + 1
  end
end
assert(todo.set(b, 1, "DONE") == nil)
local after_count = 0
for _, ln in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
  if ln:match("^%- State") then
    after_count = after_count + 1
  end
end
assert(
  after_count == before_count,
  "no new entry expected when log_states.DONE unset and log_done off; "
    .. "before="
    .. before_count
    .. " after="
    .. after_count
)

-- Case 4: explicit `false` overrides log_state_changes for that one state.
local fixture2 = org_dir .. "/y.org"
fh = assert(io.open(fixture2, "w"))
fh:write("* TODO Other\n")
fh:close()
local b2 = vim.fn.bufadd(fixture2)
vim.fn.bufload(b2)

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = {
    log_done = nil,
    log_drawer = "LOGBOOK",
    log_state_changes = true,
    log_states = { WAITING = false },
  },
})

assert(todo.set(b2, 1, "WAITING") == nil)
local j2 = table.concat(vim.api.nvim_buf_get_lines(b2, 0, -1, false), "\n")
assert(
  not j2:find(":LOGBOOK:", 1, true),
  "log_states[WAITING]=false should suppress entry even with log_state_changes=true; got:\n" .. j2
)
assert(not j2:find("- State", 1, true), "no bare state line either; got:\n" .. j2)

vim.fn.delete(tmp, "rf")
io.write("todo log_states ok\n")
os.exit(0)
