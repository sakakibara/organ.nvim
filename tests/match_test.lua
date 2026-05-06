-- match.parse + predicate: Emacs org-match query subset.
-- Run via: nvim --headless -l tests/match_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local m = require("organ.match")

local function pred(q)
  return m.predicate(q)
end

local function H(opts)
  return {
    todo_state = opts.todo,
    tags = opts.tags or {},
    level = opts.level or 1,
    title = opts.title or "",
    properties = opts.props or {},
  }
end

-- 1. Bare tag = require.
do
  local p = pred("work")
  assert(p(H({ tags = { "work" } })) == true, "tag matches")
  assert(p(H({ tags = { "home" } })) == false, "no tag mismatches")
end

-- 2. +/- tags compose with AND.
do
  local p = pred("+work-home")
  assert(p(H({ tags = { "work" } })) == true)
  assert(p(H({ tags = { "work", "home" } })) == false)
  assert(p(H({ tags = { "home" } })) == false)
end

-- 3. | gives OR between clauses.
do
  local p = pred("+work|+urgent")
  assert(p(H({ tags = { "work" } })) == true)
  assert(p(H({ tags = { "urgent" } })) == true)
  assert(p(H({ tags = { "leisure" } })) == false)
end

-- 4. /STATE narrows by TODO state.
do
  local p = pred("+work/+NEXT")
  assert(p(H({ tags = { "work" }, todo = "NEXT" })) == true)
  assert(p(H({ tags = { "work" }, todo = "TODO" })) == false)
  local q = pred("+work/-DONE")
  assert(q(H({ tags = { "work" }, todo = "TODO" })) == true)
  assert(q(H({ tags = { "work" }, todo = "DONE" })) == false)
end

-- 5. {regex} matches the title.
do
  local p = pred("{review}")
  assert(p(H({ title = "Quarterly review" })) == true)
  assert(p(H({ title = "Status update" })) == false)
end

-- 6. LEVEL=N constraint.
do
  local p = pred("LEVEL=2")
  assert(p(H({ level = 2 })) == true)
  assert(p(H({ level = 3 })) == false)
  local q = pred("LEVEL>1")
  assert(q(H({ level = 2 })) == true)
  assert(q(H({ level = 1 })) == false)
end

-- 7. Property equality + numeric.
do
  local p = pred('PROP="foo"')
  assert(p(H({ props = { PROP = "foo" } })) == true)
  assert(p(H({ props = { PROP = "bar" } })) == false)
  local q = pred("EFFORT<60")
  assert(q(H({ props = { EFFORT = "30" } })) == true)
  assert(q(H({ props = { EFFORT = "90" } })) == false)
  -- Missing property under numeric comparison fails.
  assert(q(H({})) == false)
end

-- 8. Combined clause: tag + property + level + todo.
do
  local p = pred("+work+EFFORT<60/+NEXT")
  assert(p(H({ tags = { "work" }, props = { EFFORT = "30" }, todo = "NEXT" })) == true)
  assert(p(H({ tags = { "work" }, props = { EFFORT = "30" }, todo = "TODO" })) == false)
end

io.write("match ok\n")
os.exit(0)
