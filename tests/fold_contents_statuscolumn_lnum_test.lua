-- statuscolumn_lnum returns visible-line distance, not buffer-line
-- distance, so a custom statuscolumn keeps relnum visually correct
-- under CONTENTS view's conceal_lines extmarks.
--
-- Run via: nvim --headless -l tests/fold_contents_statuscolumn_lnum_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})

local contents = require("organ.fold.contents")
if not contents.is_supported() then
  print("(skipped: nvim does not support `conceal_lines` extmark)")
  print("fold_contents_statuscolumn_lnum_test: SKIP")
  os.exit(0)
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* H1", -- 1 visible
  "body 1", -- 2 concealed in CONTENTS
  "body 2", -- 3 concealed
  "body 3", -- 4 concealed
  "* H2", -- 5 visible
  "body 4", -- 6 concealed
  "* H3", -- 7 visible
})
vim.bo[b].filetype = "org"

-- Outside CONTENTS: helper returns vim-equivalent values.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check("outside CONTENTS: relative for line 5 == 4 (raw)", contents.statuscolumn_lnum(5, true) == 4)
check("absolute mode returns lnum unchanged", contents.statuscolumn_lnum(5, false) == 5)

-- In CONTENTS: relnum from cursor on H1 (row 1) to H2 (row 5) skips
-- the 3 concealed body lines, so the visible distance is 1.
contents.enter(b)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check(
  "CONTENTS: H1 -> H2 visible distance = 1",
  contents.statuscolumn_lnum(5, true) == 1,
  "got " .. tostring(contents.statuscolumn_lnum(5, true))
)
check(
  "CONTENTS: H1 -> H3 visible distance = 2",
  contents.statuscolumn_lnum(7, true) == 2,
  "got " .. tostring(contents.statuscolumn_lnum(7, true))
)

-- Cursor on H2; H1 backwards is distance 1.
vim.api.nvim_win_set_cursor(0, { 5, 0 })
check(
  "CONTENTS: H2 -> H1 (backward) = 1",
  contents.statuscolumn_lnum(1, true) == 1,
  "got " .. tostring(contents.statuscolumn_lnum(1, true))
)
check(
  "CONTENTS: H2 -> H3 forward = 1",
  contents.statuscolumn_lnum(7, true) == 1,
  "got " .. tostring(contents.statuscolumn_lnum(7, true))
)

-- Current line returns lnum (absolute) -- mirrors how vim shows
-- absolute number for the cursor's own line under relativenumber.
check(
  "CONTENTS: cursor line returns absolute lnum",
  contents.statuscolumn_lnum(5, true) == 5,
  "got " .. tostring(contents.statuscolumn_lnum(5, true))
)

-- Concealed lines: helper still works (visible distance counts the
-- destination if it's not concealed; if destination IS concealed,
-- result is 0 from the math but in practice no statuscolumn renders
-- a concealed line, so this case is irrelevant in practice).
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check(
  "CONTENTS: H1 -> body 2 (concealed dest) returns 0 visible lines crossed",
  contents.statuscolumn_lnum(3, true) == 0,
  "got " .. tostring(contents.statuscolumn_lnum(3, true))
)

contents.leave(b)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_contents_statuscolumn_lnum_test: PASS")
os.exit(0)
