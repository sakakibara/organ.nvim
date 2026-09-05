-- `tags.exclude_from_inheritance` has to hold for the SQL tag filter as
-- well as for the tags the agenda displays: in Emacs an excluded tag
-- matches only the headline (or nothing at all, when it came from
-- #+FILETAGS, since nothing carries it directly).
-- Run via: nvim --headless -l tests/query_tag_inherit_exclude_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local path = tmp .. "/a.org"
local f = assert(io.open(path, "w"))
f:write(table.concat({
  "#+FILETAGS: :home:work:",
  "* Project alpha :proj:crypt:",
  "** Child one :child:",
  "** Child two",
  "* Beta :proj:",
  "",
}, "\n"))
f:close()

require("organ").setup({
  org_dir = tmp,
  db_path = tmp .. "/organ.db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  tags = { exclude_from_inheritance = { "crypt", "home" } },
})

require("organ.indexer").index_file_sync(path)
local query = require("organ.query")

local function matched(tag)
  local out = {}
  for _, r in ipairs(query.headlines({ tags = { any = { tag } }, inherit = true })) do
    out[#out + 1] = r.title
  end
  table.sort(out)
  return table.concat(out, "|")
end

-- Directly set on Project alpha, excluded from inheritance.
assert(matched("crypt") == "Project alpha", "crypt matched " .. matched("crypt"))
-- From #+FILETAGS and excluded, so it reaches nobody.
assert(matched("home") == "", "home matched " .. matched("home"))
-- From #+FILETAGS and not excluded, so every headline carries it.
assert(
  matched("work") == "Beta|Child one|Child two|Project alpha",
  "work matched " .. matched("work")
)
-- Ordinary inheritance is untouched.
assert(
  matched("proj") == "Beta|Child one|Child two|Project alpha",
  "proj matched " .. matched("proj")
)

vim.fn.delete(tmp, "rf")
io.write("query tag inherit exclude ok\n")
os.exit(0)
