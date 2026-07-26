-- Schema-migration framework tests: a user's live index is upgraded by
-- the MIGRATIONS cascade (transactional, one step per version) and is
-- NEVER dropped, rebuilt, or left half-migrated by any failure path.
-- Also pins the four-edit contract for shipping a schema change:
-- sql/schema.sql + SCHEMA_VERSION + MIGRATIONS[<new>] + fixture snapshot.
--
-- Run via: nvim --headless -l tests/db_migration_test.lua

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
local organ = require("organ")
organ.config.schema_path = root .. "/sql/schema.sql"
organ.config.notify = false

local tmp_files = {}
local function open_tmp()
  local p = os.tmpname() .. ".db"
  os.remove(p)
  tmp_files[#tmp_files + 1] = p
  return assert(db_mod.open(p)), p
end

local function exec(h, sql)
  local ok, err = h:exec(sql)
  assert(ok, tostring(err))
end

local function user_version(h)
  local s = assert(h:prepare("PRAGMA user_version"))
  assert(s:step() == db_mod.SQLITE_ROW)
  local v = s:column_int(0)
  s:finalize()
  return v
end

local function has_table(h, name)
  local s = assert(h:prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"))
  s:bind_text(1, name)
  local found = s:step() == db_mod.SQLITE_ROW
  s:finalize()
  return found
end

local function has_column(h, table_name, col)
  local s = assert(h:prepare("PRAGMA table_info(" .. table_name .. ")"))
  while s:step() == db_mod.SQLITE_ROW do
    if s:column_text(1) == col then
      s:finalize()
      return true
    end
  end
  s:finalize()
  return false
end

local fixture_sql = table.concat(vim.fn.readfile(root .. "/tests/fixtures/schema/v1.sql"), "\n")

-- v1 DB carrying one representative row per data table the migration
-- cascade must carry forward intact.
local function make_v1_db()
  local h, p = open_tmp()
  exec(h, fixture_sql)
  exec(h, "PRAGMA user_version = 1")
  exec(
    h,
    [[
    INSERT INTO files(path, mtime, hash, indexed, extractor_version)
      VALUES ('/tmp/mig.org', 1700000000, 'deadbeef', 1700000001, 'ev1');
    INSERT INTO headlines(id, file_path, parent_id, level, title, todo_state,
                          line_start, line_end, commented)
      VALUES ('h1', '/tmp/mig.org', NULL, 1, 'Migrate me', 'TODO', 1, 5, 0);
    INSERT INTO tags(headline_id, tag) VALUES ('h1', 'work');
    INSERT INTO links(source_headline_id, target_type, target, description, line)
      VALUES ('h1', 'id', 'target-uuid', 'a link', 3);
    INSERT INTO state_changes(headline_id, ts, from_state, to_state, note)
      VALUES ('h1', 1700000100, 'TODO', 'DONE', 'did it');
  ]]
  )
  return h, p
end

-- Compares actual column values, not row counts, so a migration that
-- rewrites a table (e.g. 12-step ALTER) can't silently corrupt rows.
local function data_intact(h)
  local s = assert(h:prepare("SELECT mtime, hash, extractor_version FROM files WHERE path = ?"))
  s:bind_text(1, "/tmp/mig.org")
  if s:step() ~= db_mod.SQLITE_ROW then
    s:finalize()
    return false, "files row missing"
  end
  local f = { s:column_int64(0), s:column_text(1), s:column_text(2) }
  s:finalize()
  if f[1] ~= 1700000000 or f[2] ~= "deadbeef" or f[3] ~= "ev1" then
    return false, "files row corrupted"
  end

  s = assert(
    h:prepare(
      "SELECT file_path, level, title, todo_state, line_start, line_end FROM headlines WHERE id = 'h1'"
    )
  )
  if s:step() ~= db_mod.SQLITE_ROW then
    s:finalize()
    return false, "headlines row missing"
  end
  local hl = {
    s:column_text(0),
    s:column_int(1),
    s:column_text(2),
    s:column_text(3),
    s:column_int(4),
    s:column_int(5),
  }
  s:finalize()
  if
    hl[1] ~= "/tmp/mig.org"
    or hl[2] ~= 1
    or hl[3] ~= "Migrate me"
    or hl[4] ~= "TODO"
    or hl[5] ~= 1
    or hl[6] ~= 5
  then
    return false, "headlines row corrupted"
  end

  s = assert(h:prepare("SELECT tag FROM tags WHERE headline_id = 'h1'"))
  if s:step() ~= db_mod.SQLITE_ROW or s:column_text(0) ~= "work" then
    s:finalize()
    return false, "tags row missing/corrupted"
  end
  s:finalize()

  s = assert(
    h:prepare(
      "SELECT target_type, target, description, line FROM links WHERE source_headline_id = 'h1'"
    )
  )
  if s:step() ~= db_mod.SQLITE_ROW then
    s:finalize()
    return false, "links row missing"
  end
  local l = { s:column_text(0), s:column_text(1), s:column_text(2), s:column_int(3) }
  s:finalize()
  if l[1] ~= "id" or l[2] ~= "target-uuid" or l[3] ~= "a link" or l[4] ~= 3 then
    return false, "links row corrupted"
  end

  s = assert(
    h:prepare("SELECT ts, from_state, to_state, note FROM state_changes WHERE headline_id = 'h1'")
  )
  if s:step() ~= db_mod.SQLITE_ROW then
    s:finalize()
    return false, "state_changes row missing"
  end
  local sc = { s:column_int64(0), s:column_text(1), s:column_text(2), s:column_text(3) }
  s:finalize()
  if sc[1] ~= 1700000100 or sc[2] ~= "TODO" or sc[3] ~= "DONE" or sc[4] ~= "did it" then
    return false, "state_changes row corrupted"
  end
  return true
end

-- 1. v1 data survives an injected two-step cascade.

do
  local h = make_v1_db()
  local fake = {
    [2] = function(th)
      assert(th:exec("ALTER TABLE headlines ADD COLUMN mig_probe INTEGER"))
    end,
    [3] = function(th)
      assert(th:exec("CREATE TABLE mig_probe_t(x INTEGER)"))
    end,
  }
  organ._run_migrations(h, 1, 3, fake)
  check("cascade: user_version reached 3", user_version(h) == 3, "got " .. user_version(h))
  local ok, why = data_intact(h)
  check("cascade: all v1 rows intact with original values", ok, why)
  check("cascade: migrated column exists", has_column(h, "headlines", "mig_probe"))
  check("cascade: migrated table exists", has_table(h, "mig_probe_t"))
  h:close()
end

-- 2. Missing migration entry: refuse loudly, change nothing.

do
  local h = make_v1_db()
  local ok, err = pcall(organ._run_migrations, h, 1, 2, {})
  check("missing entry: errors", not ok)
  check(
    "missing entry: error names the version gap",
    tostring(err):match("v1") and tostring(err):match("v2"),
    tostring(err)
  )
  check("missing entry: user_version unchanged", user_version(h) == 1)
  local intact, why = data_intact(h)
  check("missing entry: data intact", intact, why)
  h:close()
end

-- 3. Failed step rolls back everything, including the user_version
--    stamp written before the failure (PRAGMA user_version lives in the
--    db header and is transactional -- proven here, not assumed).

do
  local h = make_v1_db()
  local fake = {
    [2] = function(th)
      assert(th:exec("CREATE TABLE half_done(x INTEGER)"))
      assert(th:exec("PRAGMA user_version = 2"))
      error("boom")
    end,
  }
  local ok, err = pcall(organ._run_migrations, h, 1, 2, fake)
  check("rollback: errors", not ok)
  check(
    "rollback: error says index unchanged",
    tostring(err):match("index unchanged") and tostring(err):match("boom"),
    tostring(err)
  )
  check("rollback: user_version stamp rolled back", user_version(h) == 1)
  check("rollback: half-created table rolled back", not has_table(h, "half_done"))
  local intact, why = data_intact(h)
  check("rollback: data intact", intact, why)
  h:close()
end

-- 4. Real ensure_schema path: idempotent no-op at the current version.

local current
do
  local h = open_tmp()
  organ._ensure_schema(h)
  current = user_version(h)
  check("ensure: fresh db stamped to current version", current >= 1, "got " .. current)
  exec(h, "INSERT INTO files(path, mtime, hash, indexed) VALUES ('/tmp/probe.org', 1, 'x', 1)")
  organ._ensure_schema(h)
  check("ensure: second call is a no-op on user_version", user_version(h) == current)
  local s = assert(h:prepare("SELECT hash FROM files WHERE path = '/tmp/probe.org'"))
  local survived = s:step() == db_mod.SQLITE_ROW and s:column_text(0) == "x"
  s:finalize()
  check("ensure: probe row survives the second call", survived)
  h:close()
end

-- 5. Newer-db refusal preserved.

do
  local h = open_tmp()
  organ._ensure_schema(h)
  exec(h, "INSERT INTO files(path, mtime, hash, indexed) VALUES ('/tmp/probe.org', 1, 'x', 1)")
  exec(h, "PRAGMA user_version = " .. (current + 1))
  local ok, err = pcall(organ._ensure_schema, h)
  check("newer db: refuses", not ok)
  check(
    "newer db: error says no downgrade",
    tostring(err):match("Refusing to downgrade"),
    tostring(err)
  )
  local s = assert(h:prepare("SELECT hash FROM files WHERE path = '/tmp/probe.org'"))
  local survived = s:step() == db_mod.SQLITE_ROW and s:column_text(0) == "x"
  s:finalize()
  check("newer db: data intact", survived)
  h:close()
end

-- 6. A required column missing at the current version errors with the
--    delete-the-file recovery and never wipes anything.

do
  local h = make_v1_db()
  local dropped = h:exec("ALTER TABLE headlines DROP COLUMN commented")
  check("missing column: DROP COLUMN supported by system SQLite", dropped ~= nil)
  check("missing column: column genuinely absent", not has_column(h, "headlines", "commented"))
  exec(h, "PRAGMA user_version = " .. current)
  local ok, err = pcall(organ._ensure_schema, h)
  check("missing column: ensure_schema errors", not ok)
  check(
    "missing column: error names headlines.commented",
    tostring(err):match("headlines%.commented"),
    tostring(err)
  )
  check(
    "missing column: error gives delete-the-file recovery",
    tostring(err):match("Delete the file") and tostring(err):match(":Org scan"),
    tostring(err)
  )
  for _, t in ipairs({
    "files",
    "headlines",
    "tags",
    "properties",
    "links",
    "clock_entries",
    "state_changes",
    "file_tags",
    "aliases",
    "habit_completions",
    "file_todo_keywords",
  }) do
    check("missing column: table " .. t .. " still exists", has_table(h, t))
  end
  local intact, why = data_intact(h)
  check("missing column: data intact", intact, why)
  h:close()
end

-- 6b. A required TABLE missing at the current version errors (naming the
--     missing table) and never wipes the surviving tables or their data.

do
  local h = make_v1_db()
  local dok, derr = h:exec("DROP TABLE state_changes")
  check("missing table: DROP TABLE succeeded", dok ~= nil, tostring(derr))
  check("missing table: table genuinely absent", not has_table(h, "state_changes"))
  exec(h, "PRAGMA user_version = " .. current)
  local ok, err = pcall(organ._ensure_schema, h)
  check("missing table: ensure_schema errors", not ok)
  check(
    "missing table: error mentions state_changes",
    tostring(err):match("state_changes"),
    tostring(err)
  )
  for _, t in ipairs({
    "files",
    "headlines",
    "tags",
    "properties",
    "links",
    "clock_entries",
    "file_tags",
    "aliases",
    "habit_completions",
    "file_todo_keywords",
  }) do
    check("missing table: surviving table " .. t .. " still exists", has_table(h, t))
  end
  -- Verify surviving tables' data is untouched (state_changes row is gone, skip it).
  local s2 = assert(h:prepare("SELECT hash FROM files WHERE path = '/tmp/mig.org'"))
  local files_ok = s2:step() == db_mod.SQLITE_ROW and s2:column_text(0) == "deadbeef"
  s2:finalize()
  check("missing table: surviving data intact", files_ok)
  h:close()
end

-- 7. Migration-ledger continuity: every version step from the baseline
--    to current has a migration function. Vacuous at v1; bites the
--    moment SCHEMA_VERSION bumps without a MIGRATIONS entry.

do
  for v = 2, current do
    check("ledger: MIGRATIONS[" .. v .. "] is a function", type(organ._migrations[v]) == "function")
  end
  check("ledger: walked baseline+1 .. v" .. current, true)
end

-- 8. Schema-drift guard: sql/schema.sql must be byte-identical to the
--    snapshot fixture for the current version.

do
  local recipe = "a schema change ships as FOUR edits: "
    .. "1. edit sql/schema.sql; "
    .. "2. bump SCHEMA_VERSION in lua/organ/init.lua; "
    .. "3. add MIGRATIONS[<new>] upgrading a live index one step; "
    .. "4. snapshot the new schema.sql to tests/fixtures/schema/v<new>.sql"
  local function read_bytes(p)
    local f = io.open(p, "rb")
    if not f then
      return nil
    end
    local s = f:read("*a")
    f:close()
    return s
  end
  local live = read_bytes(root .. "/sql/schema.sql")
  local snap_path = root .. "/tests/fixtures/schema/v" .. current .. ".sql"
  local snap = read_bytes(snap_path)
  check(
    "drift: snapshot fixture exists for v" .. current,
    snap ~= nil,
    snap_path .. " missing -- " .. recipe
  )
  check(
    "drift: sql/schema.sql byte-identical to " .. "tests/fixtures/schema/v" .. current .. ".sql",
    live ~= nil and live == snap,
    "sql/schema.sql drifted from its v" .. current .. " snapshot -- " .. recipe
  )
end

-- 9. Fresh install == migrated install. Today the cascade is empty so
--    this compares v1 with itself; the moment MIGRATIONS gains entries
--    it proves each step lands on the fresh schema.sql shape.

do
  local function schema_fingerprint(h)
    local parts = {}
    local ts = assert(
      h:prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
      )
    )
    local tables = {}
    while ts:step() == db_mod.SQLITE_ROW do
      tables[#tables + 1] = ts:column_text(0)
    end
    ts:finalize()
    for _, t in ipairs(tables) do
      local cols = {}
      local ti = assert(h:prepare("PRAGMA table_info(" .. t .. ")"))
      while ti:step() == db_mod.SQLITE_ROW do
        cols[#cols + 1] = table.concat({
          ti:column_text(1),
          ti:column_text(2) or "",
          tostring(ti:column_int(3)),
          ti:column_text(4) or "<null>",
          tostring(ti:column_int(5)),
        }, "|")
      end
      ti:finalize()
      table.sort(cols)
      parts[#parts + 1] = "table " .. t .. ": " .. table.concat(cols, ", ")
    end
    local idx_names = {}
    local idx_sql = {}
    local si = assert(
      h:prepare(
        "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name"
      )
    )
    while si:step() == db_mod.SQLITE_ROW do
      local iname = si:column_text(0)
      local isql = si:column_text(1) or ""
      idx_names[#idx_names + 1] = iname
      idx_sql[iname] = isql
    end
    si:finalize()
    parts[#parts + 1] = "indexes: " .. table.concat(idx_names, ", ")
    local idx_sql_parts = {}
    for _, iname in ipairs(idx_names) do
      idx_sql_parts[#idx_sql_parts + 1] = iname .. "=" .. idx_sql[iname]
    end
    parts[#parts + 1] = "index_sql: " .. table.concat(idx_sql_parts, "; ")
    return table.concat(parts, "\n")
  end

  local ha = open_tmp()
  exec(ha, fixture_sql)
  exec(ha, "PRAGMA user_version = 1")
  organ._run_migrations(ha, 1, current, organ._migrations)
  check("equivalence: migrated db reached current version", user_version(ha) == current)

  local hb = open_tmp()
  organ._ensure_schema(hb)

  local fa, fb = schema_fingerprint(ha), schema_fingerprint(hb)
  check(
    "equivalence: migrated schema == fresh schema (columns + indexes)",
    fa == fb,
    "\n--- migrated ---\n" .. fa .. "\n--- fresh ---\n" .. fb
  )
  ha:close()
  hb:close()
end

for _, p in ipairs(tmp_files) do
  os.remove(p)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("db_migration_test: PASS")
os.exit(0)
