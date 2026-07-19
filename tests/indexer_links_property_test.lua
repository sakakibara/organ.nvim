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
assert(
  a and #a == 1,
  "Alpha should carry the property-drawer link, got " .. tostring(a and #a)
)
assert(a[1].target == "id:beta-id" and a[1].description == "ref", vim.inspect(a and a[1]))

local b = links_by_title["Beta"]
assert(b and #b == 0, "Beta should carry no links, got " .. tostring(b and #b))

io.write("indexer links property ok\n")
os.exit(0)
