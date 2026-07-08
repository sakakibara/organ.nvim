-- Tags badge style: modern.tags = { style = "badge" } wraps each tag in
-- guillemets (‹work› ‹client›) instead of the default muted run.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "Comment", { fg = 0x6c7086 })
require("organ").setup({ modern = { tags = { style = "badge" } } })

local render = require("organ.modern.render")
local tags = require("organ.modern.tags")
local G = require("organ.modern.glyphs")

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

local ra
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, render.ns, 0, -1, { details = true })) do
  if m[4].virt_text_pos == "right_align" then
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

local L, R = G.get("tag.badge.left"), G.get("tag.badge.right")
check("a right_align tag run is emitted", ra ~= nil)
check(
  "first tag is wrapped as a badge",
  text:find(L .. "work" .. R, 1, true) ~= nil,
  "run=[" .. text .. "]"
)
check(
  "second tag is wrapped as a badge",
  text:find(L .. "client" .. R, 1, true) ~= nil,
  "run=[" .. text .. "]"
)
check(
  "no middle-dot separator in badge mode",
  text:find(vim.fn.nr2char(0x00b7), 1, true) == nil,
  "run=[" .. text .. "]"
)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_tags_badge_test: PASS")
os.exit(0)
