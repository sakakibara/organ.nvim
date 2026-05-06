-- Foldable block ranges (src_block, drawer, etc.) must include their
-- closing marker line.  Treesitter `end_()` is exclusive: when
-- end_col > 0 the last content row is `end_row + 1` (1-indexed).
-- Run via: nvim --headless -l tests/fold_block_end_marker_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local fold = require("organ.fold")

local function levels_for(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  pcall(vim.treesitter.get_parser, b, "org")
  return fold._build_fold_levels(b)
end

do
  local lv = levels_for({ "* H1", "#+begin_src lua", "print('hi')", "#+end_src" })
  check("`#+begin_src` opens sub-fold", lv[2] == ">2", "got " .. tostring(lv[2]))
  check("`#+end_src` inside sub-fold", lv[4] == "2", "got " .. tostring(lv[4]))
end

do
  local lv = levels_for({ "* H1", ":PROPERTIES:", ":Effort: 1:00", ":END:" })
  check("`:PROPERTIES:` opens sub-fold", lv[2] == ">2", "got " .. tostring(lv[2]))
  check("`:END:` inside sub-fold", lv[4] == "2", "got " .. tostring(lv[4]))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_block_end_marker_test: PASS")
os.exit(0)
