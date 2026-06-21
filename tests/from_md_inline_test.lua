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

print("from_md_inline_test: PASS")
