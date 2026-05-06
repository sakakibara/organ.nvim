-- `tags.exclude_from_inheritance` mirrors Emacs `org-tags-exclude-
-- from-inheritance`: tags that NEVER inherit even when global
-- `tags.inherit = true`.  Direct application is unaffected; only
-- propagation to descendants is suppressed.
--
-- Run via: nvim --headless -l tests/tags_exclude_from_inheritance_test.lua

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

-- Build a tiny in-memory fixture: parent has `:project:`, child has
-- `:work:`.  With `exclude_from_inheritance = { "project" }`, the
-- child's effective tags should be `{ "work" }` only — `project`
-- must NOT propagate.
local fixture = os.tmpname() .. ".org"
local f = assert(io.open(fixture, "w"))
f:write([[
#+FILETAGS: :general:
* Parent project   :project:
** Child task       :work:
* Other task
]])
f:close()

local db_path = os.tmpname() .. ".db"
os.remove(db_path)

local indexer = require("organ.indexer")
local db_mod = require("organ.db")
local h = assert(db_mod.open(db_path))
local schema_sql = table.concat(vim.fn.readfile(root .. "/sql/schema.sql"), "\n")
assert(h:exec(schema_sql))
local src = table.concat(vim.fn.readfile(fixture), "\n") .. "\n"
local hls = indexer.extract(src, fixture, require("organ.defaults").parser_path)
local meta = { path = fixture, mtime = 0, hash = vim.fn.sha256(src) }
indexer.write(h, meta, hls, function() end)

-- The indexer canonicalizes file_path on write (resolves symlinks +
-- absolutizes). Match that form when we insert filetags directly so
-- the file_tags rows JOIN cleanly with headlines.
local canon_path = require("organ.path").canonical(fixture) or fixture

-- Also write filetags so `general` is on the file_tags table.
local ft = require("organ.indexer").scan_filetags(src)
local del = assert(h:prepare("DELETE FROM file_tags WHERE file_path = ?"))
del:bind_text(1, canon_path)
del:step()
del:finalize()
local ins = assert(h:prepare("INSERT INTO file_tags (file_path, tag) VALUES (?, ?)"))
for _, t in ipairs(ft) do
  ins:reset()
  ins:bind_text(1, canon_path)
  ins:bind_text(2, t)
  ins:step()
end
ins:finalize()

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  tags = { inherit = true, exclude_from_inheritance = { "project" } },
})

local query = require("organ.query")
-- Override default_db to use our fixture DB.
package.loaded["organ.db"]._test_handle = h
local orig_default_db = require("organ.db").open
package.loaded["organ.db"].open = function()
  return h
end

-- Force the query module to re-resolve the db handle by clearing any
-- cached default. (query.lua opens via require("organ.db").open())
local rows = query.headlines({
  files = { fixture },
  include_inherited_tags = true,
})
package.loaded["organ.db"].open = orig_default_db

local by_title = {}
for _, r in ipairs(rows) do
  by_title[r.title] = r
end

check(
  "Child task does NOT inherit `:project:` (exclude list)",
  by_title["Child task"] and not vim.tbl_contains(by_title["Child task"].tags, "project"),
  "tags: " .. vim.inspect(by_title["Child task"] and by_title["Child task"].tags)
)

check(
  "Child task DOES inherit `:general:` (filetag, not excluded)",
  by_title["Child task"] and vim.tbl_contains(by_title["Child task"].tags, "general")
)

check(
  "Parent project KEEPS its direct `:project:` tag",
  by_title["Parent project"] and vim.tbl_contains(by_title["Parent project"].tags, "project")
)

h:close()
os.remove(fixture)
os.remove(db_path)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("tags_exclude_from_inheritance_test: PASS")
