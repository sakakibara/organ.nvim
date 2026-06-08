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

local profile = require("organ.profile")

-- providers: name -> { name, ns, enabled, on_win, on_line, on_lines_only }
local providers = {}
local provider_order = {} -- preserves registration order for stable dispatch

-- attached_buffers: bufnr -> true
local attached_buffers = {}

-- warn_once: bufnr -> name -> true (suppresses repeat notices)
local warn_once = {}

-- Disabled-for-buffer (after raising): bufnr -> name -> true
local disabled = {}

-- Per-buffer cached parse: { tick, top, bot, ok, tree }.  Warmed for the
-- visible range at the start of each window's dispatch (dispatch_on_win),
-- keyed by changedtick + range so a scroll or edit reparses.  Providers
-- read it via M.get_tree() rather than calling parser:parse themselves.
local _tree_cache = {}

-- Parse and cache the org tree for `bufnr`.  When `top`/`bot` are given,
-- parse only that row range so injection (org_inline) cost is bounded by
-- the viewport; without a range, parse the whole injection forest.
--
-- The range form matters on the redraw path: plain parser:parse() (no
-- args) leaves parser:children() empty, so conceal / modern.pills, which
-- walk org_inline trees for emphasis and timestamp nodes, see nothing.
-- parser:parse(true) populates the whole forest but parses every
-- injection tree in the buffer (hundreds on a long file) -- a
-- multi-hundred-ms synchronous parse on each cold / first-post-edit
-- redraw.  parser:parse({top, bot+1}) populates org_inline children for
-- the visible rows only, with identical viewport coverage at sub-ms cost.
local function refresh_tree(bufnr, top, bot)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return { tick = -1, ok = false, tree = nil }
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _tree_cache[bufnr]
  if cached and cached.tick == tick and cached.top == top and cached.bot == bot then
    return cached
  end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok_parser or not parser then
    _tree_cache[bufnr] = { tick = tick, top = top, bot = bot, ok = false, tree = nil }
    return _tree_cache[bufnr]
  end
  local pt0
  if profile.frame_enabled then
    pt0 = vim.uv.hrtime()
  end
  local ok_parse
  if top and bot then
    ok_parse = pcall(function()
      parser:parse({ top, bot + 1 })
    end)
  else
    ok_parse = pcall(function()
      parser:parse(true)
    end)
  end
  if pt0 then
    profile.record_frame("frame.parse", (vim.uv.hrtime() - pt0) / 1e6, "buf=" .. bufnr)
  end
  local tree
  if ok_parse then
    tree = (parser:trees() or {})[1]
  end
  _tree_cache[bufnr] =
    { tick = tick, top = top, bot = bot, ok = ok_parse and tree ~= nil, tree = tree }
  return _tree_cache[bufnr]
end

-- Providers call this during on_win, after dispatch warmed the tree for
-- the visible range.  Return that cached tree as long as it matches the
-- current changedtick; only parse (full forest) when genuinely cold --
-- e.g. the test-facing _apply paths that drive on_win outside a redraw.
function M.get_tree(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local cached = _tree_cache[bufnr]
  if cached and cached.tick == vim.api.nvim_buf_get_changedtick(bufnr) then
    return cached.tree
  end
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

-- Debug accessor: inspect which providers have been auto-disabled per
-- buffer.  A provider lands here when its on_win / on_line raised and
-- the dispatcher caught it; it stays disabled until the user runs
-- `M._reenable(bufnr, name)` or reloads.
function M._disabled()
  return disabled
end

-- Clear the disabled flag for a single provider on a buffer (or all
-- providers if `name` is nil).  Useful after fixing the underlying bug
-- without restarting nvim.
function M._reenable(bufnr, name)
  if not disabled[bufnr] then
    return
  end
  if name then
    disabled[bufnr][name] = nil
  else
    disabled[bufnr] = {}
  end
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
          -- One-shot notification, but keep trying on subsequent
          -- redraws.  Transient parse / injection errors recover; a
          -- permanent disable would lock the provider off until reload.
          if not warn_once[bufnr][name] then
            warn_once[bufnr][name] = true
            local notify_ok, notify = pcall(require, "organ.notify")
            if notify_ok and type(notify.warn) == "function" then
              notify.warn(
                "decoration provider '"
                  .. name
                  .. "' raised in on_lines_only: "
                  .. tostring(err_call)
                  .. " (will keep retrying)."
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
  refresh_tree(bufnr, topline, botline)
  warn_once[bufnr] = warn_once[bufnr] or {}
  disabled[bufnr] = disabled[bufnr] or {}
  for _, name in ipairs(provider_order) do
    local p = providers[name]
    if p and p.on_win and not disabled[bufnr][name] then
      local ok_enabled, enabled_v = pcall(p.enabled, bufnr)
      if ok_enabled and enabled_v then
        local wt0
        if profile.frame_enabled then
          wt0 = vim.uv.hrtime()
        end
        local ok_call, err_call = pcall(p.on_win, bufnr, winid, topline, botline)
        if wt0 then
          profile.record_frame("frame.on_win:" .. name, (vim.uv.hrtime() - wt0) / 1e6)
        end
        if not ok_call then
          if not warn_once[bufnr][name] then
            warn_once[bufnr][name] = true
            local notify_ok, notify = pcall(require, "organ.notify")
            if notify_ok and type(notify.warn) == "function" then
              notify.warn(
                "decoration provider '"
                  .. name
                  .. "' raised in on_win: "
                  .. tostring(err_call)
                  .. " (will keep retrying)."
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
        local lt0
        if profile.frame_enabled then
          lt0 = vim.uv.hrtime()
        end
        local ok_call, err_call = pcall(p.on_line, bufnr, winid, row)
        if lt0 then
          profile.record_frame("frame.on_line:" .. name, (vim.uv.hrtime() - lt0) / 1e6)
        end
        if not ok_call then
          warn_once[bufnr] = warn_once[bufnr] or {}
          if not warn_once[bufnr][name] then
            warn_once[bufnr][name] = true
            local notify_ok, notify = pcall(require, "organ.notify")
            if notify_ok and type(notify.warn) == "function" then
              notify.warn(
                "decoration provider '"
                  .. name
                  .. "' raised in on_line: "
                  .. tostring(err_call)
                  .. " (will keep retrying)."
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
