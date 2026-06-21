-- Bootstrap: add project lua/ to the path so bare `require` works.
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local from_md = require("organ.ast.from_md")
local cmark = dofile(vim.fn.getcwd() .. "/tests/cmark/html.lua")

-- ex549: escaped bracket in full reference link label.
assert(
  cmark.render(from_md.parse("[foo][ref\\[]\n\n[ref\\[]: /uri\n"))
    == '<p><a href="/uri">foo</a></p>\n',
  "549 escaped bracket in ref label"
)

-- Plain full reference still works.
assert(
  cmark.render(from_md.parse("[foo][bar]\n\n[bar]: /uri\n")) == '<p><a href="/uri">foo</a></p>\n',
  "plain full reference"
)

-- Collapsed reference still works.
assert(
  cmark.render(from_md.parse("[bar][]\n\n[bar]: /uri\n")) == '<p><a href="/uri">bar</a></p>\n',
  "collapsed reference"
)

-- An unmatched full reference (no such label) falls back to literal text.
assert(
  cmark.render(from_md.parse("[foo][nope]\n")) == "<p>[foo][nope]</p>\n",
  "unmatched full reference is literal"
)

-- An unescaped bracket inside the second label is not a valid label.
assert(
  cmark.render(from_md.parse("[foo][a[b]\n\n[a[b]: /uri\n"))
    == "<p>[foo][a[b]</p>\n<p>[a[b]: /uri</p>\n",
  "unescaped bracket label invalid"
)

print("commonmark_ref_label_test: PASS")
