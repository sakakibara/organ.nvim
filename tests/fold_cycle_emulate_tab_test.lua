-- Emacs-parity for `org-cycle` (<Tab>) on NON-headline lines, ground-truthed
-- against GNU Emacs 30.1 / org 9.7.11.  The governing knob is
-- `fold.cycle_emulate_tab`, mirroring Emacs `org-cycle-emulate-tab`:
--
--   true  (default, = Emacs `t`):   <Tab> on a body/blank line does NOT
--         fold.  Emacs emulates TAB (indent); in nvim normal mode the
--         analog is "let <Tab> do its native job" (<C-i>), so cycle()
--         reports "not handled" and the keymap passes the key through.
--   false (= Emacs `nil`):          <Tab> on a body line folds/cycles
--         the ENCLOSING heading's subtree.
--
-- Run via: nvim --headless -l tests/fold_cycle_emulate_tab_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

local fold = require("organ.fold")
local buf_config = require("organ.buf_config")

local function make(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(b, "filetype", "org")
  vim.api.nvim_set_current_buf(b)
  vim.treesitter.get_parser(b, "org"):parse()
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
  vim.wo.foldenable = true
  vim.wo.foldlevel = 99
  vim.cmd("normal! zx")
  return b
end

-- Default (emulate_tab = true): <Tab> on a body line must NOT fold, and must
-- report "not handled" so the keymap can pass through to native <Tab>/<C-i>.
-- Emacs scenario C: buffer + folding unchanged.
do
  local b = make({ "* Top", "Body of top.", "** Sub", "sub body" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local handled = fold.cycle(b, 2)
  assert(
    handled == false,
    "default: body-line cycle should report not-handled; got " .. tostring(handled)
  )
  assert(
    vim.fn.foldclosed(2) == -1 and vim.fn.foldclosed(1) == -1,
    "default: <Tab> on a body line must not fold anything; foldclosed(1)="
      .. vim.fn.foldclosed(1)
      .. " foldclosed(2)="
      .. vim.fn.foldclosed(2)
  )
end

-- emulate_tab = false: <Tab> on a body line folds the ENCLOSING subtree.
-- Emacs scenario H: the whole `* Top` subtree folds.
do
  local b = make({ "* Top", "Body of top.", "** Sub", "sub body" })
  buf_config.set(b, "fold.cycle_emulate_tab", false)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local handled = fold.cycle(b, 2)
  assert(
    handled == true,
    "emulate=false: body-line cycle should report handled; got " .. tostring(handled)
  )
  assert(
    vim.fn.foldclosed(2) == 1,
    "emulate=false: body line must fold under enclosing Top (fold starts line 1); foldclosed(2)="
      .. vim.fn.foldclosed(2)
  )
end

-- On a headline line: 3-state cycle is unaffected by the emulate knob and
-- reports "handled".
do
  local b = make({ "* Top", "Body of top.", "** Sub", "sub body" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local handled = fold.cycle(b, 1)
  assert(handled == true, "headline cycle should report handled; got " .. tostring(handled))
  assert(
    vim.fn.foldclosed(2) == 1,
    "headline cycle (subtree->folded) should fold body; foldclosed(2)=" .. vim.fn.foldclosed(2)
  )
end

-- Leaf headline (body, no children): Emacs is a 2-state visible toggle
-- FOLDED <-> SUBTREE (scenario B).  organ's children==subtree collapse for
-- childless headings must reproduce that toggle.
do
  local b = make({ "* Leaf", "Line one.", "Line two.", "* Next" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  fold.cycle(b, 1)
  assert(vim.fn.foldclosed(2) == 1, "leaf #1: should fold; foldclosed(2)=" .. vim.fn.foldclosed(2))
  fold.cycle(b, 1)
  assert(vim.fn.foldclosed(2) == -1, "leaf #2: should show; foldclosed(2)=" .. vim.fn.foldclosed(2))
  fold.cycle(b, 1)
  assert(
    vim.fn.foldclosed(2) == 1,
    "leaf #3: should fold again; foldclosed(2)=" .. vim.fn.foldclosed(2)
  )
end

-- Empty entry (heading, no body, no children): Emacs prints "EMPTY ENTRY"
-- and hides nothing (scenario E).  <Tab> must not error and must not hide
-- the following heading.
do
  local b = make({ "* Empty", "* Next" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local ok = pcall(fold.cycle, b, 1)
  assert(ok, "empty entry: cycle must not error")
  assert(
    vim.fn.foldclosed(2) == -1,
    "empty entry: following heading must stay visible; foldclosed(2)=" .. vim.fn.foldclosed(2)
  )
end

-- Drawer line: <Tab> toggles that drawer (Emacs scenario G) and reports
-- "handled" -- the emulate refactor must not regress the drawer branch.
do
  local b = make({ "* Top", ":PROPERTIES:", ":ID: x", ":END:", "Body." })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local handled = fold.cycle(b, 2)
  assert(handled == true, "drawer cycle should report handled; got " .. tostring(handled))
  assert(
    vim.fn.foldclosed(3) == 2,
    "drawer line: drawer body must fold (fold starts line 2); foldclosed(3)="
      .. vim.fn.foldclosed(3)
  )
  assert(
    vim.fn.foldclosed(1) == -1,
    "drawer line: enclosing heading must stay open; foldclosed(1)=" .. vim.fn.foldclosed(1)
  )
end

io.write("fold cycle emulate-tab ok\n")
os.exit(0)
