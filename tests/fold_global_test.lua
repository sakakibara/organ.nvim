-- fold.cycle_global(bufnr) cycles foldlevel in Emacs `org-shifttab`
-- order:  SHOW_ALL -> OVERVIEW -> CONTENTS -> SHOW_ALL.
--
-- foldlevel mapping (with body lines at heading_depth + 1):
--   SHOW_ALL  foldlevel = 99 (or any value >= max_heading_depth + 1)
--   OVERVIEW  foldlevel = 0  (top-level headings show as fold heads)
--   CONTENTS  foldlevel = max_heading_depth (every heading line, no body)
--
-- Run via: nvim --headless -l tests/fold_global_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Empty buffer: max_heading_depth = 0, treated as 1 by cycle_global.
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(b)
local fold = require("organ.fold")

-- Empty buffer (md=1).  Cycle: 99 -> 0 (OVERVIEW) -> 1 (CONTENTS=md=1) -> 99 ...
vim.wo.foldlevel = 99
fold.cycle_global(b)
assert(vim.wo.foldlevel == 0, "99 -> OVERVIEW(0); got " .. vim.wo.foldlevel)
fold.cycle_global(b)
assert(vim.wo.foldlevel == 1, "0 -> CONTENTS(md=1); got " .. vim.wo.foldlevel)
fold.cycle_global(b)
assert(vim.wo.foldlevel == 99, "md -> SHOW_ALL; got " .. vim.wo.foldlevel)

-- A buffer with deepest depth 3: cycle uses md=3 for CONTENTS.
do
  local tmp = vim.fn.tempname() .. ".org"
  vim.fn.writefile({
    "* H1",
    "** H2",
    "*** H3",
    "body",
  }, tmp)
  vim.cmd("edit " .. tmp)
  vim.bo.filetype = "org"
  local buf = vim.api.nvim_get_current_buf()
  assert(fold._max_heading_depth(buf) == 3, "max_heading_depth should be 3")

  vim.wo.foldlevel = 99
  fold.cycle_global(buf)
  assert(vim.wo.foldlevel == 0, "SHOW_ALL -> OVERVIEW(0); got " .. vim.wo.foldlevel)
  fold.cycle_global(buf)
  assert(vim.wo.foldlevel == 3, "OVERVIEW(0) -> CONTENTS(md=3); got " .. vim.wo.foldlevel)
  fold.cycle_global(buf)
  assert(vim.wo.foldlevel == 99, "CONTENTS -> SHOW_ALL; got " .. vim.wo.foldlevel)

  -- Non-canonical starting foldlevel always lands on OVERVIEW first
  -- so the user always sees a visible change on the first S-Tab even
  -- when post-`zR` set foldlevel to some intermediate depth.
  for _, start in ipairs({ 2, 5, 99 }) do
    vim.wo.foldlevel = start
    fold.cycle_global(buf)
    assert(
      vim.wo.foldlevel == 0,
      string.format("from foldlevel=%d expected -> OVERVIEW(0); got %d", start, vim.wo.foldlevel)
    )
  end

  -- S-Tab cycles globally regardless of cursor position; sitting
  -- inside a drawer must not redirect to a per-drawer toggle.
  vim.fn.writefile({
    "* Heading",
    ":PROPERTIES:",
    ":STYLE: habit",
    ":END:",
  }, tmp)
  vim.cmd("edit " .. tmp)
  vim.bo.filetype = "org"
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.wo.foldlevel = 99
  fold.cycle_global(vim.api.nvim_get_current_buf())
  assert(
    vim.wo.foldlevel == 0,
    "S-Tab on a drawer line should still global-cycle; got " .. vim.wo.foldlevel
  )
  vim.fn.delete(tmp)
end

io.write("fold global ok\n")
os.exit(0)
