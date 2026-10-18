-- organ side of the export conformance gate.  A case's first line
-- "# conformance: BACKEND body|full" picks the exporter:
--
--   ascii, md, texinfo, icalendar, opml   organ.export.<module>.export
--   icalendar-combine                     index the case, then ics.export_query
--   org                                   to_org(from_org(lines))

local root = vim.fn.getcwd()
dofile(root .. "/tests/conformance/_clock.lua").pin()

local MODULES = {
  ascii = "organ.export.ascii",
  md = "organ.export.markdown",
  texinfo = "organ.export.texinfo",
  icalendar = "organ.export.ics",
  opml = "organ.export.opml",
}

local function mode(lines)
  local backend, extent = (lines[1] or ""):match("^# conformance: ([%l-]+) (%l+)$")
  if not backend or (extent ~= "body" and extent ~= "full") then
    error("no conformance header")
  end
  return backend, extent == "body"
end

local M = {}

function M.render(path, _)
  local lines = vim.fn.readfile(path)
  local backend, body_only = mode(lines)
  if backend == "org" then
    return require("organ.ast.to_org").render(require("organ.ast.from_org").from_lines(lines), {})
  elseif backend == "icalendar-combine" then
    require("organ.indexer").index_file_sync(path)
    return require("organ.export.ics").export_query({}, nil)
  end
  return require(MODULES[backend]).export(lines, {
    body_only = body_only,
    file_path = path,
  })
end

return M
