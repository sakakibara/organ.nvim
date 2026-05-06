-- match.predicate honors config.tags.groups: a query for `+gtd` matches
-- any headline tagged with one of gtd's member tags.
-- Run via: nvim --headless -l tests/match_groups_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  tags = {
    groups = {
      gtd = { "@work", "@home", "@phone" },
      project = { "small", "medium", "large" },
    },
  },
})

local m = require("organ.match")

local function H(tags)
  return { tags = tags or {}, level = 1, title = "" }
end

-- 1. Parent tag matches when any member is present.
do
  local p = m.predicate("+gtd")
  assert(p(H({ "@work" })) == true, "@work satisfies +gtd")
  assert(p(H({ "@home" })) == true, "@home satisfies +gtd")
  assert(p(H({ "@phone" })) == true, "@phone satisfies +gtd")
  assert(p(H({ "@other" })) == false, "non-member fails")
  assert(p(H({ "gtd" })) == true, "literal `gtd` tag still matches")
end

-- 2. Negation: -gtd excludes any member.
do
  local p = m.predicate("-gtd")
  assert(p(H({ "@home" })) == false, "@home is in gtd → excluded")
  assert(p(H({ "@other" })) == true, "non-member passes -gtd")
end

-- 3. Cross-group composition.
do
  local p = m.predicate("+gtd+project")
  assert(p(H({ "@work", "small" })) == true, "both groups satisfied")
  assert(p(H({ "@work" })) == false, "missing project member")
  assert(p(H({ "small" })) == false, "missing gtd member")
end

-- 4. Non-member tag with no group definition behaves as before.
do
  local p = m.predicate("+work")
  assert(p(H({ "work" })) == true, "literal tag")
  assert(p(H({ "@work" })) == false, "@work is not literal `work`")
end

io.write("match groups ok\n")
os.exit(0)
