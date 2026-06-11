-- Hand-rolled LuaJIT FFI wrapper around libsqlite3.
--
-- Surface is the minimum organ.nvim needs: open/close, exec for PRAGMAs and
-- schema text, prepare/bind/step/reset/finalize for row-level work, and a
-- small transaction helper. Lives in-process so each index op is one function
-- call rather than a `sqlite3` subprocess.

local ffi = require("ffi")
local bit = require("bit")

local M = {}

ffi.cdef([[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close_v2(sqlite3*);
int sqlite3_exec(sqlite3*, const char *sql, int (*cb)(void*,int,char**,char**), void*, char **errmsg);

int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt*);
int sqlite3_reset(sqlite3_stmt *pStmt);
int sqlite3_finalize(sqlite3_stmt *pStmt);

int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, void(*)(void*));
int sqlite3_bind_int(sqlite3_stmt*, int, int);
int sqlite3_bind_int64(sqlite3_stmt*, int, int64_t);
int sqlite3_bind_null(sqlite3_stmt*, int);

int sqlite3_column_count(sqlite3_stmt *pStmt);
const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);
int sqlite3_column_int(sqlite3_stmt*, int iCol);
int64_t sqlite3_column_int64(sqlite3_stmt*, int iCol);
int sqlite3_column_type(sqlite3_stmt*, int iCol);

const char *sqlite3_errmsg(sqlite3*);
int sqlite3_extended_errcode(sqlite3 *db);
void sqlite3_free(void*);
]])

-- Load libsqlite3 with platform-aware fallbacks.
local function load_lib()
  local names = { "sqlite3", "libsqlite3" }
  if jit.os == "Linux" then
    table.insert(names, "libsqlite3.so.0")
  end
  if jit.os == "Windows" then
    table.insert(names, "sqlite3.dll")
  end
  local errs = {}
  for _, n in ipairs(names) do
    local ok, lib = pcall(ffi.load, n)
    if ok then
      return lib
    end
    errs[#errs + 1] = n .. ": " .. tostring(lib)
  end
  error(
    "organ: could not load libsqlite3. Tried: "
      .. table.concat(names, ", ")
      .. "\n"
      .. "Install it:\n"
      .. "  macOS:   brew install sqlite\n"
      .. "  Debian:  sudo apt install libsqlite3-0\n"
      .. "  Windows: scoop install sqlite   (or place sqlite3.dll on PATH)\n"
      .. "Details: "
      .. table.concat(errs, " | ")
  )
end

local C = load_lib()

-- Result codes we care about.
M.SQLITE_OK = 0
M.SQLITE_BUSY = 5
M.SQLITE_IOERR = 10
M.SQLITE_CORRUPT = 11
M.SQLITE_NOTADB = 26
M.SQLITE_CONSTRAINT = 19
M.SQLITE_MISUSE = 21
M.SQLITE_ROW = 100
M.SQLITE_DONE = 101
-- column_type return codes
M.SQLITE_INTEGER = 1
M.SQLITE_FLOAT = 2
M.SQLITE_TEXT = 3
M.SQLITE_BLOB = 4
M.SQLITE_NULL = 5

-- Open flags.
local SQLITE_OPEN_READWRITE = 0x00000002
local SQLITE_OPEN_CREATE = 0x00000004

-- SQLITE_TRANSIENT tells SQLite to copy the bound string before returning.
-- It is the magic constant ((sqlite3_destructor_type)-1).
local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1)

-- Statement wrapper.

local Stmt = {}
Stmt.__index = Stmt

function Stmt:bind_text(idx, s)
  -- SQLITE_TRANSIENT: SQLite copies the buffer before returning. Do NOT switch
  -- to SQLITE_STATIC — Lua strings are not GC-pinned across later FFI calls.
  if s == nil then
    return C.sqlite3_bind_null(self._ptr, idx)
  end
  return C.sqlite3_bind_text(self._ptr, idx, s, #s, SQLITE_TRANSIENT)
end

function Stmt:bind_int(idx, n)
  if n == nil then
    return C.sqlite3_bind_null(self._ptr, idx)
  end
  return C.sqlite3_bind_int(self._ptr, idx, n)
end

function Stmt:bind_int64(idx, n)
  if n == nil then
    return C.sqlite3_bind_null(self._ptr, idx)
  end
  return C.sqlite3_bind_int64(self._ptr, idx, n)
end

function Stmt:bind_null(idx)
  return C.sqlite3_bind_null(self._ptr, idx)
end

function Stmt:step()
  return C.sqlite3_step(self._ptr)
end

function Stmt:reset()
  return C.sqlite3_reset(self._ptr)
end

function Stmt:finalize()
  if self._ptr ~= nil then
    C.sqlite3_finalize(self._ptr)
    self._ptr = nil
  end
end

function Stmt:column_text(i)
  local p = C.sqlite3_column_text(self._ptr, i)
  if p == nil then
    return nil
  end
  return ffi.string(p)
end

function Stmt:column_int(i)
  return tonumber(C.sqlite3_column_int(self._ptr, i))
end

function Stmt:column_int64(i)
  return tonumber(C.sqlite3_column_int64(self._ptr, i))
end

function Stmt:column_type(i)
  return tonumber(C.sqlite3_column_type(self._ptr, i))
end

-- Handle wrapper.

local Handle = {}
Handle.__index = Handle

function Handle:exec(sql)
  if self._ptr == nil then
    return nil, "handle closed", 21
  end
  local errmsg = ffi.new("char*[1]")
  local rc = C.sqlite3_exec(self._ptr, sql, nil, nil, errmsg)
  if rc ~= M.SQLITE_OK then
    local e = errmsg[0] ~= nil and ffi.string(errmsg[0]) or ffi.string(C.sqlite3_errmsg(self._ptr))
    if errmsg[0] ~= nil then
      C.sqlite3_free(errmsg[0])
    end
    return nil, e, rc
  end
  return true, nil, rc
end

function Handle:prepare(sql)
  if self._ptr == nil then
    return nil, "handle closed", 21
  end
  local ptr = ffi.new("sqlite3_stmt*[1]")
  local rc = C.sqlite3_prepare_v2(self._ptr, sql, #sql, ptr, nil)
  if rc ~= M.SQLITE_OK then
    return nil, ffi.string(C.sqlite3_errmsg(self._ptr)), rc
  end
  return setmetatable({ _ptr = ptr[0] }, Stmt), nil, rc
end

-- Run `fn(handle)` inside a BEGIN/COMMIT pair. On any Lua error raised inside
-- `fn`, issues ROLLBACK and returns the error string. On success, returns nil
-- (or the COMMIT error string if COMMIT fails). Not reentrant — SQLite does
-- not allow nested BEGIN; wrap SAVEPOINT manually for nested scopes.
function Handle:transaction(fn)
  local ok, err = self:exec("BEGIN")
  if not ok then
    return err
  end
  local success, ret = pcall(fn, self)
  if not success then
    local _, rberr = self:exec("ROLLBACK")
    if rberr then
      return tostring(ret) .. " (rollback failed: " .. rberr .. ")"
    end
    return tostring(ret)
  end
  local ok2, err2 = self:exec("COMMIT")
  return ok2 and nil or err2
end

function Handle:close()
  if self._ptr == nil then
    return
  end
  C.sqlite3_close_v2(self._ptr)
  self._ptr = nil
end

-- Entrypoint.

function M.open(path, opts)
  opts = opts or {}
  local ptr = ffi.new("sqlite3*[1]")
  local rc = C.sqlite3_open_v2(path, ptr, bit.bor(SQLITE_OPEN_READWRITE, SQLITE_OPEN_CREATE), nil)
  if rc ~= M.SQLITE_OK then
    local err = ptr[0] ~= nil and ffi.string(C.sqlite3_errmsg(ptr[0])) or ("rc=" .. rc)
    if ptr[0] ~= nil then
      C.sqlite3_close_v2(ptr[0])
    end
    return nil, err, rc
  end
  local h = setmetatable({ _ptr = ptr[0] }, Handle)

  -- Apply connection PRAGMAs in alphabetically sorted key order for deterministic
  -- behaviour and reproducible errors. Our supported PRAGMAs are order-independent;
  -- adding one with ordering constraints (e.g. locking_mode before journal_mode)
  -- would require switching to an array-of-pairs API.
  if opts.pragmas then
    local keys = {}
    for k in pairs(opts.pragmas) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = opts.pragmas[k]
      local ok, eerr, erc = h:exec(string.format("PRAGMA %s = %s", k, tostring(v)))
      if not ok then
        h:close()
        return nil, string.format("PRAGMA %s = %s failed: %s", k, tostring(v), eerr), erc
      end
    end
  end

  -- Probe the DB: a trivial read surfaces SQLITE_CORRUPT / NOTADB early.
  local probe, perr, prc = h:exec("PRAGMA schema_version")
  if not probe then
    h:close()
    return nil, perr, prc
  end

  return h, nil, rc
end

return M
