-- ASCII export: headlines underlined, lists normalised, tables with `+--+`,
-- inline emphasis stripped, links in `text (url)` form.
-- Run via: nvim --headless -l tests/export_ascii_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local p = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = p })

local ascii = require("organ.export.ascii")

local function assert_contains(haystack, needle, msg)
  assert(
    haystack:find(needle, 1, true),
    (msg or "expected to find") .. ": '" .. needle .. "' in:\n" .. haystack
  )
end

local out = ascii.export([==[
* Title
some prose with *bold* and =verb= and [[https://x][a link]].
- one
- two
| name | age |
|------+-----|
| ada  |  36 |
| ben  |  41 |
]==])

-- Headline + underline.
assert_contains(out, "Title")
assert_contains(out, "=====")
-- Inline emphasis stripped.
assert_contains(out, "with bold and verb")
-- Link rendered as text + url.
assert_contains(out, "a link (https://x)")
-- List bullets normalised.
assert_contains(out, "- one")
-- Table border + cells.
assert_contains(out, "+------+-----+")
assert_contains(out, "| ada  | 36  |")

-- Drawers + planning dropped.
local drop = ascii.export([[
* H
SCHEDULED: <2026-04-29>
:PROPERTIES:
:ID: x
:END:
Body.
]])
assert(not drop:find("SCHEDULED", 1, true), "SCHEDULED dropped")
assert(not drop:find("PROPERTIES", 1, true), "PROPERTIES dropped")
assert_contains(drop, "Body")

io.write("export ascii ok\n")
os.exit(0)
