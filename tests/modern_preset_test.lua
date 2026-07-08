-- modern preset: `modern = "all"` / `modern.preset = "all"|"rich"` enables
-- every element, while the user's explicit per-element values still win.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- preset "rich" turns everything on, but an explicit `table = false` and an
-- explicit option table for `tags` must survive.
require("organ").setup({ modern = { preset = "rich", table = false, tags = { style = "badge" } } })

local bc = require("organ.buf_config")
local modern = require("organ.modern")

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
vim.bo[b].filetype = "org"

-- A sampling of elements that default off are now on.
for _, e in ipairs({ "bullets", "checkboxes", "priority", "dates", "rule", "directives", "drawers", "blocks", "pills" }) do
  check("preset enables " .. e, bc.read(b, "modern." .. e) == true, "got " .. tostring(bc.read(b, "modern." .. e)))
end

check("explicit table = false is respected", bc.read(b, "modern.table") == false,
  "got " .. tostring(bc.read(b, "modern.table")))
check("explicit tags option table survives", bc.read(b, "modern.tags.style") == "badge",
  "got " .. tostring(bc.read(b, "modern.tags.style")))
check("modern.enabled() true under the preset", modern.enabled(b) == true)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_preset_test: PASS")
os.exit(0)
