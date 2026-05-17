-- cycle-separator-lines (Emacs `org-cycle-separator-lines`): when a
-- section folds, the LAST `min(blanks, max(N, 1))` trailing blanks
-- before the next heading stay visible (outside the section's fold);
-- the rest are hidden with the section.  Behavior probed against
-- Emacs 30.2.
--
-- Default N is 2; verified Emacs values per (blanks, N) below.
--
-- We test by computing foldlevels via our build_fold_levels-driven
-- foldexpr and asserting which lines sit at the section's level
-- (folded with it) vs. the OUTER level (visible after fold).
--
-- Run via: nvim --headless -l tests/fold_cycle_separator_lines_test.lua

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
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Build a fresh org buffer, set cycle_separator_lines via setup, and
-- return the foldexpr level (as string) for each 1-indexed line.
local function fold_levels(lines, N)
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    watcher = { enabled = false },
    fold = { cycle_separator_lines = N },
  })
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  vim.treesitter.get_parser(b, "org"):parse()
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'organ.fold'.foldexpr(v:lnum)"
  vim.wo.foldenable = true
  vim.cmd("normal! zx")
  local out = {}
  for i = 1, #lines do
    out[i] = tostring(vim.fn.foldlevel(i))
  end
  vim.api.nvim_buf_delete(b, { force = true })
  return out
end

-- Cases derived from the Emacs probe in /tmp/probe_sep2.el:
--   * A
--   body
--   <blank>...
--   * B
-- With N total blanks and config K, the LAST min(N, max(K, 1)) blanks
-- are OUTSIDE A's fold (level 0 between two top-level headings).
-- The rest are inside A's fold (level 1).

-- 1 blank: always 1 visible regardless of N.
do
  local lvls = fold_levels({ "* A", "body", "", "* B" }, 0)
  check("1 blank, N=0: blank at level 0 (visible after fold)", lvls[3] == "0", vim.inspect(lvls))
end
do
  local lvls = fold_levels({ "* A", "body", "", "* B" }, 2)
  check("1 blank, N=2: blank at level 0 (visible after fold)", lvls[3] == "0", vim.inspect(lvls))
end

-- 2 blanks: N=0 keeps 1 visible (last), N=2 keeps 2 visible.
do
  local lvls = fold_levels({ "* A", "body", "", "", "* B" }, 0)
  check(
    "2 blanks, N=0: first hidden (lvl 1), last visible (lvl 0)",
    lvls[3] == "1" and lvls[4] == "0",
    vim.inspect(lvls)
  )
end
do
  local lvls = fold_levels({ "* A", "body", "", "", "* B" }, 2)
  check("2 blanks, N=2: both visible (lvl 0)", lvls[3] == "0" and lvls[4] == "0", vim.inspect(lvls))
end

-- 5 blanks, N=2: last 2 visible, first 3 hidden.
do
  local lvls = fold_levels({ "* A", "body", "", "", "", "", "", "* B" }, 2)
  check(
    "5 blanks, N=2: first 3 hidden (lvl 1), last 2 visible (lvl 0)",
    lvls[3] == "1" and lvls[4] == "1" and lvls[5] == "1" and lvls[6] == "0" and lvls[7] == "0",
    vim.inspect(lvls)
  )
end

-- 5 blanks, N=5: all 5 visible.
do
  local lvls = fold_levels({ "* A", "body", "", "", "", "", "", "* B" }, 5)
  check(
    "5 blanks, N=5: all 5 visible (lvl 0)",
    lvls[3] == "0" and lvls[4] == "0" and lvls[5] == "0" and lvls[6] == "0" and lvls[7] == "0",
    vim.inspect(lvls)
  )
end

-- Disabled (false): every trailing blank stays with the section.
do
  local lvls = fold_levels({ "* A", "body", "", "", "* B" }, false)
  check(
    "N=false: all trailing blanks stay at section level (lvl 1)",
    lvls[3] == "1" and lvls[4] == "1",
    vim.inspect(lvls)
  )
end

-- Nested: separator between two L=2 inside an L=1 should be at L=1
-- (still inside parent, but outside the L=2 fold).
do
  local lvls = fold_levels({ "* L1", "** A", "body", "", "", "** B", "body B" }, 2)
  check(
    "nested L=2 siblings inside L=1: separator at parent level (1), not 0",
    lvls[4] == "1" and lvls[5] == "1",
    vim.inspect(lvls)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_cycle_separator_lines_test: PASS")
