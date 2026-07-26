-- tests/sparse_buffer_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({ todo = { sequence = { "TODO", "NEXT", "|", "DONE" } } })

local sparse = require("organ.sparse")

local function mk_buf(lines)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  vim.api.nvim_set_current_buf(b)
  return b
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- show_todo populates vim.b.organ_sparse.visible.
do
  local b = mk_buf({ "* TODO X", "* Y" })
  sparse.show_todo(b)
  local s = vim.b[b].organ_sparse
  assert(s, "state set")
  assert_eq(s.visible[1], true)
  assert_eq(s.visible[2], nil)
end

-- clear removes state.
do
  local b = mk_buf({ "* TODO X" })
  sparse.show_todo(b)
  assert(vim.b[b].organ_sparse, "state present")
  sparse.clear(b)
  assert_eq(vim.b[b].organ_sparse, nil, "state cleared")
end

-- show_regex matches headline title.
do
  local b = mk_buf({ "* hello world", "* foo" })
  sparse.show_regex(b, "hello")
  local s = vim.b[b].organ_sparse
  assert_eq(s.visible[1], true)
  assert_eq(s.visible[2], nil)
end

-- show_tag matches.
do
  local b = mk_buf({ "* A :work:", "* B :home:" })
  sparse.show_tag(b, "work")
  local s = vim.b[b].organ_sparse
  assert_eq(s.visible[1], true)
  assert_eq(s.visible[2], nil)
end

-- property predicate via the tree-sitter path: the drawer is a DIRECT
-- child of headline in the grammar.
do
  vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })
  local b = mk_buf({
    "* One",
    ":PROPERTIES:",
    ":KIND: keep",
    ":END:",
    "* Two",
  })
  sparse.apply(b, function(h)
    return (h.properties or {}).KIND == "keep"
  end)
  local s = vim.b[b].organ_sparse
  assert(s, "state set (ts property path)")
  assert_eq(s.visible[1], true, "TS property match visible")
  assert_eq(s.visible[5], nil, "TS property non-match hidden")
end

io.write("sparse buffer ok\n")
