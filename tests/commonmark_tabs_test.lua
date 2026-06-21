local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_md = require("organ.ast.from_md")
local cmark = dofile(root .. "/tests/cmark/html.lua")

assert(
  cmark.render(from_md.parse("\tfoo\tbaz\t\tbim\n"))
    == "<pre><code>foo\tbaz\t\tbim\n</code></pre>\n",
  "ex1 leading tab -> code, interior tabs kept"
)
assert(
  cmark.render(from_md.parse("  \tfoo\tbaz\t\tbim\n"))
    == "<pre><code>foo\tbaz\t\tbim\n</code></pre>\n",
  "ex2 spaces+tab -> code"
)
assert(
  cmark.render(from_md.parse("  - foo\n\n\tbar\n"))
    == "<ul>\n<li>\n<p>foo</p>\n<p>bar</p>\n</li>\n</ul>\n",
  "ex4 tab continues list item"
)
assert(
  cmark.render(from_md.parse("- foo\n\n\t\tbar\n"))
    == "<ul>\n<li>\n<p>foo</p>\n<pre><code>  bar\n</code></pre>\n</li>\n</ul>\n",
  "ex5 double tab -> code in item, 2-space residual"
)
assert(
  cmark.render(from_md.parse(">\t\tfoo\n"))
    == "<blockquote>\n<pre><code>  foo\n</code></pre>\n</blockquote>\n",
  "ex6 partial tab after > -> code, 2-space residual"
)
assert(
  cmark.render(from_md.parse("-\t\tfoo\n"))
    == "<ul>\n<li>\n<pre><code>  foo\n</code></pre>\n</li>\n</ul>\n",
  "ex7 partial tab after marker -> code"
)
assert(
  cmark.render(from_md.parse("    foo\n\tbar\n")) == "<pre><code>foo\nbar\n</code></pre>\n",
  "ex8 tab continues indented code"
)
assert(
  cmark.render(from_md.parse(" - foo\n   - bar\n\t - baz\n"))
    == "<ul>\n<li>foo\n<ul>\n<li>bar\n<ul>\n<li>baz</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n",
  "ex9 tab as nested-list indent"
)
-- Interior tabs in a paragraph are preserved.
assert(cmark.render(from_md.parse("a\tb\n")) == "<p>a\tb</p>\n", "interior tab in paragraph kept")
-- No-throw on pathological tab runs.
assert(
  pcall(function()
    return from_md.parse(string.rep("\t", 10000) .. "x\n")
  end),
  "many tabs no throw"
)

print("commonmark_tabs_test: PASS")
