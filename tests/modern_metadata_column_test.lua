-- One headline with priority + cookie + tags: the composer must emit exactly
-- ONE right_align mark on the row, ordered priority -> cookies -> tags.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xf38ba8 })
vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0xf9e2af })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x6c7086 })
require("organ").setup({
  modern = { priority = true, cookies = true, tags = true },
  todo = { sequence = { "TODO", "|", "DONE" } },
})
-- Load the element modules so their renderers register with the engine.
require("organ.modern.priority")
require("organ.modern.cookies")
require("organ.modern.tags")

local render = require("organ.modern.render")

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
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* [#A] project [1/3] :work:client:" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
render._render_now(b)

local marks = vim.api.nvim_buf_get_extmarks(b, render.ns, 0, -1, { details = true })
local ra_count, ra = 0, nil
for _, m in ipairs(marks) do
  if m[4].virt_text_pos == "right_align" then
    ra_count = ra_count + 1
    ra = m[4]
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
check("exactly one right_align mark for the row", ra_count == 1, "count=" .. ra_count)
local pa, pc, pt = text:find("A"), text:find("1/3"), text:find("work")
check(
  "order is priority -> cookies -> tags",
  pa and pc and pt and pa < pc and pc < pt,
  "seg=[" .. text .. "]"
)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_metadata_column_test: PASS")
os.exit(0)
