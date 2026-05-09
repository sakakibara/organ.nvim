-- Cross-pane statuscolumn fold-marker: when window A is unfocused and
-- window B is focused (both showing the same buffer with INDEPENDENT
-- fold open/closed state), asking the marker function for window A's
-- chevron must reflect window A's fold state, not the focused window's.
--
-- vim.fn.foldclosed / foldlevel are window-local; during statuscolumn
-- eval the rendering-window context is NOT switched (only v:lnum /
-- v:relnum are rendering-window-correct), so a naive call reads the
-- FOCUSED window's fold state and returns the wrong chevron.  The
-- contract: passing { winid = w } switches context to that window for
-- the fold reads via nvim_win_call.
--
-- Run via: nvim --headless -l tests/fold_statuscolumn_crosspane_marker_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  fold = { auto_statuscolumn = false },
})
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* H1",
  "  body 1",
  "  body 2",
  "* H2",
  "  body 3",
})
vim.bo[b].filetype = "org"
vim.cmd("doautocmd FileType")

vim.cmd("vsplit")
local wins = vim.api.nvim_list_wins()
local wA, wB = wins[2], wins[1]
vim.api.nvim_win_set_buf(wA, b)
vim.api.nvim_win_set_buf(wB, b)

-- Re-fire FileType in each window so win-local fold options (foldmethod,
-- foldexpr) are applied in BOTH panes.
for _, w in ipairs({ wA, wB }) do
  vim.api.nvim_set_current_win(w)
  vim.cmd("doautocmd FileType")
  vim.cmd("normal! zR")
end

-- wA: close the H1 fold at L1.  wB: leave open.
vim.api.nvim_set_current_win(wA)
vim.api.nvim_win_set_cursor(wA, { 1, 0 })
vim.cmd("normal! zc")

-- Focus wB so the cross-pane case is exercised.
vim.api.nvim_set_current_win(wB)

-- Sanity: per-window fold state actually differs.
local closed_in_wA = vim.api.nvim_win_call(wA, function()
  return vim.fn.foldclosed(1)
end)
local closed_in_wB = vim.api.nvim_win_call(wB, function()
  return vim.fn.foldclosed(1)
end)
assert(
  closed_in_wA == 1,
  "setup precondition failed: wA L1 should be in closed fold (got " .. tostring(closed_in_wA) .. ")"
)
assert(
  closed_in_wB == -1,
  "setup precondition failed: wB L1 should be open (got " .. tostring(closed_in_wB) .. ")"
)

local fillchars = vim.opt.fillchars:get()
local close_ch = fillchars.foldclose or ">"
local open_ch = fillchars.foldopen or "v"

-- Strip the highlight wrapping for assertions on the underlying char.
local function chr(s)
  return (s:gsub("%%#[^#]+#", ""):gsub("%%%*", ""))
end

local fold = require("organ.fold")
local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local m_wA = chr(fold.statuscolumn_marker(1, { winid = wA }))
check(
  "wA L1 marker (focused=wB) reflects wA's CLOSED fold",
  m_wA == close_ch,
  ("expected %q, got %q"):format(close_ch, m_wA)
)

local m_wB = chr(fold.statuscolumn_marker(1, { winid = wB }))
check(
  "wB L1 marker (focused=wB) reflects wB's OPEN fold",
  m_wB == open_ch,
  ("expected %q, got %q"):format(open_ch, m_wB)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_statuscolumn_crosspane_marker_test: PASS")
os.exit(0)
