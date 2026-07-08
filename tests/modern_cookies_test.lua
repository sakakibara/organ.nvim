-- Cookies renderer: conceals [1/3] inline and emits a right_align progress
-- bar + fraction, colored by completion (@organ.modern.cookie.partial here).
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0xf9e2af })
vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = 0xa6e3a1 })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x6c7086 })
require("organ").setup({
  modern = { cookies = true },
  todo = { sequence = { "TODO", "|", "DONE" } },
})

local render = require("organ.modern.render")
local cookies = require("organ.modern.cookies")

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
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* project [1/3]" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
cookies._apply(b)

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
local text = ra
    and (function()
      local s = ""
      for _, c in ipairs(ra.virt_text) do
        s = s .. c[1]
      end
      return s
    end)()
  or ""
check("the raw [1/3] is concealed inline", conceal ~= nil, "marks=" .. vim.inspect(marks))
check("a right_align progress segment is emitted", ra ~= nil)
check("the fraction 1/3 is shown", text:find("1/3") ~= nil, "seg=[" .. text .. "]")
check(
  "a partial-completion color is used",
  ra and vim.inspect(ra.virt_text):find("@organ.modern.cookie.partial") ~= nil,
  ra and vim.inspect(ra.virt_text) or "nil"
)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_cookies_test: PASS")
os.exit(0)
