-- Bootstrap: add project lua/ to the path so bare `require` works.
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local from_md = require("organ.ast.from_md")
local cmark = dofile(vim.fn.getcwd() .. "/tests/cmark/html.lua")

local function check(md, html, msg)
  local got = cmark.render(from_md.parse(md))
  assert(got == html, string.format("%s\n  expected: %q\n  got:      %q", msg, html, got))
end

-- ex193: multi-line def, leading spaces, single-quoted title.
check(
  "   [foo]: \n      /url  \n           'the title'  \n\n[foo]\n",
  '<p><a href="/url" title="the title">foo</a></p>\n',
  "ex193"
)

-- ex194: escaped bracket in label, bare paren destination, paren-containing title.
check(
  "[Foo*bar\\]]:my_(url) 'title (with parens)'\n\n[Foo*bar\\]]\n",
  '<p><a href="my_(url)" title="title (with parens)">Foo*bar]</a></p>\n',
  "ex194"
)

-- ex195: label with space, angle-bracketed destination on its own line.
check(
  "[Foo bar]:\n<my url>\n'title'\n\n[Foo bar]\n",
  '<p><a href="my%20url" title="title">Foo bar</a></p>\n',
  "ex195"
)

-- ex196: multi-line title.
check(
  "[foo]: /url '\ntitle\nline1\nline2\n'\n\n[foo]\n",
  '<p><a href="/url" title="\ntitle\nline1\nline2\n">foo</a></p>\n',
  "ex196"
)

-- ex198: label, destination on next line, no title.
check("[foo]:\n/url\n\n[foo]\n", '<p><a href="/url">foo</a></p>\n', "ex198")

-- ex201: trailing junk after destination -> not a definition.
check("[foo]: <bar>(baz)\n\n[foo]\n", "<p>[foo]: <bar>(baz)</p>\n<p>[foo]</p>\n", "ex201")

-- ex208: multi-line label, leftover content becomes a paragraph.
check("[\nfoo\n]: /url\nbar\n", "<p>bar</p>\n", "ex208")

-- ex217: three consecutive defs, the middle title on a wrapped line.
check(
  '[foo]: /foo-url "foo"\n[bar]: /bar-url\n  "bar"\n[baz]: /baz-url\n\n[foo],\n[bar],\n[baz]\n',
  '<p><a href="/foo-url" title="foo">foo</a>,\n<a href="/bar-url" title="bar">bar</a>,\n<a href="/baz-url">baz</a></p>\n',
  "ex217"
)

-- ex541: multi-line label normalized for lookup.
check("[Foo\n  bar]: /url\n\n[Baz][Foo bar]\n", '<p><a href="/url">Baz</a></p>\n', "ex541")

-- Non-regression: single-line definition still works.
check('[foo]: /url "t"\n\n[foo]\n', '<p><a href="/url" title="t">foo</a></p>\n', "single-line def")

-- Non-regression: a def cannot interrupt a paragraph.
check("text\n[foo]: /url\n", "<p>text\n[foo]: /url</p>\n", "def cannot interrupt paragraph")

-- Non-regression: first definition wins.
check("[foo]: /a\n[foo]: /b\n\n[foo]\n", '<p><a href="/a">foo</a></p>\n', "first def wins")

-- Non-regression: no-throw on a pathological label.
assert(
  pcall(function()
    return from_md.parse("[" .. string.rep("a", 20000) .. "]: /u\n")
  end),
  "long label no throw"
)

-- ex215: a setext underline applies to what remains after leading defs.
assert(
  cmark.render(from_md.parse("[foo]: /url\nbar\n===\n[foo]\n"))
    == '<h1>bar</h1>\n<p><a href="/url">foo</a></p>\n',
  "ex215 ref-def then setext underlines remaining"
)

-- ex216: a paragraph that is entirely defs yields no setext heading.
assert(
  cmark.render(from_md.parse("[foo]: /url\n===\n[foo]\n")) == '<p>===\n<a href="/url">foo</a></p>\n',
  "ex216 all-defs paragraph: no setext heading"
)

-- A single-line ref-def whose destination contains a pipe must not be stolen as
-- a GFM table header by a following delimiter row.
assert(
  cmark.render(from_md.parse("[a]: /b|ar\n|---|---|\n\n[a]\n"))
    == '<p>|---|---|</p>\n<p><a href="/b%7Car">a</a></p>\n',
  "ref-def with pipe dest is not a table header"
)

print("commonmark_linkref_test: PASS")
