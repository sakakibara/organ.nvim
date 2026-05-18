-- fold.cycle_global(bufnr) cycles SHOW_ALL -> OVERVIEW -> CONTENTS.
--   SHOW_ALL: foldlevel = 99, no conceal layer.
--   OVERVIEW: foldlevel = 0.
--   CONTENTS: foldlevel = 99 + conceal extmarks over body ranges.
--
-- Run via: nvim --headless -l tests/fold_global_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  scan_on_startup = false,
  watcher = { enabled = false },
  notify = false,
})

local fold = require("organ.fold")
local contents = require("organ.fold.contents")

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
vim.fn.writefile({ "* H1", "body", "** H2", "more body", "*** H3", "deep" }, tmp)
vim.cmd("edit " .. tmp)
vim.bo.filetype = "org"
local buf = vim.api.nvim_get_current_buf()

-- Start in SHOW_ALL, cycle through.
vim.wo.foldlevel = 99
fold.cycle_global(buf)
check("SHOW_ALL -> OVERVIEW (foldlevel=0)", vim.wo.foldlevel == 0)
check("OVERVIEW: contents extmark layer NOT active", not contents.is_active(buf))

fold.cycle_global(buf)
check("OVERVIEW -> CONTENTS (foldlevel back to 99)", vim.wo.foldlevel == 99)
check("CONTENTS: contents extmark layer ACTIVE", contents.is_active(buf))

fold.cycle_global(buf)
check("CONTENTS -> SHOW_ALL (foldlevel=99)", vim.wo.foldlevel == 99)
check("SHOW_ALL: contents extmark layer cleared", not contents.is_active(buf))

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_global_test: PASS")
os.exit(0)
