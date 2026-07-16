-- meta_return.dispatch leaves the cursor ON the freshly inserted
-- heading, whatever the buffer's blank-line style.  Regression: in an
-- "after" style buffer (blank line below each heading) the cursor used
-- to land one line past the new heading, because the placement guessed
-- the heading's row from the buffer's total line-count growth and
-- attributed below-heading blanks to above.
--
-- Run via: nvim --headless -l tests/meta_return_cursor_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local meta_return = require("organ.meta_return")
local spacing = require("organ.spacing")

local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function cursor_line_text(b)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return row, (vim.api.nvim_buf_get_lines(b, row - 1, row, false)[1] or "")
end

-- spacing.normalize_around reports the heading's final row.
do
  local b = buf_with({ "* A", "body", "* B" })
  local row = spacing.normalize_around(b, 3, { before = 1, after = 0 })
  check("normalize_around returns row after inserting above", row == 4, "got " .. tostring(row))
end

do
  local b = buf_with({ "* A", "body", "* B", "tail" })
  local row = spacing.normalize_around(b, 3, { before = 0, after = 1 })
  check("normalize_around returns row after inserting below", row == 3, "got " .. tostring(row))
end

do
  local b = buf_with({ "* A", "", "", "body" })
  local row = spacing.normalize_around(b, 1, { before = 1, after = 1 })
  check("normalize_around returns row at buffer start", row == 1, "got " .. tostring(row))
end

-- "after" style buffer (blank below each heading), M-RET on a headline:
-- cursor must sit on the new `* ` line, not below it.
do
  local b = buf_with({
    "* A",
    "",
    "body a",
    "* B",
    "",
    "body b",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  meta_return.dispatch({ enter_insert = false })
  local row, text = cursor_line_text(b)
  check(
    "after-style: cursor on new heading (headline case)",
    text == "* ",
    ("cursor on row %d = %q"):format(row, text)
  )
end

-- Same style, M-RET from a body line (case 4) must also land on the
-- new heading.
do
  local b = buf_with({
    "* A",
    "",
    "body a",
    "* B",
    "",
    "body b",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  meta_return.dispatch({ enter_insert = false })
  local row, text = cursor_line_text(b)
  check(
    "after-style: cursor on new heading (body-line case)",
    text == "* ",
    ("cursor on row %d = %q"):format(row, text)
  )
end

-- "before" style (blank above each heading) keeps working: the new
-- heading gains a blank above and the cursor follows it down.
do
  local b = buf_with({
    "* A",
    "body a",
    "",
    "* B",
    "body b",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  meta_return.dispatch({ enter_insert = false })
  local row, text = cursor_line_text(b)
  check(
    "before-style: cursor on new heading",
    text == "* ",
    ("cursor on row %d = %q"):format(row, text)
  )
end

-- Preamble-only buffer (case 5): heading appended at EOF, cursor on it.
do
  local b = buf_with({
    "#+TITLE: t",
    "prose",
  })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  meta_return.dispatch({ enter_insert = false })
  local row, text = cursor_line_text(b)
  check(
    "preamble-only buffer: cursor on appended heading",
    text == "* ",
    ("cursor on row %d = %q"):format(row, text)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("meta_return_cursor_test: PASS")
