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

return M
