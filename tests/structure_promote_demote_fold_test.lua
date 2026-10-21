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

-- An editor idles (SafeState) between the user's fold commands and the
-- next edit; headless -l never does.
local function idle()
  require("organ.fold.marks").on_safe_state()
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
  idle()
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
  idle()
  structure.demote_headline({ count = 1 })
  idle()
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
  idle()
  structure.demote_headline({ count = 1 })
  idle()
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
  idle()
  structure.promote_subtree({ count = 1 })
  idle()
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
  idle()
  structure.promote_headline({ count = 1 })
  idle()
  local is_closed_after = vim.fn.foldclosed(1) == 1
  check(
    "promote_headline keeps closed fold closed",
    was_closed_before and is_closed_after,
    ("before=%s after=%s"):format(tostring(was_closed_before), tostring(is_closed_after))
  )
end

-- 5. Demoting a nested heading must not disturb untouched neighbors:
--    the open parent stays open and the closed sibling C stays closed.
--    B joins the closed A, which opens so the edited line stays visible
--    (Emacs shows B too; Vim cannot keep A's own body hidden then).
--    (Regression: demoting `** B` collapsed the whole `* Parent`.)
do
  set_up_buf({
    "* Parent", -- 1
    "** A", -- 2
    "body a", -- 3
    "** B", -- 4  <- demote target
    "body b", -- 5
    "** C", -- 6
    "body c", -- 7
  })
  pcall(vim.cmd, "1foldopen") -- Parent open
  pcall(vim.cmd, "2foldclose") -- A closed
  pcall(vim.cmd, "4foldclose") -- B closed (the demote target)
  pcall(vim.cmd, "6foldclose") -- C closed
  local parent_open_before = vim.fn.foldclosed(1) ~= 1
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  idle()
  structure.demote_headline()
  idle()
  local parent_open_after = vim.fn.foldclosed(1) ~= 1
  local a_closed_after = vim.fn.foldclosed(2) == 2
  local c_closed_after = vim.fn.foldclosed(6) == 6
  check(
    "demote_headline leaves parent open + siblings closed untouched",
    parent_open_before and parent_open_after and not a_closed_after and c_closed_after,
    ("parent_before=%s parent_after=%s A_closed=%s C_closed=%s"):format(
      tostring(parent_open_before),
      tostring(parent_open_after),
      tostring(a_closed_after),
      tostring(c_closed_after)
    )
  )
end

-- 6. promote_subtree must not flip a folded sibling that sits outside the
--    promoted subtree.
do
  set_up_buf({
    "* Parent", -- 1
    "** A", -- 2  <- promote_subtree target
    "body a", -- 3
    "*** A1", -- 4
    "** B", -- 5  <- sibling, closed, must stay closed
    "body b", -- 6
  })
  pcall(vim.cmd, "1foldopen") -- Parent open
  pcall(vim.cmd, "2foldopen") -- A open
  pcall(vim.cmd, "5foldclose") -- B closed
  local b_closed_before = vim.fn.foldclosed(5) == 5
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  idle()
  structure.promote_subtree()
  idle()
  local b_closed_after = vim.fn.foldclosed(5) == 5
  check(
    "promote_subtree leaves untouched sibling B closed",
    b_closed_before and b_closed_after,
    ("B_before=%s B_after=%s"):format(tostring(b_closed_before), tostring(b_closed_after))
  )
end

-- 7. A heading closed-and-buried inside a closed ancestor keeps its own
--    closed state through a demote that joins B to that ancestor: the
--    ancestor opens to show the edited line, and A1 is still folded.
do
  set_up_buf({
    "* Parent", -- 1
    "** A", -- 2
    "*** A1", -- 3  <- closed, then buried under closed A
    "body a1", -- 4
    "** B", -- 5  <- unrelated demote target
    "body b", -- 6
    "** C", -- 7
    "body c", -- 8
  })
  pcall(vim.cmd, "1foldopen") -- Parent open
  pcall(vim.cmd, "3foldclose") -- A1 closed
  pcall(vim.cmd, "2foldclose") -- A closed -> A1 now buried & closed
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  idle()
  structure.demote_headline() -- B: ** -> ***, joins A's subtree
  idle()
  local a_closed_after = vim.fn.foldclosed(2) == 2
  pcall(vim.cmd, "2foldopen") -- reveal A's children
  local a1_closed_after = vim.fn.foldclosed(3) == 3
  check(
    "buried-closed A1 stays closed through a demote into A",
    not a_closed_after and a1_closed_after,
    ("A_closed=%s A1_closed_after_open=%s"):format(
      tostring(a_closed_after),
      tostring(a1_closed_after)
    )
  )
end

-- 8. A folded PROPERTIES drawer inside a promoted subtree keeps its
--    folded state through the star rewrite.
do
  set_up_buf({
    "** A", -- 1  <- promote_subtree target
    ":PROPERTIES:", -- 2  <- folded drawer, must stay folded
    ":ID: x", -- 3
    ":END:", -- 4
    "body a", -- 5
    "** B", -- 6
  })
  vim.cmd("normal! zX")
  pcall(vim.cmd, "2foldclose") -- drawer folded
  local drawer_closed_before = vim.fn.foldclosed(2) == 2
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  idle()
  structure.promote_subtree() -- ** A -> * A
  idle()
  local drawer_closed_after = vim.fn.foldclosed(2) == 2
  check(
    "promote_subtree keeps a folded PROPERTIES drawer folded",
    drawer_closed_before and drawer_closed_after,
    ("before=%s after=%s"):format(tostring(drawer_closed_before), tostring(drawer_closed_after))
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
