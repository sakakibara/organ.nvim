-- Unit tests for lua/organ/db.lua.
-- Run via: nvim --headless -l tests/db_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local db = require("organ.db")

-- open on a fresh temp file
local path = os.tmpname() .. ".db"
os.remove(path) -- os.tmpname creates a 0-byte file; remove so SQLite opens fresh
local h, err = db.open(path)
assert(h, "open failed: " .. tostring(err))

-- exec a CREATE + INSERT + SELECT-via-exec (no rows expected back through this API)
local ok, e = h:exec("CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (42);")
assert(ok, "exec create/insert failed: " .. tostring(e))

-- exec with a bad statement returns error
local ok2, e2 = h:exec("NOT VALID SQL")
assert(not ok2 and e2, "bad sql should have errored")
assert(e2:match("syntax error") or e2:match("near"), "unexpected error msg: " .. e2)

h:close()
os.remove(path)

----------------------------------------------------------------------
-- Prepared statement roundtrip.

do
  local path2 = os.tmpname() .. ".db"
  os.remove(path2)
  local h2 = assert(db.open(path2))
  assert(h2:exec("CREATE TABLE kv(k TEXT PRIMARY KEY, v INTEGER)"))

  local ins = assert(h2:prepare("INSERT INTO kv(k, v) VALUES (?, ?)"))
  ins:bind_text(1, "alpha")
  ins:bind_int(2, 1)
  assert(ins:step() == db.SQLITE_DONE)
  ins:reset()
  ins:bind_text(1, "beta")
  ins:bind_int(2, 2)
  assert(ins:step() == db.SQLITE_DONE)
  ins:reset()
  ins:bind_text(1, "gamma")
  ins:bind_null(2)
  assert(ins:step() == db.SQLITE_DONE)
  ins:finalize()

  local sel = assert(h2:prepare("SELECT k, v FROM kv ORDER BY k"))
  local rows = {}
  while sel:step() == db.SQLITE_ROW do
    rows[#rows + 1] = { sel:column_text(0), sel:column_int(1) }
  end
  sel:finalize()

  assert(#rows == 3, "row count " .. #rows)
  assert(rows[1][1] == "alpha" and rows[1][2] == 1)
  assert(rows[2][1] == "beta" and rows[2][2] == 2)
  assert(rows[3][1] == "gamma" and rows[3][2] == 0) -- NULL → 0 via column_int
  h2:close()
  os.remove(path2)
end

----------------------------------------------------------------------
-- Transactions.

do
  local path3 = os.tmpname() .. ".db"
  os.remove(path3)
  local h3 = assert(db.open(path3))
  assert(h3:exec("CREATE TABLE t(x INTEGER)"))

  -- successful txn commits.
  local err = h3:transaction(function(h)
    assert(h:exec("INSERT INTO t VALUES (1)"))
    assert(h:exec("INSERT INTO t VALUES (2)"))
  end)
  assert(err == nil, "expected nil err, got " .. tostring(err))

  local sel = assert(h3:prepare("SELECT COUNT(*) FROM t"))
  assert(sel:step() == db.SQLITE_ROW)
  assert(sel:column_int(0) == 2)
  sel:finalize()

  -- failing txn rolls back.
  local err2 = h3:transaction(function(h)
    assert(h:exec("INSERT INTO t VALUES (3)"))
    error("boom")
  end)
  assert(err2 and err2:match("boom"), "expected boom error, got " .. tostring(err2))

  local sel2 = assert(h3:prepare("SELECT COUNT(*) FROM t"))
  assert(sel2:step() == db.SQLITE_ROW)
  assert(sel2:column_int(0) == 2, "rollback failed")
  sel2:finalize()

  h3:close()
  os.remove(path3)
end

----------------------------------------------------------------------
-- PRAGMA apply + user_version bootstrap.

do
  local path4 = os.tmpname() .. ".db"
  os.remove(path4)
  local h4 = assert(db.open(path4, {
    pragmas = {
      journal_mode = "WAL",
      synchronous = "NORMAL",
      foreign_keys = "ON",
      busy_timeout = 5000,
    },
  }))

  local function pragma(name)
    local s = assert(h4:prepare("PRAGMA " .. name))
    assert(s:step() == db.SQLITE_ROW)
    local v = s:column_text(0)
    s:finalize()
    return v
  end
  assert(pragma("journal_mode") == "wal", "journal_mode = " .. pragma("journal_mode"))
  assert(pragma("foreign_keys") == "1", "foreign_keys = " .. pragma("foreign_keys"))
  assert(tonumber(pragma("busy_timeout")) == 5000)

  -- user_version bootstrap: fresh DB → 0. Apply schema → 1 (initial release).
  assert(tonumber(pragma("user_version")) == 0)
  local schema_sql = table.concat(vim.fn.readfile(root .. "/sql/schema.sql"), "\n")
  assert(h4:exec(schema_sql))
  assert(tonumber(pragma("user_version")) == 1)

  h4:close()
  os.remove(path4)
end

----------------------------------------------------------------------
-- Corruption detection: opening garbage file returns a typed error.

do
  local path5 = os.tmpname() .. ".db"
  local f = io.open(path5, "w")
  f:write("this is not a database")
  f:close()
  local h5, err, rc = db.open(path5)
  assert(h5 == nil, "expected open to fail")
  assert(rc == db.SQLITE_NOTADB or err:match("not a database"), "got: " .. tostring(err))
  os.remove(path5)
end

io.write("db core ok\n")
os.exit(0)
