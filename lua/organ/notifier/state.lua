-- State file for organ's OS-level scheduled notifications.
--
-- Maps reminder ids to the platform-specific job handle we used to schedule
-- them, so a later set_pending() call can cancel the previous batch before
-- writing the new one. Survives Neovim restarts; that's the whole point.

local M = {}

local SCHEMA_VERSION = 1

local function dir()
  return vim.fn.stdpath("data") .. "/organ"
end

function M.path()
  return dir() .. "/notifier-state.json"
end

local function empty()
  return { version = SCHEMA_VERSION, platform = nil, entries = {} }
end

function M.load()
  local path = M.path()
  local fd = io.open(path, "r")
  if not fd then
    return empty()
  end
  local raw = fd:read("*a")
  fd:close()
  if not raw or raw == "" then
    return empty()
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return empty()
  end
  decoded.version = decoded.version or SCHEMA_VERSION
  decoded.entries = decoded.entries or {}
  return decoded
end

function M.save(state)
  vim.fn.mkdir(dir(), "p")
  local path = M.path()
  local tmp = path .. ".tmp"
  local fd, err = io.open(tmp, "w")
  if not fd then
    return false, err
  end
  fd:write(vim.json.encode(state))
  fd:close()
  local ok = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, "rename failed"
  end
  return true
end

function M.set_entries(entries, platform)
  local state = empty()
  state.platform = platform
  state.entries = entries or {}
  return M.save(state)
end

return M
