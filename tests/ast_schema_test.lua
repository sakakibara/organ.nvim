-- Schema-level smoke test for organ.ast block-kind constructors:
-- construct the node, verify the shape, confirm the validator accepts
-- a document containing it.
--
-- Run via: nvim --headless -l tests/ast_schema_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local A = require("organ.ast")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- footnote_definition: block kind paired with the inline footnote_ref.
local fn_def = A.footnote_definition("1", { A.paragraph({ A.text("body") }) })
check(
  "footnote_definition constructor returns the right kind",
  fn_def.kind == "footnote_definition",
  "got " .. tostring(fn_def.kind)
)
check(
  "footnote_definition has a label field",
  fn_def.label == "1",
  "got " .. tostring(fn_def.label)
)
check(
  "footnote_definition.content is a list of blocks",
  type(fn_def.content) == "table" and fn_def.content[1] and fn_def.content[1].kind == "paragraph"
)

-- Validator accepts a document containing a footnote_definition.
local doc = A.document({ fn_def })
local ok, err = A.validate(doc)
check("validator accepts document with footnote_definition", ok, err)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_schema_test: PASS")
os.exit(0)
