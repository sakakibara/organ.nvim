-- Blocks body tint: modern.blocks = { tint_body = true } fills each body line
-- with a subtle background (line_hl_group = @organ.modern.block_tint). The
-- frame lines are not tinted; default (bool `true`) leaves the body untinted.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({ modern = { blocks = { tint_body = true } } })

local render = require("organ.modern.render")
local blocks = require("organ.modern.blocks")

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
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "#+begin_src lua", "print('hi')", "  more()", "#+end_src" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
blocks._apply(b)

local marks = vim.api.nvim_buf_get_extmarks(b, render.ns, 0, -1, { details = true })
local function tint_on(row)
  for _, m in ipairs(marks) do
    if m[2] == row and m[4].line_hl_group == "@organ.modern.block_tint" then
      return true
    end
  end
  return false
end

check("body row 1 is tinted", tint_on(1))
check("body row 2 is tinted", tint_on(2))
check("frame top row is NOT tinted", not tint_on(0))
check("frame bottom row is NOT tinted", not tint_on(3))

-- With the bool form (no tint_body), the body must not be tinted.
require("organ.buf_config").set(b, "modern.blocks", true)
blocks._apply(b)
marks = vim.api.nvim_buf_get_extmarks(b, render.ns, 0, -1, { details = true })
check("bool form leaves the body untinted", not tint_on(1))

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_blocks_tint_test: PASS")
os.exit(0)
