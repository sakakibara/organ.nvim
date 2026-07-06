-- nvim-treesitter-textobjects resolves `queries/<lang>/textobjects.scm` over
-- runtimepath.  Assert both the block-level (org) and inline (org_inline)
-- queries parse and capture the intended nodes, so a typo'd node type or a
-- deleted file is caught (a bad node type makes query.get throw/return nil).
--
-- Run via: nvim --headless -l tests/textobjects_query_test.lua

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

-- Collect the set of capture names a query produces over a parsed tree.
local function captures_of(q, root_node, src)
  local set = {}
  for id in q:iter_captures(root_node, src, 0, -1) do
    set[q.captures[id]] = true
  end
  return set
end

-- Block-level query.
do
  local q = vim.treesitter.query.get("org", "textobjects")
  check("org textobjects query resolves", q ~= nil)
  if q then
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, {
      "* Head",
      "body",
      "- item one",
      "- item two",
      "| a | b |",
      "#+begin_src lua",
      "print(1)",
      "#+end_src",
    })
    vim.bo[b].filetype = "org"
    local tree = vim.treesitter.get_parser(b, "org"):parse()[1]
    local caps = captures_of(q, tree:root(), b)
    for _, name in ipairs({
      "org.subtree.outer",
      "org.subtree.inner",
      "org.heading.outer",
      "org.heading.inner",
      "org.list.outer",
      "org.item.outer",
      "org.table.outer",
      "org.row.outer",
      "org.cell.outer",
      "org.block.outer",
      "block.outer",
    }) do
      check("org captures @" .. name, caps[name] == true)
    end
  end
end

-- Inline query (org_inline injected grammar).
do
  local q = vim.treesitter.query.get("org_inline", "textobjects")
  check("org_inline textobjects query resolves", q ~= nil)
  if q then
    local text = "see *bold* and [[https://x][a link]] on <2026-07-06 Mon>"
    local p = vim.treesitter.get_string_parser(text, "org_inline")
    local tree = p:parse()[1]
    local caps = captures_of(q, tree:root(), text)
    for _, name in ipairs({
      "org.link.outer",
      "org.link.inner",
      "org.timestamp.outer",
      "org.emphasis.outer",
    }) do
      check("org_inline captures @" .. name, caps[name] == true)
    end
  end
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("textobjects_query_test: PASS")
os.exit(0)
