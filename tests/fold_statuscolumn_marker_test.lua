-- Sibling headings at the same depth (e.g., the second `**` after the
-- first `**`'s body) have foldlevel(prev) >= foldlevel(cur) because
-- body sits at body_level > max_heading_depth (required for CONTENTS
-- view).  A level-compare statuscolumn would miss them.  The helper
-- treats any `^%*+%s` line as a fold start regardless of the
-- transition.  Run via:
--   nvim --headless -l tests/fold_statuscolumn_marker_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })
require("organ").setup({ scan_on_startup = false, watcher = { enabled = false }, notify = false })

local fold = require("organ.fold")
local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function setup_buf(lines)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  vim.cmd("doautocmd FileType")
  vim.cmd("normal! zx")
  return b
end

-- Strip the highlight wrapping for assertions on the underlying char.
local function chr(s)
  return (s:gsub("%%#[^#]+#", ""):gsub("%%%*", ""))
end

-- Sibling headings at the same level: the second one MUST get a marker.
do
  setup_buf({
    "* H1",
    "body of H1",
    "* H2",
    "body of H2",
  })
  check("L1 (* H1): fold-start marker", chr(fold.statuscolumn_marker(1)) ~= " ")
  check("L3 (* H2 sibling): fold-start marker", chr(fold.statuscolumn_marker(3)) ~= " ")
end

-- Heading following body of a deeper subtree (the cur < prev case).
do
  setup_buf({
    "* H1",
    "** H1a",
    "body deep",
    "* H2", -- prev_foldlevel = body_level (high), cur = 1 -> would fail level-compare
  })
  check("L4 (* H2 after deep body): fold-start marker", chr(fold.statuscolumn_marker(4)) ~= " ")
end

-- Body lines should NOT get a marker (the helper preserves "blank inside").
do
  setup_buf({
    "* H1",
    "body line",
    "more body",
  })
  check("L2 (body): no marker", chr(fold.statuscolumn_marker(2)) == " ")
  check("L3 (body): no marker", chr(fold.statuscolumn_marker(3)) == " ")
end

-- Closed fold: foldclose char.
do
  setup_buf({ "* H1", "body" })
  vim.cmd("normal! zM")
  check("L1 closed: foldclose marker", chr(fold.statuscolumn_marker(1)) ~= " ")
end

-- Non-org filetype: falls back to level-compare (no `^%*` short-circuit).
do
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "plain", "* not a heading because not org" })
  vim.bo[b].filetype = "text"
  vim.wo.foldmethod = "manual"
  check("non-org: foldlevel 0 returns space", chr(fold.statuscolumn_marker(1)) == " ")
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_statuscolumn_marker_test: PASS")
os.exit(0)
