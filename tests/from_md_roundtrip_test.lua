local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_md = require("organ.ast.from_md")
local to_md = require("organ.ast.to_md")
local to_org = require("organ.ast.to_org")
local from_org = require("organ.ast.from_org")

-- org -> AST -> md -> AST -> org should preserve a plain paragraph document.
-- from_org exposes from_lines(lines_list) (see lua/organ/ast/from_org.lua:769).
local org_in = "first paragraph\n\nsecond paragraph\n"
local ast1 = from_org.from_lines(vim.split(org_in, "\n", { plain = true }))
local md = to_md.render(ast1, {})
local ast2 = from_md.parse(md)
local org_out = to_org.render(ast2)

assert(org_out:find("first paragraph", 1, true), "roundtrip keeps first paragraph")
assert(org_out:find("second paragraph", 1, true), "roundtrip keeps second paragraph")
-- Paragraph count is preserved (two blocks separated by a blank line).
local blocks = select(2, org_out:gsub("\n\n", "\n\n"))
assert(blocks >= 1, "roundtrip preserves the paragraph break")

print("from_md_roundtrip_test: PASS")
