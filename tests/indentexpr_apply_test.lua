-- == uses the org indentexpr and agrees with :Org format.
-- Run via: nvim --headless -l tests/indentexpr_apply_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  vim.api.nvim_set_current_buf(b)
  vim.wo.foldenable = false
  require("organ.ftplugin.core").attach(b)
  return b
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

-- == on a flush-left DEADLINE line indents it to the section indent.
do
  local b = mkbuf({ "* TODO Task", "DEADLINE: <2026-06-17 Wed>", "body" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  feed("==")
  check(
    vim.api.nvim_buf_get_lines(b, 1, 2, false)[1] == "  DEADLINE: <2026-06-17 Wed>",
    "== indents DEADLINE to level+1"
  )
end

-- == on a real (column-0) headline keeps it at column 0.
do
  local b = mkbuf({ "* TODO Task", "body" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed("==")
  check(
    vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "* TODO Task",
    "== keeps a headline at column 0"
  )
end

-- == on a `*`-bulleted list item under a headline does NOT treat it as a
-- headline and flush it to column 0 (regression: indented `*` is a list bullet).
do
  local b = mkbuf({ "* H", "  * list item" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  feed("==")
  check(
    vim.api.nvim_buf_get_lines(b, 1, 2, false)[1] == "  * list item",
    "== leaves an indented `*` list item alone"
  )
end

-- indentexpr is actually set on the buffer.
do
  local b = mkbuf({ "* H" })
  check(
    vim.bo[b].indentexpr:find("organ.indentexpr", 1, true) ~= nil,
    "indentexpr option points at organ.indentexpr"
  )
end

print("ALL PASS: indentexpr_apply")
