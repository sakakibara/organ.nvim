-- OPML 2.0 outline-only export for org buffers.
--
-- Pipeline: optional #+SETUPFILE / #+INCLUDE expansion -> from_org
-- (org -> AST) -> to_opml (AST -> OPML XML).
--
-- Body content other than headlines + their first-paragraph note is
-- dropped (OPML is an outline interchange format).

local M = {}

function M.export(src, opts)
  opts = opts or {}
  local lines
  if type(src) == "string" then
    lines = vim.split(src, "\n", { plain = true })
  else
    lines = src
  end
  local text = table.concat(lines, "\n")

  if opts.expand then
    text = require("organ.expand").process(text, {
      base_dir = opts.base_dir,
      file_path = opts.file_path,
      properties = opts.properties,
    })
    lines = vim.split(text, "\n", { plain = true })
  end

  local ast = require("organ.ast.from_org").from_lines(lines)
  local ok, err = require("organ.ast").validate(ast)
  if not ok then
    error("export.opml: AST validation failed: " .. err)
  end
  return require("organ.ast.to_opml").render(ast, opts)
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
    path = name:gsub("%.org$", "") .. ".opml"
  end
  local out = M.export_buffer(bufnr, opts)
  local ok, werr = require("organ.path").write_atomic(path, out)
  if not ok then
    return nil, "could not write " .. path .. ": " .. tostring(werr)
  end
  return path
end

return M
