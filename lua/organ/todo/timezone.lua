-- System timezone -> ISO country detection for organ.nvim.

local M = {}

-- Indirection for testability.
M._readlink = function(path)
  return vim.uv.fs_readlink(path)
end

function M.detect_country()
  local target = M._readlink("/etc/localtime")
  if not target then
    return nil
  end
  local zone = target:match("zoneinfo/(.+)$")
  if not zone then
    return nil
  end
  local table_ok, t = pcall(require, "organ.todo.timezone_table")
  if not table_ok then
    return nil
  end
  return t[zone]
end

return M
