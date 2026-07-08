-- Checkbox renderer: conceals [ ]/[X]/[-] and emits a single-cell state icon
-- (nerd) colored by state via @organ.modern.checkbox.<state>.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = 0xa6e3a1 })
vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0xf9e2af })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x6c7086 })
require("organ").setup({ modern = { checkboxes = true } })

local render = require("organ.modern.render")
local checkboxes = require("organ.modern.checkboxes")

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
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "- [ ] todo", "- [X] done", "- [-] partial" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
checkboxes._apply(b)

local marks = vim.api.nvim_buf_get_extmarks(b, render.ns, 0, -1, { details = true })
local function on_row(row, pred)
  for _, m in ipairs(marks) do
    if m[2] == row and pred(m[4]) then
      return m
    end
  end
end
local function has_conceal(row)
  return on_row(row, function(d)
    return d.conceal ~= nil
  end)
end
local function glyph_hl(row)
  local m = on_row(row, function(d)
    return d.virt_text ~= nil
  end)
  return m and m[4].virt_text[1][2]
end

check(
  "empty row concealed + inline glyph",
  has_conceal(0) ~= nil and glyph_hl(0) == "@organ.modern.checkbox.empty",
  "hl=" .. tostring(glyph_hl(0))
)
check(
  "checked row uses checked hl",
  glyph_hl(1) == "@organ.modern.checkbox.checked",
  "hl=" .. tostring(glyph_hl(1))
)
check(
  "partial row uses partial hl",
  glyph_hl(2) == "@organ.modern.checkbox.partial",
  "hl=" .. tostring(glyph_hl(2))
)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_checkboxes_test: PASS")
os.exit(0)
