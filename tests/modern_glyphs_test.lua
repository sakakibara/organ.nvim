-- tests/modern_glyphs_test.lua
-- The glyph registry enforces single-cell width (the alignment-regression
-- guard) and returns nerd vs ascii glyphs per modern.nerd_font.
-- Run via: nvim --headless -l tests/modern_glyphs_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})

local glyphs = require("organ.modern.glyphs")
local fails = 0
local function check(label, ok, detail)
  if ok then print("PASS  " .. label)
  else fails = fails + 1; print("FAIL  " .. label .. (detail and ("\n     " .. detail) or "")) end
end

-- Every registered glyph (nerd AND ascii) is exactly one cell wide.
local bad = glyphs.verify()
check("all registered glyphs are single-cell", #bad == 0, vim.inspect(bad))

-- get() returns the nerd glyph by default, ascii when nerd_font = false.
local b = vim.api.nvim_create_buf(true, false)
vim.bo[b].filetype = "org"
require("organ.buf_config").set(b, "modern.nerd_font", true)
check("nerd mode returns the nerd cap", glyphs.get("pill.cap.left", b) == glyphs._GLYPHS["pill.cap.left"].nerd)
require("organ.buf_config").set(b, "modern.nerd_font", false)
check("ascii mode returns the ascii cap", glyphs.get("pill.cap.left", b) == glyphs._GLYPHS["pill.cap.left"].ascii)

-- Unknown name is a safe empty string, never nil.
check("unknown glyph -> empty string", glyphs.get("does.not.exist", b) == "")

if fails > 0 then print("\nFAILED " .. fails .. " checks"); os.exit(1) end
print("\nmodern_glyphs_test: PASS"); os.exit(0)
