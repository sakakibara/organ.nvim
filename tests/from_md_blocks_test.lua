local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
local from_md = require("organ.ast.from_md")

local function only(md)
  local d = from_md.parse(md)
  return d.children[1]
end

-- ATX heading levels and content.
local h = only("# Title\n")
assert(h.kind == "headline" and h.level == 1, "level-1 heading")
assert(h.title[1].kind == "text" and h.title[1].text == "Title", "heading title text")
assert(only("###### Six\n").level == 6, "level-6 heading")
assert(only("####### Seven\n").kind == "paragraph", "7 hashes is a paragraph, not a heading")
-- Optional closing sequence and surrounding spaces are stripped.
assert(only("##  Padded  ##\n").title[1].text == "Padded", "closing #s and spaces trimmed")
-- Up to 3 leading spaces still a heading; a hash with no space is not.
assert(only("   # Indented\n").level == 1, "<=3 leading spaces ok")
assert(only("#No space\n").kind == "paragraph", "hash without space is a paragraph")

assert(only("***\n").kind == "rule", "*** is a thematic break")
assert(only("---\n").kind == "rule", "--- alone is a thematic break")
assert(only("___\n").kind == "rule", "___ is a thematic break")
assert(only("- - -\n").kind == "rule", "spaced dashes are a thematic break")
assert(only("--\n").kind == "paragraph", "only two dashes is not a break")
assert(only("*-*\n").kind == "paragraph", "mixed chars are not a break")

local cb = only("```lua\nx = 1\n```\n")
assert(cb.kind == "code_block", "fenced code block")
assert(cb.language == "lua", "info string language")
assert(cb.body == "x = 1\n", "code body keeps trailing newline")
local plain = only("```\nraw\n```\n")
assert(
  plain.kind == "code_block" and (plain.language == nil or plain.language == ""),
  "no language"
)
-- Unclosed fence runs to EOF.
local unclosed = only("```\nstill code\n")
assert(unclosed.kind == "code_block" and unclosed.body == "still code\n", "unclosed fence to EOF")
-- Tildes work too.
assert(only("~~~\ntc\n~~~\n").kind == "code_block", "tilde fence")

-- Indented code blocks (>=4 spaces, not continuing a paragraph).
local ic = only("    indented code\n")
assert(ic.kind == "code_block" and ic.body == "indented code\n", "4-space indented code")
-- A paragraph followed by an indented line is a lazy paragraph continuation.
local doc = from_md.parse("text\n    not code\n")
assert(doc.children[1].kind == "paragraph", "indent after paragraph stays paragraph")

-- ATX heading whose entire content is a closing '#' run must yield an empty title.
local empty_atx = only("### ###\n")
assert(
  empty_atx.kind == "headline" and (#empty_atx.title == 0 or empty_atx.title[1].text == ""),
  "empty ATX heading from all-closing content"
)

-- Setext headings: a paragraph underlined by = (h1) or - (h2).
local s1 = only("Title\n=====\n")
assert(s1.kind == "headline" and s1.level == 1, "setext h1")
assert(s1.title[1].text == "Title", "setext h1 title")
local s2 = only("Subtitle\n---\n")
assert(s2.kind == "headline" and s2.level == 2, "setext h2")
-- Multi-line paragraph content joins into the heading.
local multi = only("foo\nbar\n===\n")
assert(multi.kind == "headline" and multi.title[1].text == "foo\nbar", "multi-line setext content")
-- An underline with no preceding paragraph is not a setext heading.
assert(only("=====\n").kind == "paragraph", "=== with no paragraph is a paragraph")
-- A dash line with no paragraph is still a thematic break.
assert(only("---\n").kind == "rule", "--- with no paragraph stays a thematic break")

-- Link reference definitions: consumed, emit no block, recorded in the map.
local d = from_md.parse('[foo]: /url "title"\n')
assert(#d.children == 0, "a lone reference definition emits no block")
assert(d.reference_map ~= nil, "parse attaches a reference_map")
assert(d.reference_map["foo"].destination == "/url", "destination recorded")
assert(d.reference_map["foo"].title == "title", "title recorded")
-- Label normalization: case-fold + whitespace-collapse.
local d2 = from_md.parse("[  Foo  Bar ]: /u\n")
assert(d2.reference_map["foo bar"].destination == "/u", "label normalized (case-fold, collapse)")
-- A definition followed by a paragraph: def consumed, paragraph kept.
local d3 = from_md.parse("[a]: /x\n\ntext\n")
assert(#d3.children == 1 and d3.children[1].kind == "paragraph", "paragraph after def survives")
-- A bracketed line that is NOT a definition stays a paragraph.
local d4 = from_md.parse("[not a def] just text\n")
assert(d4.children[1].kind == "paragraph", "non-definition bracket line is a paragraph")

-- HTML blocks (kinds 1-6): raw, verbatim, mapped to block(export/html).
local function is_html_block(node)
  return node.kind == "block" and node.style == "export" and node.backend == "html"
end
-- Kind 2: comment, complete on one line.
assert(is_html_block(only("<!-- a comment -->\n")), "kind 2 single-line comment")
-- Kind 1: pre ... </pre>, multi-line, verbatim body.
local pre = only("<pre>\nx < y & z\n</pre>\n")
assert(is_html_block(pre), "kind 1 pre block")
assert(pre.body == "<pre>\nx < y & z\n</pre>\n", "kind 1 body is verbatim (no escaping)")
-- Kind 6: a <div> block ends at the next blank line (the blank line is excluded).
local doc = from_md.parse("<div>\nstuff\n\nafter\n")
assert(is_html_block(doc.children[1]), "kind 6 div block")
assert(doc.children[1].body == "<div>\nstuff\n", "kind 6 body ends before the blank line")
assert(doc.children[2].kind == "paragraph", "content after the blank line is a paragraph")

-- Kind 7: a complete tag alone on a line (ending at a blank line); cannot
-- interrupt a paragraph.
local k7 = from_md.parse('<a href="/x">\ncontent\n\nafter\n')
assert(is_html_block(k7.children[1]), "kind 7 open tag block")
assert(k7.children[1].body == '<a href="/x">\ncontent\n', "kind 7 body ends before blank line")
-- Kind 7 does NOT interrupt a paragraph.
local notk7 = from_md.parse('text\n<a href="/x">\n')
assert(notk7.children[1].kind == "paragraph", "kind 7 cannot interrupt a paragraph")
-- A non-complete tag line is not a kind-7 block.
assert(only("<a href=\n").kind == "paragraph", "incomplete tag is a paragraph")

-- Block quotes: the first real container.  Content is parsed by the same stack
-- machinery (recursive containment), so quotes nest and any block may open
-- inside one.
local function is_quote(n)
  return n.kind == "block" and n.style == "quote"
end
-- Simple block quote with a paragraph inside.
local q = only("> hello\n> world\n")
assert(is_quote(q), "block quote node")
assert(q.content[1].kind == "paragraph", "quote contains a paragraph")
assert(q.content[1].inline[1].text == "hello\nworld", "quote paragraph text (marker stripped)")
-- A heading inside a quote.
local qh = only("> # Title\n")
assert(
  is_quote(qh) and qh.content[1].kind == "headline" and qh.content[1].level == 1,
  "heading in quote"
)
-- Nested block quotes.
local nq = only("> > deep\n")
assert(is_quote(nq) and is_quote(nq.content[1]), "nested block quote")
-- Lazy continuation: a >-less line continues the quote's paragraph.
local lazy = only("> a\nb\n")
assert(
  is_quote(lazy) and lazy.content[1].inline[1].text == "a\nb",
  "lazy continuation into quote paragraph"
)

-- A long single-line run of '>' markers must not overflow the stack.
local ok = pcall(function()
  return from_md.parse(string.rep("> ", 10000) .. "deep\n")
end)
assert(ok, "deeply-quoted single line must not throw (stack overflow regression)")

-- Lists: bullet and ordered, with structure + tight HTML.
local cmark = dofile(vim.fn.getcwd() .. "/tests/cmark/html.lua")
local function is_list(n)
  return n.kind == "list"
end
local bl = only("- a\n- b\n")
assert(is_list(bl) and bl.ordered == false, "bullet list node")
assert(#bl.items == 2, "two list items, got " .. #bl.items)
assert(bl.items[1].kind == "list_item", "list_item node")
local ol = only("1. a\n2. b\n")
assert(is_list(ol) and ol.ordered == true, "ordered list node")
-- Tight rendering: item with one paragraph -> no <p> wrapper.
assert(
  cmark.render(from_md.parse("- a\n- b\n")) == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n",
  "tight bullet HTML"
)
assert(
  cmark.render(from_md.parse("1. a\n2. b\n")) == "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n",
  "tight ordered HTML"
)
-- Ordered start attribute.
assert(
  cmark.render(from_md.parse("3. a\n")) == '<ol start="3">\n<li>a</li>\n</ol>\n',
  "ordered start attr"
)
-- Nesting: an indented marker opens a sublist inside the item.
local nest = from_md.parse("- a\n  - b\n")
assert(
  nest.children[1].kind == "list" and nest.children[1].items[1].content[2].kind == "list",
  "nested sublist in item"
)
-- A spaced-dash thematic break is NOT a list.
assert(only("- - -\n").kind == "rule", "spaced-dash stays a thematic break")

-- A long single-line run of list markers must not overflow the stack.
local ok_list = pcall(function()
  return from_md.parse(string.rep("  - ", 5000) .. "x\n")
end)
assert(ok_list, "deeply-nested single-line list markers must not throw (stack overflow regression)")

print("from_md_blocks_test: PASS")
