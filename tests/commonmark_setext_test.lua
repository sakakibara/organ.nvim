-- Bootstrap: add project lua/ to the path so bare `require` works.
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local from_md = require("organ.ast.from_md")
local cmark = dofile(vim.fn.getcwd() .. "/tests/cmark/html.lua")

assert(
  cmark.render(from_md.parse("Foo\n= =\n\nFoo\n--- -\n")) == "<p>Foo\n= =</p>\n<p>Foo</p>\n<hr />\n",
  "ex88 '--- -' is a thematic break, not setext"
)
assert(
  cmark.render(from_md.parse("> Foo\n---\n")) == "<blockquote>\n<p>Foo</p>\n</blockquote>\n<hr />\n",
  "ex92 lazy '---' closes quote, is hr"
)
assert(
  cmark.render(from_md.parse("> foo\nbar\n===\n"))
    == "<blockquote>\n<p>foo\nbar\n===</p>\n</blockquote>\n",
  "ex93 lazy '===' is paragraph text, not setext"
)
assert(
  cmark.render(from_md.parse("- Foo\n---\n")) == "<ul>\n<li>Foo</li>\n</ul>\n<hr />\n",
  "ex94 '---' closes list, is hr"
)
assert(
  cmark.render(from_md.parse("- foo\n-----\n")) == "<ul>\n<li>foo</li>\n</ul>\n<hr />\n",
  "ex99 '-----' closes list, is hr"
)
assert(
  cmark.render(from_md.parse("> foo\n-----\n"))
    == "<blockquote>\n<p>foo</p>\n</blockquote>\n<hr />\n",
  "ex101 '-----' closes quote, is hr"
)
-- Non-regression: a real setext underline in the SAME container still forms a heading.
assert(
  cmark.render(from_md.parse("Foo\n---\n")) == "<h2>Foo</h2>\n",
  "top-level setext still works"
)
assert(
  cmark.render(from_md.parse("> Foo\n> ---\n")) == "<blockquote>\n<h2>Foo</h2>\n</blockquote>\n",
  "setext inside a continued quote still works"
)
assert(cmark.render(from_md.parse("Foo\n===\n")) == "<h1>Foo</h1>\n", "setext level 1 still works")

print("commonmark_setext_test: PASS")
