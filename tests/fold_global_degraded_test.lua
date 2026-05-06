-- When `conceal_lines` extmarks aren't available (nvim < 0.11), the
-- default `body_fold = false` path can't conceal body, so cycle_global
-- falls back to a foldlevel-only state machine where CONTENTS is
-- "level-1 headings only" (foldlevel = 1).
--
-- Run via: nvim --headless -l tests/fold_global_degraded_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  scan_on_startup = false,
  watcher = { enabled = false },
  notify = false,
})

local contents = require("organ.fold.contents")
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

-- Force the degraded path even on conceal-capable nvim by stubbing
-- the support probe.  This keeps coverage uniform across nvim
-- versions and proves the fallback works without needing a 0.10 host.
local orig_is_supported = contents.is_supported
contents.is_supported = function()
  return false
end

local tmp = vim.fn.tempname() .. ".org"
vim.fn.writefile({ "* H1", "body", "** H2", "more body", "*** H3" }, tmp)
vim.cmd("edit " .. tmp)
vim.bo.filetype = "org"
local buf = vim.api.nvim_get_current_buf()

vim.wo.foldlevel = 99
fold.cycle_global(buf)
check("SHOW_ALL -> OVERVIEW (foldlevel=0)", vim.wo.foldlevel == 0)

fold.cycle_global(buf)
check("OVERVIEW -> CONTENTS-degraded (foldlevel=1)", vim.wo.foldlevel == 1)

fold.cycle_global(buf)
check("CONTENTS -> SHOW_ALL (foldlevel=99)", vim.wo.foldlevel == 99)

contents.is_supported = orig_is_supported

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_global_degraded_test: PASS")
os.exit(0)
