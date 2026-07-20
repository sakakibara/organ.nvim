-- Emacs (org-element) recognizes a lowercase 'scheduled:' line as a
-- planning element (line-level recognition is case-insensitive) but
-- binds NO :scheduled property to it -- only exact-uppercase keywords
-- bind dates. The indexer must not fold the keyword to uppercase before
-- matching.
-- Run via: nvim --headless -l tests/indexer_planning_case_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
local indexer = require("organ.indexer")

local src = table.concat({
  "* TODO Water plants",
  "  scheduled: <2026-05-06 Wed>",
  "",
}, "\n")

local headlines = indexer.extract(src, "lowercase-planning.org", parser_path)
assert(#headlines == 1, "expected 1 headline, got " .. #headlines)
local hl = headlines[1]

assert(
  hl.scheduled == nil,
  "lowercase 'scheduled:' must not bind :scheduled -- got " .. tostring(hl.scheduled)
)
assert(
  hl.scheduled_date == nil,
  "lowercase 'scheduled:' must not bind scheduled_date -- got " .. tostring(hl.scheduled_date)
)

io.write("indexer planning case ok\n")
os.exit(0)
