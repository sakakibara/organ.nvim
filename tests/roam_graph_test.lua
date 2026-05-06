-- Verifies organ.roam.graph builds an adjacency from indexed roam files.
-- Run via: nvim --headless -l tests/roam_graph_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local organ = require("organ")
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

organ.setup({ org_dir = tmpdir, db_path = tmpdir .. "/organ.db" })

local function write_file(name, content)
  local path = tmpdir .. "/" .. name
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  return path
end

-- Three notes A → B → C, plus B → C.
local A_id = "11111111-aaaa-aaaa-aaaa-111111111111"
local B_id = "22222222-bbbb-bbbb-bbbb-222222222222"
local C_id = "33333333-cccc-cccc-cccc-333333333333"

write_file(
  "A.org",
  string.format(
    [==[
#+title: A
* Heading A
:PROPERTIES:
:ID:       %s
:END:
This points to [[id:%s][note B]].
]==],
    A_id,
    B_id
  )
)

write_file(
  "B.org",
  string.format(
    [==[
#+title: B
* Heading B
:PROPERTIES:
:ID:       %s
:END:
And to [[id:%s][note C]].
]==],
    B_id,
    C_id
  )
)

write_file(
  "C.org",
  string.format(
    [==[
#+title: C
* Heading C
:PROPERTIES:
:ID:       %s
:END:
End of chain.
]==],
    C_id
  )
)

local indexer = require("organ.indexer")
indexer.index_file_sync(tmpdir .. "/A.org")
indexer.index_file_sync(tmpdir .. "/B.org")
indexer.index_file_sync(tmpdir .. "/C.org")

local graph = require("organ.roam.graph")

-- A's graph at depth 1 should have edge A→B (forward) and surface B as a node.
do
  local nodes, edges = graph.adjacency(A_id, 1)
  assert(nodes[A_id], "A should be in nodes")
  assert(nodes[B_id], "B should be in nodes (1-hop forward)")
  local found = false
  for _, e in ipairs(edges) do
    if e.from == A_id and e.to == B_id then
      found = true
    end
  end
  assert(found, "A → B edge missing in adjacency")
end

-- B's graph at depth 1 should include both A (incoming) and C (outgoing).
do
  local nodes = graph.adjacency(B_id, 1)
  assert(nodes[A_id], "A (caller) should appear in B's neighbourhood")
  assert(nodes[C_id], "C (target) should appear in B's neighbourhood")
end

-- A's graph at depth 2 reaches C transitively via B.
do
  local nodes = graph.adjacency(A_id, 2)
  assert(nodes[C_id], "C should be reachable from A at depth 2")
end

-- Tree mode produces lines with arrows + a line_index.
do
  local lines, line_index = graph.tree(A_id, 1)
  assert(#lines >= 2, "tree should produce at least the root + 1 link")
  local found_jump = false
  for _, j in pairs(line_index) do
    if j.id == B_id then
      found_jump = true
    end
  end
  assert(found_jump, "tree line_index should reference B's id")
end

-- Mermaid mode emits a flowchart-LR document.
do
  local doc = graph.mermaid(A_id, 1)
  assert(doc:find("flowchart LR", 1, true), "mermaid header missing:\n" .. doc)
  assert(doc:find("-->", 1, true), "mermaid edge missing:\n" .. doc)
end

io.write("roam graph ok\n")
os.exit(0)
