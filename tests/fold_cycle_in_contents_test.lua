-- <Tab> on a heading while the CONTENTS global view is active must reveal
-- that heading (its body is hidden by a conceal_lines extmark, not a fold),
-- NOT run the fold-based 3-state cycle.  The fold cycle reads foldclosed(),
-- which is -1 in CONTENTS state, so it mis-detects "subtree" and collapses
-- the heading instead of expanding it -- the "S-Tab then Tab doesn't
-- expand" bug.  `za` already routes to the contents toggle; Tab must too.
--
-- Run via: nvim --headless -l tests/fold_cycle_in_contents_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})

local fold = require("organ.fold")
local contents = require("organ.fold.contents")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function setup()
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* A", -- 1
    "body a1", -- 2
    "body a2", -- 3
    "** A1", -- 4
    "body a1x", -- 5
    "* B", -- 6
    "body b1", -- 7
  })
  vim.bo[b].filetype = "org"
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'organ.fold'.foldexpr(v:lnum)"
  vim.wo.foldenable = true
  vim.wo.foldlevel = 99
  pcall(vim.treesitter.start, b, "org")
  return b
end

local win = vim.api.nvim_get_current_win

do
  local b = setup()
  -- S-Tab x2: show_all -> overview -> content (CONTENTS).
  fold.cycle_global(b)
  fold.cycle_global(b)
  check("reached CONTENTS state", fold.detect_global_state(win(), b) == "content")
  check("heading A body concealed by CONTENTS", contents.heading_concealed(b, 1))

  -- Tab on A must REVEAL it, not collapse it.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  fold.cycle(b, 1)
  check(
    "Tab on A in CONTENTS reveals the heading",
    not contents.heading_concealed(b, 1),
    "A still concealed after Tab"
  )
  check(
    "Tab on A in CONTENTS did not fold it",
    vim.fn.foldclosed(1) == -1,
    "foldclosed(1)=" .. vim.fn.foldclosed(1)
  )

  -- A second Tab re-conceals (toggle), matching the CONTENTS `za` behavior.
  fold.cycle(b, 1)
  check("second Tab re-conceals A", contents.heading_concealed(b, 1))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_cycle_in_contents_test: PASS")
os.exit(0)
