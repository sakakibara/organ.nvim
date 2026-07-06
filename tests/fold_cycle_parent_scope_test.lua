-- <Tab> (org-cycle) on a headline must fold ONLY that heading's own
-- subtree, never an enclosing parent -- matching Emacs org-cycle.
--
-- Regression: apply_state's "folded" branch closed a RANGE ending at the
-- tree-sitter `heading:end_()`, which reaches the trailing separator blank
-- after the subtree.  `cycle_separator_lines` demotes that blank to the
-- PARENT's fold level, and a ranged `:{a},{b}foldclose` closes the fold at
-- the shallowest level the range touches -- so vim closed the parent.
-- (The earlier `foldclose!` -> `foldclose` fix only shrank the blast
-- radius from grandparent to parent; it did not remove it.)
--
-- Run via: nvim --headless -l tests/fold_cycle_parent_scope_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})

local fold = require("organ.fold")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function setup(lines)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'organ.fold'.foldexpr(v:lnum)"
  vim.wo.foldminlines = 0
  vim.wo.foldenable = true
  vim.cmd("normal! zR")
  pcall(vim.treesitter.start, b, "org")
  return b
end
local function closed(l)
  return vim.fn.foldclosed(l) == l
end

-- 1. Tab on a level-3 child whose subtree is followed by a separator blank
--    (demoted to the level-2 parent) must fold L3 and leave L2 (and L1)
--    open.
do
  setup({
    "* L1", -- 1
    "body l1", -- 2
    "** L2", -- 3  parent
    "*** L3a", -- 4  <- cycle here
    "body l3a", -- 5
    "", -- 6  separator blank -> level 2
    "*** L3b", -- 7
    "body l3b", -- 8
  })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  fold.cycle(0, 4)
  check(
    "Tab on L3 child folds L3, leaves L2 + L1 open",
    closed(4) and not closed(3) and not closed(1),
    ("L3a_closed=%s L2_closed=%s L1_closed=%s"):format(
      tostring(closed(4)),
      tostring(closed(3)),
      tostring(closed(1))
    )
  )
end

-- 2. The reported case: Tab on a level-2 heading whose subtree is followed
--    by a separator blank (demoted to the level-1 parent) must fold L2 and
--    leave L1 open.
do
  setup({
    "* L1", -- 1  parent
    "** L2a", -- 2  <- cycle here
    "body l2a", -- 3
    "", -- 4  separator blank -> level 1
    "** L2b", -- 5
    "body l2b", -- 6
  })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  fold.cycle(0, 2)
  check(
    "Tab on L2 folds L2, leaves L1 open",
    closed(2) and not closed(1),
    ("L2a_closed=%s L1_closed=%s"):format(tostring(closed(2)), tostring(closed(1)))
  )
end

-- 3. Cycling through all three states never disturbs the parent.
do
  setup({
    "* L1",
    "** L2",
    "*** L3a",
    "body",
    "",
    "*** L3b",
    "body",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local ok = true
  for _ = 1, 4 do
    fold.cycle(0, 3)
    if closed(2) or closed(1) then
      ok = false
      break
    end
  end
  check("cycling L3 through all states never collapses L2/L1", ok)
end

-- 4. The open transitions (children / subtree) must also stay scoped: with
--    separator blanks demoted to the parent level, cycling a MIDDLE child
--    must not disturb its folded siblings or the parent.
do
  setup({
    "* L1", -- 1
    "** L2a", -- 2
    "body a", -- 3
    "", -- 4  sep -> level 1
    "** L2b", -- 5  <- cycle here
    "body b", -- 6
    "", -- 7  sep -> level 1
    "** L2c", -- 8
    "body c", -- 9
  })
  pcall(vim.cmd, "2foldclose") -- L2a folded
  pcall(vim.cmd, "8foldclose") -- L2c folded
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  local ok = true
  for _ = 1, 3 do
    fold.cycle(0, 5) -- folded -> children -> subtree
    if not (closed(2) and closed(8)) or closed(1) then
      ok = false
      break
    end
  end
  check(
    "cycling a middle child never disturbs folded siblings or parent",
    ok,
    ("L2a_closed=%s L2c_closed=%s L1_closed=%s"):format(
      tostring(closed(2)),
      tostring(closed(8)),
      tostring(closed(1))
    )
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_cycle_parent_scope_test: PASS")
os.exit(0)
