-- todo.log_state_changes = true: every state transition writes a timestamp
-- entry to the LOGBOOK drawer.
-- Run via: nvim --headless -l tests/todo_log_state_changes_test.lua

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
    log_done = nil,
    log_drawer = "LOGBOOK",
    log_state_changes = true,
  },
})

local todo = require("organ.todo")
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)

assert(todo.set(b, 1, "NEXT") == nil)
assert(todo.set(b, 1, "WAITING") == nil)
assert(todo.set(b, 1, "DONE") == nil)

local entries = 0
for _, ln in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
  if ln:match("^%- State") then
    entries = entries + 1
  end
end
assert(entries == 3, "expected 3 state-change entries; got " .. entries)

local joined = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
assert(joined:find('- State "NEXT"', 1, true), "expected NEXT entry")
assert(joined:find('- State "WAITING"', 1, true), "expected WAITING entry")
assert(joined:find('- State "DONE"', 1, true), "expected DONE entry")

-- No-op transition (DONE → DONE) should not add another entry.
assert(todo.set(b, 1, "DONE") == nil)
local entries2 = 0
for _, ln in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
  if ln:match("^%- State") then
    entries2 = entries2 + 1
  end
end
assert(entries2 == 3, "no-op should not add an entry; got " .. entries2)

vim.fn.delete(tmp, "rf")
io.write("todo log_state_changes ok\n")
os.exit(0)
