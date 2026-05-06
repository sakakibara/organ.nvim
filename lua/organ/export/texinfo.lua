-- GNU Texinfo (.texi) exporter.
--
-- Headlines map to @chapter / @section / @subsection / @subsubsection.
-- Beyond level 4, levels collapse to @subsubsection. @node directives
-- are emitted to satisfy `info` navigation; `Up`/`Next`/`Previous` are
-- left empty (Texinfo will infer or the user supplies via post-processing).
--
-- Inline:
--   *bold*       → @strong{...}
--   /italic/     → @emph{...}
--   =verb=       → @code{...}
--   ~code~       → @code{...}
--   _underline_  → @sansserif{...}      (closest stock equivalent)
--   +strike+     → @strikethrough{...}  (Texinfo 6.6+)
--   [[t][d]]     → @uref{t, d}

local M = {}

local function lstrip(s)
  return s:gsub("^%s+", "")
end

local function heading_level(node, src)
  local sr = node:start()
  local stars = (src[sr + 1] or ""):match("^(%*+)%s") or ""
  return #stars
end

local function clean_title(line, todo_keywords)
  line = line:gsub("^%*+%s+", "")
  for _, kw in ipairs(todo_keywords or {}) do
    if kw ~= "|" then
      local pat = "^" .. kw .. "%s+"
      if line:match(pat) then
        line = line:gsub(pat, "")
        break
      end
    end
  end
  line = line:gsub("^%[#%w%]%s*", "")
  line = line:gsub("%s+:[%w_:@]+:%s*$", "")
  return line
end

local SECT = {
  [1] = "@chapter",
  [2] = "@section",
  [3] = "@subsection",
  [4] = "@subsubsection",
}

-- Texinfo escape: { } @ are special. Only escape outside math regions —
-- which Texinfo doesn't support natively (we keep math source verbatim
-- inside @math{...} when surrounded by `$..$`).
local function escape_text(s)
  s = s:gsub("@", "@@")
  s = s:gsub("{", "@{")
  s = s:gsub("}", "@}")
  return s
end

local function inline_to_texinfo(s)
  -- Stash math `$...$` so escape doesn't mangle backslashes in formulas.
  local subs = {}
  local function stash(latex)
    subs[#subs + 1] = latex
    return string.format("\1MJ%d\1", #subs)
  end
  -- Stash citations BEFORE escape so `@cite{}` survives.
  do
    local cite = require("organ.cite")
    local hits = cite.scan(s)
    if #hits > 0 then
      local out, pos = {}, 1
      for _, h in ipairs(hits) do
        out[#out + 1] = s:sub(pos, h.s - 1)
        local rendered = "@cite{"
          .. table.concat(
            (function()
              local keys = {}
              for _, r in ipairs(h.parsed.refs) do
                keys[#keys + 1] = r.key
              end
              return keys
            end)(),
            ", "
          )
          .. "}"
        out[#out + 1] = stash(rendered)
        pos = h.e + 1
      end
      out[#out + 1] = s:sub(pos)
      s = table.concat(out)
    end
  end
  s = s:gsub("%$([^%$\n]+)%$", function(body)
    return stash("@math{" .. body .. "}")
  end)
  -- Stash links + code spans BEFORE escape so they don't get mangled.
  s = s:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", function(t, d)
    return stash("@uref{" .. t .. ", " .. d .. "}")
  end)
  s = s:gsub("%[%[([^%]]-)%]%]", function(t)
    return stash("@uref{" .. t .. "}")
  end)
  s = s:gsub("=([^=\n]+)=", function(b)
    return stash("@code{" .. b .. "}")
  end)
  s = s:gsub("~([^~\n]+)~", function(b)
    return stash("@code{" .. b .. "}")
  end)
  s = s:gsub("%*([^%*\n]+)%*", function(b)
    return stash("@strong{" .. escape_text(b) .. "}")
  end)
  s = s:gsub("(^[%s%p])/([^/\n]+)/", function(prefix, body)
    return prefix .. stash("@emph{" .. escape_text(body) .. "}")
  end)
  s = s:gsub("^/([^/\n]+)/", function(b)
    return stash("@emph{" .. escape_text(b) .. "}")
  end)
  s = s:gsub("_([%w][^_\n]*)_", function(b)
    return stash("@sansserif{" .. escape_text(b) .. "}")
  end)
  s = s:gsub("%+([^%+\n]+)%+", function(b)
    return stash("@strikethrough{" .. escape_text(b) .. "}")
  end)
  -- Now escape leftover prose.
  s = escape_text(s)
  -- Restore stashes.
  s = s:gsub("\1MJ(%d+)\1", function(idx)
    return subs[tonumber(idx)]
  end)
  return s
end

local function emit_headline(node, src, out, opts)
  local level = heading_level(node, src)
  local title = clean_title(src[node:start() + 1] or "", opts.todo_keywords)
  out[#out + 1] = "@node " .. inline_to_texinfo(title)
  local cmd = SECT[math.min(level, 4)] or "@subsubsection"
  out[#out + 1] = cmd .. " " .. inline_to_texinfo(title)
  out[#out + 1] = ""
end

local function emit_paragraph(node, src, out)
  local sr, _, er, ec = node:range()
  -- Tree-sitter end position is exclusive: when ec > 0 the paragraph
  -- ends mid-row at column ec (last content row is `er`); when ec == 0
  -- the paragraph ends at the start of row `er` (last content row is
  -- `er - 1`). Without this guard, single-row paragraphs whose source
  -- has no trailing newline (e.g. last line of a document) are dropped.
  local last_row = ec > 0 and er or er - 1
  local lines = {}
  for r = sr, last_row do
    if src[r + 1] then
      lines[#lines + 1] = inline_to_texinfo(src[r + 1])
    end
  end
  out[#out + 1] = table.concat(lines, "\n")
  out[#out + 1] = ""
end

local function list_kind(child, src)
  local sr = child:start()
  local raw = src[sr + 1] or ""
  if raw:match("^%s*%d+[.)]") then
    return "@enumerate"
  end
  return "@itemize"
end

local function emit_list(node, src, out, indent_level)
  indent_level = indent_level or 0
  local first_item
  for c in node:iter_children() do
    if c:type() == "list_item" then
      first_item = c
      break
    end
  end
  local env = first_item and list_kind(first_item, src) or "@itemize"
  out[#out + 1] = env
  for child in node:iter_children() do
    if child:type() == "list_item" then
      local sr = child:start()
      local raw = src[sr + 1] or ""
      local _, _, after = raw:match("^(%s*)([%-%+%*]?%d*[.)]?)%s*(.*)$")
      out[#out + 1] = "@item " .. inline_to_texinfo(after or "")
      for sub in child:iter_children() do
        if sub:type() == "list" then
          emit_list(sub, src, out, indent_level + 1)
        end
      end
    elseif child:type() == "list" then
      emit_list(child, src, out, indent_level + 1)
    end
  end
  out[#out + 1] = "@end " .. env:sub(2) -- @end itemize / @end enumerate
  out[#out + 1] = ""
end

local function emit_src_block(node, src, out)
  local sr, _, er = node:range()
  out[#out + 1] = "@example"
  for r = sr + 2, er do
    if src[r] and not src[r]:match("^%s*#%+[Ee][Nn][Dd]_") then
      out[#out + 1] = src[r]
    end
  end
  out[#out + 1] = "@end example"
  out[#out + 1] = ""
end

local function emit_quote_block(node, src, out)
  local sr, _, er = node:range()
  out[#out + 1] = "@quotation"
  for r = sr + 2, er do
    if src[r] and not src[r]:match("^%s*#%+[Ee][Nn][Dd]_") then
      out[#out + 1] = inline_to_texinfo(src[r])
    end
  end
  out[#out + 1] = "@end quotation"
  out[#out + 1] = ""
end

local function emit_table(node, src, out)
  local sr, _, er = node:range()
  local rows = {}
  for r = sr + 1, er do
    local line = src[r] or ""
    if line:match("^%s*|%-") then
      -- divider; ignored in @multitable
    elseif line:match("^%s*|") then
      local cells = {}
      for c in (line .. "|"):gmatch("|([^|]*)") do
        cells[#cells + 1] = lstrip(c):gsub("%s+$", "")
      end
      if cells[#cells] == "" then
        cells[#cells] = nil
      end
      rows[#rows + 1] = cells
    end
  end
  if #rows == 0 then
    return
  end
  -- @multitable @columnfractions .. .. ..
  local n = #rows[1]
  local cf = {}
  for i = 1, n do
    cf[i] = string.format(".%d", math.floor(100 / n))
  end
  out[#out + 1] = "@multitable @columnfractions " .. table.concat(cf, " ")
  for _, r in ipairs(rows) do
    local cells = {}
    for _, c in ipairs(r) do
      cells[#cells + 1] = inline_to_texinfo(c)
    end
    out[#out + 1] = "@item " .. table.concat(cells, " @tab ")
  end
  out[#out + 1] = "@end multitable"
  out[#out + 1] = ""
end

local DROP_TYPES = {
  drawer = true,
  property_drawer = true,
  planning = true,
  clock = true,
  comment = true,
  comment_block = true,
  affiliated_keyword = true,
  keyword = true,
  diary_sexp = true,
}

local function walk(node, src, out, opts)
  local t = node:type()
  if DROP_TYPES[t] then
    return
  end
  if t == "headline" then
    emit_headline(node, src, out, opts)
    for c in node:iter_children() do
      if c:named() then
        walk(c, src, out, opts)
      end
    end
  elseif t == "section" or t == "zeroth_section" or t == "document" then
    for c in node:iter_children() do
      if c:named() then
        walk(c, src, out, opts)
      end
    end
  elseif t == "paragraph" then
    emit_paragraph(node, src, out)
  elseif t == "list" then
    emit_list(node, src, out, 0)
  elseif t == "src_block" or t == "example_block" or t == "verse_block" then
    emit_src_block(node, src, out)
  elseif t == "quote_block" then
    emit_quote_block(node, src, out)
  elseif t == "table" then
    emit_table(node, src, out)
  elseif t == "footnote_definition" then
    emit_paragraph(node, src, out)
  end
end

local function scan_keywords(lines)
  local kw = {}
  for _, ln in ipairs(lines) do
    if ln:match("^%*+%s") then
      break
    end
    local k, v = ln:match("^%s*#%+([%u_]+):%s*(.+)%s*$")
    if k and v then
      kw[k] = v
    end
  end
  return kw
end

function M.export(src, opts)
  opts = opts or {}
  local lines = type(src) == "string" and vim.split(src, "\n", { plain = true }) or src
  local text = table.concat(lines, "\n")

  if opts.expand then
    text = require("organ.expand").process(text, {
      base_dir = opts.base_dir,
      file_path = opts.file_path,
      properties = opts.properties,
    })
    lines = vim.split(text, "\n", { plain = true })
  end

  local native_ctx
  if opts.cite_native then
    text, native_ctx = require("organ.cite").preprocess_native(text, {
      style = opts.cite_style,
      bib_files = opts.bib_files,
      backend = "texinfo",
    })
    lines = vim.split(text, "\n", { plain = true })
  end

  local parser = vim.treesitter.get_string_parser(text, "org")
  local root = parser:parse()[1]:root()

  opts.todo_keywords = opts.todo_keywords
    or (require("organ").config.todo and require("organ").config.todo.sequence)
    or { "TODO", "|", "DONE" }

  local kw = scan_keywords(lines)
  local body = {}
  walk(root, lines, body, opts)

  local function finish(s)
    if native_ctx then
      s = require("organ.cite").finalize_native(s, native_ctx)
    end
    return s
  end

  if opts.body_only then
    return finish(table.concat(body, "\n") .. "\n")
  end

  local title = kw.TITLE or "Untitled"
  local doc = {
    [[\input texinfo @c -*-texinfo-*-]],
    "@c %**start of header",
    "@setfilename " .. (kw.FILENAME or (title:gsub("%s+", "_") .. ".info")),
    "@settitle " .. inline_to_texinfo(title),
    "@c %**end of header",
    "",
    "@titlepage",
    "@title " .. inline_to_texinfo(title),
  }
  if kw.AUTHOR then
    doc[#doc + 1] = "@author " .. inline_to_texinfo(kw.AUTHOR)
  end
  doc[#doc + 1] = "@end titlepage"
  doc[#doc + 1] = ""
  doc[#doc + 1] = "@contents"
  doc[#doc + 1] = ""
  for _, l in ipairs(body) do
    doc[#doc + 1] = l
  end
  doc[#doc + 1] = "@bye"
  return finish(table.concat(doc, "\n") .. "\n")
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
    path = name:gsub("%.org$", "") .. ".texi"
  end
  local out = M.export_buffer(bufnr, opts)
  local ok, werr = require("organ.path").write_atomic(path, out)
  if not ok then
    return nil, "could not write " .. path .. ": " .. tostring(werr)
  end
  return path
end

return M
