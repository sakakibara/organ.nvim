-- List-bullet renderer: conceals a `-`/`+` bullet and emits a single-cell `•`
-- colored via @org.list.bullet; leaves ordered bullets (1.) untouched.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({ modern = { list_bullets = true } })

local render = require("organ.modern.render")
local list_bullets = require("organ.modern.list_bullets")

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
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "- dash item", "+ plus item", "1. ordered item" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
list_bullets._apply(b)

local marks = vim.api.nvim_buf_get_extmarks(b, render.ns, 0, -1, { details = true })
local function glyph_on(row)
  for _, m in ipairs(marks) do
    if m[2] == row and m[4].virt_text then
      return m[4].virt_text[1][1]
    end
  end
end
local function conceal_on(row)
  for _, m in ipairs(marks) do
    if m[2] == row and m[4].conceal ~= nil then
      return true
    end
  end
  return false
end

check("dash bullet -> • glyph", glyph_on(0) == vim.fn.nr2char(0x2022), "got " .. tostring(glyph_on(0)))
check("dash bullet concealed", conceal_on(0))
check("plus bullet -> • glyph", glyph_on(1) == vim.fn.nr2char(0x2022), "got " .. tostring(glyph_on(1)))
check("ordered bullet left untouched (no mark)", glyph_on(2) == nil and not conceal_on(2))

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_list_bullets_test: PASS")
os.exit(0)
