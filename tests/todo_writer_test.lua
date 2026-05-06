-- todo.cycle and todo.set mutate the headline keyword in place.
-- Run via: nvim --headless -l tests/todo_writer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write([[* TODO Heading one
  body line 1
  body line 2
* Heading two
* DONE Already done
]])
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { log_done = false }, -- isolate from CLOSED-line side effects
})

local todo = require("organ.todo")

local function read(line_idx)
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  return vim.api.nvim_buf_get_lines(b, line_idx - 1, line_idx, false)[1]
end

local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)

-- cycle on TODO → NEXT (per default sequence)
assert(todo.cycle(b, 1) == nil, "cycle TODO err")
assert(read(1) == "* NEXT Heading one", "got: " .. read(1))

-- cycle on no-state → TODO
assert(todo.cycle(b, 4) == nil, "cycle no-state err")
assert(read(4) == "* TODO Heading two", "got: " .. read(4))

-- set explicit
assert(todo.set(b, 1, "DONE") == nil, "set DONE err")
assert(read(1) == "* DONE Heading one", "got: " .. read(1))

-- clear via set(nil)
assert(todo.set(b, 1, nil) == nil, "clear err")
assert(read(1) == "* Heading one", "got: " .. read(1))

-- cursor on body line walks up to parent
assert(todo.cycle(b, 3) == nil, "walk-up err") -- line 3 is body of "Heading one"
assert(read(1) == "* TODO Heading one", "walked-up cycle, got: " .. read(1))

-- non-headline target (no headline above) → error
local sb = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(sb, 0, -1, false, { "no headline at all" })
local err = todo.cycle(sb, 1)
assert(err and err:find("no headline"), "expected no-headline error, got " .. tostring(err))

vim.fn.delete(tmp, "rf")
io.write("todo writer ok\n")
os.exit(0)
