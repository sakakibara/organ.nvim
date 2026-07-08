-- Regression: the tree-sitter grammar closes a block on `#+end_TYPE` even
-- with trailing junk on the line (`#+end_src>`), so the modern frame must too
-- -- otherwise the block the tree/folds see as valid renders un-framed, and
-- the user has to "fix" a line that was never actually broken.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({ modern = { blocks = true } })

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

-- The tree parses `#+end_src>` as a normal src_block close; confirm the frame
-- renders top (row 0), body (row 1), and bottom (row 2) marks anyway.
local b = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "#+begin_src lua", "print('hi')", "#+end_src>" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
blocks._apply(b)

local function has_overlay(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, render.ns, { row, 0 }, { row, -1 }, { details = true })) do
    if m[4].virt_text_pos == "overlay" then
      return true
    end
  end
  return false
end

check("begin line is framed (top corner)", has_overlay(0))
check("end line with trailing '>' is framed (bottom corner)", has_overlay(2))

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_blocks_lenient_end_test: PASS")
os.exit(0)
