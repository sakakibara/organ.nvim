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

vim.fn.delete(tmp, "rf")
io.write("todo closed ok\n")
os.exit(0)
