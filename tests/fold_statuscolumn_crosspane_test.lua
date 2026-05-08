-- Cross-pane statuscolumn: when window A is unfocused and B is focused,
-- evaluating A's statuscolumn must use A's cursor for the relative-
-- number, not B's.  Vim's docs claim eval context switches to the
-- rendering window, but in practice (verified via nvim_eval_statusline)
-- `nvim_get_current_*` and `vim.fn.line('.')` keep returning the
-- focused window's values.  Only `v:lnum` / `v:relnum` are set
-- correctly per rendering window.
--
-- Contract: organ's auto-applied statuscolumn computes relnum from
-- v:relnum, NOT from `vim.fn.line('.') - lnum`.  This test asserts
-- the rendered relnum for an unfocused window's statuscolumn matches
-- what vim's `v:relnum` reports -- proving cross-pane independence.
--
-- Run via: nvim --headless -l tests/fold_statuscolumn_crosspane_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  fold = { auto_statuscolumn = true },
})
local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

local b1 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b1, 0, -1, false, {
  "* H1",
  "  body 1",
  "* H2",
  "  body 2",
  "* H3",
  "  body 3",
  "* H4",
  "  body 4",
})
local b2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, {
  "* B1",
  "  body B1",
  "* B2",
})

vim.cmd("vsplit")
local wins = vim.api.nvim_list_wins()
local wA, wB = wins[2], wins[1]
vim.api.nvim_win_set_buf(wA, b1)
vim.api.nvim_win_set_buf(wB, b2)
vim.bo[b1].filetype = "org"
vim.bo[b2].filetype = "org"
for _, w in ipairs({ wA, wB }) do
  vim.api.nvim_set_option_value("number", true, { win = w })
  vim.api.nvim_set_option_value("relativenumber", true, { win = w })
  vim.api.nvim_set_option_value("statuscolumn", "%!v:lua._organ_statuscolumn()", { win = w })
end

-- A's cursor on L6, B's cursor on L1.  Focus B.
vim.api.nvim_set_current_win(wA)
vim.api.nvim_win_set_cursor(wA, { 6, 0 })
vim.api.nvim_set_current_win(wB)
vim.api.nvim_win_set_cursor(wB, { 1, 0 })

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- For each line in A, render A's statuscolumn (B is focused).  The
-- relnum slot must show A's distance from L6, NOT B's distance from
-- L1.
local function render_relnum(winid, lnum)
  local r = vim.api.nvim_eval_statusline(
    "%!v:lua._organ_statuscolumn()",
    { winid = winid, use_statuscol_lnum = lnum }
  )
  local n = (r.str or ""):match("(%d+)")
  return tonumber(n)
end

-- A.cursor=6.  Expected relnums per buffer line (`v:relnum`-style):
--   L1 -> 5,  L2 -> 4,  L3 -> 3,  L4 -> 2,  L5 -> 1,
--   L6 -> 6 (cursor: hybrid mode shows absolute lnum),
--   L7 -> 1,  L8 -> 2.
local expected = { [1] = 5, [2] = 4, [3] = 3, [4] = 2, [5] = 1, [6] = 6, [7] = 1, [8] = 2 }
for ln, want in pairs(expected) do
  local got = render_relnum(wA, ln)
  check(
    ("wA L%d relnum = %d (focused window is wB)"):format(ln, want),
    got == want,
    ("got %s"):format(tostring(got))
  )
end

-- And B's own statuscolumn on its lines.  B.cursor=1.  Hybrid:
--   L1 -> 1, L2 -> 1, L3 -> 2.
local expected_B = { [1] = 1, [2] = 1, [3] = 2 }
for ln, want in pairs(expected_B) do
  local got = render_relnum(wB, ln)
  check(("wB L%d relnum = %d"):format(ln, want), got == want, ("got %s"):format(tostring(got)))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_statuscolumn_crosspane_test: PASS")
