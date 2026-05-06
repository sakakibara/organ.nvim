-- `zR` opens every fold in an org buffer — headings, body, and
-- drawers.  Our foldexpr puts body lines at heading_depth+1 and
-- drawers at heading_depth+2, so the deepest fold level is >= 3 in
-- a typical buffer.  `zR` must set 'foldlevel' high enough that
-- nothing is hidden after.
--
-- Run via: nvim --headless -l tests/fold_zR_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local tmp = vim.fn.tempname() .. ".org"
vim.fn.writefile({
  "* Heading 1",
  "  :PROPERTIES:",
  "  :ID:       abc",
  "  :END:",
  "  body line under H1",
  "** Heading 2",
  "   nested body",
  "*** Heading 3",
  "    deeper body",
}, tmp)

vim.cmd("edit " .. tmp)
vim.bo.filetype = "org"
require("organ.ftplugin.core").attach(0)

-- Wait for scheduled drawer-close to fire.
vim.wait(50)

-- Trigger zR.
vim.cmd("silent! normal! zR")

-- foldlevel should now be high enough that no line is in a closed fold.
local total = vim.api.nvim_buf_line_count(0)
local hidden = 0
for l = 1, total do
  if vim.fn.foldclosed(l) ~= -1 then
    hidden = hidden + 1
  end
end
check(
  "zR: zero lines remain inside a closed fold",
  hidden == 0,
  "got " .. hidden .. " hidden lines (foldlevel=" .. vim.wo.foldlevel .. ")"
)

-- Drawer interior must specifically be visible after zR.
local drawer_id_line = 3 -- the `:ID: abc` line
check(
  "zR: drawer interior line is visible (not folded)",
  vim.fn.foldclosed(drawer_id_line) == -1,
  "drawer line " .. drawer_id_line .. " still folded"
)

vim.cmd("bdelete!")
vim.fn.delete(tmp)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_zR_test: PASS")
