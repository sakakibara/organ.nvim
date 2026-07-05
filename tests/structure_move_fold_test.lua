-- Moving a subtree up/down must carry each heading's visual fold state
-- WITH the heading, not leave it pinned to the old line position.  Vim
-- keys expr-fold open/closed state by buffer line, so a raw line swap
-- makes two sibling subtrees exchange fold states (the moved node adopts
-- its neighbor's state and vice-versa).  These tests lock in that the
-- state follows the content.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local structure = require("organ.structure")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function set_up_buf(lines)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'organ.fold'.foldexpr(v:lnum)"
  vim.wo.foldenable = true
  vim.cmd("normal! zX")
  return b
end

local function closed(l)
  return vim.fn.foldclosed(l) == l
end

-- Find the 1-based line of the heading whose title matches `title`.
local function line_of(title)
  for i, txt in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if txt:match("^%*+%s+" .. title .. "%s*$") then
      return i
    end
  end
  return nil
end

-- 1. move_subtree_down: A closed, B open.  After moving A past B, the
--    heading text A must still be closed and B still open (states follow
--    the content, they do not swap by line position).
do
  set_up_buf({ "* A", "body a", "* B", "body b", "* C", "body c" })
  pcall(vim.cmd, "1foldclose") -- A closed
  pcall(vim.cmd, "3foldopen") -- B open
  pcall(vim.cmd, "5foldclose") -- C closed
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  structure.move_subtree_down()
  local a_closed = closed(line_of("A"))
  local b_closed = closed(line_of("B"))
  local c_closed = closed(line_of("C"))
  check(
    "move_down keeps A closed / B open / C closed after swap",
    a_closed and not b_closed and c_closed,
    ("A_closed=%s B_closed=%s C_closed=%s"):format(
      tostring(a_closed),
      tostring(b_closed),
      tostring(c_closed)
    )
  )
end

-- 2. move_subtree_up: symmetric.  B open, C closed; move C up past B.
do
  set_up_buf({ "* A", "body a", "* B", "body b", "* C", "body c" })
  pcall(vim.cmd, "3foldopen") -- B open
  pcall(vim.cmd, "5foldclose") -- C closed
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  structure.move_subtree_up()
  local b_closed = closed(line_of("B"))
  local c_closed = closed(line_of("C"))
  check(
    "move_up keeps C closed / B open after swap",
    c_closed and not b_closed,
    ("C_closed=%s B_closed=%s"):format(tostring(c_closed), tostring(b_closed))
  )
end

-- 3. move_subtree_down with a nested child: A (closed) has a child A1;
--    move A past sibling B (open).  A stays closed at its new position.
do
  set_up_buf({ "* A", "** A1", "body", "* B", "body b" })
  pcall(vim.cmd, "1foldclose") -- A closed (hides A1)
  pcall(vim.cmd, "4foldopen") -- B open
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  structure.move_subtree_down()
  local a_closed = closed(line_of("A"))
  local b_closed = closed(line_of("B"))
  check(
    "move_down keeps closed parent A closed, open B open",
    a_closed and not b_closed,
    ("A_closed=%s B_closed=%s"):format(tostring(a_closed), tostring(b_closed))
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("structure_move_fold_test: PASS")
os.exit(0)
