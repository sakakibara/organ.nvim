-- `fold.body_fold = false` semantics: body lines (including blanks)
-- share the parent heading's level.  No phantom body fold can exist
-- because body has no fold of its own.
--
-- This test explicitly disables `cycle_separator_lines` (which would
-- otherwise demote trailing blanks to an outer level so they stay
-- visible after the section folds -- the Emacs-default behavior, see
-- tests/fold_cycle_separator_lines_test.lua).  The two features are
-- orthogonal and this file pins the body-blank-at-section-level
-- contract with separator-lines OFF.
--
-- Run via: nvim --headless -l tests/fold_blank_separator_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  fold = { cycle_separator_lines = false },
})

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
  check("body line at heading level (no body fold)", lv[2] == "1", "got " .. tostring(lv[2]))
  check("trailing blank at heading level", lv[3] == "1", "got " .. tostring(lv[3]))
end

do
  local lv = levels_for({ "* H1", "", "para" })
  check("leading blank at heading level", lv[2] == "1", "got " .. tostring(lv[2]))
  check("body line at heading level", lv[3] == "1", "got " .. tostring(lv[3]))
end

do
  local lv = levels_for({ "* H1", "para1", "", "para2" })
  check("body line at heading level", lv[2] == "1", "got " .. tostring(lv[2]))
  check("intermediate blank at heading level", lv[3] == "1", "got " .. tostring(lv[3]))
  check("subsequent body at heading level", lv[4] == "1", "got " .. tostring(lv[4]))
end

do
  local lv = levels_for({ "* H1", "para", "" })
  check("EOF trailing blank at heading level", lv[3] == "1", "got " .. tostring(lv[3]))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_blank_separator_test: PASS")
os.exit(0)
