-- Shared decoration infrastructure for organ.nvim.
--
-- Owns the single nvim_set_decoration_provider registration: dispatches
-- on_win and on_line callbacks to every registered provider per redraw
-- frame, with pcall isolation.  Also owns the per-buffer
-- nvim_buf_attach lifecycle to notify on_lines_only providers (fold
-- state, fold/contents) of buffer edits -- on_win-based providers query
-- the tree per frame instead and don't need edit-time notifications.
--
-- Providers register via decoration.register({...}).  See the validate()
-- function for the accepted record shapes.

local M = {}

-- providers: name -> { name, ns, enabled, on_win, on_line, on_lines_only }
local providers = {}
local provider_order = {} -- preserves registration order for stable dispatch

-- attached_buffers: bufnr -> true
local attached_buffers = {}

-- warn_once: bufnr -> name -> true (suppresses repeat notices)
local warn_once = {}

-- Disabled-for-buffer (after raising): bufnr -> name -> true
local disabled = {}

-- Per-buffer cached parse: { tick = changedtick, ok = bool, tree = tree_or_nil }.
-- Refreshed at the start of each redraw cycle via on_buf, and lazily by
-- providers driven outside the redraw cycle (e.g. test-facing _apply()).
-- Providers consume this via M.get_tree() instead of calling parser:parse
-- themselves so we (a) parse at most once per buffer per redraw, and
-- (b) never use the range form of parser:parse, which interacts badly
-- with org_inline injection bookkeeping and produces "Index out of bounds"
-- crashes inside vim/treesitter.lua's buf_range_get_text.
local _tree_cache = {}

local function refresh_tree(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return { tick = -1, ok = false, tree = nil }
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _tree_cache[bufnr]
  if cached and cached.tick == tick then
    return cached
  end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok_parser or not parser then
    _tree_cache[bufnr] = { tick = tick, ok = false, tree = nil }
    return _tree_cache[bufnr]
  end
  -- Pass `true` to parse the entire injection forest in one shot.
  -- Plain parser:parse() (no args) parses ONLY the root tree on nvim
  -- 0.12.x: parser:children() is empty afterwards, and for_each_tree
  -- yields just the root.  Injection trees are not lazily materialized
  -- on access (verified empirically against the org grammar), so
  -- conceal and modern.pills, which walk org_inline trees for emphasis
  -- and timestamp nodes, would see no nodes under plain parse().  The
  -- range form parser:parse({...}) DOES populate injection children,
  -- but left org_inline bookkeeping in a stale state that downstream
  -- queries tripped over with "Index out of bounds" in
  -- buf_range_get_text.  parser:parse(true) is the correct call.
  local ok_parse = pcall(function()
    parser:parse(true)
  end)
  local tree
  if ok_parse then
    tree = (parser:trees() or {})[1]
  end
  _tree_cache[bufnr] = { tick = tick, ok = ok_parse and tree ~= nil, tree = tree }
  return _tree_cache[bufnr]
end

function M.get_tree(bufnr)
  return refresh_tree(bufnr).tree
end

-- Test-only reset of all module state.
function M._reset()
  providers = {}
  provider_order = {}
  attached_buffers = {}
  warn_once = {}
  disabled = {}
  _tree_cache = {}
end

local REQUIRED = { "name", "ns", "enabled" }
local function validate(p)
  for _, k in ipairs(REQUIRED) do
    if p[k] == nil then
      return false, "organ.decoration.register: missing field '" .. k .. "'"
    end
  end
  if p.on_lines_only then
    if p.on_lines or p.on_line or p.on_win then
      return false,
        "organ.decoration.register: on_lines_only is mutually exclusive with on_lines / on_line / on_win"
    end
    return true
  end
  if p.on_lines then
    return false, "organ.decoration.register: on_lines is no longer supported; use on_win"
  end
  if type(p.on_win) ~= "function" or type(p.on_line) ~= "function" then
    return false,
      "organ.decoration.register: provider must supply on_win + on_line (or on_lines_only)"
  end
  return true
end

function M.register(provider)
  local ok, err = validate(provider)
  if not ok then
    error(err)
  end
  if providers[provider.name] then
    error("organ.decoration: provider '" .. provider.name .. "' already registered")
  end
  providers[provider.name] = provider
  provider_order[#provider_order + 1] = provider.name
end

function M.unregister(name)
  if not providers[name] then
    return
  end
  providers[name] = nil
  for i, n in ipairs(provider_order) do
    if n == name then
      table.remove(provider_order, i)
      break
    end
  end
  -- Clear per-buffer state for this provider.
  for bufnr, _ in pairs(warn_once) do
    warn_once[bufnr][name] = nil
  end
  for bufnr, _ in pairs(disabled) do
    disabled[bufnr][name] = nil
  end
end

-- Internal accessor for tests.
M._providers = function()
  return providers, provider_order
end
M._attached = function()
  return attached_buffers
end

-- Internal: dispatch an on_lines notification to on_lines_only providers.
-- (Regular on_win/on_line providers don't receive edit notifications --
-- they query the visible range every frame.)
local function dispatch_on_lines(bufnr, first, last_old, last_new)
  warn_once[bufnr] = warn_once[bufnr] or {}
  disabled[bufnr] = disabled[bufnr] or {}
  for _, name in ipairs(provider_order) do
    local p = providers[name]
    if p and p.on_lines_only and not disabled[bufnr][name] then
      local ok_enabled, enabled = pcall(p.enabled, bufnr)
      if ok_enabled and enabled then
        local ok_call, err_call = pcall(p.on_lines_only, bufnr, first, last_old, last_new)
        if not ok_call then
          if not warn_once[bufnr][name] then
            warn_once[bufnr][name] = true
            disabled[bufnr][name] = true
            local notify_ok, notify = pcall(require, "organ.notify")
            if notify_ok and type(notify.warn) == "function" then
              notify.warn(
                "decoration provider '"
                  .. name
                  .. "' raised in on_lines_only: "
                  .. tostring(err_call)
                  .. ".  Disabling for this buffer."
              )
            end
          end
        end
      end
    end
  end
end

-- Internal: dispatch an on_win callback to all enabled providers.
local function dispatch_on_win(_tick, winid, bufnr, topline, botline)
  if not attached_buffers[bufnr] then
    return
  end
  warn_once[bufnr] = warn_once[bufnr] or {}
  disabled[bufnr] = disabled[bufnr] or {}
  for _, name in ipairs(provider_order) do
    local p = providers[name]
    if p and p.on_win and not disabled[bufnr][name] then
      local ok_enabled, enabled_v = pcall(p.enabled, bufnr)
      if ok_enabled and enabled_v then
        local ok_call, err_call = pcall(p.on_win, bufnr, winid, topline, botline)
        if not ok_call then
          if not warn_once[bufnr][name] then
            warn_once[bufnr][name] = true
            disabled[bufnr][name] = true
            local notify_ok, notify = pcall(require, "organ.notify")
            if notify_ok and type(notify.warn) == "function" then
              notify.warn(
                "decoration provider '"
                  .. name
                  .. "' raised in on_win: "
                  .. tostring(err_call)
                  .. ".  Disabling for this buffer."
              )
            end
          end
        end
      end
    end
  end
end

M._dispatch_on_win = dispatch_on_win

function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("organ.decoration: not a valid buffer: " .. tostring(bufnr))
  end
  if attached_buffers[bufnr] then
    return -- idempotent
  end
  attached_buffers[bufnr] = true
  warn_once[bufnr] = {}
  disabled[bufnr] = {}

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, b, _changedtick, first, last_old, last_new)
      if not attached_buffers[b] then
        return true -- detach signal
      end
      dispatch_on_lines(b, first, last_old, last_new)
    end,
    on_detach = function(_, b)
      attached_buffers[b] = nil
      warn_once[b] = nil
      disabled[b] = nil
      _tree_cache[b] = nil
    end,
  })

  -- Synthesize the initial population call.
  local n = vim.api.nvim_buf_line_count(bufnr)
  dispatch_on_lines(bufnr, 0, n, n)
end

function M.detach(bufnr)
  if not attached_buffers[bufnr] then
    return
  end
  attached_buffers[bufnr] = nil
  warn_once[bufnr] = nil
  disabled[bufnr] = nil
  _tree_cache[bufnr] = nil
end

-- Internal: dispatch an on_line callback to all enabled providers.
-- Each provider's namespace is cleared for this single row before its
-- on_line runs, so stale extmarks don't accumulate when the provider
-- decides not to place anything on this row.
local function dispatch_on_line(_tick, winid, bufnr, row)
  if not attached_buffers[bufnr] then
    return
  end
  for _, name in ipairs(provider_order) do
    local p = providers[name]
    if p and p.on_line and not (disabled[bufnr] and disabled[bufnr][name]) then
      local ok_enabled, enabled = pcall(p.enabled, bufnr)
      if ok_enabled and enabled then
        pcall(vim.api.nvim_buf_clear_namespace, bufnr, p.ns, row, row + 1)
        local ok_call, err_call = pcall(p.on_line, bufnr, winid, row)
        if not ok_call then
          warn_once[bufnr] = warn_once[bufnr] or {}
          disabled[bufnr] = disabled[bufnr] or {}
          if not warn_once[bufnr][name] then
            warn_once[bufnr][name] = true
            disabled[bufnr][name] = true
            local notify_ok, notify = pcall(require, "organ.notify")
            if notify_ok and type(notify.warn) == "function" then
              notify.warn(
                "decoration provider '"
                  .. name
                  .. "' raised in on_line: "
                  .. tostring(err_call)
                  .. ".  Disabling for this buffer."
              )
            end
          end
        end
      end
    end
  end
end

M._dispatch_on_line = dispatch_on_line

-- Force a full repopulation for `bufnr`.  Clears all namespaces, resets
-- per-provider state, and re-notifies on_lines_only providers covering
-- the whole buffer.  Use after config toggles, :e reload, etc.
function M.refresh(bufnr)
  if not attached_buffers[bufnr] then
    return
  end
  warn_once[bufnr] = {}
  disabled[bufnr] = {}
  for _, name in ipairs(provider_order) do
    local p = providers[name]
    if p and p.ns then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, p.ns, 0, -1)
    end
  end
  -- on_lines_only providers still need a re-notify covering the whole buffer.
  local n = vim.api.nvim_buf_line_count(bufnr)
  dispatch_on_lines(bufnr, 0, n, n)
end

do
  local provider_ns = vim.api.nvim_create_namespace("organ_decoration_provider")
  vim.api.nvim_set_decoration_provider(provider_ns, {
    on_buf = function(_, bufnr, _tick)
      -- Warm the parse cache once per redraw cycle, before on_win runs
      -- for any window backed by this buffer.  All providers then read
      -- from the cached tree via M.get_tree().
      refresh_tree(bufnr)
    end,
    on_win = function(_, winid, bufnr, topline, botline)
      dispatch_on_win(0, winid, bufnr, topline, botline)
      return true
    end,
    on_line = function(_, winid, bufnr, row)
      dispatch_on_line(0, winid, bufnr, row)
    end,
  })
end

return M
