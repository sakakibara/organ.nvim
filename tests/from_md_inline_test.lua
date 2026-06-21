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

-- Trailing spaces on a paragraph's final line are stripped (CommonMark #645).
assert(
  cmark.render(from_md.parse("foo  \n")) == "<p>foo</p>\n",
  "trailing spaces on last line stripped"
)
-- ...but a significant space before a code span is preserved.
assert(
  cmark.render(from_md.parse("foo `code`\n")) == "<p>foo <code>code</code></p>\n",
  "space before code span kept"
)

-- Autolinks.
assert(
  cmark.render(from_md.parse("<http://foo.bar.baz>\n"))
    == '<p><a href="http://foo.bar.baz">http://foo.bar.baz</a></p>\n',
  "uri autolink"
)
assert(
  cmark.render(from_md.parse("<irc://foo.bar:2233/baz>\n"))
    == '<p><a href="irc://foo.bar:2233/baz">irc://foo.bar:2233/baz</a></p>\n',
  "scheme autolink"
)
assert(
  cmark.render(from_md.parse("<MAILTO:FOO@BAR.BAZ>\n"))
    == '<p><a href="MAILTO:FOO@BAR.BAZ">MAILTO:FOO@BAR.BAZ</a></p>\n',
  "uppercase scheme autolink"
)
assert(
  cmark.render(from_md.parse("<foo@bar.example.com>\n"))
    == '<p><a href="mailto:foo@bar.example.com">foo@bar.example.com</a></p>\n',
  "email autolink"
)
-- A space inside disqualifies an autolink (falls through to literal <).
assert(
  cmark.render(from_md.parse("<http://foo.bar/baz bim>\n"))
    == "<p>&lt;http://foo.bar/baz bim&gt;</p>\n",
  "autolink with space is literal"
)
-- Raw inline HTML emitted verbatim.
assert(
  cmark.render(from_md.parse("<a><bab><c2c>\n")) == "<p><a><bab><c2c></p>\n",
  "raw html tags verbatim"
)
-- Mid-text open tag with multiple attribute forms (not a line-filling block).
assert(
  cmark.render(from_md.parse("x <a foo=\"bar\" bam = 'baz' _boolean zoop:33=zoop:33> y\n"))
    == "<p>x <a foo=\"bar\" bam = 'baz' _boolean zoop:33=zoop:33> y</p>\n",
  "raw html open tag with attributes verbatim"
)
assert(
  cmark.render(from_md.parse("x </a></foo > y\n")) == "<p>x </a></foo > y</p>\n",
  "raw html closing tags verbatim"
)
assert(
  cmark.render(from_md.parse("foo <!-- this is a comment - with hyphen --> bar\n"))
    == "<p>foo <!-- this is a comment - with hyphen --> bar</p>\n",
  "raw html comment verbatim"
)
assert(
  cmark.render(from_md.parse("foo <?php echo $a; ?> bar\n")) == "<p>foo <?php echo $a; ?> bar</p>\n",
  "raw html processing instruction verbatim"
)
assert(
  cmark.render(from_md.parse("foo <!ELEMENT br EMPTY> bar\n"))
    == "<p>foo <!ELEMENT br EMPTY> bar</p>\n",
  "raw html declaration verbatim"
)
assert(
  cmark.render(from_md.parse("foo <![CDATA[>&<]]> bar\n")) == "<p>foo <![CDATA[>&<]]> bar</p>\n",
  "raw html cdata verbatim"
)
-- A bare < that is neither autolink nor tag is a literal <.
assert(cmark.render(from_md.parse("a < b\n")) == "<p>a &lt; b</p>\n", "bare less-than is literal")
assert(
  cmark.render(from_md.parse("foo <bar/ baz>\n")) == "<p>foo &lt;bar/ baz&gt;</p>\n",
  "malformed tag is literal"
)

-- No-throw / no-hang guard on pathological < runs (must terminate quickly).
assert(pcall(from_md.parse, string.rep("<", 10000) .. "x\n"), "long < run must not throw")
assert(
  pcall(from_md.parse, string.rep("<a ", 10000) .. "\n"),
  "long unfinished-tag run must not throw"
)

-- A 1-character URI scheme is not an autolink (CommonMark #609).
assert(
  cmark.render(from_md.parse("<m:abc>\n")) == "<p>&lt;m:abc&gt;</p>\n",
  "1-char scheme is not an autolink"
)
-- A 2-character scheme IS an autolink.
assert(
  cmark.render(from_md.parse("<ab:xyz>\n")) == '<p><a href="ab:xyz">ab:xyz</a></p>\n',
  "2-char scheme is an autolink"
)
-- An HTML comment may contain internal double-hyphens (CommonMark 0.31).
assert(
  cmark.render(from_md.parse("foo <!-- a -- b -->\n")) == "<p>foo <!-- a -- b --></p>\n",
  "comment allows internal --"
)

-- Emphasis and strong (delimiter stack).
assert(cmark.render(from_md.parse("*foo bar*\n")) == "<p><em>foo bar</em></p>\n", "simple em")
assert(
  cmark.render(from_md.parse("**foo bar**\n")) == "<p><strong>foo bar</strong></p>\n",
  "simple strong"
)
assert(
  cmark.render(from_md.parse("***foo***\n")) == "<p><em><strong>foo</strong></em></p>\n",
  "em+strong"
)
-- Intraword: * allowed, _ not.
assert(
  cmark.render(from_md.parse("**foo**bar\n")) == "<p><strong>foo</strong>bar</p>\n",
  "intraword strong with *"
)
assert(
  cmark.render(from_md.parse("__foo__bar\n")) == "<p>__foo__bar</p>\n",
  "intraword __ is literal"
)
assert(
  cmark.render(from_md.parse("foo_bar_\n")) == "<p>foo_bar_</p>\n",
  "intraword _ closer is literal"
)
-- Flanking with punctuation.
assert(
  cmark.render(from_md.parse('a*"foo"*\n')) == "<p>a*&quot;foo&quot;*</p>\n",
  "* before quote not left-flanking here"
)
-- Leftover delimiter.
assert(
  cmark.render(from_md.parse("*foo**\n")) == "<p><em>foo</em>*</p>\n",
  "leftover delimiter stays literal"
)
-- Nested emphasis.
assert(
  cmark.render(from_md.parse("*foo **bar** baz*\n"))
    == "<p><em>foo <strong>bar</strong> baz</em></p>\n",
  "nested strong in em"
)
-- Emphasis across a soft break.
assert(
  cmark.render(from_md.parse("**foo\nbar**\n")) == "<p><strong>foo\nbar</strong></p>\n",
  "strong across soft break"
)
-- A code span inside emphasis stays a code span (precedence).
assert(
  cmark.render(from_md.parse("*`code`*\n")) == "<p><em><code>code</code></em></p>\n",
  "code span inside em"
)
-- No-throw on pathological delimiter runs.
assert(
  pcall(function()
    return from_md.parse(string.rep("*", 10000) .. "x\n")
  end),
  "10000 asterisks must not throw"
)
assert(
  pcall(function()
    return from_md.parse(string.rep("*a", 10000) .. "\n")
  end),
  "alternating must not throw"
)

-- Inline links.
assert(
  cmark.render(from_md.parse('[link](/uri "title")\n'))
    == '<p><a href="/uri" title="title">link</a></p>\n',
  "inline link with title"
)
assert(
  cmark.render(from_md.parse("[link](/uri)\n")) == '<p><a href="/uri">link</a></p>\n',
  "inline link no title"
)
assert(
  cmark.render(from_md.parse("[link]()\n")) == '<p><a href="">link</a></p>\n',
  "empty destination"
)
assert(
  cmark.render(from_md.parse("[a](<b c>)\n")) == '<p><a href="b%20c">a</a></p>\n',
  "angle dest with space normalized"
)
assert(
  cmark.render(from_md.parse("[link](foo\nbar)\n")) == "<p>[link](foo\nbar)</p>\n",
  "newline in dest is not a link"
)
assert(
  cmark.render(from_md.parse("[link](foo(and(bar))\n")) == "<p>[link](foo(and(bar))</p>\n",
  "unbalanced parens not a link"
)
-- Emphasis inside link text resolves.
assert(
  cmark.render(from_md.parse("[*foo*](/u)\n")) == '<p><a href="/u"><em>foo</em></a></p>\n',
  "emphasis inside link text"
)
-- Links cannot nest links: the inner [b](/u) forms a link and deactivates the
-- outer [ opener, so the outer brackets stay literal.
assert(
  cmark.render(from_md.parse("[a [b](/u) c]\n")) == '<p>[a <a href="/u">b</a> c]</p>\n',
  "no nested links: inner link, outer brackets literal"
)
-- Inline images; alt text is plain (emphasis stripped).
assert(
  cmark.render(from_md.parse("![](/url)\n")) == '<p><img src="/url" alt="" /></p>\n',
  "empty image"
)
assert(
  cmark.render(from_md.parse("![*foo*](/u)\n")) == '<p><img src="/u" alt="foo" /></p>\n',
  "image alt is plain text"
)
-- No-throw on pathological brackets.
assert(
  pcall(function()
    return from_md.parse(string.rep("[", 10000) .. "x\n")
  end),
  "10000 open brackets no throw"
)
assert(
  pcall(function()
    return from_md.parse(string.rep("![](", 10000) .. "\n")
  end),
  "10000 image opens no throw"
)

print("from_md_inline_test: PASS")
