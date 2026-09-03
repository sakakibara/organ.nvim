-- A bracket link inside a property-drawer VALUE must attribute to its
-- own heading. property_drawer rows sit outside the `section` node, so
-- collect_links's old section-only row bucket dropped them.
-- Run via: nvim --headless -l tests/indexer_links_property_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
local indexer = require("organ.indexer")

local src = table.concat({
  "* Alpha",
  "  :PROPERTIES:",
  "  :ID:       alpha-id",
  "  :LINK:     [[id:beta-id][ref]]",
  "  :END:",
  "",
  "* Beta",
  "  :PROPERTIES:",
  "  :ID:       beta-id",
  "  :END:",
  "",
}, "\n")

local headlines = indexer.extract(src, "prop-link.org", parser_path)

local links_by_title = {}
for _, hl in ipairs(headlines) do
  links_by_title[hl.title] = hl.links or {}
end

local a = links_by_title["Alpha"]
assert(a and #a == 1, "Alpha should carry the property-drawer link, got " .. tostring(a and #a))
assert(a[1].target == "id:beta-id" and a[1].description == "ref", vim.inspect(a and a[1]))

local b = links_by_title["Beta"]
assert(b and #b == 0, "Beta should carry no links, got " .. tostring(b and #b))

-- parse_link_text anchors the whole trimmed value with ^...$, so a
-- property value holding TWO whole links back to back matches neither
-- the single-link nor the two-link pattern and extracts zero links.
-- This locks that known limitation rather than the desired behavior.
local src_two = table.concat({
  "* Gamma",
  "  :PROPERTIES:",
  "  :ID:       gamma-id",
  "  :LINKS:    [[id:a][x]] [[id:b][y]]",
  "  :END:",
  "",
}, "\n")

local headlines_two = indexer.extract(src_two, "prop-link-two.org", parser_path)
local links_by_title_two = {}
for _, hl in ipairs(headlines_two) do
  links_by_title_two[hl.title] = hl.links or {}
end

local g = links_by_title_two["Gamma"]
assert(
  g and #g == 0,
  "Gamma with two whole links in one value should extract zero links (known limitation), got "
    .. tostring(g and #g)
)

-- org-link-bracket-re lets the description contain `]`.
local src_desc = table.concat({
  "* Delta",
  "  :PROPERTIES:",
  "  :ID:       delta-id",
  "  :REF:      [[id:beta-id][ref [v2] note]]",
  "  :END:",
  "",
}, "\n")

local headlines_desc = indexer.extract(src_desc, "prop-link-desc.org", parser_path)
local d
for _, hl in ipairs(headlines_desc) do
  if hl.title == "Delta" then
    d = hl.links or {}
  end
end
assert(
  d and #d == 1,
  "Delta should carry the bracketed-description link, got " .. tostring(d and #d)
)
assert(d[1].target == "id:beta-id" and d[1].description == "ref [v2] note", vim.inspect(d[1]))

io.write("indexer links property ok\n")
os.exit(0)
