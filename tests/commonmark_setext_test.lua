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

-- A setext underline whose paragraph is entirely link reference definitions has
-- nothing to underline.  The line was already consumed as a setext candidate, so
-- it becomes ORDINARY paragraph text -- a `-` run does NOT fall back to a
-- thematic break, and a lone `-` does NOT open a list.  Verified against
-- CommonMark 0.31.2 (`cmark`); the bundled spec covers only the `===` variant
-- (example 216).
assert(
  cmark.render(from_md.parse("[a]: /u\n---\n")) == "<p>---</p>\n",
  "ref-def then '---' is paragraph text, not a thematic break"
)
assert(
  cmark.render(from_md.parse("[a]: /u\n-\n")) == "<p>-</p>\n",
  "ref-def then lone '-' is paragraph text, not an empty list item"
)
assert(
  cmark.render(from_md.parse("[a]: /u\n-----\n")) == "<p>-----</p>\n",
  "ref-def then a longer dash run is still paragraph text"
)
assert(
  cmark.render(from_md.parse("[foo]: /url\n===\n[foo]\n")) == '<p>===\n<a href="/url">foo</a></p>\n',
  "ref-def then '===' is paragraph text (spec example 216), unchanged"
)
-- A `*`/`_` run after a ref-def is a pure thematic break (never a setext marker),
-- so it stays an <hr> -- this path is untouched by the fix.
assert(
  cmark.render(from_md.parse("[a]: /u\n***\n")) == "<hr />\n",
  "ref-def then '***' is still a thematic break"
)

print("commonmark_setext_test: PASS")
