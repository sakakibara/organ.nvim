-- lua/organ/runtime.lua
-- Singleton lazy accessor for the SQLite handle.
-- Each accessor opens-and-caches on first call. Subsequent calls are O(1).

local M = {}

local _db_handle = nil

-- Returns the SQLite handle, opening + applying schema on first call.
function M.db()
  if _db_handle then
    return _db_handle
  end
  local cfg = require("organ").config
  local db_mod = require("organ.db")
  local dir = vim.fn.fnamemodify(cfg.db_path, ":h")
  vim.fn.mkdir(dir, "p")
  local h, err, rc = db_mod.open(cfg.db_path, { pragmas = cfg.pragmas })
  if not h then
    local fatal = (
      rc == db_mod.SQLITE_CORRUPT
      or rc == db_mod.SQLITE_NOTADB
      or rc == db_mod.SQLITE_IOERR
      or (err and (err:match("not a database") or err:match("malformed") or err:match("disk I/O")))
    )
    if fatal and cfg.auto_recover then
      local bak = cfg.db_path .. ".corrupt." .. tostring(os.time())
      os.rename(cfg.db_path, bak)
      require("organ.notify").warn("organ: DB corruption detected; moved to " .. bak)
      h, err, rc = db_mod.open(cfg.db_path, { pragmas = cfg.pragmas })
    end
    if not h then
      error(
        ("organ: failed to open DB at %s: %s (rc=%s)"):format(
          cfg.db_path,
          tostring(err),
          tostring(rc)
        )
      )
    end
  end
  require("organ")._ensure_schema(h)
  h._organ_row_chunk = cfg.row_chunk
  _db_handle = h
  return h
end

-- Returns the handle only if it was already opened; never triggers lazy open.
function M.db_if_open()
  return _db_handle
end

-- For test cleanup / re-init scenarios.
function M.reset()
  if _db_handle and _db_handle.close then
    pcall(_db_handle.close, _db_handle)
  end
  _db_handle = nil
end

return M
