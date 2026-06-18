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

print("from_md_blocks_test: PASS")
