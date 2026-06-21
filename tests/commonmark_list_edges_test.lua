-- Bootstrap: add project lua/ to the path so bare `require` works.
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local from_md = require("organ.ast.from_md")
local cmark = dofile(vim.fn.getcwd() .. "/tests/cmark/html.lua")

-- 315 / 280 / 320 oracle
assert(
  cmark.render(from_md.parse("* a\n*\n\n* c\n"))
    == "<ul>\n<li>\n<p>a</p>\n</li>\n<li></li>\n<li>\n<p>c</p>\n</li>\n</ul>\n",
  "315 empty item in loose list"
)
assert(
  cmark.render(from_md.parse("-\n\n  foo\n")) == "<ul>\n<li></li>\n</ul>\n<p>foo</p>\n",
  "280 item begins with at most one blank line"
)
assert(
  cmark.render(from_md.parse("* a\n  > b\n  >\n* c\n"))
    == "<ul>\n<li>a\n<blockquote>\n<p>b</p>\n</blockquote>\n</li>\n<li>c</li>\n</ul>\n",
  "320 blank in blockquote does not loosen list"
)

-- Non-regression: tight and loose basics, empty item followed immediately by
-- content, blank directly in an item loosens.
assert(
  cmark.render(from_md.parse("* a\n* c\n")) == "<ul>\n<li>a</li>\n<li>c</li>\n</ul>\n",
  "simple tight list"
)
assert(
  cmark.render(from_md.parse("* a\n\n* c\n"))
    == "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n",
  "blank between items loosens"
)
assert(
  cmark.render(from_md.parse("-\n  foo\n")) == "<ul>\n<li>foo</li>\n</ul>\n",
  "empty marker then immediate content (one blank only)"
)
assert(
  cmark.render(from_md.parse("- a\n\n  b\n")) == "<ul>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n</ul>\n",
  "blank directly in item loosens (two paragraphs)"
)
assert(
  cmark.render(from_md.parse("- a\n- \n- c\n"))
    == "<ul>\n<li>a</li>\n<li></li>\n<li>c</li>\n</ul>\n",
  "tight list with empty item"
)
-- A blank inside a sublist nested in a blockquote inside an item still loosens
-- the outer list when a sibling outer item follows (deepest match is the inner item).
assert(
  cmark.render(from_md.parse("- > - a\n  >\n- b\n"))
    == "<ul>\n<li>\n<blockquote>\n<ul>\n<li>a</li>\n</ul>\n</blockquote>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n",
  "blank in sublist-in-blockquote loosens outer list"
)

print("commonmark_list_edges_test: PASS")
