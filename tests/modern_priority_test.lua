-- Priority renderer: conceals [#A] inline and emits a right_align segment
-- with a flag glyph + rank letter colored by @organ.modern.priority.<rank>.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xf38ba8 })
require("organ").setup({
  modern = { priority = true },
  todo = { sequence = { "TODO", "|", "DONE" } },
})

local render = require("organ.modern.render")
local priority = require("organ.modern.priority")

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
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* [#A] TODO ship it" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
priority._apply(b)

local marks = vim.api.nvim_buf_get_extmarks(b, render.ns, 0, -1, { details = true })
local conceal, ra
for _, m in ipairs(marks) do
  local d = m[4]
  if d.conceal ~= nil then
    conceal = m
  end
  if d.virt_text_pos == "right_align" then
    ra = d
  end
end
check("the raw [#A] is concealed inline", conceal ~= nil, "marks=" .. vim.inspect(marks))
check("a right_align segment is emitted", ra ~= nil)
check(
  "the segment carries the rank letter A",
  ra and vim.inspect(ra.virt_text):find("A") ~= nil,
  ra and vim.inspect(ra.virt_text) or "nil"
)
check(
  "the segment uses the rank-A hl group",
  ra and vim.inspect(ra.virt_text):find("@organ.modern.priority.a") ~= nil,
  ra and vim.inspect(ra.virt_text) or "nil"
)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_priority_test: PASS")
os.exit(0)
