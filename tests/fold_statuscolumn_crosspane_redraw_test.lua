-- End-to-end: with two splits showing the same buffer at different
-- fold open/closed state, the auto-applied statuscolumn must render
-- each window's OWN fold marker (and number-column digits, since
-- vim.wo.number / vim.wo.relativenumber are window-local too).
--
-- The body lives in `M.statuscolumn(winid)`; `_G._organ_statuscolumn`
-- resolves the rendering winid via decoration-provider callbacks and
-- forwards.  Calling `M.statuscolumn(w)` directly side-steps the need
-- for a real redraw cycle (headless `:redraw!` fires statuscolumn
-- evals on some Neovim versions and not on others — see v0.10.4).
-- The decoration-provider plumbing itself is a four-line on_win that
-- writes one local; we trust Neovim's API contract for that.
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

-- Apply ftplugin in BOTH windows so each pane has its own fold +
-- statuscolumn options.
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

-- Sanity: per-window fold state actually differs.
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

-- Strip highlight wrapping for assertions on the underlying char.
local function chr(s)
  return (s:gsub("%%#[^#]+#", ""):gsub("%%%*", ""))
end

local function marker_of(rendered)
  -- M.statuscolumn returns "%s<nstr> <marker> ".  Pull the marker char
  -- out: the non-space token between the digit run and the trailing
  -- space.
  local without_signs = rendered:gsub("^%%s", "")
  return chr(without_signs):match("^%s*%-?%d*%s+(%S)%s*$")
end

-- Set v:lnum = 1 for the eval (otherwise it defaults to 0 and the
-- marker computes for line 0, which has foldlevel 0).  Use
-- nvim_eval_statusline as a clean way to inject v:lnum without driving
-- a real redraw.
local function eval_at_l1(winid)
  local r =
    vim.api.nvim_eval_statusline("%!v:lua.require('organ.fold').statuscolumn(" .. winid .. ")", {
      winid = winid,
      use_statuscol_lnum = 1,
    })
  return r.str
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

local rendered_wA = eval_at_l1(wA)
local rendered_wB = eval_at_l1(wB)

local marker_wA = marker_of(rendered_wA)
local marker_wB = marker_of(rendered_wB)

check(
  "M.statuscolumn(wA) marker (focused=wB) reflects wA's CLOSED fold",
  marker_wA == close_ch,
  ("expected %q, got %q (rendered=%q)"):format(close_ch, marker_wA or "<nil>", rendered_wA)
)
check(
  "M.statuscolumn(wB) marker (focused=wB) reflects wB's OPEN fold",
  marker_wB == open_ch,
  ("expected %q, got %q (rendered=%q)"):format(open_ch, marker_wB or "<nil>", rendered_wB)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_statuscolumn_crosspane_redraw_test: PASS")
os.exit(0)
