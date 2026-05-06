-- fold.cycle(bufnr, line) advances 3-state on a headline; falls back to za
-- on non-headline lines.
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

-- Cursor on line 1 ("* Top"), first cycle: children folded (sub one, sub two
-- collapse but their headline lines remain visible).
vim.api.nvim_win_set_cursor(0, { 1, 0 })
fold.cycle(b, 1)
-- After "children folded", line 4 (body of sub one) should be inside a
-- closed fold whose start is line 3 ("** Sub one").
assert(
  vim.fn.foldclosed(4) == 3,
  "expected line 4 in fold starting at line 3; got " .. vim.fn.foldclosed(4)
)

-- Second cycle: subtree open (everything visible).
fold.cycle(b, 1)
assert(
  vim.fn.foldclosed(4) == -1,
  "expected line 4 not folded after cycle to subtree; got " .. vim.fn.foldclosed(4)
)

-- Third cycle: folded (entire Top + descendants collapsed).
fold.cycle(b, 1)
assert(
  vim.fn.foldclosed(4) == 1,
  "expected line 4 in fold starting at line 1; got " .. vim.fn.foldclosed(4)
)

-- Fourth cycle: back to "children folded".
fold.cycle(b, 1)
assert(vim.fn.foldclosed(4) == 3, "cycle should wrap; got " .. vim.fn.foldclosed(4))

-- Non-headline line: should fall back to za toggle (no error).
local ok, err = pcall(fold.cycle, b, 4)
assert(ok, "cycle on non-headline raised: " .. tostring(err))

io.write("fold cycle ok\n")
os.exit(0)
