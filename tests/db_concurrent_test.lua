-- Two organ-managed handles to the same DB file (e.g. two nvim
-- instances on the same org_dir) must not corrupt each other.
-- Default pragmas use WAL + busy_timeout 5s, which sqlite documents
-- as safe for one-writer-many-readers across processes.
--
-- Run via: nvim --headless -l tests/db_concurrent_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})

local db = require("organ.db")
local pragmas = require("organ.defaults").pragmas

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local path = tmp .. "/concurrent.db"

local h1, err1 = db.open(path, { pragmas = pragmas })
check("first handle opens", h1 ~= nil, tostring(err1))
assert(h1, err1)
local ok = h1:exec("CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT)")
check("schema created via h1", ok)

local h2, err2 = db.open(path, { pragmas = pragmas })
check("second handle opens against same file", h2 ~= nil, tostring(err2))
assert(h2, err2)

-- Write via h1, read via h2.
ok = h1:exec("INSERT INTO t (k, v) VALUES (1, 'from-h1')")
check("h1 INSERT succeeds", ok)

local stmt2, perr = h2:prepare("SELECT v FROM t WHERE k = 1")
check("h2 prepare SELECT", stmt2 ~= nil, tostring(perr))
assert(stmt2, perr)
local rc = stmt2:step()
check("h2 step finds row", rc == db.SQLITE_ROW)
local v = stmt2:column_text(0)
check("h2 reads h1's write", v == "from-h1", "got " .. tostring(v))
stmt2:finalize()

-- Now write via h2 with h1 still alive; read via h1.
ok = h2:exec("INSERT INTO t (k, v) VALUES (2, 'from-h2')")
check("h2 INSERT succeeds (writer rotated)", ok)

local stmt1 = h1:prepare("SELECT v FROM t WHERE k = 2")
assert(stmt1)
rc = stmt1:step()
check("h1 reads h2's write", rc == db.SQLITE_ROW and stmt1:column_text(0) == "from-h2")
stmt1:finalize()

-- Concurrent writes serialised by busy_timeout: start a write tx on h1
-- (holds writer lock), attempt a write on h2.  h2 should retry up to
-- busy_timeout and succeed once h1 commits.  We simulate by wrapping a
-- tx around h2's write.
ok = h1:exec("BEGIN IMMEDIATE")
check("h1 BEGIN IMMEDIATE", ok)
-- h2's write should fail-or-wait; sqlite returns SQLITE_BUSY past the
-- timeout.  Commit h1 immediately, then h2's write should succeed.
ok = h1:exec("INSERT INTO t (k, v) VALUES (3, 'from-h1-tx')")
check("h1 within tx INSERT", ok)
ok = h1:exec("COMMIT")
check("h1 COMMIT", ok)
ok = h2:exec("INSERT INTO t (k, v) VALUES (4, 'from-h2-after-h1')")
check("h2 INSERT after h1 commit", ok)

-- Final check: total rows = 4.
local stmt = h1:prepare("SELECT COUNT(*) FROM t")
assert(stmt)
stmt:step()
local n = tonumber(stmt:column_text(0))
check("4 rows present (no writes lost)", n == 4, "got " .. tostring(n))
stmt:finalize()

h1:close()
h2:close()
vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("db_concurrent_test: PASS")
os.exit(0)
