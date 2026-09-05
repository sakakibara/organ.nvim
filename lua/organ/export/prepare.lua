-- Shared front half of every export backend: the source pre-pass and the
-- pruned AST the renderers consume.
--
-- Emacs expands macros, SETUPFILE and INCLUDE on every export and prunes
-- the parse tree before handing it to a backend, so both run by default
-- here too.  `opts.expand = false` opts out of the source pre-pass;
-- `opts.export_options` overrides individual resolved `#+OPTIONS:`.

local M = {}

-- Run the macro / SETUPFILE / INCLUDE pre-pass.  Relative INCLUDE and
-- SETUPFILE paths resolve against the exported file's directory, as they
-- do in Emacs.
function M.expand(lines, opts)
  opts = opts or {}
  if opts.expand == false then
    return lines
  end
  local file_path = opts.file_path
  local base_dir = opts.base_dir
  if not base_dir and file_path and file_path ~= "" then
    base_dir = vim.fs.dirname(file_path)
  end
  local text = require("organ.expand").process(table.concat(lines, "\n"), {
    base_dir = base_dir,
    file_path = file_path,
    properties = opts.properties,
  })
  return vim.split(text, "\n", { plain = true })
end

-- Parse and prune.  Raises on an invalid tree so a backend bug surfaces
-- at the source rather than as malformed output.
function M.ast(lines, opts, label)
  opts = opts or {}
  local doc = require("organ.ast.from_org").from_lines(lines)
  local ok, err = require("organ.ast").validate(doc)
  if not ok then
    error("export." .. (label or "?") .. ": AST validation failed: " .. err)
  end
  doc = require("organ.export.filter").apply(doc, opts.export_options)
  return require("organ.ast.radio").resolve(doc)
end

return M
