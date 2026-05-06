-- Blank lines under a heading must not open a phantom 1-line body
-- fold (which would render as a closed-fold "+" indicator on the
-- separator).  Run via: nvim --headless -l tests/fold_blank_separator_test.lua

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
  return fold._build_fold_levels(b)
end

do
  local lv = levels_for({ "* H1", "", "* H2" })
  check("H/blank/H: separator at heading level", lv[2] == "1", "got " .. tostring(lv[2]))
end

do
  local lv = levels_for({ "* H1", "para", "", "* H2" })
  check("trailing blank demoted", lv[3] == "1", "got " .. tostring(lv[3]))
end

do
  local lv = levels_for({ "* H1", "", "para" })
  check("leading blank stays at heading level", lv[2] == "1", "got " .. tostring(lv[2]))
  check("first content opens body fold", lv[3] == ">2", "got " .. tostring(lv[3]))
end

do
  local lv = levels_for({ "* H1", "para1", "", "para2" })
  check("intermediate blank inside body fold", lv[3] == "2", "got " .. tostring(lv[3]))
end

do
  local lv = levels_for({ "* H1", "para", "" })
  check("EOF trailing blank demoted", lv[3] == "1", "got " .. tostring(lv[3]))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_blank_separator_test: PASS")
os.exit(0)
