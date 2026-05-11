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

-- Validator accepts a document built from every new kind added by this branch.
local big = A.document({
  A.directive("TITLE", "Big doc"),
  A.directive("AUTHOR", "Author"),
  A.rule(),
  A.block("quote", { content = { A.paragraph({ A.text("quoted") }) } }),
  A.block("example", { body = "raw text\nline 2" }),
  A.block("verse", { body = "verse line 1\nverse line 2" }),
  A.block("export", { body = "<html>" }),
  {
    kind = "table",
    alignments = { "l", "l" },
    rows = {
      { cells = { { A.text("a") }, { A.text("b") } }, sep = false },
      { sep = true, cells = {} },
      { cells = { { A.text("c") }, { A.text("d") } }, sep = false },
    },
  },
  { kind = "image", target = "fig.png", alt = "a fig" },
  A.paragraph({
    A.text("ref "),
    { kind = "footnote_ref", label = "1" },
    A.text(" and "),
    { kind = "math", display = false, body = "x" },
    A.text("."),
  }),
  A.footnote_definition("1", { A.paragraph({ A.text("footnote body") }) }),
})
local ok2, err2 = A.validate(big)
check("validator accepts every new kind", ok2, err2)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_schema_test: PASS")
os.exit(0)
