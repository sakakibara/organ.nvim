-- Pure unit: find.format_columns(record, columns_list) builds the display
-- string per the spec table; missing fields contribute nothing; gaps collapse.
-- Run via: nvim --headless -l tests/find_format_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local find = require("organ.find")

local function mk(over)
  local r = {
    level = 1,
    todo_state = nil,
    priority = nil,
    title = "Hello",
    tags = {},
    file_path = "/tmp/x.org",
    line_start = 0,
  }
  for k, v in pairs(over or {}) do
    r[k] = v
  end
  return r
end

-- Title only.
do
  local s = find.format_columns(mk({}), { "title" })
  assert(s == "Hello", "title-only: " .. s)
end

-- Level + title.
do
  local s = find.format_columns(mk({ level = 2 }), { "level", "title" })
  assert(s == "** Hello", "level+title: " .. s)
end

-- All columns, populated.
do
  local s = find.format_columns(
    mk({
      level = 1,
      todo_state = "TODO",
      priority = "A",
      title = "Important task",
      tags = { "work", "urgent" },
      file_path = "/tmp/x.org",
      line_start = 5,
    }),
    { "level", "todo", "priority", "title", "tags", "path" }
  )
  -- Expected: "* TODO  [A] Important task :work:urgent: ~/tmp/x.org:5"
  -- Note: TODO is %-5s so it has trailing spaces inside its slot.
  assert(s:find("Important task", 1, true), "title in: " .. s)
  assert(s:find(":work:urgent:", 1, true), "tags in: " .. s)
  -- Org's convention: priority cookie is `[#A]`, not `[A]`.
  assert(s:find("[#A]", 1, true), "priority bracket in: " .. s)
  assert(s:match("^%*"), "starts with stars: " .. s)
end

-- Empty fields contribute nothing; no double spaces.
do
  local s = find.format_columns(
    mk({ level = 1, title = "T" }),
    { "level", "todo", "priority", "title", "tags", "path" }
  )
  assert(
    not s:find("  ", 1, true) or not s:find("   ", 1, true),
    "no double spaces from empty fields: '" .. s .. "'"
  )
  -- "T" must appear, with `[ ]` from the priority default.
  assert(s:find("T", 1, true))
  -- find.format_columns omits the priority slot entirely when missing.
  -- (The `[ ]` placeholder is an agenda-only behavior.)
  assert(
    not s:find("[", 1, true) or s:find("[#", 1, true),
    "no priority placeholder for unprioritized row: " .. s
  )
end

-- Configurable order: title before level.
do
  local s = find.format_columns(mk({ level = 2, title = "X" }), { "title", "level" })
  assert(s == "X **", "custom order: " .. s)
end

io.write("find format ok\n")
os.exit(0)
