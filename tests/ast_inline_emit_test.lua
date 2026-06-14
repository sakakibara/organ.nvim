-- to_org.emit_inline reproduces the org surface form of each inline kind.
-- Run via: nvim --headless -l tests/ast_inline_emit_test.lua
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

-- Render a paragraph holding a single inline node, return the line.
local function emit(node)
  return to_org.render(A.document({ A.paragraph({ node }) }))
end

check(emit(A.entity("copy")):find("\\copy", 1, true) ~= nil, "emit entity")
check(emit(A.subscript({ A.text("i") })):find("_{i}", 1, true) ~= nil, "emit subscript")
check(emit(A.superscript({ A.text("2") })):find("^{2}", 1, true) ~= nil, "emit superscript")
check(emit(A.statistics_cookie("[1/3]")):find("[1/3]", 1, true) ~= nil, "emit statistics_cookie")
check(
  emit(A.timestamp("<2026-06-14 Sun>", "active")):find("<2026-06-14 Sun>", 1, true) ~= nil,
  "emit timestamp"
)
check(emit(A.target("x")):find("<<x>>", 1, true) ~= nil, "emit target")
check(emit(A.macro("m", { "a", "b" })):find("{{{m(a,b)}}}", 1, true) ~= nil, "emit macro with args")
check(emit(A.macro("plain", {})):find("{{{plain}}}", 1, true) ~= nil, "emit macro no args")
check(emit(A.raw_inline("@@html:<br>@@")):find("@@html:<br>@@", 1, true) ~= nil, "emit raw_inline")
check(emit(A.footnote_ref("1")):find("[fn:1]", 1, true) ~= nil, "emit footnote label only")
check(
  emit(A.footnote_ref(nil, { A.text("anon") })):find("[fn::anon]", 1, true) ~= nil,
  "emit anonymous footnote"
)
check(
  emit(A.footnote_ref("lbl", { A.text("body") })):find("[fn:lbl:body]", 1, true) ~= nil,
  "emit inline-named footnote"
)
check(
  emit(A.math({ display = false, body = "x", style = "dollar" })):find("$x$", 1, true) ~= nil,
  "emit inline dollar math"
)
check(
  emit(A.math({ display = true, body = "x", style = "dollar" })):find("$$x$$", 1, true) ~= nil,
  "emit display dollar math"
)
check(
  emit(A.math({ display = false, body = "x", style = "paren" })):find("\\(x\\)", 1, true) ~= nil,
  "emit paren math"
)
check(
  emit(A.math({ display = true, body = "x", style = "bracket" })):find("\\[x\\]", 1, true) ~= nil,
  "emit bracket math"
)

print("ALL PASS: ast_inline_emit")
