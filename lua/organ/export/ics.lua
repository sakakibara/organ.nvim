-- ICS (RFC 5545) exporter for org buffers.
--
-- Pipeline: from_org (org -> AST) -> to_ics (AST -> VCALENDAR).
-- Emits one VEVENT per SCHEDULED / DEADLINE timestamp on a headline.
--
-- Scope: M.export / M.export_buffer / M.export_buffer_to_file act on a
-- single source.  M.export_query walks the indexed corpus and renders
-- every SCHEDULED/DEADLINE in one VCALENDAR document.

local M = {}

-- Re-export helpers that external callers (and the test suite) reach
-- through the facade.
local to_ics = require("organ.ast.to_ics")
M._parse_org_ts = to_ics._parse_org_ts
M._fold_line = to_ics._fold_line
M._escape_text = to_ics._escape_text

function M.export(src, opts)
  opts = opts or {}
  local lines
  if type(src) == "string" then
    lines = vim.split(src, "\n", { plain = true })
  else
    lines = src
  end
  local ast = require("organ.ast.from_org").from_lines(lines)
  local ok, err = require("organ.ast").validate(ast)
  if not ok then
    error("export.ics: AST validation failed: " .. err)
  end
  ast = require("organ.ast.radio").resolve(ast)
  return to_ics.render(ast, opts)
end

function M.export_buffer(bufnr, opts)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.export(lines, opts)
end

function M.export_buffer_to_file(bufnr, path, opts)
  bufnr = bufnr or 0
  if not path or path == "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return nil, "no buffer name; specify a path"
    end
    path = name:gsub("%.org$", "") .. ".ics"
  end
  local out = M.export_buffer(bufnr, opts)
  local ok, werr = require("organ.path").write_atomic(path, out)
  if not ok then
    return nil, "could not write " .. path .. ": " .. tostring(werr)
  end
  return path
end

-- Build a synthetic AST from indexer rows so export_query can share the
-- to_ics renderer.  One headline per row, carrying the row's title +
-- planning + ID property; to_ics emits a VEVENT per SCHEDULED/DEADLINE.
local function rows_to_ast(rows)
  local A = require("organ.ast")
  local headlines = {}
  for _, r in ipairs(rows) do
    local planning = {}
    if r.scheduled or r.scheduled_date then
      planning.scheduled = r.scheduled or ("<" .. r.scheduled_date .. ">")
    end
    if r.deadline or r.deadline_date then
      planning.deadline = r.deadline or ("<" .. r.deadline_date .. ">")
    end
    if next(planning) == nil then
      planning = nil
    end
    local properties
    if r.id then
      properties = { ID = r.id }
    end
    headlines[#headlines + 1] = A.headline({
      level = 1,
      title = { A.text(r.title or "") },
      planning = planning,
      properties = properties,
    })
  end
  return A.document(headlines)
end

-- Export every SCHEDULED/DEADLINE in the indexed corpus to a single .ics.
-- Uses the DB; doesn't touch buffers.
function M.export_query(filter, path)
  local rows = require("organ.query").agenda(
    vim.tbl_extend("force", { types = { "scheduled", "deadline" } }, filter or {})
  )
  local ast = rows_to_ast(rows)
  local body = to_ics.render(ast, {})
  if path then
    local ok, werr = require("organ.path").write_atomic(path, body)
    if not ok then
      return nil, werr
    end
    return path
  end
  return body
end

return M
