-- Agenda buffer's `t` keymap cycles the source headline; agenda re-renders.
-- Run via: nvim --headless -l tests/agenda_todo_keymap_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/x.org"
local today = os.date("%Y-%m-%d")
local weekday = os.date("%a")
local fh = assert(io.open(fixture, "w"))
fh:write("* TODO Task one\n  SCHEDULED: <" .. today .. " " .. weekday .. ">\n")
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { log_done = false },
})
require("organ").scan_blocking(org_dir, 5000)

local agenda = require("organ.agenda")
local bufnr = agenda.open({
  from = "today",
  to = "today",
  group_by = "none",
})

-- Find the line index for "Task one" in the agenda buffer.
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local task_line
for i, ln in ipairs(lines) do
  if ln:find("Task one", 1, true) then
    task_line = i
    break
  end
end
assert(task_line, "could not find Task one in agenda:\n" .. table.concat(lines, "\n"))

vim.api.nvim_win_set_cursor(0, { task_line, 0 })

-- Trigger the keymap by invoking its callback directly (vim.api.nvim_input
-- doesn't process buffer-local maps reliably in headless).
local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
local cb
for _, m in ipairs(maps) do
  if m.lhs == "t" then
    cb = m.callback
    break
  end
end
assert(cb, "no `t` keymap registered in agenda buffer")
cb()

-- Wait briefly for the BufWritePost reindex + agenda refresh.
vim.wait(500, function()
  local ls = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, ln in ipairs(ls) do
    if ln:find("NEXT", 1, true) then
      return true
    end
  end
  return false
end, 50)

-- Source file should now reflect TODO → NEXT
local src_lines = vim.fn.readfile(fixture)
assert(
  src_lines[1] == "* NEXT Task one",
  "expected source updated to NEXT; got '" .. src_lines[1] .. "'"
)

vim.fn.delete(tmp, "rf")
io.write("agenda todo keymap ok\n")
os.exit(0)
