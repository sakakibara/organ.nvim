-- Unit tests for organ.ast.to_md.  Hand-built ASTs are fed directly
-- to M.render; no from_org involvement, no tree-sitter.
--
-- Run via: nvim --headless -l tests/ast_to_md_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local A = require("organ.ast")
local to_md = require("organ.ast.to_md")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- ---- empty document --------------------------------------------------
do
  local doc = A.document({})
  local out = to_md.render(doc)
  check("empty doc renders to a single newline", out == "\n",
    "got " .. vim.inspect(out))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_md_test: PASS")
os.exit(0)
