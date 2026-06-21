local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
local inline = require("organ.ast.from_md_inline")
local from_md = require("organ.ast.from_md")
local cmark = dofile(root .. "/tests/cmark/html.lua")

-- Plain text is one text node (round-trippable, unchanged).
local n = inline.parse("hello world", {})
assert(
  #n == 1 and n[1].kind == "text" and n[1].text == "hello world",
  "plain text -> one text node"
)

-- Backslash before ASCII punctuation drops the backslash, keeps the punctuation literal.
assert(
  inline.parse("\\*not emphasis\\*", {})[1].text == "*not emphasis*",
  "escaped asterisks are literal"
)
assert(inline.parse("a\\!b", {})[1].text == "a!b", "escaped punctuation")
-- Backslash before a non-punctuation char stays a literal backslash.
assert(
  inline.parse("\\A\\ \\3", {})[1].text == "\\A\\ \\3",
  "backslash before non-punct stays literal"
)
assert(inline.parse("foo\\", {})[1].text == "foo\\", "trailing backslash stays literal")

-- The inline pass replaces a paragraph's flat text with parsed inline nodes.
local doc = from_md.parse("a \\* b\n")
assert(doc.children[1].kind == "paragraph", "paragraph block")
assert(cmark.render(doc) == "<p>a * b</p>\n", "paragraph inline-parsed: escaped * is literal")
-- Plain paragraph still renders identically (roundtrip safety).
assert(
  cmark.render(from_md.parse("just words here\n")) == "<p>just words here</p>\n",
  "plain paragraph unchanged"
)

print("from_md_inline_test: PASS")
