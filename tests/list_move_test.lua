-- Moving list items: the move_up/move_down command family is
-- context-sensitive like Emacs M-UP/M-DOWN -- on a list item it swaps
-- the item (with its children) with the previous/next sibling at the
-- same indent, keeping ordered bullets positional (probed against
-- Emacs 30.2: metaup on `2. two` yields `1. two / 2. one`).
--
-- Run via: nvim --headless -l tests/list_move_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

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

local list = require("organ.list")

local function org_buf(lines)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  vim.cmd("doautocmd FileType")
  return b
end
local function lines_of(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end
local function eq(a, b)
  return vim.deep_equal(a, b)
end
local function detail(got)
  return "got:\n     " .. table.concat(got, "\n     ")
end

-- move up carries children and returns the item's new first line.
do
  local b = org_buf({ "* H", "- one", "- two", "  - two child", "- three" })
  local new_line = list.move(b, 3, "up")
  local got = lines_of(b)
  check(
    "move up swaps with previous sibling incl children",
    new_line == 2 and eq(got, { "* H", "- two", "  - two child", "- one", "- three" }),
    detail(got) .. " new_line=" .. tostring(new_line)
  )
end

-- move down over the next sibling's block.
do
  local b = org_buf({ "* H", "- one", "- two", "  - two child", "- three" })
  local new_line = list.move(b, 2, "down")
  local got = lines_of(b)
  check(
    "move down swaps over next sibling's block",
    new_line == 4 and eq(got, { "* H", "- two", "  - two child", "- one", "- three" }),
    detail(got) .. " new_line=" .. tostring(new_line)
  )
end

-- ordered bullets stay positional (Emacs renumbers after the swap).
do
  local b = org_buf({ "1. one", "2. two", "3. three" })
  local new_line = list.move(b, 2, "up")
  local got = lines_of(b)
  check(
    "move up renumbers ordered list positionally",
    new_line == 1 and eq(got, { "1. two", "2. one", "3. three" }),
    detail(got)
  )
end

-- moving up over a sibling whose children sit in between.
do
  local b = org_buf({ "- one", "  - one child", "- two" })
  local new_line = list.move(b, 3, "up")
  local got = lines_of(b)
  check(
    "move up jumps over previous sibling's children",
    new_line == 1 and eq(got, { "- two", "- one", "  - one child" }),
    detail(got)
  )
end

-- boundaries: no sibling to swap with.
do
  local b = org_buf({ "- one", "- two" })
  check("move up on first item returns false", list.move(b, 1, "up") == false)
  check("move down on last item returns false", list.move(b, 2, "down") == false)
  check("buffer unchanged after refused moves", eq(lines_of(b), { "- one", "- two" }))
end

do
  local b = org_buf({ "- a", "", "- b" })
  check("move down stops at a blank line (list boundary)", list.move(b, 1, "down") == false)
end

-- <M-k>/<M-j> on an item dispatch to the list move; cursor follows.
do
  local b = org_buf({ "* H", "- one", "- two", "- three" })
  vim.api.nvim_win_set_cursor(0, { 3, 2 })
  feed("<M-k>")
  local got = lines_of(b)
  local pos = vim.api.nvim_win_get_cursor(0)
  check(
    "<M-k> on item swaps with previous sibling",
    eq(got, { "* H", "- two", "- one", "- three" }),
    detail(got)
  )
  check("<M-k> cursor follows the moved item", pos[1] == 2 and pos[2] == 2, vim.inspect(pos))
  feed("<M-j>")
  got = lines_of(b)
  pos = vim.api.nvim_win_get_cursor(0)
  check("<M-j> moves it back down", eq(got, { "* H", "- one", "- two", "- three" }), detail(got))
  check("<M-j> cursor follows the moved item", pos[1] == 3 and pos[2] == 2, vim.inspect(pos))
end

-- Headlines keep the subtree move behavior.
do
  local b = org_buf({ "* A", "body a", "* B", "body b" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  feed("<M-k>")
  local got = lines_of(b)
  check(
    "<M-k> on headline still swaps subtrees",
    eq(got, { "* B", "body b", "* A", "body a" }),
    detail(got)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("list_move_test: PASS")
