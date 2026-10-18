-- organ side of the latex conformance gate: exports a case with
-- organ.export.latex (default run) or organ.export.beamer (option
-- "beamer").  A case's first line "# conformance: BACKEND body|full"
-- picks its backend and body-only or whole-document export (default:
-- latex body); a case of the other backend renders as "".

local root = vim.fn.getcwd()
dofile(root .. "/tests/conformance/_clock.lua").pin()

local function mode(lines)
  local backend, extent = (lines[1] or ""):match("^# conformance: (%l+) (%l+)$")
  if backend and (extent == "body" or extent == "full") then
    return backend, extent == "body"
  end
  return "latex", true
end

local M = {}

function M.render(path, option)
  local lines = vim.fn.readfile(path)
  local backend, body_only = mode(lines)
  if backend ~= (option or "latex") then
    return ""
  end
  return require("organ.export." .. backend).export(lines, {
    body_only = body_only,
    file_path = path,
  })
end

return M
