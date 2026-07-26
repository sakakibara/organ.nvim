-- Tests for Phase 5: prefix tokens (todo:, priority:, tag:, file:) for multi-criteria filter.
-- Run via: nvim --headless -l tests/find_filter_tokens_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local find = require("organ.find")

-- parse_filter_tokens

-- 1. Empty / nil query → all empty arrays.
do
  local p = find.parse_filter_tokens("")
  assert(
    #p.todo == 0 and #p.priority == 0 and #p.tag == 0 and #p.file == 0 and #p.plain == 0,
    "empty query → all empty"
  )
  local p2 = find.parse_filter_tokens(nil)
  assert(#p2.todo == 0, "nil query → all empty")
end

-- 2. todo: prefix.
do
  local p = find.parse_filter_tokens("todo:NEXT")
  assert(#p.todo == 1 and p.todo[1] == "NEXT", "todo:NEXT parsed")
  assert(#p.plain == 0, "no plain tokens")
end

-- 3. priority: prefix.
do
  local p = find.parse_filter_tokens("priority:A")
  assert(#p.priority == 1 and p.priority[1] == "A", "priority:A parsed")
end

-- 4. tag: prefix.
do
  local p = find.parse_filter_tokens("tag:work")
  assert(#p.tag == 1 and p.tag[1] == "work", "tag:work parsed")
end

-- 5. file: prefix.
do
  local p = find.parse_filter_tokens("file:inbox")
  assert(#p.file == 1 and p.file[1] == "inbox", "file:inbox parsed")
end

-- 6. Plain word → goes to plain.
do
  local p = find.parse_filter_tokens("review")
  assert(#p.plain == 1 and p.plain[1] == "review", "plain word parsed")
end

-- 7. Mixed: todo:NEXT foo → one todo, one plain.
do
  local p = find.parse_filter_tokens("todo:NEXT foo")
  assert(#p.todo == 1 and p.todo[1] == "NEXT", "todo from mixed")
  assert(#p.plain == 1 and p.plain[1] == "foo", "plain from mixed")
end

-- 8. Multiple same-prefix → OR list.
do
  local p = find.parse_filter_tokens("todo:NEXT todo:TODO")
  assert(#p.todo == 2, "two todo tokens: " .. #p.todo)
end

-- apply_filter_tokens

local function mk_item(over)
  local base = {
    title = "Task",
    todo_state = nil,
    priority = nil,
    tags = {},
    file_path = "/org/inbox.org",
  }
  for k, v in pairs(over or {}) do
    base[k] = v
  end
  return base
end

local items = {
  mk_item({
    title = "Fix bug",
    todo_state = "NEXT",
    priority = "A",
    tags = { "work" },
    file_path = "/org/work.org",
  }),
  mk_item({
    title = "Buy milk",
    todo_state = "TODO",
    priority = "B",
    tags = { "home" },
    file_path = "/org/home.org",
  }),
  mk_item({
    title = "Fix tests",
    todo_state = "NEXT",
    priority = "B",
    tags = { "work" },
    file_path = "/org/work.org",
  }),
  mk_item({
    title = "Journal",
    todo_state = "DONE",
    priority = nil,
    tags = {},
    file_path = "/org/journal.org",
  }),
  mk_item({
    title = "Review PR",
    todo_state = "NEXT",
    priority = "A",
    tags = { "work", "pr" },
    file_path = "/org/work.org",
  }),
}

-- 9. todo:NEXT → only NEXT items (3).
do
  local parsed = find.parse_filter_tokens("todo:NEXT")
  local out = find.apply_filter_tokens(items, parsed)
  assert(#out == 3, "todo:NEXT should return 3 items; got " .. #out)
  for _, it in ipairs(out) do
    assert(it.todo_state == "NEXT", "all results should be NEXT; got " .. tostring(it.todo_state))
  end
end

-- 10. todo:NEXT + plain "fix" → NEXT items whose title contains "fix" (case-insensitive).
do
  local parsed = find.parse_filter_tokens("todo:NEXT fix")
  local out = find.apply_filter_tokens(items, parsed)
  assert(#out == 2, "todo:NEXT fix → 2 items; got " .. #out)
  for _, it in ipairs(out) do
    assert(it.todo_state == "NEXT", "must be NEXT")
    assert(it.title:lower():find("fix", 1, true), "must contain 'fix'")
  end
end

-- 11. priority:A → items with priority A (2: "Fix bug", "Review PR").
do
  local parsed = find.parse_filter_tokens("priority:A")
  local out = find.apply_filter_tokens(items, parsed)
  assert(#out == 2, "priority:A → 2; got " .. #out)
end

-- 12. tag:work → items tagged work (3).
do
  local parsed = find.parse_filter_tokens("tag:work")
  local out = find.apply_filter_tokens(items, parsed)
  assert(#out == 3, "tag:work → 3; got " .. #out)
end

-- 13. file:home → 1 item in home.org.
do
  local parsed = find.parse_filter_tokens("file:home")
  local out = find.apply_filter_tokens(items, parsed)
  assert(#out == 1, "file:home → 1; got " .. #out)
  assert(out[1].title == "Buy milk", "should be Buy milk; got " .. tostring(out[1].title))
end

-- 14. Multiple plain tokens ANDed: "fix test" → "Fix tests" only.
do
  local parsed = find.parse_filter_tokens("fix test")
  local out = find.apply_filter_tokens(items, parsed)
  assert(#out == 1, "fix test → 1; got " .. #out)
  assert(out[1].title == "Fix tests")
end

-- 15. todo:NEXT todo:TODO (OR) → all NEXT + all TODO.
do
  local parsed = find.parse_filter_tokens("todo:NEXT todo:TODO")
  local out = find.apply_filter_tokens(items, parsed)
  assert(#out == 4, "todo:NEXT todo:TODO → 4; got " .. #out)
end

-- 16. No matching criteria → empty.
do
  local parsed = find.parse_filter_tokens("todo:CANCELLED")
  local out = find.apply_filter_tokens(items, parsed)
  assert(#out == 0, "no match → 0; got " .. #out)
end

-- Integration: find.pick with opts.query applies pre-filtering.

require("organ").setup({
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub", columns = { "title" }, match_fields = { "title" } },
})

do
  local backend_stub = require("organ.find.backend")._test_stub
  backend_stub.last = nil

  find.pick({
    source = "complete",
    items = items,
    default_action = "jump",
    query = "todo:NEXT fix",
  })

  local last = backend_stub.last
  assert(last and last.items, "stub should have received items")
  assert(
    #last.items == 2,
    "pick with query 'todo:NEXT fix' should yield 2 items; got "
      .. tostring(last.items and #last.items)
  )
end

io.write("find filter tokens ok\n")
os.exit(0)
