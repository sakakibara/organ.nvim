-- Emacs parity: `org-odd-levels-only` headline promote/demote step.
--
-- When `org-odd-levels-only = t`, every promote / demote step bumps
-- the star count by 2 instead of 1 so the heading always lands on
-- an odd valid level (`*`, `***`, `*****`, ...).  Off (default),
-- step is 1 as normal.
--
-- Our implementation: `structure.odd_levels_only` config knob; the
-- promote/demote functions in lua/organ/structure.lua read it and
-- adjust the step.  Note: the tree-sitter grammar still treats `**`
-- as a level-2 heading regardless of this setting -- the knob only
-- affects the promote/demote (and move) ops.  Full parser-side
-- coverage of odd-levels-only is out of scope for this commit.
--
-- Run via: nvim --headless -l tests/parity_odd_levels_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parity = dofile(root .. "/tests/_emacs_parity.lua")
parity.skip_if_no_emacs()

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local structure = require("organ.structure")

local function with_setup(odd_only)
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    watcher = { enabled = false },
    structure = { odd_levels_only = odd_only },
  })
end

local function our_op(op, input, odd_only)
  with_setup(odd_only)
  local stripped, cursor = parity.parse_cursor(input)
  local b = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(stripped, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, cursor)
  if op == "heading-demote" then
    structure.demote_headline({ bufnr = b, line = cursor[1] })
  elseif op == "heading-promote" then
    structure.promote_headline({ bufnr = b, line = cursor[1] })
  else
    error("unknown op: " .. op)
  end
  local out_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.api.nvim_buf_delete(b, { force = true })
  return table.concat(out_lines, "\n") .. "\n"
end

-- Setup uses `setq-default` + `setq` because `setq-local` doesn't apply
-- early enough: the buffer is recreated by `with-temp-buffer` inside
-- the op runner, and `setq-local` on the global buffer wouldn't carry
-- over to the new temp buffer.  `setq-default` sets the global value,
-- which the new temp buffer inherits at org-mode init.
local setup_off = "(setq-default org-odd-levels-only nil) (setq org-odd-levels-only nil)"
local setup_on = "(setq-default org-odd-levels-only t) (setq org-odd-levels-only t)"

-- Default (step=1).
do
  local input = "* <CURSOR>Heading\n"
  local em = parity.run_with_setup("heading-demote", input, setup_off)
  local us = our_op("heading-demote", input, false)
  check("default demote `*` -> `**`", em == us, string.format("emacs=%q\n     ours= %q", em, us))
end
do
  local input = "*** <CURSOR>Heading\n"
  local em = parity.run_with_setup("heading-promote", input, setup_off)
  local us = our_op("heading-promote", input, false)
  check("default promote `***` -> `**`", em == us, string.format("emacs=%q\n     ours= %q", em, us))
end

-- odd-levels-only (step=2).
do
  local input = "* <CURSOR>Heading\n"
  local em = parity.run_with_setup("heading-demote", input, setup_on)
  local us = our_op("heading-demote", input, true)
  check(
    "odd-levels demote `*` -> `***` (step by 2)",
    em == us,
    string.format("emacs=%q\n     ours= %q", em, us)
  )
end
do
  local input = "*** <CURSOR>Heading\n"
  local em = parity.run_with_setup("heading-promote", input, setup_on)
  local us = our_op("heading-promote", input, true)
  check(
    "odd-levels promote `***` -> `*` (step by 2)",
    em == us,
    string.format("emacs=%q\n     ours= %q", em, us)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("parity_odd_levels_test: PASS")
