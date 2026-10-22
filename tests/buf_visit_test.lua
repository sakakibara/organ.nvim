-- Jumping to a place in the file already in the window must not re-edit
-- it: `:edit` of a modified current file fails with E37, and of an
-- unmodified one re-reads it and opens every fold.
-- Run via: nvim --headless -l tests/buf_visit_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local obuf = require("organ.buf")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local a, b = dir .. "/a.txt", dir .. "/b.txt"
vim.fn.writefile({ "one", "two", "three" }, a)
vim.fn.writefile({ "other" }, b)

local failures = 0
local function check(label, ok, detail)
  if not ok then
    failures = failures + 1
    io.write("FAIL " .. label .. (detail and (": " .. tostring(detail)) or "") .. "\n")
  end
end

vim.cmd("edit " .. vim.fn.fnameescape(a))
local buf = vim.api.nvim_get_current_buf()
vim.wo.foldmethod = "manual"
vim.cmd("2,3fold")
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "ONE" })

local ok, err = pcall(obuf.visit, a)
check("visiting the modified current file does not fail", ok, err)
check("it stays the same buffer", vim.api.nvim_get_current_buf() == buf)
check("its edits are kept", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "ONE")
check("its folds are kept", vim.fn.foldclosed(2) == 2)

vim.cmd("silent write")
ok, err = pcall(obuf.visit, dir .. "/./a.txt")
check(
  "visiting the current file by another spelling keeps its folds",
  ok and vim.fn.foldclosed(2) == 2,
  err
)

ok, err = pcall(obuf.visit, b)
check("visiting another file switches to it", ok and vim.fn.expand("%:t") == "b.txt", err)

vim.fn.delete(dir, "rf")
if failures > 0 then
  os.exit(1)
end
io.write("buf visit ok\n")
