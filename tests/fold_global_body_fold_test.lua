-- Legacy fold strategy: `fold.body_fold = true` puts body lines at
-- body_level = max_heading_depth + 1.  cycle_global encodes state in
-- foldlevel alone:
--   SHOW_ALL  foldlevel = 99
--   OVERVIEW  foldlevel = 0
--   CONTENTS  foldlevel = max_heading_depth
--
-- Run via: nvim --headless -l tests/fold_global_body_fold_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  scan_on_startup = false,
  watcher = { enabled = false },
  notify = false,
  fold = { body_fold = true },
})

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

-- Empty buffer: max_heading_depth = 0, treated as 1 by cycle_global.
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(b)
vim.wo.foldlevel = 99
fold.cycle_global(b)
check("empty buf: 99 -> OVERVIEW (0)", vim.wo.foldlevel == 0)
fold.cycle_global(b)
check("empty buf: 0 -> CONTENTS (md=1)", vim.wo.foldlevel == 1)
fold.cycle_global(b)
check("empty buf: 1 -> SHOW_ALL (99)", vim.wo.foldlevel == 99)

-- Buffer with depth 3.
local tmp = vim.fn.tempname() .. ".org"
vim.fn.writefile({ "* H1", "** H2", "*** H3", "body" }, tmp)
vim.cmd("edit " .. tmp)
vim.bo.filetype = "org"
local buf = vim.api.nvim_get_current_buf()
check("max_heading_depth = 3", fold._max_heading_depth(buf) == 3)

vim.wo.foldlevel = 99
fold.cycle_global(buf)
check("d3: SHOW_ALL -> OVERVIEW (0)", vim.wo.foldlevel == 0)
fold.cycle_global(buf)
check("d3: OVERVIEW -> CONTENTS (md=3)", vim.wo.foldlevel == 3)
fold.cycle_global(buf)
check("d3: CONTENTS -> SHOW_ALL (99)", vim.wo.foldlevel == 99)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_global_body_fold_test: PASS")
os.exit(0)
