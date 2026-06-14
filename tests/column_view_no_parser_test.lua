-- column_view.find_spec walks ancestor headlines through the tree-sitter
-- node returned by element.headline_at. On the regex fallback (no parser)
-- that record has no .node, so the walk must not crash -- it returns the
-- inherited COLUMNS value without an owning line.
-- Run via: nvim --headless -l tests/column_view_no_parser_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Force the regex fallback so headline_at returns a record with no .node.
local element = require("organ.element")
element.parser_loaded = function()
  return false
end

local cv = require("organ.column_view")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

-- Contract: the regex-fallback record carries no tree-sitter node.
local b0 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b0, 0, -1, false, { "* TODO A", "body" })
check(element.headline_at(b0, 0).node == nil, "headline_at has no .node on the regex fallback")

-- COLUMNS is set on Parent and inherited by Child; querying the child
-- reaches the ancestor walk, which previously indexed a nil .node.
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* TODO Parent",
  ":PROPERTIES:",
  ":COLUMNS: %25ITEM",
  ":END:",
  "** TODO Child",
  "body",
})

local val, line = cv.find_spec(b, 5)
check(val == "%25ITEM", "inherited COLUMNS value resolves on the no-parser path")
check(line == nil, "no owning line without the parser, and no crash")

print("column_view_no_parser_test: PASS")
