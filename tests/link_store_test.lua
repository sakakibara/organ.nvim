-- tests/link_store_test.lua
-- Tests for lua/organ/link_store.lua
-- Run via: nvim --headless -l tests/link_store_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local store = require("organ.link_store")

-- ─── Test 1: push 3 entries, list returns them newest-first ──────────────────
do
  store.clear()

  local e1 = { kind = "id", id = "a1", title = "First", file_path = "/a.org" }
  local e2 = { kind = "id", id = "b2", title = "Second", file_path = "/b.org" }
  local e3 = { kind = "id", id = "c3", title = "Third", file_path = "/c.org" }

  store.push(e1)
  store.push(e2)
  store.push(e3)

  local list = store.list()
  assert(#list == 3, "test1: expected 3 entries, got " .. #list)
  -- LIFO: newest first
  assert(list[1].title == "Third", "test1: list[1] should be 'Third', got " .. list[1].title)
  assert(list[2].title == "Second", "test1: list[2] should be 'Second', got " .. list[2].title)
  assert(list[3].title == "First", "test1: list[3] should be 'First', got " .. list[3].title)
end

-- ─── Test 2: push 51 entries → size stays at 50 (oldest dropped) ─────────────
do
  store.clear()

  for i = 1, 51 do
    store.push({ kind = "id", id = tostring(i), title = "Entry " .. i, file_path = "/x.org" })
  end

  assert(store.size() == 50, "test2: size should be 50 after 51 pushes, got " .. store.size())

  -- Newest entry (pushed last) should be at index 1.
  local list = store.list()
  assert(
    list[1].title == "Entry 51",
    "test2: list[1] should be 'Entry 51', got " .. (list[1] and list[1].title or "nil")
  )

  -- Oldest (Entry 1) should have been dropped (only 50 remain, Entry 2..51).
  local found_e1 = false
  for _, e in ipairs(list) do
    if e.title == "Entry 1" then
      found_e1 = true
      break
    end
  end
  assert(not found_e1, "test2: 'Entry 1' should have been dropped (overflow)")
end

-- ─── Test 3: clear empties the store ─────────────────────────────────────────
do
  store.clear()
  store.push({ kind = "id", id = "x", title = "X", file_path = "/x.org" })
  assert(store.size() == 1, "test3 pre: size should be 1")
  store.clear()
  assert(store.size() == 0, "test3: clear should empty the store")
  local list = store.list()
  assert(#list == 0, "test3: list should be empty after clear")
end

-- ─── Test 4: file_line entry stored and retrieved ─────────────────────────────
do
  store.clear()
  local e = { kind = "file_line", file_path = "/notes.org", line = 42, title = "notes.org:42" }
  store.push(e)
  local list = store.list()
  assert(#list == 1, "test4: expected 1 entry")
  assert(list[1].kind == "file_line", "test4: kind should be file_line")
  assert(list[1].line == 42, "test4: line should be 42")
  assert(list[1].title == "notes.org:42", "test4: title mismatch")
end

io.write("link_store ok\n")
os.exit(0)
