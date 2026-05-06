-- When organ adds a column to schema.sql pre-release, existing DBs at
-- the same `user_version` lack the column.  ensure_schema() detects
-- the mismatch and rebuilds the affected tables in place so the next
-- :Org scan re-extracts cleanly — instead of every query erroring with
-- "no such column: h.commented".
--
-- Run via: nvim --headless -l tests/schema_auto_rebuild_test.lua

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

local db_mod = require("organ.db")

-- Build a DB at user_version=1 missing the `commented` column on
-- `headlines` (mimicking the pre-rebuild state of an upgraded user).
local db_path = os.tmpname() .. ".db"
os.remove(db_path)
local h = assert(db_mod.open(db_path))
assert(h:exec([[
  CREATE TABLE files (
    path TEXT PRIMARY KEY, mtime INTEGER NOT NULL, hash TEXT NOT NULL,
    indexed INTEGER NOT NULL
  );
  CREATE TABLE headlines (
    id TEXT PRIMARY KEY, file_path TEXT NOT NULL, parent_id TEXT,
    level INTEGER NOT NULL, title TEXT NOT NULL, todo_state TEXT,
    priority TEXT, scheduled TEXT, deadline TEXT, closed TEXT,
    scheduled_date TEXT, deadline_date TEXT, closed_date TEXT,
    line_start INTEGER NOT NULL, line_end INTEGER NOT NULL,
    UNIQUE(file_path, line_start)
  );
  PRAGMA user_version = 1;
]]))

-- Pre-rebuild: assert the column is genuinely absent.
local function has_column(handle, table_name, col)
  local stmt = handle:prepare("PRAGMA table_info(" .. table_name .. ")")
  if not stmt then
    return false
  end
  while stmt:step() == db_mod.SQLITE_ROW do
    if stmt:column_text(1) == col then
      stmt:finalize()
      return true
    end
  end
  stmt:finalize()
  return false
end
check("setup: stale DB missing `headlines.commented`", not has_column(h, "headlines", "commented"))
check(
  "setup: stale DB missing `files.extractor_version`",
  not has_column(h, "files", "extractor_version")
)

-- Run ensure_schema — should detect the missing columns and rebuild.
require("organ").config.schema_path = root .. "/sql/schema.sql"
require("organ").config.notify = false -- suppress the WARN notify
require("organ")._ensure_schema(h)

check("post-rebuild: `headlines.commented` exists", has_column(h, "headlines", "commented"))
check("post-rebuild: `files.extractor_version` exists", has_column(h, "files", "extractor_version"))

-- Verify user_version was preserved/reset to current.
local s = assert(h:prepare("PRAGMA user_version"))
assert(s:step() == db_mod.SQLITE_ROW)
local v = s:column_int(0)
s:finalize()
check("post-rebuild: user_version reset to current", v == 1, "got: " .. tostring(v))

-- Tables that existed should still be callable (no orphaned references).
local cnt_files = h:prepare("SELECT COUNT(*) FROM files")
assert(cnt_files:step() == db_mod.SQLITE_ROW)
local nfiles = cnt_files:column_int(0)
cnt_files:finalize()
check(
  "post-rebuild: files table is empty (re-scan will repopulate)",
  nfiles == 0,
  "rows: " .. nfiles
)

-- A second ensure_schema call must be a no-op (idempotent).
local function ok_idempotent()
  local ok = pcall(function()
    require("organ")._ensure_schema(h)
  end)
  return ok
end
check("post-rebuild: ensure_schema is idempotent", ok_idempotent())

h:close()
os.remove(db_path)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("schema_auto_rebuild_test: PASS")
