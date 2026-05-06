-- Exercise `agenda_files` config: single file, list of files,
-- directory-as-list-entry (top-level expansion), and glob patterns
-- including `**` recursion and `!`-prefixed exclusion.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")
vim.fn.mkdir(TMP .. "/sub", "p")

-- Two top-level org files + one nested.
local function write(p, body)
  local f = io.open(p, "w")
  f:write(body)
  f:close()
end
write(
  TMP .. "/a.org",
  [[
#+CATEGORY: Top
* TODO Task in A
SCHEDULED: <2026-05-04 Mon>
]]
)
write(
  TMP .. "/b.org",
  [[
#+CATEGORY: Top
* NEXT Task in B
SCHEDULED: <2026-05-04 Mon>
]]
)
write(
  TMP .. "/sub/c.org",
  [[
#+CATEGORY: Sub
* TODO Task in nested C
SCHEDULED: <2026-05-04 Mon>
]]
)

local DB = TMP .. "/organ.db"
require("organ").setup({
  org_dir = TMP,
  db_path = DB,
  parser_path = vim.fn.expand("~/.local/share/nvim/organ/parser/org.so"),
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
})
local indexer = require("organ.indexer")
indexer.index_file_sync(TMP .. "/a.org")
indexer.index_file_sync(TMP .. "/b.org")
indexer.index_file_sync(TMP .. "/sub/c.org")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local agenda = require("organ.agenda")

-- 1. nil → all 3 files visible
local res = agenda.resolve_agenda_files(nil)
check("nil → no restriction", res == nil)

-- 2. string (file) → 1 entry
res = agenda.resolve_agenda_files(TMP .. "/a.org")
check("string-file → 1 entry", res and #res == 1, vim.inspect(res))
check("string-file → matches", res and res[1] == TMP .. "/a.org", vim.inspect(res))

-- 3. string (dir) → top-level only (a.org + b.org, NOT sub/c.org)
res = agenda.resolve_agenda_files(TMP)
check("string-dir → top-level expansion", res and #res == 2, vim.inspect(res))
local got = {}
for _, p in ipairs(res or {}) do
  got[p] = true
end
check("string-dir → includes a.org", got[TMP .. "/a.org"] == true)
check("string-dir → includes b.org", got[TMP .. "/b.org"] == true)
check("string-dir → SKIPS sub/c.org", got[TMP .. "/sub/c.org"] == nil)

-- 4. list of files
res = agenda.resolve_agenda_files({ TMP .. "/a.org", TMP .. "/b.org" })
check("list-of-files → 2 entries", res and #res == 2)

-- 5. function returning a list
res = agenda.resolve_agenda_files(function()
  return { TMP .. "/a.org" }
end)
check("function spec → resolved", res and #res == 1)

-- 6. Wire through to query: with files filter, only matching rows.
local query = require("organ.query")
local rows = query.agenda({
  from = "2026-05-04",
  to = "2026-05-04",
  types = { "scheduled" },
  files = { TMP .. "/a.org" },
})
check("query.agenda(files=[a.org]) → 1 row", rows and #rows == 1, vim.inspect(rows))
check(
  "query.agenda(files=[a.org]) → it's `Task in A`",
  rows and rows[1] and rows[1].title == "Task in A"
)

-- Empty files list → no rows (semantically distinct from nil).
rows = query.agenda({
  from = "2026-05-04",
  to = "2026-05-04",
  types = { "scheduled" },
  files = {},
})
check("query.agenda(files={}) → 0 rows", rows and #rows == 0)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_files_filter_test: PASS")

-- ── glob + exclusion patterns ────────────────────────────────────────
do
  -- Make sure glob detection picks up `**`, `*`, and `?` patterns.
  local glob_all = agenda.resolve_agenda_files(TMP .. "/**/*.org")
  print("glob_all=", vim.inspect(glob_all))
  check(
    "glob '**/*.org' → recursive (all 3 files)",
    glob_all and #glob_all == 3,
    vim.inspect(glob_all)
  )

  local top_glob = agenda.resolve_agenda_files(TMP .. "/*.org")
  check(
    "glob '*.org' → top-level only (2 files)",
    top_glob and #top_glob == 2,
    vim.inspect(top_glob)
  )

  -- List with negation: include everything, exclude nested.
  local with_excl = agenda.resolve_agenda_files({
    TMP .. "/**/*.org",
    "!" .. TMP .. "/sub/*.org",
  })
  check(
    "glob + '!negation' → excludes nested",
    with_excl and #with_excl == 2,
    vim.inspect(with_excl)
  )
  local set = {}
  for _, p in ipairs(with_excl or {}) do
    set[p] = true
  end
  check("negation excluded sub/c.org", set[TMP .. "/sub/c.org"] == nil)
  check("negation kept a.org", set[TMP .. "/a.org"] == true)

  -- Function returning a list of globs
  local fn_spec = function()
    return { TMP .. "/a.org", TMP .. "/sub/*.org" }
  end
  local res = agenda.resolve_agenda_files(fn_spec)
  check("function → list of mixed glob/file", res and #res == 2, vim.inspect(res))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_files_filter_test (extended): PASS")
