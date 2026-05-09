-- End-to-end: under a REAL redraw cycle (not nvim_eval_statusline),
-- the auto-applied `_organ_statuscolumn` must render each window's
-- own fold-marker, even when an unfocused pane shows the same buffer
-- with a different fold open/closed state.
--
-- Mechanism: a decoration provider stashes the rendering winid in a
-- module-local during `on_win`, and `_organ_statuscolumn` re-enters
-- that window's context via nvim_win_call before reading window-local
-- fold state.  This test triggers a real `:redraw!` and captures every
-- statuscolumn output for L1; the captures must contain BOTH chevrons
-- (one closed for wA, one open for wB), proving the per-window
-- plumbing fired.  Without the fix, both captures would match the
-- focused window's fold state.
--
-- Run via: nvim --headless -l tests/fold_statuscolumn_crosspane_redraw_test.lua

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

-- Apply ftplugin in BOTH windows so each gets its own win-local
-- statuscolumn / fold options.
for _, w in ipairs({ wA, wB }) do
  vim.api.nvim_set_current_win(w)
  vim.cmd("doautocmd FileType")
  vim.cmd("normal! zR")
end

-- Diverge fold state: wA closes H1, wB leaves it open.
vim.api.nvim_set_current_win(wA)
vim.api.nvim_win_set_cursor(wA, { 1, 0 })
vim.cmd("normal! zc")
vim.api.nvim_set_current_win(wB)

-- Sanity.
local closed_in_wA = vim.api.nvim_win_call(wA, function()
  return vim.fn.foldclosed(1)
end)
local closed_in_wB = vim.api.nvim_win_call(wB, function()
  return vim.fn.foldclosed(1)
end)
assert(
  closed_in_wA == 1 and closed_in_wB == -1,
  "setup precondition failed: wA closed="
    .. tostring(closed_in_wA)
    .. ", wB closed="
    .. tostring(closed_in_wB)
)

local fillchars = vim.opt.fillchars:get()
local close_ch = fillchars.foldclose or ">"
local open_ch = fillchars.foldopen or "v"

-- Wrap _organ_statuscolumn so we can capture per-eval outputs.  The
-- statuscolumn option-string still ultimately invokes the original via
-- the wrapper.
local original_sc = _G._organ_statuscolumn
local captured_l1 = {}
_G._organ_statuscolumn = function()
  local out = original_sc()
  if vim.v.lnum == 1 then
    table.insert(captured_l1, out)
  end
  return out
end
for _, w in ipairs({ wA, wB }) do
  vim.api.nvim_set_option_value("statuscolumn", "%!v:lua._organ_statuscolumn()", { win = w })
end

-- Drive a real redraw.  In headless this still fires decoration
-- providers + statuscolumn evals against the virtual screen.
vim.cmd("redraw!")

-- Strip highlight wrapping for assertions.
local function chr(s)
  return (s:gsub("%%#[^#]+#", ""):gsub("%%%*", ""))
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local seen_close, seen_open = false, false
for _, raw in ipairs(captured_l1) do
  -- _organ_statuscolumn returns "%s<n_str> <marker> ".  Pull the marker
  -- char out: it's the non-space token between the digit run and the
  -- trailing space.
  local without_signs = raw:gsub("^%%s", "")
  local marker = chr(without_signs):match("^%s*%-?%d*%s+(%S)%s*$")
  if marker == close_ch then
    seen_close = true
  end
  if marker == open_ch then
    seen_open = true
  end
end

check(
  "real redraw: at least one L1 capture",
  #captured_l1 >= 2,
  ("captured = %d, raws = %s"):format(#captured_l1, vim.inspect(captured_l1))
)
check(
  "real redraw: a window rendered close_ch (wA's fold state)",
  seen_close,
  ("captures = %s"):format(vim.inspect(captured_l1))
)
check(
  "real redraw: a window rendered open_ch (wB's fold state)",
  seen_open,
  ("captures = %s"):format(vim.inspect(captured_l1))
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_statuscolumn_crosspane_redraw_test: PASS")
os.exit(0)
