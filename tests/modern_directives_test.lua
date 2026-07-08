-- Directive renderer: dims the `#+KEYWORD:` label (up to the value) via
-- @organ.modern.directive; the value is left un-dimmed.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "Comment", { fg = 0x6c7086 })
require("organ").setup({ modern = { directives = true } })

local render = require("organ.modern.render")
local directives = require("organ.modern.directives")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local b = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "#+TITLE: My notes", "#+CAPTION: a cap", "* Head" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
directives._apply(b)

local function dim_on(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, render.ns, { row, 0 }, { row, -1 }, { details = true })) do
    if m[4].hl_group == "@organ.modern.directive" then
      return m
    end
  end
end
local d0 = dim_on(0)
check("directive label on #+TITLE line is dimmed", d0 ~= nil)
-- `#+TITLE: ` is 9 columns; the dim must stop at the value (col 9), not cover it.
check("dim stops before the value", d0 ~= nil and d0[4].end_col ~= nil and d0[4].end_col <= 9,
  d0 and ("end_col=" .. tostring(d0[4].end_col)) or "nil")
check("affiliated keyword (#+CAPTION) is dimmed too", dim_on(1) ~= nil)
check("no dim on the headline row", dim_on(2) == nil)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_directives_test: PASS")
os.exit(0)
