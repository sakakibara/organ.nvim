-- Citation rendering driver. Combines parsed cite blocks (from
-- cite/init.lua), a bibliography index (from cite/bibtex or
-- cite/csl_json), and a style implementation (from cite/styles) to
-- produce in-text citations and a bibliography list.
--
-- Two-pass design: scan first to build the per-document context
-- (used keys, ieee numbering), then render in a second pass so
-- style.render_cite can use accumulated state.

local M = {}

local STYLES = require("organ.cite.styles")

-- Backend-specific italic wrappers. styles.lua emits `\1IT\1text\1IT\1`
-- as a backend-neutral italic sentinel; finalize() rewrites it.
local IT_WRAPPERS = {
  default = function(s)
    return s
  end, -- strip
  org = function(s)
    return "/" .. s .. "/"
  end,
  markdown = function(s)
    return "*" .. s .. "*"
  end,
  html = function(s)
    return "<em>" .. s .. "</em>"
  end,
  latex = function(s)
    return "\\emph{" .. s .. "}"
  end,
  texinfo = function(s)
    return "@emph{" .. s .. "}"
  end,
  ascii = function(s)
    return s
  end,
}

-- Replace italic sentinels with the backend's wrapper. Pairs are
-- consumed left-to-right (open → close → open → close). The "raw"
-- backend short-circuits: callers (preprocess_native) want the
-- markers preserved so finalize_native can substitute them after the
-- exporter is done emitting text.
local function finalize(s, backend)
  if backend == "raw" then
    return s
  end
  local wrap = IT_WRAPPERS[backend] or IT_WRAPPERS.default
  local out, pos, depth = {}, 1, 0
  local buf = {}
  while pos <= #s do
    local i, j = s:find("\1IT\1", pos, true)
    if not i then
      break
    end
    if depth == 0 then
      out[#out + 1] = s:sub(pos, i - 1)
      depth = 1
    else
      buf[#buf + 1] = s:sub(pos, i - 1)
      out[#out + 1] = wrap(table.concat(buf))
      buf = {}
      depth = 0
    end
    pos = j + 1
  end
  if depth == 1 then
    -- Unbalanced — should never happen, but handle by stripping the
    -- residual marker so we don't leak control bytes.
    out[#out + 1] = table.concat(buf) .. s:sub(pos)
  else
    out[#out + 1] = s:sub(pos)
  end
  return table.concat(out)
end

-- Resolve a style identifier to a style table. Accepts the built-in
-- names (apa / chicago / ieee) and falls back to apa for unknown.
local function get_style(name)
  if not name then
    return STYLES.apa
  end
  local s = STYLES[name:lower()]
  if not s then
    return STYLES.apa, "unknown citation style '" .. name .. "', falling back to apa"
  end
  return s
end

-- Make a fresh per-document render context. Optional `backend` controls
-- the italic-sentinel transform applied to all rendered strings.
function M.new_ctx(opts)
  return { backend = opts and opts.backend or "default" }
end

-- Record the keys a parsed cite block references so render_bibliography
-- includes them and year disambiguation sees every cited entry. Callers
-- rendering a whole document register every block before rendering
-- the first one.
function M.register_cite(parsed, ctx)
  ctx._used = ctx._used or {}
  ctx._used_set = ctx._used_set or {}
  for _, r in ipairs(parsed.refs or {}) do
    if not ctx._used_set[r.key] then
      ctx._used_set[r.key] = true
      ctx._used[#ctx._used + 1] = r.key
    end
  end
end

-- Render a single parsed cite block.
function M.render_cite(parsed, bib_index, style_name, ctx)
  ctx = ctx or M.new_ctx()
  local style = get_style(style_name)
  M.register_cite(parsed, ctx)
  if parsed.style == "nocite" then
    return ""
  end
  return finalize(style.render_cite(parsed, bib_index, ctx), ctx.backend)
end

-- Render the bibliography for the keys ctx has seen so far.
function M.render_bibliography(bib_index, style_name, ctx)
  ctx = ctx or M.new_ctx()
  local style = get_style(style_name)
  local lines = style.render_bibliography(bib_index, ctx._used or {}, ctx)
  for i, l in ipairs(lines) do
    lines[i] = finalize(l, ctx.backend)
  end
  return lines
end

-- Convenience: scan a buffer's text, render all cites + bibliography
-- in one go. `text` may contain multiple `[cite:...]` blocks.
function M.render_text(text, bib_index, style_name, opts)
  local cite = require("organ.cite")
  local hits = cite.scan(text)
  local ctx = M.new_ctx(opts)
  for _, h in ipairs(hits) do
    M.register_cite(h.parsed, ctx)
  end
  local out = {}
  local pos = 1
  for _, h in ipairs(hits) do
    out[#out + 1] = text:sub(pos, h.s - 1)
    out[#out + 1] = M.render_cite(h.parsed, bib_index, style_name, ctx)
    pos = h.e + 1
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out), M.render_bibliography(bib_index, style_name, ctx)
end

M._finalize = finalize

return M
