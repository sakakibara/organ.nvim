-- Active-clock state persistence to <stdpath data>/organ/clock.json.

local M = {}

local function path()
  return vim.fn.stdpath("data") .. "/organ/clock.json"
end

local function ensure_parent()
  vim.fn.mkdir(vim.fn.fnamemodify(path(), ":h"), "p")
end

function M.load()
  local p = path()
  if not vim.loop.fs_stat(p) then
    return nil
  end
  local f = io.open(p, "r")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" or raw == "null" then
    return nil
  end
  local ok, data = pcall(vim.fn.json_decode, raw)
  if not ok or type(data) ~= "table" then
    return nil
  end
  return data
end

function M.save(state)
  ensure_parent()
  local p = path()
  local tmp = p .. ".tmp." .. tostring(vim.loop.os_getpid())
  local f, err = io.open(tmp, "w")
  if not f then
    error("clock.state: open " .. tmp .. ": " .. tostring(err))
  end
  f:write(vim.fn.json_encode(state))
  f:close()
  os.rename(tmp, p)
end

function M.clear()
  pcall(os.remove, path())
end

return M
