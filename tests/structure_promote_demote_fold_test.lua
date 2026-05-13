-- Promote / demote should preserve the visual fold state of each
-- affected headline.  If a heading was folded before, it stays folded;
-- if it was open, it stays open.  Applies to both single-headline ops
-- (promote_headline / demote_headline) and subtree ops
-- (promote_subtree / demote_subtree).

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
  -- Force foldexpr evaluation across the buffer so foldclosed() is meaningful.
  vim.cmd("normal! zX")
  return b
end

-- 1. demote_headline preserves an open headline's open state.
do
  set_up_buf({
    "* Parent",
    "body of parent",
    "** Child",
    "body of child",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  pcall(vim.cmd, "1foldopen")
  local was_closed_before = vim.fn.foldclosed(1) == 1
  structure.demote_headline({ count = 1 })
  local is_closed_after = vim.fn.foldclosed(1) == 1
  check(
    "demote_headline keeps open fold open",
    (not was_closed_before) and not is_closed_after,
    ("before=%s after=%s"):format(tostring(was_closed_before), tostring(is_closed_after))
  )
end

-- 2. demote_headline preserves a closed headline's closed state.
do
  set_up_buf({
    "* Parent",
    "body of parent",
    "* Sibling",
    "body of sibling",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  pcall(vim.cmd, "1foldclose")
  local was_closed_before = vim.fn.foldclosed(1) == 1
  structure.demote_headline({ count = 1 })
  local is_closed_after = vim.fn.foldclosed(1) == 1
  check(
    "demote_headline keeps closed fold closed",
    was_closed_before and is_closed_after,
    ("before=%s after=%s"):format(tostring(was_closed_before), tostring(is_closed_after))
  )
end

-- 3. promote_subtree preserves nested folds (parent open, child closed).
do
  set_up_buf({
    "** Parent",
    "body of parent",
    "*** Child",
    "body of child",
    "*** Other",
    "body of other",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  pcall(vim.cmd, "1foldopen")
  pcall(vim.cmd, "3foldclose")
  local parent_closed_before = vim.fn.foldclosed(1) == 1
  local child_closed_before = vim.fn.foldclosed(3) == 3
  structure.promote_subtree({ count = 1 })
  local parent_closed_after = vim.fn.foldclosed(1) == 1
  local child_closed_after = vim.fn.foldclosed(3) == 3
  check(
    "promote_subtree preserves parent open + child closed",
    not parent_closed_before
      and not parent_closed_after
      and child_closed_before
      and child_closed_after,
    ("p_before=%s p_after=%s c_before=%s c_after=%s"):format(
      tostring(parent_closed_before),
      tostring(parent_closed_after),
      tostring(child_closed_before),
      tostring(child_closed_after)
    )
  )
end

-- 4. promote_headline (single-line op) on closed headline keeps it closed.
do
  set_up_buf({
    "** Parent",
    "body",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  pcall(vim.cmd, "1foldclose")
  local was_closed_before = vim.fn.foldclosed(1) == 1
  structure.promote_headline({ count = 1 })
  local is_closed_after = vim.fn.foldclosed(1) == 1
  check(
    "promote_headline keeps closed fold closed",
    was_closed_before and is_closed_after,
    ("before=%s after=%s"):format(tostring(was_closed_before), tostring(is_closed_after))
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("structure_promote_demote_fold_test: PASS")
os.exit(0)
