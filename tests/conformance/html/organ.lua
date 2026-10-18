-- Organ side of the html conformance gate: exports each .org case the way
-- `:Org export html` does and records the result for normalize.lua, which
-- maps Emacs's generated ids onto organ's.  A case that is not an .org
-- file is a fixture and renders as "fixture: <basename>", as on the
-- Emacs side.

local root = vim.fn.getcwd()
dofile(root .. "/tests/conformance/_clock.lua").pin()

local html = require("organ.export.html")

local M = {}

M.rendered = {}
package.loaded["conformance.html.organ"] = M

function M.render(path)
  local name = vim.fn.fnamemodify(path, ":t")
  local out
  if not name:match("%.org$") then
    out = "fixture: " .. name .. "\n"
  else
    out = html.export(vim.fn.readfile(path), { file_path = path })
  end
  M.rendered[name] = out
  return out
end

return M
