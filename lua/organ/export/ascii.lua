-- ASCII / plain-text exporter for org buffers.
--
-- Pipeline: optional #+SETUPFILE / #+INCLUDE expansion -> optional
-- native-citation preprocess -> from_org (org -> AST) -> to_ascii (AST ->
-- plain text) -> optional citation finalize.

local M = {}

function M.export(src, opts)
  opts = opts or {}
  local lines
  if type(src) == "string" then
    lines = vim.split(src, "\n", { plain = true })
  else
    lines = src
  end
  lines = require("organ.export.prepare").expand(lines, opts)
  local text = table.concat(lines, "\n")

  local native_ctx
  if opts.cite_native then
    text, native_ctx = require("organ.cite").preprocess_native(text, {
      style = opts.cite_style,
      bib_files = opts.bib_files,
      backend = "ascii",
    })
    lines = vim.split(text, "\n", { plain = true })
  end

  local ast = require("organ.export.prepare").ast(lines, opts, "ascii")
  local result = require("organ.ast.to_ascii").render(ast, opts)

  if native_ctx then
    result = require("organ.cite").finalize_native(result, native_ctx)
  end
  return result
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
    path = name:gsub("%.org$", "") .. ".txt"
  end
  local out = M.export_buffer(bufnr, opts)
  local ok, werr = require("organ.path").write_atomic(path, out)
  if not ok then
    return nil, "could not write " .. path .. ": " .. tostring(werr)
  end
  return path
end

return M
