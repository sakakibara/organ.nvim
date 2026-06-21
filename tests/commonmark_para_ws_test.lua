-- Bootstrap: add project lua/ to the path so bare `require` works.
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local from_md = require("organ.ast.from_md")
local cmark = dofile(vim.fn.getcwd() .. "/tests/cmark/html.lua")

local function check(md, html, msg)
  local got = cmark.render(from_md.parse(md))
  assert(got == html, string.format("%s\n  expected: %q\n  got:      %q", msg, html, got))
end

-- ex56: 1-space-indented paragraph.
check(" *-*\n", "<p><em>-</em></p>\n", "ex56")

-- ex222: 2-space-indented first line, 1-space-indented second line.
check("  aaa\n bbb\n", "<p>aaa\nbbb</p>\n", "ex222")

-- ex224: 3-space-indented first line, second line not indented.
check("   aaa\nbbb\n", "<p>aaa\nbbb</p>\n", "ex224")

-- ex252: block-quote: 5-space body is code (4+ cols after '>'), 4-space is not.
check(
  ">     code\n\n>    not code\n",
  "<blockquote>\n<pre><code>code\n</code></pre>\n</blockquote>\n<blockquote>\n<p>not code</p>\n</blockquote>\n",
  "ex252"
)

-- ex255: list item followed by 1-space lazy continuation (not indented enough for item).
check("- one\n\n two\n", "<ul>\n<li>one</li>\n</ul>\n<p>two</p>\n", "ex255")

-- ex275: 3-space-indented paragraph.
check("   foo\n\nbar\n", "<p>foo</p>\n<p>bar</p>\n", "ex275")

-- ex276: list item followed by 2-space indented paragraph (outside item).
check("-    foo\n\n  bar\n", "<ul>\n<li>foo</li>\n</ul>\n<p>bar</p>\n", "ex276")

-- Non-regression: interior whitespace and a hard line break are preserved.
assert(cmark.render(from_md.parse("a   b\n")) == "<p>a   b</p>\n", "interior whitespace kept")
assert(
  cmark.render(from_md.parse("foo  \nbar\n")) == "<p>foo<br />\nbar</p>\n",
  "hard line break kept"
)
-- A 4-space-indented lazy continuation line is stripped (cannot become code).
assert(
  cmark.render(from_md.parse("aaa\n    bbb\n")) == "<p>aaa\nbbb</p>\n",
  "indented lazy continuation stripped"
)
-- An indented code block is unaffected (its body keeps interior indentation).
assert(
  cmark.render(from_md.parse("    code\n     more\n")) == "<pre><code>code\n more\n</code></pre>\n",
  "indented code body unaffected"
)

print("commonmark_para_ws_test: PASS")
