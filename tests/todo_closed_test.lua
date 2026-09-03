-- log_done = "time" inserts CLOSED: [<now>] on active→done; removes on done→active.
-- Run via: nvim --headless -l tests/todo_closed_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write([[* TODO Heading
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

local todo = require("organ.todo")
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)

-- active → DONE inserts CLOSED line directly under the headline.
assert(todo.set(b, 1, "DONE") == nil)
local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
assert(lines[1] == "* DONE Heading", "headline: " .. lines[1])
assert(
  lines[2]:match("^%s*CLOSED:%s*%[%d%d%d%d%-%d%d%-%d%d %a%a%a %d%d:%d%d%]"),
  "expected CLOSED timestamp on line 2; got '" .. lines[2] .. "'"
)

-- done → active removes CLOSED line.
assert(todo.set(b, 1, "TODO") == nil)
lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
assert(lines[1] == "* TODO Heading", "headline: " .. lines[1])
assert(
  not (lines[2] and lines[2]:match("CLOSED:")),
  "CLOSED should be gone; got '" .. (lines[2] or "") .. "'"
)

-- re-toggle replaces old CLOSED with new (no duplicate)
assert(todo.set(b, 1, "DONE") == nil)
local closed_count = 0
for _, ln in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
  if ln:match("CLOSED:") then
    closed_count = closed_count + 1
  end
end
assert(closed_count == 1, "expected 1 CLOSED line, got " .. closed_count)

-- SCHEDULED + CLOSED: reopen removes only CLOSED, preserves SCHEDULED.
local fixture2 = org_dir .. "/y.org"
local fh2 = assert(io.open(fixture2, "w"))
fh2:write([[* TODO Task
  SCHEDULED: <2026-05-06 Wed>
  body
]])
fh2:close()

local b2 = vim.fn.bufadd(fixture2)
vim.fn.bufload(b2)

-- active -> DONE: CLOSED added, SCHEDULED preserved.
assert(todo.set(b2, 1, "DONE") == nil)
local lines2 = vim.api.nvim_buf_get_lines(b2, 0, -1, false)
assert(lines2[1] == "* DONE Task", "headline: " .. lines2[1])
-- Emacs `org-add-planning-info` keeps one planning line and puts the
-- keyword being set first: `CLOSED: [...] SCHEDULED: <...>`.
assert(
  lines2[2]:match("^%s*CLOSED: %[[^%]]+%] SCHEDULED: <2026%-05%-06 Wed>$"),
  "expected CLOSED then SCHEDULED on the planning line; got: " .. lines2[2]
)

-- DONE -> active: CLOSED removed, SCHEDULED still present.
assert(todo.set(b2, 1, "TODO") == nil)
lines2 = vim.api.nvim_buf_get_lines(b2, 0, -1, false)
assert(lines2[1] == "* TODO Task", "headline: " .. lines2[1])
local found_scheduled_after_reopen = false
local found_closed_after_reopen = false
for _, ln in ipairs(lines2) do
  if ln:match("SCHEDULED:") then
    found_scheduled_after_reopen = true
  end
  if ln:match("CLOSED:") then
    found_closed_after_reopen = true
  end
end
assert(found_scheduled_after_reopen, "SCHEDULED lost after DONE->active reopen")
assert(not found_closed_after_reopen, "CLOSED should be gone after DONE->active reopen")

vim.fn.delete(tmp, "rf")
io.write("todo closed ok\n")
os.exit(0)
