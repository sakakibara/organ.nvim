-- Radio matching core: collect_targets + build_matcher.
-- Run via: nvim --headless -l tests/ast_radio_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local A = require("organ.ast.init")
local radio = require("organ.ast.radio")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

-- collect_targets: dedupe (case-insensitive), sort longest-first.
do
  local doc = A.document({
    A.paragraph({
      A.radio_target("lead"),
      A.radio_target("Lead"),
      A.radio_target("lead developer"),
    }),
  })
  local t = radio.collect_targets(doc)
  check(#t == 2, "collect: deduped case-insensitively to 2")
  check(t[1] == "lead developer", "collect: longest first")
end

-- a whitespace-only / empty target is skipped (it would otherwise build an
-- empty pattern and zero-width match, looping the splitter forever).
do
  local doc = A.document({ A.paragraph({ A.radio_target("   "), A.radio_target("") }) })
  check(#radio.collect_targets(doc) == 0, "collect: whitespace-only target skipped")
end

-- matcher rules.
do
  local m = radio.build_matcher({ "lead developer", "lead" })
  local s1, e1, p1 = m("the lead developer spoke")
  check(p1 == "lead developer" and s1 == 5 and e1 == 18, "match: longest at position, boundaries")
  local _, _, p2 = m("MY LEAD here")
  check(p2 == "lead", "match: case-insensitive")
  check(m("misleading text") == nil, "match: no match inside a word (misleading)")
  check(m("leads the team") == nil, "match: no match inside a word (leads)")
  local s3, e3, p3 = m("the lead\ndeveloper wrote")
  check(p3 == "lead developer", "match: internal whitespace flexible (newline)")
end

print("ALL PASS: ast_radio (core)")
