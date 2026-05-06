-- Verifies query.agenda(include_inherited_tags=true) returns rows whose
-- r.tags include parent headline tags + #+FILETAGS.
-- Run via: nvim --headless -l tests/agenda_inherited_tags_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local organ = require("organ")
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

organ.setup({
  org_dir = tmpdir,
  db_path = tmpdir .. "/organ.db",
})

local function write_file(name, content)
  local path = tmpdir .. "/" .. name
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  return path
end

local indexer = require("organ.indexer")
local query = require("organ.query")

local today = os.date("%Y-%m-%d")
local path = write_file(
  "inh.org",
  string.format(
    [[
#+FILETAGS: :project:
* Parent :urgent:
** Child
   SCHEDULED: <%s>
* Other
   SCHEDULED: <%s>
]],
    today,
    today
  )
)

indexer.index_file_sync(path)

-- include_inherited_tags = true → Child's row.tags includes
-- "urgent" (parent) and "project" (filetag).
local rows = query.agenda({
  from = today,
  to = today,
  types = { "scheduled" },
  include_inherited_tags = true,
})

local function find_in(rs, title)
  for _, r in ipairs(rs) do
    if r.title == title then
      return r
    end
  end
end
local function has_tag(r, t)
  for _, x in ipairs(r.tags or {}) do
    if x == t then
      return true
    end
  end
  return false
end

local child = assert(find_in(rows, "Child"), "Child row missing")
assert(
  has_tag(child, "urgent"),
  "Child should inherit 'urgent' from parent; got tags=["
    .. table.concat(child.tags or {}, ",")
    .. "]"
)
assert(has_tag(child, "project"), "Child should inherit 'project' from #+FILETAGS")

local other = assert(find_in(rows, "Other"), "Other row missing")
assert(has_tag(other, "project"), "Other should inherit 'project' from #+FILETAGS")
assert(not has_tag(other, "urgent"), "Other must NOT inherit 'urgent' (different subtree)")

-- include_inherited_tags = false (default) → Child's tags should be empty.
local rows2 = query.agenda({
  from = today,
  to = today,
  types = { "scheduled" },
})
local child2 = assert(find_in(rows2, "Child"), "Child row missing in rows2")
assert(
  not has_tag(child2, "urgent"),
  "without inherited_tags Child must not show 'urgent'; got=["
    .. table.concat(child2.tags or {}, ",")
    .. "]"
)

io.write("agenda inherited tags ok\n")
os.exit(0)
