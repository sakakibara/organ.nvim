-- lua/organ/link_store.lua
-- Session-scoped link kill-ring for :Org store_link / :Org insert_link.
-- Mirrors Emacs's `org-stored-links`.
--
-- Each entry is one of:
--   { kind = "id",        id, title, file_path }
--   { kind = "file_line", file_path, line, title }
--
-- LIFO order (newest first); bounded at MAX_ENTRIES.

local M = {}

local MAX_ENTRIES = 50
local _store = {} -- list; index 1 = newest

-- Push an entry onto the front of the store. Drops the oldest if overflow.
function M.push(entry)
  table.insert(_store, 1, entry)
  if #_store > MAX_ENTRIES then
    _store[#_store] = nil
  end
end

-- Return a shallow copy of the store list (newest first).
function M.list()
  local out = {}
  for i, e in ipairs(_store) do
    out[i] = e
  end
  return out
end

-- Empty the store.
function M.clear()
  _store = {}
end

-- Return the number of stored entries.
function M.size()
  return #_store
end

return M
