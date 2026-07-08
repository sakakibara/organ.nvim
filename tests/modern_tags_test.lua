-- Tags renderer: conceals :work:client: inline and emits a right_align run
-- "work <sep> client" in the muted @organ.modern.tag group.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "Comment", { fg = 0x6c7086 })
require("organ").setup({ modern = { tags = true }, todo = { sequence = { "TODO", "|", "DONE" } } })

local render = require("organ.modern.render")
local tags = require("organ.modern.tags")

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
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* a headline :work:client:" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
tags._apply(b)

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
check("the raw :work:client: is concealed inline", conceal ~= nil, "marks=" .. vim.inspect(marks))
check("a right_align tag run is emitted", ra ~= nil)
check(
  "the run names both tags",
  text:find("work") ~= nil and text:find("client") ~= nil,
  "run=[" .. text .. "]"
)
check(
  "both tag chunks use @organ.modern.tag",
  ra and vim.inspect(ra.virt_text):find("@organ.modern.tag") ~= nil,
  ra and vim.inspect(ra.virt_text) or "nil"
)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_tags_test: PASS")
os.exit(0)
