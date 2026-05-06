-- Property drawers (PROPERTIES, LOGBOOK, etc.) must stay folded
-- across the global Shift-Tab cycle, mirroring Emacs's `org-cycle-
-- hide-drawers` behavior.  Pressing Shift-Tab repeatedly cycles
-- outline visibility but leaves drawers collapsed.  Only Tab on a
-- drawer line opens it.
--
-- Run via: nvim --headless -l tests/fold_drawer_stays_closed_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local parser_path = require("organ.defaults").parser_path
local indexer = require("organ.indexer")
vim.treesitter.language.add("org", { path = parser_path })
vim.treesitter.language.add("org_inline", { path = indexer._inline_parser_path(parser_path) })

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* Heading 1",
  ":PROPERTIES:",
  ":ID: known-id-1",
  ":END:",
  "Body text 1.",
  "* Heading 2",
  ":PROPERTIES:",
  ":CATEGORY: Tasks",
  ":END:",
  "Body text 2.",
})
vim.bo[b].filetype = "org"
vim.wo.foldmethod = "expr"
vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
vim.wo.foldlevel = 99
-- Force a parse so foldexpr returns sensible levels.
local parser = vim.treesitter.get_parser(b, "org")
parser:parse()
vim.cmd("normal! zx") -- recompute folds

local fold = require("organ.fold")
fold.close_all_drawers(b)
vim.wait(50, function()
  return false
end) -- yield so any scheduled work runs

local function drawer_closed_at(line)
  -- foldclosed returns the start line of the closed fold, or -1 if open.
  return vim.fn.foldclosed(line) ~= -1
end

-- Initially: outline open, drawers closed.
check("initial state: drawer-1 closed (line 2)", drawer_closed_at(2))
check("initial state: drawer-2 closed (line 7)", drawer_closed_at(7))

-- Cycle: foldlevel 99 → 1.  Drawers must remain closed.
fold.cycle_global(b)
vim.wait(50, function()
  return false
end)
check("after cycle 1 (foldlevel=1): drawer-1 still closed", drawer_closed_at(2))
check("after cycle 1 (foldlevel=1): drawer-2 still closed", drawer_closed_at(7))

-- Cycle: foldlevel 1 → 0.  Drawers still closed (they're inside
-- folds anyway, but the cycle shouldn't break the rule).
fold.cycle_global(b)
vim.wait(50, function()
  return false
end)
check("after cycle 2 (foldlevel=0): drawer-1 still closed", drawer_closed_at(2))

-- Cycle: foldlevel 0 → 99.  Outline opens fully — drawers MUST stay
-- closed (this was the user-reported bug).
fold.cycle_global(b)
vim.wait(50, function()
  return false
end)
check("after cycle 3 (foldlevel=99, outline open): drawer-1 STILL closed", drawer_closed_at(2))
check("after cycle 3 (foldlevel=99, outline open): drawer-2 STILL closed", drawer_closed_at(7))

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_drawer_stays_closed_test: PASS")
