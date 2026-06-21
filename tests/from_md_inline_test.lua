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

-- Code spans.
assert(cmark.render(from_md.parse("`foo`\n")) == "<p><code>foo</code></p>\n", "simple code span")
assert(
  cmark.render(from_md.parse("`` foo ` bar ``\n")) == "<p><code>foo ` bar</code></p>\n",
  "double-backtick code span trims one space each end"
)
assert(
  cmark.render(from_md.parse("`` `code` ``\n")) == "<p><code>`code`</code></p>\n",
  "code span keeps inner backticks"
)
assert(cmark.render(from_md.parse("`foo\n")) == "<p>`foo</p>\n", "unmatched backtick is literal")
-- Code span content is HTML-escaped, not markup-processed.
assert(
  cmark.render(from_md.parse("`a < b`\n")) == "<p><code>a &lt; b</code></p>\n",
  "code span escapes html but no markup"
)
-- Hard break (two trailing spaces) and soft break.
assert(
  cmark.render(from_md.parse("foo  \nbar\n")) == "<p>foo<br />\nbar</p>\n",
  "two-space hard break"
)
assert(
  cmark.render(from_md.parse("foo\\\nbar\n")) == "<p>foo<br />\nbar</p>\n",
  "backslash hard break"
)
assert(cmark.render(from_md.parse("foo\nbar\n")) == "<p>foo\nbar</p>\n", "soft break is a newline")
-- Unmatched long backtick run must not throw or hang.
local ok_probe = pcall(from_md.parse, string.rep("`", 10000) .. "x\n")
assert(ok_probe, "unmatched long backtick run must not throw")

print("from_md_inline_test: PASS")
