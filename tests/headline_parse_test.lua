-- Verifies organ.headline.split, the shared headline stars-splitting used
-- by element, structure, and the indexer regex fallbacks.
-- Run via: nvim --headless -l tests/headline_parse_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local H = require("organ.headline")

-- level + rest
local lvl, rest = H.split("* Heading")
assert(lvl == 1 and rest == "Heading", "single star")

lvl, rest = H.split("*** TODO [#A] Buy milk :work:home:")
assert(lvl == 3, "three stars")
assert(rest == "TODO [#A] Buy milk :work:home:", "rest is everything after the stars+space")

-- stars immediately followed by more space collapse into the %s+
lvl, rest = H.split("** ")
assert(lvl == 2 and rest == "", "trailing-only line yields empty rest")

-- non-headlines
assert(H.split("*notstar") == nil, "no space after stars is not a headline")
assert(H.split("*") == nil, "bare stars (no following space) is not split here")
assert(H.split("not a headline") == nil, "plain text")
assert(H.split("- list item") == nil, "list bullet")
assert(H.split("") == nil, "empty line")

print("headline_parse_test: PASS")
