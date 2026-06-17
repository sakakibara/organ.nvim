-- Per-production unit tests for the org / org_inline tree-sitter grammars.
-- Asserts that minimal fixtures produce the expected node types, so a
-- grammar regression fails here at parse time rather than only indirectly
-- via downstream render diffs.
-- Run via: nvim --headless -l tests/grammar_productions_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function node_types(src, lang)
  local parser = vim.treesitter.get_string_parser(src, lang or "org")
  local tree = parser:parse()[1]
  local seen = {}
  local function walk(node)
    seen[node:type()] = true
    for child in node:iter_children() do
      walk(child)
    end
  end
  walk(tree:root())
  return seen
end

local function assert_has(src, lang, want)
  local seen = node_types(src, lang)
  assert(seen[want], string.format("expected node %q in %q (lang %s)", want, src, lang))
end

-- block grammar (org)
assert_has("* Heading\n", "org", "headline")
assert_has("* Heading\n", "org", "headline_line")
assert_has("* H\nSCHEDULED: <2026-06-17 Wed>\n", "org", "planning")
assert_has("* H\n:PROPERTIES:\n:ID: x\n:END:\n", "org", "property_drawer")
assert_has("- a\n- b\n", "org", "list")
assert_has("- a\n- b\n", "org", "list_item")
assert_has("| a | b |\n", "org", "table")
assert_has("| a | b |\n", "org", "table_row")
assert_has(":LOGBOOK:\nCLOCK: [2026-06-17 Wed 10:00]\n:END:\n", "org", "drawer")

-- inline grammar (org_inline)
assert_has("*bold*", "org_inline", "bold")
assert_has("/italic/", "org_inline", "italic")
assert_has("~code~", "org_inline", "code")
assert_has("=verbatim=", "org_inline", "verbatim")
assert_has("[[https://example.com][label]]", "org_inline", "link_regular")
assert_has("see https://example.com here", "org_inline", "link_plain")
assert_has("<2026-06-17 Wed>", "org_inline", "timestamp_active")

print("grammar_productions_test: PASS")
