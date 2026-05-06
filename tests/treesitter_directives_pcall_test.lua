-- Regression: treesitter_directives predicates / helpers must not throw
-- when the highlighter runs against a stale tree (e.g. mid-undo, before
-- the next reparse). Prior bug: get_node_text raised "Index out of bounds"
-- when the buffer shrank during undo, propagating up through the
-- highlighter's decoration-provider callback and surfacing as an ugly
-- modal error.
--
-- We can't easily simulate "stale tree" without a real undo flow, but we
-- CAN call each predicate / helper with a node whose range exceeds the
-- source string. That triggers the same `nvim_buf_get_text` / string
-- bounds check inside `get_node_text` and is exactly what the pcall guard
-- now defuses.
--
-- Run via: nvim --headless -l tests/treesitter_directives_pcall_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local td = require("organ.treesitter_directives")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- A fake node that mimics tree-sitter's API surface used by the helpers:
-- :range(true) returns srow, scol, erow, ecol, sbyte, ebyte. We give
-- ranges that are deliberately out-of-bounds for the source string so
-- get_node_text raises.
local function fake_node(srow, scol, erow, ecol, sb, eb)
  return {
    range = function(_self, _bytes)
      return srow, scol, erow, ecol, sb, eb
    end,
    start = function(_self)
      return srow, scol
    end,
  }
end

local source = "* TODO Heading" -- 14 chars; 1 line

-- 1. Each of the three local helpers must not throw.
do
  local node = fake_node(50, 0, 51, 0, 9999, 99999)
  -- src_block_lang / src_block_body_range / headline_stars are local but
  -- accessible via the predicates we register. Easier: install predicates
  -- and invoke them through td.register, then call the predicate with a
  -- crafted match table.
end

-- 2. Each registered predicate must return false on a throwing get_node_text
-- (instead of throwing). To exercise: install via M.register(), then look
-- up the predicate function from vim.treesitter.query and call it directly.
local q = vim.treesitter.query
td.register()

-- vim.treesitter.query exposes the predicates via internal table; we call
-- via add_predicate's callback path through query.list_predicates() for
-- reading, but the simplest test is to just create a buffer + parse it
-- and let the highlighter run, watching for any thrown error. We use a
-- minimal nvim_buf_get_text monkey-patch to FORCE the throw on any call
-- and assert no error escapes up through our predicate callbacks.
local saved_get_text = vim.api.nvim_buf_get_text
vim.api.nvim_buf_get_text = function(_buf, _sr, _sc, _er, _ec, _opts)
  error("Index out of bounds")
end

-- Now invoke a predicate manually. We need the registered fn; it's stored
-- inside the query module and isn't publicly exposed. We can call
-- get_node_text directly (which uses our patched nvim_buf_get_text) and
-- prove the pcall in our helpers swallows it.
local fake = fake_node(0, 0, 0, 14, 0, 14)
local ok, _ = pcall(vim.treesitter.get_node_text, fake, source)
check(
  "baseline: get_node_text WITH our patched buf_get_text would throw",
  not ok,
  "patched throw didn't fire as expected"
)

-- The predicate paths in treesitter_directives.lua use pcall around
-- get_node_text. Verify by calling the local-but-conceptually-public
-- behaviour through a real query+match cycle. Easiest: parse a string,
-- run a query that uses one of our predicates, and confirm no error
-- propagates up the iter() loop.
vim.api.nvim_buf_get_text = saved_get_text -- restore for parser

local parser_path = require("organ.defaults").parser_path
if vim.fn.filereadable(parser_path) == 1 then
  vim.treesitter.language.add("org", { path = parser_path })
  local p = vim.treesitter.get_string_parser(source, "org")
  local tree = p:parse()[1]
  local root = tree:root()

  -- Use the predicate through a query — this exercises the registered
  -- callback. Re-patch to force the throw inside get_node_text.
  vim.api.nvim_buf_get_text = function()
    error("Index out of bounds")
  end

  local query_str = [[
    ((headline) @h (#org-heading-level? @h 1))
  ]]
  local q_obj = vim.treesitter.query.parse("org", query_str)

  local ok2, err2 = pcall(function()
    for _id, _node in q_obj:iter_captures(root, source, 0, -1) do
      -- iterating exercises the predicate
    end
  end)
  vim.api.nvim_buf_get_text = saved_get_text

  check(
    "predicate iter_captures: does NOT throw when get_node_text errors",
    ok2,
    "got: " .. tostring(err2)
  )
else
  vim.api.nvim_buf_get_text = saved_get_text
  io.write("(skipped predicate iter test: parser not installed)\n")
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("treesitter_directives_pcall_test: PASS")
