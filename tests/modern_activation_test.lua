-- Enabling ONLY a right-column / line-level element (no bullets/blocks/pills)
-- must still activate modern rendering, and the persistent engine must bump
-- conceallevel so conceal-based elements actually hide their raw tokens.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = 0xa6e3a1 })
require("organ").setup({ modern = { checkboxes = true } })

local modern = require("organ.modern")
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
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "- [X] done" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")

-- The ftplugin gates modern.attach on modern.enabled(); a checkboxes-only
-- config must report enabled.
check("modern.enabled() true with only checkboxes on", modern.enabled(b) == true)

vim.wo.conceallevel = 0
modern.attach(b)
render._render_now(b)

local marks = vim.api.nvim_buf_get_extmarks(b, render.ns, 0, -1, {})
check("checkbox element rendered marks", #marks > 0, "got " .. #marks)
check("engine bumped conceallevel to >= 2", vim.wo.conceallevel >= 2, "got " .. vim.wo.conceallevel)

modern.detach(b)
check("conceallevel restored to 0 after detach", vim.wo.conceallevel == 0, "got " .. vim.wo.conceallevel)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_activation_test: PASS")
os.exit(0)
