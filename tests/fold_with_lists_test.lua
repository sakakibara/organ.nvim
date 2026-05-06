-- The foldexpr's two passes produce the right levels for a buffer
-- that mixes lists, drawers, and blocks under headings.  Lists are
-- NOT outline elements — they inherit the parent heading's level
-- and don't get their own fold.  Drawers / blocks DO get their own
-- sub-fold (one level deeper than the surrounding heading) so that
-- close_all_drawers and S-Tab on a drawer line can target them.
--
-- Run via: nvim --headless -l tests/fold_with_lists_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local fold = require("organ.fold")

-- Build a sample buffer mirroring the user's repro file: headlines
-- at multiple levels, lists nested inside sections, property
-- drawers.  The foldexpr must return ">N" for each headline line
-- and the level number for body lines.
local lines = {
  "* Active", -- 1: level-1 heading
  "** TODO Item with list", -- 2: level-2 heading
  ":PROPERTIES:", -- 3: drawer (body of level-2)
  ":Effort: 2:00", -- 4: drawer
  ":END:", -- 5: drawer
  "- [ ] First", -- 6: list item (body of level-2)
  "- [ ] Second", -- 7: list item
  "1. Numbered", -- 8: ordered list
  "2. List", -- 9: ordered list
  "** TODO Sibling", -- 10: level-2 heading (closes prev fold)
  "Body of sibling.", -- 11: body of level-2
  "* Recurring", -- 12: level-1 heading
  "** NEXT Water plants", -- 13: level-2
  "- [ ] Habit checkbox", -- 14: list item
  "*** TODO Sub-task", -- 15: level-3 heading
  "Body.", -- 16: body of level-3
}

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
vim.bo[b].filetype = "org"

local levels = fold._build_fold_levels(b)

-- Default `fold.body_fold = false`: body lines share their parent
-- heading's level, so the whole subtree is one fold and `za` on body
-- folds the heading.  Drawers / blocks bump one further than their
-- enclosing heading via the treesitter pass.
local expected = {
  [1] = ">1", -- * Active
  [2] = ">2", -- ** TODO Item with list
  [3] = ">3", -- :PROPERTIES: (drawer sub-fold = parent heading level + 1)
  [4] = "3", -- :Effort: 2:00
  [5] = "3", -- :END:
  [6] = "2", -- list item: body of H2 at heading level
  [7] = "2",
  [8] = "2",
  [9] = "2",
  [10] = ">2", -- ** TODO Sibling
  [11] = "2", -- body of Sibling
  [12] = ">1", -- * Recurring
  [13] = ">2",
  [14] = "2", -- body of Water plants
  [15] = ">3", -- *** TODO Sub-task
  [16] = "3", -- body of Sub-task
}

for i = 1, #lines do
  check(
    ("line %d (`%s`): foldexpr = %q"):format(i, lines[i]:sub(1, 30), expected[i]),
    levels[i] == expected[i],
    ("got %q"):format(tostring(levels[i]))
  )
end

-- Cache invalidation: editing the buffer must rebuild the level
-- map.  foldexpr() reads `nvim_get_current_buf()` per the Neovim
-- foldexpr contract, so we make `b` current before invoking.
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, 1, false, { "* Different heading 1" })
local levels2 = {}
for i = 1, vim.api.nvim_buf_line_count(b) do
  levels2[i] = fold.foldexpr(i)
end
check(
  "post-edit cache invalidation: foldexpr re-evaluated",
  levels2[1] == ">1" and levels2[12] == ">1",
  vim.inspect(levels2)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_with_lists_test: PASS")
