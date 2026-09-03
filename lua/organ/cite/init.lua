-- Org-cite citation references: parse [cite:@key] / [cite/style:@key1;@key2]
-- / [cite:; common-prefix @key1 ;; @key2 common-suffix].
--
-- Subset implemented:
--   [cite:@KEY]                          minimal: one key, default style
--   [cite:@KEY1;@KEY2]                   multiple keys, default style
--   [cite/STYLE:@KEY]                    custom style ("noauthor", "year"...)
--   [cite:@KEY suffix]                   per-key suffix (after the @KEY token)
--   [cite:prefix @KEY]                   per-key prefix (before @KEY)
--
-- Returns a parsed record:
--   { style    = "default" | "noauthor" | ...,
--     prefixes = nil,
--     suffixes = nil,
--     refs     = { { key, prefix, suffix }, ... } }
--
-- Per-export rendering (cite.render(parsed, backend)) emits the convention
-- for each backend: \cite{} / \citeauthor{} for LaTeX, anchor links for
-- HTML, [@key] for Markdown, [key] for ASCII.

local M = {}

local obuf = require("organ.buf")
-- Minimal scanner: split a citation body on `;` at top level (ignoring
-- ones inside brackets/braces, which org-cite doesn't actually use today).
local function split_refs(body)
  local out, buf = {}, {}
  local depth = 0
  for i = 1, #body do
    local c = body:sub(i, i)
    if c == ";" and depth == 0 then
      out[#out + 1] = table.concat(buf)
      buf = {}
    else
      if c == "[" or c == "{" then
        depth = depth + 1
      end
      if c == "]" or c == "}" then
        depth = math.max(0, depth - 1)
      end
      buf[#buf + 1] = c
    end
  end
  if #buf > 0 then
    out[#out + 1] = table.concat(buf)
  end
  return out
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Characters allowed in a key, after `org-element-citation-key-re`:
-- word characters (any script) plus a fixed set of punctuation.
local KEY_CHARS = "[%w\128-\255%-%.:%?!`'/%*@%+|%(%)%{%}<>&_%^%$#%%~]"
M.KEY_CHARS = KEY_CHARS

-- Parse a single ref segment: "prefix @KEY suffix" -> { key, prefix, suffix }.
local function parse_ref(seg)
  seg = trim(seg)
  local s, e = seg:find("@" .. KEY_CHARS .. "+")
  if not s then
    return nil
  end
  local key = seg:sub(s + 1, e)
  local prefix = trim(seg:sub(1, s - 1))
  local suffix = trim(seg:sub(e + 1))
  return {
    key = key,
    prefix = prefix ~= "" and prefix or nil,
    suffix = suffix ~= "" and suffix or nil,
  }
end

-- Short style and variant names from `org-cite-basic` `:cite-styles`.
local STYLE_ALIASES = {
  a = "author",
  na = "noauthor",
  n = "nocite",
  ft = "note",
  nb = "numeric",
  t = "text",
}
local VARIANT_ALIASES = { b = "bare", c = "caps", bc = "bare-caps" }

-- Parse the body of a `[cite/STYLE:body]` block. Returns parsed record.
local function parse_body(style_part, body)
  local refs_raw = split_refs(body)
  local refs = {}
  for _, seg in ipairs(refs_raw) do
    local r = parse_ref(seg)
    if r then
      refs[#refs + 1] = r
    end
  end
  local style, variant
  if style_part and style_part ~= "" then
    style, variant = style_part:match("^([^/]+)/?(.*)$")
    style = STYLE_ALIASES[style] or style
    variant = variant ~= "" and (VARIANT_ALIASES[variant] or variant) or nil
  end
  return { style = style or "default", variant = variant, refs = refs }
end

-- Position of the `]` closing a citation whose body starts at `pos`,
-- balancing nested square brackets the way Emacs `scan-lists` does.
local function find_close(text, pos)
  local depth = 0
  for i = pos, #text do
    local c = text:sub(i, i)
    if c == "[" then
      depth = depth + 1
    elseif c == "]" then
      if depth == 0 then
        return i
      end
      depth = depth - 1
    end
  end
  return nil
end

-- Find every citation in `text`. Returns { { start, end, parsed } }, where
-- positions are 1-based byte offsets. A citation is `[cite` + optional
-- `/STYLE` + `:` + at least one `@key`, as in `org-element-citation-prefix-re`.
function M.scan(text)
  local out = {}
  local pos = 1
  while pos <= #text do
    local s = text:find("[cite", pos, true)
    if not s then
      break
    end
    pos = s + 1
    local style_part, body_open = "", text:match("^%[cite:()", s)
    if not body_open then
      style_part, body_open = text:match("^%[cite/([%w/_%-]+):()", s)
    end
    local body_close = body_open and find_close(text, body_open)
    if body_close then
      local parsed = parse_body(style_part, text:sub(body_open, body_close - 1))
      if #parsed.refs > 0 then
        out[#out + 1] = { s = s, e = body_close, parsed = parsed }
        pos = body_close + 1
      end
    end
  end
  return out
end

-- Convenience: parse a single `[cite:...]` substring (matching pattern
-- assumed). Returns parsed record or nil.
function M.parse(text)
  local hits = M.scan(text)
  return hits[1] and hits[1].parsed
end

-- Per-backend renderers. Each `render(parsed)` returns a single string with
-- the appropriate substitution.

local RENDERERS = {}

function RENDERERS.latex(p)
  local cmd = "\\cite"
  if p.style == "noauthor" then
    cmd = "\\citeyear"
  elseif p.style == "author" then
    cmd = "\\citeauthor"
  elseif p.style == "text" then
    cmd = "\\citet"
  elseif p.style == "nocite" then
    cmd = "\\nocite"
  end
  local keys = {}
  for _, r in ipairs(p.refs) do
    keys[#keys + 1] = r.key
  end
  return cmd .. "{" .. table.concat(keys, ",") .. "}"
end

function RENDERERS.html(p)
  local pieces = {}
  for _, r in ipairs(p.refs) do
    pieces[#pieces + 1] = string.format('<a class="citation" href="#bib-%s">[%s]</a>', r.key, r.key)
  end
  return table.concat(pieces, " ")
end

function RENDERERS.markdown(p)
  local keys = {}
  for _, r in ipairs(p.refs) do
    keys[#keys + 1] = "@" .. r.key
  end
  return "[" .. table.concat(keys, "; ") .. "]"
end

function RENDERERS.ascii(p)
  local keys = {}
  for _, r in ipairs(p.refs) do
    keys[#keys + 1] = r.key
  end
  return "[" .. table.concat(keys, ", ") .. "]"
end

RENDERERS.texinfo = RENDERERS.ascii

function M.render(parsed, backend)
  local fn = RENDERERS[backend]
  if not fn then
    return "[cite]"
  end
  if parsed.style == "nocite" and backend ~= "latex" then
    return ""
  end
  return fn(parsed)
end

-- Substitute every citation in `text` using the given backend. Useful for
-- exporters that walk inline text line-by-line.
function M.replace_in(text, backend)
  local hits = M.scan(text)
  if #hits == 0 then
    return text
  end
  local out, pos = {}, 1
  for _, h in ipairs(hits) do
    out[#out + 1] = text:sub(pos, h.s - 1)
    out[#out + 1] = M.render(h.parsed, backend)
    pos = h.e + 1
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out)
end

-- Native CSL pipeline: bibliography discovery + load + render. The
-- functions below complement the per-backend RENDERERS above. They
-- exist so users who want native, bibliography-aware output (rather
-- than delegating to LaTeX's bibtex) can do everything in pure Lua.

-- Find every `#+bibliography:` directive in `text`. Returns an ordered
-- list of file paths (deduplicated, in first-occurrence order). The
-- directive is case-insensitive and may appear multiple times.
function M.find_bibliographies(text)
  local out, seen = {}, {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local path = line:match("^%s*#%+[Bb][Ii][Bb][Ll][Ii][Oo][Gg][Rr][Aa][Pp][Hh][Yy]:%s*(.-)%s*$")
    if path and path ~= "" and not seen[path] then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  return out
end

-- Read the `#+cite_export:` directive's processor + style. Returns
-- (style, processor) — processor is unused by the native renderer
-- (which is always "csl"-flavoured) but is preserved for caller info.
function M.find_cite_export(text)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local rest = line:match("^%s*#%+[Cc][Ii][Tt][Ee]_[Ee][Xx][Pp][Oo][Rr][Tt]:%s*(.+)%s*$")
    if rest then
      local proc, style = rest:match("^(%S+)%s+(.+)$")
      if proc then
        -- Strip a trailing ".csl" from style for nicer matching.
        style = style:gsub("%.csl$", "")
        return style, proc
      end
      return rest, nil
    end
  end
  return nil, nil
end

-- Load + merge multiple bibliography sources. Each path's extension
-- selects the parser: .bib → bibtex, .json → csl-json. Returns a
-- combined { key = entry } index. Later files override earlier on key
-- collision (matches CSL behaviour). On read errors, the path is
-- silently skipped — caller can pre-validate paths if strictness
-- matters.
function M.load_bibliographies(paths)
  local bibtex = require("organ.cite.bibtex")
  local csl_json = require("organ.cite.csl_json")
  local idx = {}
  for _, p in ipairs(paths or {}) do
    local entries
    if p:match("%.json$") or p:match("%.csl$") then
      entries = csl_json.parse_file(p)
    else
      entries = bibtex.parse_file(p)
      if entries then
        entries = bibtex.normalize(entries)
      end
    end
    if entries then
      for _, e in ipairs(entries) do
        if e.key then
          idx[e.key] = e
        end
      end
    end
  end
  return idx
end

-- High-level driver: scan `text`, render every `[cite:...]` against
-- the bibliography, and return the rewritten text + bibliography
-- lines. Bibliography sources come from opts.bib_files (paths) or
-- opts.bib_index (preloaded). When neither is given, scans the text
-- itself for `#+bibliography:` directives.
--
-- opts:
--   style      "apa" | "chicago" | "ieee"      (default: from cite_export, else "apa")
--   backend    "default" | "org" | "markdown" | "html" | "latex" | "ascii"
--   bib_files  { "refs.bib", ... }
--   bib_index  preloaded { key = entry }
--
-- Returns: rendered_text, { bibliography_line, ... }
function M.process(text, opts)
  opts = opts or {}
  local render = require("organ.cite.render")
  local idx
  if opts.bib_index then
    idx = opts.bib_index
  else
    local paths = opts.bib_files or M.find_bibliographies(text)
    idx = M.load_bibliographies(paths)
  end
  local style = opts.style or M.find_cite_export(text) or "apa"
  return render.render_text(text, idx, style, { backend = opts.backend })
end

-- Export-pipeline integration: pre-process raw org source so that the
-- existing tree-sitter-driven exporters can ship native CSL output
-- without each one needing to know the rendering rules.
--
-- The pre-processor:
--   1. Renders every `[cite:...]` block against the bibliography using
--      a single shared ctx (so IEEE numbering and year-disambig are
--      consistent across the whole document).
--   2. Replaces each `[cite:...]` block in the text with a sentinel
--      token that survives tree-sitter parsing and inline-markup
--      regexes (control bytes \1, \1NCITE\1id\1NCITE\1).
--   3. Replaces the `#+print_bibliography` directive line with a
--      single-byte sentinel `\1NBIB\1`.
--
-- The exporter runs as normal — sentinels are emitted verbatim. After
-- the export string is built, finalize_native() rewrites the sentinels
-- with the rendered values (cite text, bibliography lines joined as
-- paragraphs) and applies backend-specific italic substitution to any
-- residual italic markers in the bibliography.

local NCITE_OPEN = "\1NCITE\1"
local NCITE_CLOSE = "\1NCITE\1"
local NBIB = "\1NBIB\1"

-- Pre-render and stamp the source. Returns the new text plus a
-- "native_ctx" table the exporter passes back to finalize_native().
-- opts mirrors process(): bib_files / bib_index / style / backend.
function M.preprocess_native(text, opts)
  opts = opts or {}
  local render = require("organ.cite.render")
  local idx
  if opts.bib_index then
    idx = opts.bib_index
  else
    idx = M.load_bibliographies(opts.bib_files or M.find_bibliographies(text))
  end
  local style = opts.style or M.find_cite_export(text) or "apa"
  local backend = opts.backend or "default"

  -- Phase 1: scan + render. We render with backend="raw" so the
  -- italic sentinels stay raw — finalize_native applies the backend
  -- substitution after the exporter is done escaping text.
  local hits = M.scan(text)
  local ctx = render.new_ctx({ backend = "raw" })
  for _, h in ipairs(hits) do
    render.register_cite(h.parsed, ctx)
  end
  local cite_stash = {}
  for i, h in ipairs(hits) do
    cite_stash[i] = render.render_cite(h.parsed, idx, style, ctx)
  end
  local bib_lines = render.render_bibliography(idx, style, ctx)

  -- Phase 2: rewrite source. Citations get unique sentinels; the
  -- bibliography directive line is replaced wholesale.
  local out, pos = {}, 1
  for i, h in ipairs(hits) do
    out[#out + 1] = text:sub(pos, h.s - 1)
    out[#out + 1] = NCITE_OPEN .. tostring(i) .. NCITE_CLOSE
    pos = h.e + 1
  end
  out[#out + 1] = text:sub(pos)
  local stamped = table.concat(out)

  -- Replace any `#+print_bibliography[ :options]` line with the bib
  -- sentinel. We swap the entire line so the directive's own
  -- formatting doesn't bleed into the export.
  stamped = stamped:gsub(
    "([^\n]*#%+[Pp][Rr][Ii][Nn][Tt]_[Bb][Ii][Bb][Ll][Ii][Oo][Gg][Rr][Aa][Pp][Hh][Yy][^\n]*)",
    function(line)
      -- Preserve any leading whitespace ahead of the directive.
      local lead = line:match("^(%s*)#%+") or ""
      return lead .. NBIB
    end
  )

  return stamped,
    {
      cite_stash = cite_stash,
      bib_lines = bib_lines,
      backend = backend,
      has_bib_directive = stamped:find(NBIB, 1, true) ~= nil,
    }
end

local function html_escape(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub('"', "&quot;")
  return s
end

-- Rendered citation text is substituted after the exporter has escaped
-- the document, so it is escaped here. LaTeX gets bibliography fields
-- raw, like `org-cite-basic--get-field` for LaTeX-derived backends.
local ESCAPES = {
  html = html_escape,
  texinfo = function(s)
    return require("organ.ast.to_texinfo")._escape_text(s)
  end,
}

-- Substitute sentinels in the export output and apply backend-specific
-- italic finalisation to any residual `\1IT\1...\1IT\1` markers.
-- Joins bibliography lines with double newlines so each entry becomes
-- its own paragraph in markdown / html / latex / ascii.
function M.finalize_native(out_text, native_ctx)
  if not native_ctx then
    return out_text
  end
  local escape = ESCAPES[native_ctx.backend] or function(s)
    return s
  end
  -- Cite sentinels. \1 is not a Lua-pattern metacharacter, so it can
  -- appear in the pattern verbatim.
  out_text = out_text:gsub("\1NCITE\1(%d+)\1NCITE\1", function(id)
    return escape(native_ctx.cite_stash[tonumber(id)] or "")
  end)
  -- Bibliography sentinel: joined as separate paragraphs. Use a
  -- replacement function so the bib content (which can contain `%`)
  -- bypasses the gsub `%n` capture rules.
  if native_ctx.has_bib_directive then
    local lines = {}
    for i, l in ipairs(native_ctx.bib_lines) do
      lines[i] = escape(l)
    end
    local joined = table.concat(lines, "\n\n")
    out_text = out_text:gsub("\1NBIB\1", function()
      return joined
    end)
  end
  -- Italic markers in bibliography → backend-specific.
  local render = require("organ.cite.render")
  return render._finalize(out_text, native_ctx.backend)
end

-- Completion / picker support: surface bibliography keys for use in
-- `[cite:@<partial>` insert-mode completion and a `:Org cite find`
-- picker.

-- Resolve a bibliography path string against the buffer's directory
-- (when known) so users can write relative paths in #+bibliography:
-- and have them resolve consistently from inside neovim and from
-- background scans.
local function resolve_path(p, buf_dir)
  local full = vim.fn.fnamemodify(p, ":p")
  if full == "" or not vim.uv.fs_stat(full) then
    if buf_dir then
      full = vim.fs.joinpath(buf_dir, p)
    end
  end
  return full
end

-- Pull every bibliography path the user has wired in. Sources, in
-- precedence order:
--   1. Explicit `paths` argument (when caller knows what they want).
--   2. `#+bibliography:` directives in the current org buffer.
--   3. `organ.config.cite.bibliographies` (file paths or globs).
-- Returns the list of resolved absolute paths.
function M.discover_paths(paths, bufnr)
  if paths and #paths > 0 then
    return paths
  end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buf_dir
  if vim.api.nvim_buf_is_valid(bufnr) then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name and name ~= "" then
      buf_dir = vim.fs.dirname(name)
    end
  end
  local out, seen = {}, {}
  -- (2) Directives in the buffer.
  if vim.api.nvim_buf_is_valid(bufnr) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for _, p in ipairs(M.find_bibliographies(table.concat(lines, "\n"))) do
      local resolved = resolve_path(p, buf_dir)
      if not seen[resolved] then
        seen[resolved] = true
        out[#out + 1] = resolved
      end
    end
  end
  -- (3) Config — supports plain paths and globs.
  local ok, organ = pcall(require, "organ")
  if
    ok
    and organ.config
    and require("organ.buf_config").read(nil, "cite")
    and require("organ.buf_config").read(nil, "cite.bibliographies")
  then
    for _, pat in ipairs(require("organ.buf_config").read(nil, "cite.bibliographies")) do
      for _, p in ipairs(vim.fn.glob(pat, false, true) or { pat }) do
        local resolved = vim.fn.fnamemodify(p, ":p")
        if not seen[resolved] then
          seen[resolved] = true
          out[#out + 1] = resolved
        end
      end
    end
  end
  return out
end

-- Module-level cache: { path = { mtime = ..., entries = { key, entry } } }.
-- Avoids re-parsing a 10k-entry .bib on every keystroke during
-- completion. Invalidated on mtime change.
local _bib_cache = {}

local function load_with_cache(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local cached = _bib_cache[path]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.entries
  end
  local bibtex = require("organ.cite.bibtex")
  local csl_json = require("organ.cite.csl_json")
  local entries
  if path:match("%.json$") or path:match("%.csl$") then
    entries = csl_json.parse_file(path)
  else
    entries = bibtex.parse_file(path)
    if entries then
      entries = bibtex.normalize(entries)
    end
  end
  if not entries then
    return nil
  end
  _bib_cache[path] = { mtime = stat.mtime.sec, entries = entries }
  return entries
end

-- Public for tests / explicit invalidation.
function M.clear_cache()
  _bib_cache = {}
end

-- Build a list of completion items from the discovered bibliographies.
-- Each item: { key, label, description, entry } where `description`
-- summarises author + year + title for picker display. Items are
-- sorted by key for deterministic ordering. Optional `query` filters
-- substring-match against key + author family + title (case-insens).
function M.completion_items(query, opts)
  opts = opts or {}
  local items = {}
  local seen = {}
  local q = (query or ""):lower()
  for _, path in ipairs(M.discover_paths(opts.paths, opts.bufnr)) do
    local entries = load_with_cache(path)
    if entries then
      for _, e in ipairs(entries) do
        if e.key and not seen[e.key] then
          seen[e.key] = true
          local family = (e.author and e.author[1] and e.author[1].family) or ""
          local title = (e.fields and e.fields.title) or ""
          local year = e.year or ""
          local hay = (e.key .. " " .. family .. " " .. title):lower()
          if q == "" or hay:find(q, 1, true) then
            local label
            if family ~= "" and year ~= "" then
              label = string.format("%s (%s, %s) %s", e.key, family, year, title)
            elseif family ~= "" then
              label = string.format("%s (%s) %s", e.key, family, title)
            else
              label = string.format("%s %s", e.key, title)
            end
            items[#items + 1] = {
              key = e.key,
              label = label,
              description = title ~= "" and title or e.key,
              entry = e,
            }
          end
        end
      end
    end
  end
  table.sort(items, function(a, b)
    return a.key < b.key
  end)
  return items
end

-- Detect a cite-key completion trigger at the cursor. Recognises
--   [cite:@<partial>
--   [cite/STYLE:@<partial>
--   [cite:...; @<partial>
-- Returns nil when not in cite context, else
--   { kind = "cite_key", prefix_col = <col of @>, query = "<partial>" }.
function M.trigger_at_cursor(bufnr)
  bufnr = bufnr or 0
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local prefix_part = line:sub(1, col)
  -- Find the most recent `@` to the left of the cursor on this line.
  local at_pos
  for i = #prefix_part, 1, -1 do
    local c = prefix_part:sub(i, i)
    if c == "@" then
      at_pos = i
      break
    end
    if not c:match(KEY_CHARS) then
      break
    end
  end
  if not at_pos then
    return nil
  end
  -- Confirm we're inside an unclosed `[cite...:` opening to the left.
  local before_at = prefix_part:sub(1, at_pos - 1)
  local cite_open = before_at:find("%[cite[^%]]*$")
  if not cite_open then
    return nil
  end
  -- Make sure the cite block isn't closed before us.
  if before_at:sub(cite_open):find("%]", 1, true) then
    return nil
  end
  return {
    kind = "cite_key",
    prefix_col = at_pos, -- 1-based byte column of `@`
    query = prefix_part:sub(at_pos + 1),
  }
end

-- Resolve `#+bibliography:` paths against the current buffer's directory
-- so users can write `#+bibliography: refs.bib` and have it just work.
local function resolve_bib_paths(bufnr, paths)
  local buf_dir
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name and name ~= "" then
    buf_dir = vim.fs.dirname(name)
  end
  local out = {}
  for _, p in ipairs(paths) do
    local resolved = vim.fn.fnamemodify(p, ":p")
    if resolved == "" or not vim.uv.fs_stat(resolved) then
      if buf_dir then
        resolved = vim.fs.joinpath(buf_dir, p)
      end
    end
    out[#out + 1] = resolved
  end
  return out
end

local STYLE_COMPLETE = function()
  return { "apa", "chicago", "ieee" }
end

M.commands = {
  ["cite preview"] = {
    fn = function(cmd)
      local bufnr = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local text = table.concat(lines, "\n")
      local paths = resolve_bib_paths(bufnr, M.find_bibliographies(text))
      if #paths == 0 then
        require("organ.notify").warn("cite_preview: no #+bibliography: directives found in buffer")
        return
      end
      local style = (cmd and cmd.args ~= "" and cmd.args) or M.find_cite_export(text) or "apa"
      local rendered, bib = M.process(text, { bib_files = paths, style = style, backend = "org" })
      local out_lines = vim.split(rendered, "\n", { plain = true })
      out_lines[#out_lines + 1] = ""
      out_lines[#out_lines + 1] = "* References"
      for _, l in ipairs(bib) do
        out_lines[#out_lines + 1] = l
      end
      vim.cmd("vnew")
      obuf.set_lines(0, 0, -1, out_lines)
      vim.bo.filetype = "org"
      vim.bo.bufhidden = "wipe"
      vim.bo.buftype = "nofile"
    end,
    nargs = "?",
    complete = STYLE_COMPLETE,
    desc = "Preview rendered citations + bibliography",
  },
  ["cite bibliography"] = {
    fn = function(cmd)
      local bufnr = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local text = table.concat(lines, "\n")
      local paths = resolve_bib_paths(bufnr, M.find_bibliographies(text))
      if #paths == 0 then
        require("organ.notify").warn("cite_bibliography: no #+bibliography: directives found")
        return
      end
      local style = (cmd and cmd.args ~= "" and cmd.args) or M.find_cite_export(text) or "apa"
      local _, bib = M.process(text, { bib_files = paths, style = style, backend = "org" })
      local directive_idx
      for i, l in ipairs(lines) do
        if
          l:match("^%s*#%+[Pp][Rr][Ii][Nn][Tt]_[Bb][Ii][Bb][Ll][Ii][Oo][Gg][Rr][Aa][Pp][Hh][Yy]")
        then
          directive_idx = i
          break
        end
      end
      if directive_idx then
        obuf.set_lines(bufnr, directive_idx - 1, directive_idx, bib)
      else
        local append = { "", "* References" }
        for _, l in ipairs(bib) do
          append[#append + 1] = l
        end
        obuf.set_lines(bufnr, -1, -1, append)
      end
      require("organ.notify").info("organ: rendered " .. #bib .. " bibliography entries")
    end,
    nargs = "?",
    complete = STYLE_COMPLETE,
    desc = "Replace #+print_bibliography line in buffer with rendered entries",
  },
  ["cite find"] = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local items_raw = M.completion_items("", { bufnr = bufnr })
      if #items_raw == 0 then
        require("organ.notify").warn(
          "cite_find: no bibliography keys found (add #+bibliography:"
            .. " or set organ.config.cite.bibliographies)"
        )
        return
      end
      local picker_items = {}
      for _, it in ipairs(items_raw) do
        picker_items[#picker_items + 1] = {
          display = it.label,
          match_fields = { "display" },
          _key = it.key,
        }
      end
      require("organ.find").pick({
        source = "complete",
        items = picker_items,
        title = "Insert citation",
        default_action = "insert_cite",
        actions = {
          insert_cite = function(picker_item)
            local row, col = unpack(vim.api.nvim_win_get_cursor(0))
            local insert = "[cite:@" .. picker_item._key .. "]"
            obuf.set_text(bufnr, row - 1, col, row - 1, col, { insert })
            vim.api.nvim_win_set_cursor(0, { row, col + #insert })
          end,
          yank = function(picker_item)
            vim.fn.setreg("+", "@" .. picker_item._key)
            require("organ.notify").info("yanked @" .. picker_item._key)
          end,
        },
      })
    end,
    desc = "Find a cite key from #+bibliography sources + insert [cite:@KEY]",
  },
}

return M
