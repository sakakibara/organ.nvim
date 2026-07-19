-- `* COMMENT Foo` (and `* TODO COMMENT Foo`) marks a headline + subtree
-- as commented.  When `agenda.skip_comment_trees` is true (the default,
-- mirroring Emacs `org-agenda-skip-comment-trees`), the agenda must
-- drop the commented headline AND every descendant.
--
-- Two checks:
--   1. `indexer.extract` flags the right rows.
--   2. The agenda filter drops commented rows + descendants and the
--      `skip_comment_trees = false` escape hatch surfaces them.
--
-- Run via: nvim --headless -l tests/agenda_skip_comment_trees_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- ---------------------------------------------------------------------------
-- 1. Parser-level: indexer.extract sets `commented` on the right rows.
-- ---------------------------------------------------------------------------
local fixture_path = os.tmpname() .. ".org"
local f = assert(io.open(fixture_path, "w"))
f:write([[
* TODO Active task
* COMMENT Suppressed parent
** TODO Suppressed child
* TODO Visible task
* TODO COMMENT Suppressed-via-todo-comment
* TODO [#A] COMMENT Canonical-order
]])
f:close()

local src = table.concat(vim.fn.readfile(fixture_path), "\n") .. "\n"
local indexer = require("organ.indexer")
local hls = indexer.extract(src, fixture_path, require("organ.defaults").parser_path)
os.remove(fixture_path)

local by_title = {}
for _, hl in ipairs(hls) do
  by_title[hl.title] = hl
end

check(
  "indexer flags `* COMMENT Foo`",
  by_title["Suppressed parent"] and by_title["Suppressed parent"].commented == 1
)
check(
  "indexer flags `* TODO COMMENT Foo`",
  by_title["Suppressed-via-todo-comment"] and by_title["Suppressed-via-todo-comment"].commented == 1
)
check(
  "indexer does NOT flag normal `* TODO Foo`",
  by_title["Active task"]
    and (by_title["Active task"].commented or 0) == 0
    and by_title["Visible task"]
    and (by_title["Visible task"].commented or 0) == 0
)
check(
  "indexer flags canonical `* TODO [#A] COMMENT Foo`",
  by_title["Canonical-order"] and by_title["Canonical-order"].commented == 1
)
check(
  "priority cookie before COMMENT still parsed",
  by_title["Canonical-order"] and by_title["Canonical-order"].priority == "A"
)

-- ---------------------------------------------------------------------------
-- 2. Agenda filter: drops commented rows + descendants, transitive via
--    parent_id chain (commented_chain).
-- ---------------------------------------------------------------------------
local SAMPLE = {
  {
    id = "h1",
    title = "Active task",
    file_path = "/t.org",
    line_start = 1,
    level = 1,
    todo_state = "TODO",
    parent_id = nil,
    commented = false,
    tags = {},
  },
  {
    id = "h2",
    title = "Suppressed parent",
    file_path = "/t.org",
    line_start = 2,
    level = 1,
    todo_state = nil,
    parent_id = nil,
    commented = true,
    tags = {},
  },
  {
    id = "h3",
    title = "Suppressed child",
    file_path = "/t.org",
    line_start = 3,
    level = 2,
    todo_state = "TODO",
    parent_id = "h2",
    commented = false,
    tags = {},
  },
  {
    id = "h4",
    title = "Another suppressed child",
    file_path = "/t.org",
    line_start = 4,
    level = 2,
    todo_state = "TODO",
    parent_id = "h2",
    commented = false,
    tags = {},
  },
  {
    id = "h5",
    title = "Visible task",
    file_path = "/t.org",
    line_start = 5,
    level = 1,
    todo_state = "TODO",
    parent_id = nil,
    commented = false,
    tags = {},
  },
}

-- Stub query.headlines + query.get_by_id (used by transitive parent walk).
package.loaded["organ.query"] = {
  headlines = function()
    return SAMPLE
  end,
  agenda = function()
    return SAMPLE
  end,
  files = function()
    return {}
  end,
  links = function()
    return {}
  end,
  get_by_id = function(id)
    for _, r in ipairs(SAMPLE) do
      if r.id == id then
        return r
      end
    end
    return nil
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "|", "DONE" } },
})

local agenda = require("organ.agenda")

local function titles_in(rows)
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = r.title
  end
  return out
end
local function present(list, t)
  for _, x in ipairs(list) do
    if x == t then
      return true
    end
  end
  return false
end

local rows_on = agenda._run_query({ kind = "todo", skip_comment_trees = true })
local titles_on = titles_in(rows_on)
check(
  "skip_comment_trees=true: drops the COMMENT parent",
  not present(titles_on, "Suppressed parent")
)
check(
  "skip_comment_trees=true: drops descendants of COMMENT parent (transitive)",
  not present(titles_on, "Suppressed child") and not present(titles_on, "Another suppressed child")
)
check(
  "skip_comment_trees=true: keeps non-commented siblings",
  present(titles_on, "Active task") and present(titles_on, "Visible task")
)

local rows_off = agenda._run_query({ kind = "todo", skip_comment_trees = false })
local titles_off = titles_in(rows_off)
check(
  "skip_comment_trees=false: surfaces the COMMENT parent (escape hatch)",
  present(titles_off, "Suppressed parent")
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_skip_comment_trees_test: PASS")
