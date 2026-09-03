-- to_org.emit_list renders bullet marker, counter, checkbox, and tag.
-- Run via: nvim --headless -l tests/ast_list_emit_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local A = require("organ.ast.init")
local to_org = require("organ.ast.to_org")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

local function emit(item, ordered)
  return to_org.render(A.document({ A.list(ordered or false, { item }) }))
end

local function para(s)
  return { A.paragraph({ A.text(s) }) }
end

check(emit(A.list_item({ marker = "-", content = para("a") })):find("- a", 1, true), "marker dash")
check(emit(A.list_item({ marker = "+", content = para("a") })):find("+ a", 1, true), "marker plus")
check(emit(A.list_item({ marker = "*", content = para("a") })):find("* a", 1, true), "marker star")
check(
  emit(A.list_item({ marker = "1)", content = para("a") }), true):find("1) a", 1, true),
  "marker paren ordered"
)
check(
  emit(A.list_item({ marker = "3.", content = para("a") }), true):find("3. a", 1, true),
  "marker non-1 start"
)
check(
  emit(A.list_item({ marker = "1.", counter = "5", content = para("x") }), true):find(
    "1. [@5] x",
    1,
    true
  ),
  "counter"
)
check(
  emit(A.list_item({ marker = "-", checkbox = "done", content = para("x") })):find(
    "- [X] x",
    1,
    true
  ),
  "checkbox"
)
check(
  emit(A.list_item({ marker = "-", tag = { A.text("term") }, content = para("def") })):find(
    "- term :: def",
    1,
    true
  ),
  "description tag"
)
-- fallback: no marker -> computed
check(
  emit(A.list_item({ content = para("a") }), true):find("1. a", 1, true),
  "fallback ordered marker"
)
check(
  emit(A.list_item({ content = para("a") }), false):find("- a", 1, true),
  "fallback unordered marker"
)

-- Continuation blocks: a blank line before a second paragraph, every
-- block kind rendered at the item's content column.
do
  local out = emit(A.list_item({
    marker = "-",
    content = {
      A.paragraph({ A.text("first para") }),
      A.paragraph({ A.text("second para") }),
    },
  }))
  check(
    out:find("- first para\n\n  second para\n", 1, true) ~= nil,
    "continuation paragraph after blank line"
  )
  local out2 = emit(A.list_item({
    marker = "1.",
    content = {
      A.paragraph({ A.text("intro") }),
      A.code_block("lua", "print(1)"),
      A.list(false, { A.list_item({ marker = "-", content = para("nested") }) }),
    },
  }))
  check(
    out2:find("1. intro\n   #+begin_src lua\n   print(1)\n   #+end_src\n   - nested\n", 1, true)
      ~= nil,
    "code block and sublist at the content column"
  )
end

print("ALL PASS: ast_list_emit")
