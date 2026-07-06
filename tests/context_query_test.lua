-- nvim-treesitter-context builds its sticky header from the `context`
-- query resolved via runtimepath.  Without queries/org/context.scm the
-- header works for markdown but stays empty for org.  Assert the query
-- exists, parses, and captures the (nesting) headline nodes so a deleted
-- or malformed file is caught.
--
-- Run via: nvim --headless -l tests/context_query_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local q = vim.treesitter.query.get("org", "context")
check("org context query resolves", q ~= nil)

if q then
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* A", -- 1
    "body a", -- 2
    "** A1", -- 3
    "body a1", -- 4
    "* B", -- 5
  })
  vim.bo[b].filetype = "org"
  local parser = vim.treesitter.get_parser(b, "org")
  local tree = parser:parse()[1]

  local rows = {}
  for id, node in q:iter_captures(tree:root(), b, 0, -1) do
    check("capture is @context (" .. node:type() .. ")", q.captures[id] == "context")
    check("captured node is a headline @L" .. (node:start() + 1), node:type() == "headline")
    rows[#rows + 1] = node:start() + 1
  end
  table.sort(rows)
  check(
    "captures the nesting heading chain (L1 A, L3 A1, L5 B)",
    vim.deep_equal(rows, { 1, 3, 5 }),
    "rows=" .. vim.inspect(rows)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("context_query_test: PASS")
os.exit(0)
