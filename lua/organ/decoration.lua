-- Shared decoration infrastructure for organ.nvim.
--
-- Owns the single nvim_set_decoration_provider registration (per-frame,
-- per-visible-line dispatch) AND the per-buffer nvim_buf_attach
-- lifecycle (incremental on_lines notifications).  Decoration modules
-- register as participants via decoration.register({...}); the shared
-- infrastructure fans dispatch out to them with pcall isolation.
--
-- See docs/superpowers/specs/2026-05-12-decoration-provider-migration-design.md.

local M = {}

-- providers: name -> { name, ns, enabled, on_lines, on_line, on_lines_only }
local providers = {}
local provider_order = {}  -- preserves registration order for stable dispatch

-- attached_buffers: bufnr -> true
local attached_buffers = {}

-- caches: bufnr -> name -> per-provider table (provider's choice of shape)
local caches = {}

-- warn_once: bufnr -> name -> true (suppresses repeat notices)
local warn_once = {}

-- Disabled-for-buffer (after raising): bufnr -> name -> true
local disabled = {}

-- Test-only reset of all module state.
function M._reset()
  providers = {}
  provider_order = {}
  attached_buffers = {}
  caches = {}
  warn_once = {}
  disabled = {}
end

-- Required fields on a provider registration record.
local REQUIRED = { "name", "ns", "enabled" }
-- Either on_lines + on_line (decoration provider) OR on_lines_only.
local function validate(p)
  for _, k in ipairs(REQUIRED) do
    if p[k] == nil then
      return false, "organ.decoration.register: missing field '" .. k .. "'"
    end
  end
  if p.on_lines_only then
    if p.on_lines or p.on_line then
      return false,
        "organ.decoration.register: on_lines_only is mutually exclusive with on_lines / on_line"
    end
  else
    if type(p.on_lines) ~= "function" or type(p.on_line) ~= "function" then
      return false,
        "organ.decoration.register: missing on_lines or on_line (or supply on_lines_only)"
    end
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
  -- Clear per-buffer caches + state for this provider.
  for bufnr, by_name in pairs(caches) do
    by_name[name] = nil
    if warn_once[bufnr] then warn_once[bufnr][name] = nil end
    if disabled[bufnr] then disabled[bufnr][name] = nil end
  end
end

-- Internal accessor for tests.
M._providers = function() return providers, provider_order end
M._caches = function() return caches end
M._attached = function() return attached_buffers end

-- Internal: dispatch an on_lines notification to all enabled providers.
local function dispatch_on_lines(bufnr, first, last_old, last_new)
  caches[bufnr] = caches[bufnr] or {}
  warn_once[bufnr] = warn_once[bufnr] or {}
  disabled[bufnr] = disabled[bufnr] or {}
  for _, name in ipairs(provider_order) do
    local p = providers[name]
    if p and not p.on_lines_only and not disabled[bufnr][name] then
      local ok_enabled, enabled = pcall(p.enabled, bufnr)
      if ok_enabled and enabled then
        local ok_call, err_call = pcall(p.on_lines, bufnr, first, last_old, last_new)
        if not ok_call then
          if not warn_once[bufnr][name] then
            warn_once[bufnr][name] = true
            disabled[bufnr][name] = true
            local notify_ok, notify = pcall(require, "organ.notify")
            if notify_ok and type(notify.warn) == "function" then
              notify.warn(
                "decoration provider '" .. name .. "' raised in on_lines: "
                  .. tostring(err_call) .. ".  Disabling for this buffer."
              )
            end
          end
        end
      elseif not ok_enabled then
        if not warn_once[bufnr][name] then
          warn_once[bufnr][name] = true
        end
      end
    end
    -- on_lines_only providers also receive on_lines notifications.
    if p and p.on_lines_only and not disabled[bufnr][name] then
      local ok_enabled, enabled = pcall(p.enabled, bufnr)
      if ok_enabled and enabled then
        local ok_call = pcall(p.on_lines_only, bufnr, first, last_old, last_new)
        if not ok_call then
          warn_once[bufnr][name] = true
          disabled[bufnr][name] = true
        end
      end
    end
  end
end

function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("organ.decoration: not a valid buffer: " .. tostring(bufnr))
  end
  if attached_buffers[bufnr] then
    return  -- idempotent
  end
  attached_buffers[bufnr] = true
  caches[bufnr] = {}
  warn_once[bufnr] = {}
  disabled[bufnr] = {}

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, b, _changedtick, first, last_old, last_new)
      if not attached_buffers[b] then
        return true  -- detach signal
      end
      dispatch_on_lines(b, first, last_old, last_new)
    end,
    on_detach = function(_, b)
      attached_buffers[b] = nil
      caches[b] = nil
      warn_once[b] = nil
      disabled[b] = nil
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
  caches[bufnr] = nil
  warn_once[bufnr] = nil
  disabled[bufnr] = nil
end

return M
