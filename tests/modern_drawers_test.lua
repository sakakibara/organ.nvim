-- Drawer renderer: dims the whole :PROPERTIES: .. :END: block and prefixes a
-- leaf glyph on the header, both in @organ.modern.drawer.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "Comment", { fg = 0x6c7086 })
require("organ").setup({ modern = { drawers = true } })

local render = require("organ.modern.render")
local drawers = require("organ.modern.drawers")

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
vim.api.nvim_buf_set_lines(
  b,
  0,
  -1,
  false,
  { "* Head", "  :PROPERTIES:", "  :ID: abc", "  :END:", "body" }
)
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
drawers._apply(b)

local marks = vim.api.nvim_buf_get_extmarks(b, render.ns, 0, -1, { details = true })
local dim, glyph
for _, m in ipairs(marks) do
  local d = m[4]
  if d.hl_group == "@organ.modern.drawer" and d.end_row then
    dim = m
  end
  if d.virt_text and d.virt_text[1][2] == "@organ.modern.drawer" then
    glyph = m
  end
end
check("a multi-line dim covers the drawer", dim ~= nil and dim[2] == 1, "dim=" .. vim.inspect(dim))
check(
  "the dim spans past the header row",
  dim ~= nil and dim[4].end_row >= 3,
  dim and ("end_row=" .. tostring(dim[4].end_row)) or "nil"
)
check(
  "a leaf glyph sits on the header row",
  glyph ~= nil and glyph[2] == 1,
  "glyph=" .. vim.inspect(glyph)
)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_drawers_test: PASS")
os.exit(0)
