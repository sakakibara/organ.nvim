local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_md = require("organ.ast.from_md")

-- Two blank-line-separated paragraphs.
local doc = from_md.parse("hello world\n\nsecond para\n")
assert(doc.kind == "document", "returns a document node")
assert(#doc.children == 2, "two paragraphs, got " .. #doc.children)
assert(doc.children[1].kind == "paragraph", "first child is a paragraph")
assert(doc.children[1].inline[1].kind == "text", "paragraph holds a text node")
assert(doc.children[1].inline[1].text == "hello world", "first paragraph text")
assert(doc.children[2].inline[1].text == "second para", "second paragraph text")

-- Soft-wrapped lines join within one paragraph; inline pass emits a soft-break
-- text node between them.
local wrapped = from_md.parse("line one\nline two\n")
assert(#wrapped.children == 1, "soft-wrapped lines are one paragraph")
local winline = wrapped.children[1].inline
assert(winline[1].text == "line one", "first line text")
assert(winline[2].kind == "text" and winline[2].text == "\n", "soft-break node")
assert(winline[3].text == "line two", "second line text")

-- Empty / blank input yields an empty document, never an error.
assert(#from_md.parse("").children == 0, "empty input -> empty document")
assert(#from_md.parse("\n\n  \n").children == 0, "blank-only input -> empty document")

print("from_md_parse_test: PASS")
