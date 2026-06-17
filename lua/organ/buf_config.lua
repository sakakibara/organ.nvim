-- Per-buffer config override layer.  Each org buffer can have its own
-- partial config table that takes precedence over organ.config.  Reads
-- go through M.effective(bufnr) which deep-merges global with buf
-- overrides; writes go through M.set(bufnr, path, value) for a single
-- dotted path or M.set_table(bufnr, partial) for a partial table.
--
-- Mutations fire a reapply hook so providers that care can re-attach
-- (or detach) immediately.  Buffer entries clear automatically when
-- the buffer is deleted.

local M = {}

local _overrides = {} -- bufnr -> partial config table
local _reapply_hooks = {} -- list of fn(bufnr)
local reapply

-- Resolve a dotted path against a (possibly nested) table.  Returns
-- the value or nil.
local function dig(tbl, path)
  if tbl == nil then
    return nil
  end
  for part in path:gmatch("[^.]+") do
    if type(tbl) ~= "table" then
      return nil
    end
    tbl = tbl[part]
  end
  return tbl
end

-- Set a dotted path on a (possibly nested) table, creating intermediate
-- tables as needed.  Mutates `tbl` in place.
local function plant(tbl, path, value)
  local parts = {}
  for p in path:gmatch("[^.]+") do
    parts[#parts + 1] = p
  end
  for i = 1, #parts - 1 do
    if type(tbl[parts[i]]) ~= "table" then
      tbl[parts[i]] = {}
    end
    tbl = tbl[parts[i]]
  end
  tbl[parts[#parts]] = value
end

-- Get the partial overrides table for bufnr (empty if none).
function M.get(bufnr)
  return _overrides[bufnr] or {}
end

-- The effective config for bufnr is the global config merged with the
-- buf-local overrides on top.  Returns the global table directly when
-- there are no overrides (cheap path; callers must not mutate it).
-- Otherwise returns a fresh deep-merged table -- vim.tbl_deep_extend
-- shares subtables that only exist in one input, so we deepcopy the
-- result to keep mutations of the returned table local to the caller.
function M.effective(bufnr)
  local global = require("organ").config or {}
  local buf = _overrides[bufnr]
  if not buf then
    return global
  end
  return vim.deepcopy(vim.tbl_deep_extend("force", global, buf))
end

-- Read a single dotted path from the effective config for `bufnr`.  If
-- `bufnr` is nil or 0, falls back to the current buffer.
function M.read(bufnr, path)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return dig(M.effective(bufnr), path)
end

-- Set a dotted path in the buf-local overrides.  Fires the reapply hook
-- so any feature that cares about live config changes can react.
function M.set(bufnr, path, value)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local o = _overrides[bufnr]
  if not o then
    o = {}
    _overrides[bufnr] = o
  end
  plant(o, path, value)
  reapply(bufnr)
end

-- Merge a partial table into the buf-local overrides.  Useful for
-- bulk-applying a profile of settings.
function M.set_table(bufnr, partial)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if type(partial) ~= "table" then
    return
  end
  local o = _overrides[bufnr] or {}
  _overrides[bufnr] = vim.tbl_deep_extend("force", o, partial)
  reapply(bufnr)
end

-- Toggle a boolean at `path`.  Reads from effective config, writes the
-- inverse to the buf overrides.  Returns the new value.
function M.toggle(bufnr, path)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local cur = M.read(bufnr, path)
  if type(cur) ~= "boolean" then
    -- Treat non-boolean truthy as true.
    cur = cur and true or false
  end
  M.set(bufnr, path, not cur)
  return not cur
end

-- Remove a buf override at `path` so the effective config falls back to
-- the global value.
function M.unset(bufnr, path)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local o = _overrides[bufnr]
  if not o then
    return
  end
  local parts = {}
  for p in path:gmatch("[^.]+") do
    parts[#parts + 1] = p
  end
  local cur = o
  for i = 1, #parts - 1 do
    if type(cur[parts[i]]) ~= "table" then
      return
    end
    cur = cur[parts[i]]
  end
  cur[parts[#parts]] = nil
  reapply(bufnr)
end

-- Wipe all buf overrides for `bufnr`.
function M.reset(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  _overrides[bufnr] = nil
  reapply(bufnr)
end

-- Register a function to be called whenever a buf's config changes.
-- Features (indent, modern, conceal, etc.) register here to react to
-- live toggles by attaching/detaching their decoration providers.
function M.on_reapply(fn)
  _reapply_hooks[#_reapply_hooks + 1] = fn
end

reapply = function(bufnr)
  for _, fn in ipairs(_reapply_hooks) do
    pcall(fn, bufnr)
  end
end

-- Iterate dotted paths across an arbitrary nested-table tree.  Used by
-- `:Org set/toggle/unset` completion.  Yields strings like `"indent.enabled"`
-- and `"agenda.span"`.  Leaves are anything that isn't a table; nested
-- arrays (lists with integer keys) are NOT recursed into -- they're
-- treated as scalar leaves so completion doesn't fork on `[1]`/`[2]`/...
local function is_array(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    n = n + 1
  end
  return n > 0
end

function M.paths(root, prefix)
  root = root or (require("organ").config or {})
  prefix = prefix or ""
  local out = {}
  if type(root) ~= "table" then
    return out
  end
  for k, v in pairs(root) do
    if type(k) == "string" then
      local p = prefix == "" and k or (prefix .. "." .. k)
      if type(v) == "table" and not is_array(v) then
        out[#out + 1] = p -- expose the group itself
        for _, sub in ipairs(M.paths(v, p)) do
          out[#out + 1] = sub
        end
      else
        out[#out + 1] = p
      end
    end
  end
  return out
end

-- Auto-cleanup when buffers are deleted.  Wire once at module load.
do
  require("organ.errors").autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("organ_buf_config", { clear = true }),
    callback = function(ev)
      _overrides[ev.buf] = nil
    end,
  })
end

-- Test-only access.
M._overrides = function()
  return _overrides
end
return M
