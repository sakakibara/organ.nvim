-- tests/modern_glyphs_health_test.lua
-- The health check surfaces any registered glyph that is not single-cell.
-- Run via: nvim --headless -l tests/modern_glyphs_health_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})
local fails = 0
local function check(l, ok, d) if ok then print("PASS  "..l) else fails=fails+1; print("FAIL  "..l..(d and "\n     "..d or "")) end end

-- With a clean registry, the health helper reports OK (no offenders).
local offenders = require("organ.health")._glyph_width_offenders()
check("no glyph-width offenders in the default registry", #offenders == 0, vim.inspect(offenders))

if fails > 0 then print("\nFAILED "..fails); os.exit(1) end
print("\nmodern_glyphs_health_test: PASS"); os.exit(0)
