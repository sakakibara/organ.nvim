-- fold.cycle(bufnr, line) advances 3-state on a headline; falls back to za
-- on non-headline lines.  Mirrors Emacs `org-cycle`: the cycle starts
-- from the heading's CURRENT visual state, not from a stale cache.  With
-- the buffer freshly opened in showall (everything visible = SUBTREE),
-- the first Tab folds it (SUBTREE -> FOLDED), the next shows children
-- (FOLDED -> CHILDREN), the next reveals the subtree (CHILDREN -> SUBTREE).
-- Run via: nvim --headless -l tests/fold_cycle_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

-- Prepare a fixture buffer with nested headlines.
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* Top", -- 1
  "Body of top.", -- 2
  "** Sub one", -- 3
  "Body of sub one.", -- 4
  "*** Deep", -- 5
  "Body of deep.", -- 6
  "** Sub two", -- 7
  "Body of sub two.", -- 8
})
vim.api.nvim_buf_set_option(b, "filetype", "org")
vim.api.nvim_set_current_buf(b)

-- Attach parser and set fold options.
local parser = vim.treesitter.get_parser(b, "org")
parser:parse()
vim.wo.foldmethod = "expr"
vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
vim.wo.foldenable = true
vim.wo.foldlevel = 99

local fold = require("organ.fold")

-- Force fold recompute.
vim.cmd("normal! zx")

-- Cursor on line 1 ("* Top").  Buffer is in showall (foldlevel=99) so
-- the heading's visual state is SUBTREE; first cycle folds it.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
fold.cycle(b, 1)
-- After SUBTREE -> FOLDED, line 4 (body of sub one) should be inside
-- a closed fold whose start is line 1 ("* Top").
assert(
  vim.fn.foldclosed(4) == 1,
  "expected line 4 in fold starting at line 1; got " .. vim.fn.foldclosed(4)
)

-- Second cycle: FOLDED -> CHILDREN (sub headings visible, deeper hidden).
fold.cycle(b, 1)
assert(
  vim.fn.foldclosed(4) == 3,
  "expected line 4 in fold starting at line 3; got " .. vim.fn.foldclosed(4)
)

-- Third cycle: CHILDREN -> SUBTREE (everything visible).
fold.cycle(b, 1)
assert(
  vim.fn.foldclosed(4) == -1,
  "expected line 4 not folded after cycle to subtree; got " .. vim.fn.foldclosed(4)
)

-- Fourth cycle: SUBTREE -> FOLDED (wraps).
fold.cycle(b, 1)
assert(
  vim.fn.foldclosed(4) == 1,
  "expected line 4 in fold starting at line 1 after wrap; got " .. vim.fn.foldclosed(4)
)

-- Non-headline line: should fall back to za toggle (no error).
local ok, err = pcall(fold.cycle, b, 4)
assert(ok, "cycle on non-headline raised: " .. tostring(err))

-- Scoping: Tab on a level-2 heading must fold ONLY that heading's
-- subtree.  Mirrors Emacs `org-cycle`: <Tab> is per-heading (this
-- subtree only); <S-Tab> is the global cycle.  Earlier code used
-- `:{r1},{r2}foldclose!` -- the bang in vim means "also close parent
-- folds" (zC-like), so a Tab on `** L2 a` collapsed its enclosing
-- `* L1` subtree too, visually identical to a global S-Tab.
do
  local b2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b2, 0, -1, false, {
    "* L1 A", -- 1
    "** L2 a", -- 2
    "body a", -- 3
    "** L2 b", -- 4
    "body b", -- 5
    "* L1 B", -- 6
    "body B", -- 7
  })
  vim.api.nvim_buf_set_option(b2, "filetype", "org")
  vim.api.nvim_set_current_buf(b2)
  vim.treesitter.get_parser(b2, "org"):parse()
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
  vim.wo.foldenable = true
  vim.wo.foldlevel = 99
  vim.cmd("normal! zx")

  -- Tab on `** L2 a` (line 2): SUBTREE -> FOLDED on L2 a only.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  fold.cycle(b2, 2)
  -- L2 a's subtree (lines 2-3) must be inside a fold STARTING at line 2,
  -- not at line 1 (which would mean the L1 A fold also closed).
  assert(
    vim.fn.foldclosed(2) == 2,
    "Tab on L2 a: L2 a should be the start of its own closed fold; foldclosed(2)="
      .. vim.fn.foldclosed(2)
  )
  assert(
    vim.fn.foldclosed(3) == 2,
    "Tab on L2 a: body a (line 3) should be inside L2 a's fold; foldclosed(3)="
      .. vim.fn.foldclosed(3)
  )
  -- L1 A (line 1), L2 b (line 4), L1 B (line 6) must all stay open.
  assert(
    vim.fn.foldclosed(1) == -1,
    "Tab on L2 a should NOT close enclosing L1 A; foldclosed(1)=" .. vim.fn.foldclosed(1)
  )
  assert(
    vim.fn.foldclosed(4) == -1,
    "Tab on L2 a should NOT close sibling L2 b; foldclosed(4)=" .. vim.fn.foldclosed(4)
  )
  assert(
    vim.fn.foldclosed(6) == -1,
    "Tab on L2 a should NOT close unrelated L1 B; foldclosed(6)=" .. vim.fn.foldclosed(6)
  )
end

io.write("fold cycle ok\n")
os.exit(0)
