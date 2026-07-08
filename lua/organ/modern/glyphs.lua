-- lua/organ/modern/glyphs.lua
-- Single source of every glyph modern mode emits, in two sets: `nerd`
-- (Nerd Font, single-width in a mono Nerd Font) and `ascii` (fallback,
-- always single-width). Elements pull glyphs by name so the width rule and
-- the nerd/ascii switch live in one place. See verify(): every glyph must
-- be exactly one terminal cell (the alignment-regression guard).

local M = {}

-- name -> { nerd = "<glyph>", ascii = "<glyph>" }. Nerd caps are the
-- powerline half-circles (built from codepoints to keep source ASCII).
local GLYPHS = {
  ["pill.cap.left"] = { nerd = vim.fn.nr2char(0xe0b6), ascii = "" },
  ["pill.cap.right"] = { nerd = vim.fn.nr2char(0xe0b4), ascii = "" },
  ["priority.flag"] = { nerd = vim.fn.nr2char(0xf024), ascii = "!" },
  ["tag.sep"] = { nerd = vim.fn.nr2char(0x00b7), ascii = vim.fn.nr2char(0x00b7) },
  ["tag.badge.left"] = { nerd = vim.fn.nr2char(0x2039), ascii = "<" },
  ["tag.badge.right"] = { nerd = vim.fn.nr2char(0x203a), ascii = ">" },
  ["cookie.bar.left"] = { nerd = vim.fn.nr2char(0x2590), ascii = "[" },
  ["cookie.bar.right"] = { nerd = vim.fn.nr2char(0x258c), ascii = "]" },
  ["cookie.bar.fill"] = { nerd = vim.fn.nr2char(0x2593), ascii = "#" },
  ["cookie.bar.track"] = { nerd = vim.fn.nr2char(0x2591), ascii = "-" },
  ["checkbox.empty"] = { nerd = vim.fn.nr2char(0xf096), ascii = "" },
  ["checkbox.checked"] = { nerd = vim.fn.nr2char(0xf046), ascii = "" },
  ["checkbox.partial"] = { nerd = vim.fn.nr2char(0xf146), ascii = "" },
  ["list.bullet"] = { nerd = vim.fn.nr2char(0x2022), ascii = vim.fn.nr2char(0x2022) },
  ["date.calendar"] = { nerd = vim.fn.nr2char(0xf073), ascii = "" },
  ["date.clock"] = { nerd = vim.fn.nr2char(0xf017), ascii = "" },
  ["rule.line"] = { nerd = vim.fn.nr2char(0x2500), ascii = vim.fn.nr2char(0x2500) },
  ["drawer.leaf"] = { nerd = vim.fn.nr2char(0xf105), ascii = "" },
  ["bullet.1"] = { nerd = vim.fn.nr2char(0xf111), ascii = vim.fn.nr2char(0x2022) },
  ["bullet.2"] = { nerd = vim.fn.nr2char(0xf10c), ascii = vim.fn.nr2char(0x2022) },
  ["bullet.3"] = { nerd = vim.fn.nr2char(0xf192), ascii = vim.fn.nr2char(0x2022) },
  ["bullet.4"] = { nerd = vim.fn.nr2char(0xf1db), ascii = vim.fn.nr2char(0x2022) },
}

M._GLYPHS = GLYPHS

local function nerd_on(bufnr)
  local v = require("organ.buf_config").read(bufnr, "modern.nerd_font")
  if v == nil then
    return true
  end
  return v and true or false
end

function M.get(name, bufnr)
  local g = GLYPHS[name]
  if not g then
    return ""
  end
  return nerd_on(bufnr) and g.nerd or g.ascii
end

-- Any glyph (either mode) that nvim accounts as wider than one cell.
-- Empty-string glyphs (ascii "no cap") are skipped.
function M.verify()
  local bad = {}
  for name, g in pairs(GLYPHS) do
    for mode, glyph in pairs(g) do
      if glyph ~= "" and vim.api.nvim_strwidth(glyph) ~= 1 then
        bad[#bad + 1] = { name = name, mode = mode, glyph = glyph, width = vim.api.nvim_strwidth(glyph) }
      end
    end
  end
  return bad
end

return M
