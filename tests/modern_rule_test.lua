-- Horizontal-rule renderer: a `-----` line gets an overlay `─` run in the
-- @organ.modern.rule group.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "NonText", { fg = 0x585b70 })
require("organ").setup({ modern = { rule = true } })

local render = require("organ.modern.render")
local rule = require("organ.modern.rule")

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
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "before", "-----", "after" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
rule._apply(b)

local marks = vim.api.nvim_buf_get_extmarks(b, render.ns, { 1, 0 }, { 1, -1 }, { details = true })
local ov
for _, m in ipairs(marks) do
  if m[4].virt_text_pos == "overlay" then
    ov = m[4]
  end
end
local text = ov and ov.virt_text[1][1] or ""
check("overlay mark on the rule row", ov ~= nil, "marks=" .. vim.inspect(marks))
check(
  "overlay text is a run of box-drawing dashes",
  #text > 0 and text:gsub(vim.fn.nr2char(0x2500), "") == "",
  "text=[" .. text .. "]"
)
check(
  "uses the @organ.modern.rule group",
  ov and ov.virt_text[1][2] == "@organ.modern.rule",
  ov and vim.inspect(ov.virt_text) or "nil"
)
check(
  "no overlay on non-rule rows",
  #vim.api.nvim_buf_get_extmarks(b, render.ns, { 0, 0 }, { 0, -1 }, {}) == 0
)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_rule_test: PASS")
os.exit(0)
