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

print("from_md_blocks_test: PASS")
