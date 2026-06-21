local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_md = require("organ.ast.from_md")
local cmark_html = dofile(root .. "/tests/cmark/html.lua")

-- Ratchet floor: the number of CommonMark examples that must pass. Raise this
-- as each parser stage lands. Never lower it.
local BASELINE = 360

local examples =
  vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/commonmark/spec.json"), "\n"))

local passing = 0
for _, ex in ipairs(examples) do
  local ok, got = pcall(function()
    return cmark_html.render(from_md.parse(ex.markdown))
  end)
  if ok and got == ex.html then
    passing = passing + 1
  end
end

print(string.format("CommonMark conformance: %d/%d passing", passing, #examples))
assert(
  passing >= BASELINE,
  string.format("conformance regressed: %d passing < baseline %d", passing, BASELINE)
)
print("commonmark_conformance_test: PASS")
