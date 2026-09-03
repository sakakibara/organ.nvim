-- statistics: [N/M] and [%] cookies update on TODO change + checkbox toggle.
-- Run via: nvim --headless -l tests/statistics_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { log_done = false },
})

local stats = require("organ.statistics")

-- 1. Headline cookie counts direct children with TODO state.
do
  local fixture = org_dir .. "/h.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write([[
* Project [/]
** TODO Task A
** TODO Task B
** DONE Task C
* Other
]])
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)

  local n = stats.update_buffer(b)
  assert(n >= 1, "expected at least 1 cookie line updated")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "* Project [1/3]", "1.line: " .. lines[1])
end

-- 2. Percent cookie alongside fraction — both update on the same line.
do
  local fixture = org_dir .. "/p.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write([[
* Project [/] [%]
** DONE Task A
** TODO Task B
]])
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  stats.update_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "* Project [1/2] [50%]", "1.line: " .. lines[1])
end

-- 3. Auto-update via TODO state change (organ.todo.set hook).
do
  local fixture = org_dir .. "/t.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write([[
* Project [/]
** TODO A
** TODO B
]])
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  -- Initial cookie reflects 0 done out of 2.
  stats.update_buffer(b)
  local first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(first == "* Project [0/2]", "initial: " .. first)

  -- Toggle child A to DONE — ancestor cookie should auto-recompute.
  assert(require("organ.todo").set(b, 2, "DONE") == nil)
  local after = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(after == "* Project [1/2]", "after TODO change, expected [1/2]; got: " .. after)
end

-- 4. List-item cookie counts checked descendants.
do
  local fixture = org_dir .. "/l.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write([[
- Project [/]
  - [X] step 1
  - [ ] step 2
  - [ ] step 3
]])
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  stats.update_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "- Project [1/3]", "1.line: " .. lines[1])
end

-- 5. Auto-update on checkbox toggle.
do
  local fixture = org_dir .. "/c.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write([[
* Owner [/]
- [ ] one
- [ ] two
]])
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  stats.update_buffer(b)
  -- Toggle line 2 ([ ] one) → [X] one. Headline cookie should update.
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  require("organ.checkbox").toggle({ bufnr = b, line = 2 })
  local first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(first == "* Owner [1/2]", "owner after toggle: " .. first)
  stats.update_buffer(b)
  first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(first == "* Owner [1/2]", "owner after update_buffer: " .. first)
end

local function mk_buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function line1(b)
  return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
end

-- 6. Headline cookie over checkboxes: top-level items of every list in the
-- section, nested items and items under child headlines excluded
-- (org-update-checkbox-count, org-checkbox-hierarchical-statistics t).
do
  local b = mk_buf({
    "* Tasks [/] [%]",
    "- [ ] a",
    "  - [X] aa",
    "  - [ ] ab",
    "- [X] b",
    "- plain",
    "",
    "Text",
    "- [ ] c",
    "** Sub",
    "- [ ] d",
  })
  assert(stats.update_line(b, 1) == true)
  assert(line1(b) == "* Tasks [1/3] [33%]", "6: " .. line1(b))
end

-- 7. Percent cookies floor (Emacs `(floor (* 100.0 checked) total)`).
do
  local b = mk_buf({ "* Tasks [%]", "- [ ] a", "- [X] b", "- [X] c" })
  stats.update_line(b, 1)
  assert(line1(b) == "* Tasks [66%]", "7a: " .. line1(b))
  b = mk_buf({ "* T [%]", "** DONE a", "** TODO b", "** DONE c" })
  stats.update_line(b, 1)
  assert(line1(b) == "* T [66%]", "7b: " .. line1(b))
  b = mk_buf({ "- p [%]", "  - [ ] a", "  - [X] b", "  - [X] c" })
  stats.update_line(b, 1)
  assert(line1(b) == "- p [66%]", "7c: " .. line1(b))
end

-- 8. List cookie counts direct children only.
do
  local b = mk_buf({ "- p [/] [%]", "  - [ ] a", "    - [X] aa", "  - [X] b", "  - [X] c" })
  stats.update_line(b, 1)
  assert(line1(b) == "- p [2/3] [66%]", "8a: " .. line1(b))
  b = mk_buf({ "- p [/]", "  - [ ] a", "    - [X] aa", "  - [X] b" })
  stats.update_line(b, 1)
  assert(line1(b) == "- p [1/2]", "8b: " .. line1(b))
end

-- 9. Checkboxes and TODO children under one cookie: a checkbox toggle and
-- a plain update count checkboxes, a TODO change counts children
-- (org-update-checkbox-count vs org-update-parent-todo-statistics).
do
  local b = mk_buf({ "* Tasks [/]", "- [ ] a", "- [X] b", "** TODO c", "** DONE d" })
  stats.update_line(b, 1)
  assert(line1(b) == "* Tasks [1/2]", "9a: " .. line1(b))
  vim.api.nvim_set_current_buf(b)
  require("organ.checkbox").toggle({ bufnr = b, line = 2 })
  assert(line1(b) == "* Tasks [2/2]", "9b: " .. line1(b))
  require("organ.checkbox").toggle({ bufnr = b, line = 2 })
  assert(require("organ.todo").set(b, 4, "DONE") == nil)
  assert(line1(b) == "* Tasks [2/2]", "9c: " .. line1(b))
  assert(require("organ.todo").set(b, 4, "TODO") == nil)
  assert(line1(b) == "* Tasks [1/2]", "9d: " .. line1(b))
end

-- 10. COOKIE_DATA selects the source and recursion.
do
  local b = mk_buf({
    "* Tasks [/]",
    ":PROPERTIES:",
    ":COOKIE_DATA: todo",
    ":END:",
    "- [ ] a",
    "- [X] b",
    "** TODO c",
    "** DONE d",
    "** DONE e",
  })
  stats.update_line(b, 1)
  assert(line1(b) == "* Tasks [2/3]", "10a: " .. line1(b))
  b = mk_buf({
    "* Tasks [/]",
    ":PROPERTIES:",
    ":COOKIE_DATA: recursive",
    ":END:",
    "- [ ] a",
    "  - [X] aa",
    "- [X] b",
  })
  stats.update_line(b, 1)
  assert(line1(b) == "* Tasks [2/3]", "10b: " .. line1(b))
end

-- 11. Any checkbox item in the section selects the checkbox count, even
-- when every one is nested; the TODO children are not a fallback.
do
  local b = mk_buf({
    "* P [/] [%]",
    "- item",
    "  - [ ] nested",
    "  - [X] nested2",
    "** TODO x",
    "** DONE y",
  })
  stats.update_line(b, 1)
  assert(line1(b) == "* P [0/0] [0%]", "11a: " .. line1(b))
  b = mk_buf({ "* P [/]", "** TODO x", "- [ ] under child" })
  stats.update_line(b, 1)
  assert(line1(b) == "* P [0/1]", "11b: " .. line1(b))
end

-- 12. An item's continuation line before its child items neither ends
-- the list nor sets the child indent.
do
  local b = mk_buf({ "- [/] parent", "  continuation", "    - [X] a", "    - [ ] b" })
  stats.update_line(b, 1)
  assert(line1(b) == "- [1/2] parent", "12a: " .. line1(b))
  b = mk_buf({ "- [/] parent", "  - [X] a", "    text of a", "  - [ ] b", "  - [ ] c" })
  stats.update_line(b, 1)
  assert(line1(b) == "- [1/3] parent", "12b: " .. line1(b))
end

vim.fn.delete(tmp, "rf")
io.write("statistics ok\n")
os.exit(0)
