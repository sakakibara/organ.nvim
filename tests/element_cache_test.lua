-- Run via: nvim --headless -l tests/element_cache_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local ec = require("organ.element_cache")

local function buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

-- 1. Basic headlines extraction.
do
  local b = buf({
    "* A",
    "body",
    "** A1",
    "* B",
  })
  local h = ec.headlines(b)
  assert(#h == 3, "expected 3 headlines, got " .. #h)
  assert(h[1].line == 1 and h[1].level == 1)
  assert(h[2].line == 3 and h[2].level == 2)
  assert(h[3].line == 4 and h[3].level == 1)
end

-- 2. containing() finds the enclosing headline by binary search.
do
  local b = buf({
    "* A", -- 1
    "body of A", -- 2
    "** A1", -- 3
    "more body", -- 4
    "* B", -- 5
  })
  assert(ec.containing(b, 1).line == 1)
  assert(ec.containing(b, 2).line == 1)
  assert(ec.containing(b, 4).line == 3)
  assert(ec.containing(b, 5).line == 5)
  -- Line 0 has no containing headline.
  -- Line above first headline returns nil; here the buffer starts with one.
end

-- 3. subtree_end stops at next same-or-shallower headline.
do
  local b = buf({
    "* A", -- 1
    "body", -- 2
    "** A1", -- 3
    "** A2", -- 4
    "* B", -- 5
  })
  assert(ec.subtree_end(b, 1) == 4, "A subtree should end at line 4, got " .. ec.subtree_end(b, 1))
  assert(ec.subtree_end(b, 3) == 3, "A1 subtree (no body) ends at 3")
end

-- 4. Cache hit on second call when changedtick unchanged.
do
  ec._reset_stats()
  local b = buf({ "* A", "body", "* B" })
  ec.headlines(b)
  ec.headlines(b)
  ec.headlines(b)
  local s = ec.stats()
  assert(
    s.hits == 2 and s.misses == 1 and s.rebuilds == 1,
    "expected 2 hits, 1 miss, 1 rebuild; got " .. vim.inspect(s)
  )
end

-- 5. Cache rebuilds after edit.
do
  ec._reset_stats()
  local b = buf({ "* A", "body" })
  ec.headlines(b)
  vim.api.nvim_buf_set_lines(b, 1, 1, false, { "* B" })
  local h = ec.headlines(b)
  assert(#h == 2, "expected 2 headlines after edit, got " .. #h)
  local s = ec.stats()
  assert(s.rebuilds == 2, "expected rebuild after edit; stats=" .. vim.inspect(s))
end

-- 6. outline_path returns ancestor titles root→leaf.
do
  local b = buf({
    "* A",
    "** A1",
    "*** A1a",
    "body here",
  })
  local p = ec.outline_path(b, 4)
  assert(#p == 3, "expected 3 ancestors, got " .. #p)
  assert(p[1] == "A" and p[2] == "A1" and p[3] == "A1a", "path: " .. vim.inspect(p))
end

-- 7. next_headline / prev_headline.
do
  local b = buf({
    "* A", -- 1
    "x", -- 2
    "* B", -- 3
    "y", -- 4
    "* C", -- 5
  })
  assert(ec.next_headline(b, 1).line == 3, "A → next is B")
  assert(ec.next_headline(b, 2).line == 3, "from body → next is B")
  assert(ec.next_headline(b, 3).line == 5, "B → next is C")
  assert(ec.next_headline(b, 5) == nil, "C has no next")
  assert(ec.prev_headline(b, 5).line == 3, "C → prev is B")
  assert(ec.prev_headline(b, 4).line == 3, "from body → prev is B")
  assert(ec.prev_headline(b, 1) == nil, "A has no prev")
end

io.write("element cache ok\n")
os.exit(0)
