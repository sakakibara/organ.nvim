-- tests/sparse_visible_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({ todo = { sequence = { "TODO", "NEXT", "|", "DONE" } } })

local sparse = require("organ.sparse")

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- Match TODO-state: ancestor + match + body visible.
do
  local lines = {
    "* Parent", -- 1
    "  body", -- 2
    "** TODO Child", -- 3
    "   child body", -- 4
    "** Sibling", -- 5  (no TODO state — should be hidden)
  }
  local visible = sparse._compute_visible(lines, function(h)
    return h.todo_state ~= nil
  end)
  assert_eq(visible[1], true, "Parent (ancestor) visible")
  assert_eq(visible[3], true, "TODO Child match visible")
  assert_eq(visible[4], true, "child body under match visible")
  assert_eq(visible[5], nil, "Sibling (no TODO) hidden")
  -- Body of Parent (line 2): not under a match, but the test predicate doesn't
  -- match Parent. So line 2 is NOT auto-visible. Confirm:
  assert_eq(visible[2], nil, "Parent body not auto-visible (Parent isn't a match)")
end

-- Match by tag: nested ancestor visible.
do
  local lines = {
    "* Top", -- 1
    "** Mid", -- 2
    "*** Leaf :work:", -- 3
    "* Other :work:", -- 4
  }
  local visible = sparse._compute_visible(lines, function(h)
    for _, t in ipairs(h.tags or {}) do
      if t == "work" then
        return true
      end
    end
    return false
  end)
  assert_eq(visible[1], true, "Top is ancestor of Leaf")
  assert_eq(visible[2], true, "Mid is ancestor of Leaf")
  assert_eq(visible[3], true, "Leaf match")
  assert_eq(visible[4], true, "Other :work: match")
end

-- No matches: empty visible map.
do
  local lines = { "* A", "* B" }
  local visible = sparse._compute_visible(lines, function(_)
    return false
  end)
  assert_eq(next(visible), nil)
end

-- Body of match extends through next headline of any level.
do
  local lines = {
    "* TODO A", -- 1
    "  body 1", -- 2
    "  body 2", -- 3
    "* B", -- 4
  }
  local visible = sparse._compute_visible(lines, function(h)
    return h.todo_state ~= nil
  end)
  assert_eq(visible[1], true)
  assert_eq(visible[2], true, "body 1 visible")
  assert_eq(visible[3], true, "body 2 visible")
  assert_eq(visible[4], nil, "B (no TODO) hidden")
end

-- Regex path: every tag in the trailing block is read, including `@`/`#`
-- tags, and the title excludes the block.
do
  local lines = { "* Foo :work:home:", "* Bar :@phone:", "* Baz :a:b:c:", "* Time 10:30:45" }
  local seen = {}
  sparse._compute_visible(lines, function(h)
    seen[h.line] = { tags = h.tags, title = h.title }
    return false
  end)
  assert_eq(table.concat(seen[1].tags, ","), "work,home", "two tags")
  assert_eq(seen[1].title, "Foo", "title without tag block")
  assert_eq(table.concat(seen[2].tags, ","), "@phone", "@ tag")
  assert_eq(seen[2].title, "Bar", "title without @ tag block")
  assert_eq(table.concat(seen[3].tags, ","), "a,b,c", "three tags")
  assert_eq(#seen[4].tags, 0, "clock text is not a tag block")
  assert_eq(seen[4].title, "Time 10:30:45", "title keeps colon text")
end

-- Regex path: whitespace after the tag block is not part of the title.
do
  local lines = { "* Foo :a:b: ", "* Baz  :x_y:  ", "* :onlytags:\t" }
  local seen = {}
  sparse._compute_visible(lines, function(h)
    seen[h.line] = { tags = h.tags, title = h.title }
    return false
  end)
  assert_eq(table.concat(seen[1].tags, ","), "a,b", "tags before trailing space")
  assert_eq(seen[1].title, "Foo", "title with trailing space after block")
  assert_eq(table.concat(seen[2].tags, ","), "x_y", "tag before trailing spaces")
  assert_eq(seen[2].title, "Baz", "title with trailing spaces after block")
  assert_eq(table.concat(seen[3].tags, ","), "onlytags", "tags-only line with trailing tab")
  assert_eq(seen[3].title, "", "tags-only title is empty")
end

io.write("sparse visible ok\n")
