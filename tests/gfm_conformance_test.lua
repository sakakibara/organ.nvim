local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
local from_md = require("organ.ast.from_md")
local cmark = dofile(root .. "/tests/cmark/html.lua")
local GFM_BASELINE = 12
local examples =
  vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/gfm/spec.json"), "\n"))
local passing = 0
for _, ex in ipairs(examples) do
  local ok, got = pcall(function()
    return cmark.render(from_md.parse(ex.markdown))
  end)
  if ok and got == ex.html then
    passing = passing + 1
  end
end
print(string.format("GFM conformance: %d/%d passing", passing, #examples))
assert(
  passing >= GFM_BASELINE,
  string.format("GFM regressed: %d < baseline %d", passing, GFM_BASELINE)
)
print("gfm_conformance_test: PASS")
