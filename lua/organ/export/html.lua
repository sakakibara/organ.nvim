-- HTML5 exporter for org buffers.
-- Reuses the markdown exporter's tree walk where possible; emits semantic
-- HTML5 with optional inline <style>.

local M = {}

local function html_escape(s)
  if not s then
    return ""
  end
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- Module-local flag flipped on whenever a math region is encountered. The
-- exporter checks this when assembling the document head so MathJax loads
-- only when needed.
local _math_used = false

-- Pull math regions out of `s` BEFORE html escaping so we don't mangle
-- characters like `<` inside formulas. Returns (text_with_placeholders,
-- restore_fn) — the caller substitutes back after running its own escape +
-- markup passes.
local function stash_math(s)
  local subs = {}
  local function stash(payload)
    subs[#subs + 1] = payload
    _math_used = true
    return string.format("\1MATH%d\1", #subs)
  end
  -- `\[ ... \]` (display, multi-line not supported in this single-line
  -- pass — handled at paragraph level via the same escape).
  s = s:gsub("\\%[(.-)\\%]", function(body)
    return stash("\\[" .. body .. "\\]")
  end)
  -- `\( ... \)` (inline)
  s = s:gsub("\\%((.-)\\%)", function(body)
    return stash("\\(" .. body .. "\\)")
  end)
  -- `$...$` inline. We're permissive: a $ followed by a non-$ then anything
  -- non-newline up to the next $.
  s = s:gsub("%$([^%$\n]+)%$", function(body)
    return stash("$" .. body .. "$")
  end)
  return s, subs
end

local function inline_to_html(s)
  local subs
  s, subs = stash_math(s)
  -- Stash citation renders BEFORE html_escape so `<a class="...">` survives.
  local cite_stash = {}
  do
    local cite = require("organ.cite")
    local hits = cite.scan(s)
    if #hits > 0 then
      local out, pos = {}, 1
      for _, h in ipairs(hits) do
        out[#out + 1] = s:sub(pos, h.s - 1)
        cite_stash[#cite_stash + 1] = cite.render(h.parsed, "html")
        out[#out + 1] = string.format("\1CITE%d\1", #cite_stash)
        pos = h.e + 1
      end
      out[#out + 1] = s:sub(pos)
      s = table.concat(out)
    end
  end
  -- Order matters: escape before substitution so `<` in user text doesn't
  -- collide with our generated tags. We escape first, then re-introduce
  -- safe markers and replace.
  s = html_escape(s)
  -- `=verb=` and `~code~` → <code>
  s = s:gsub("=([^=\n]+)=", "<code>%1</code>")
  s = s:gsub("~([^~\n]+)~", "<code>%1</code>")
  -- `*bold*` → <strong>
  s = s:gsub("%*([^%*\n]+)%*", "<strong>%1</strong>")
  -- `/italic/`
  s = s:gsub("(^[%s%p])/([^/\n]+)/", function(prefix, body)
    return prefix .. "<em>" .. body .. "</em>"
  end)
  s = s:gsub("^/([^/\n]+)/", "<em>%1</em>")
  -- `_underline_`
  s = s:gsub("_([%w][^_\n]*)_", "<u>%1</u>")
  -- `+strike+`
  s = s:gsub("%+([^%+\n]+)%+", "<del>%1</del>")
  -- `[[target][desc]]` → `<a href="target">desc</a>`
  s = s:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", function(t, d)
    return string.format('<a href="%s">%s</a>', t, d)
  end)
  -- `[[target]]` → `<a href="target">target</a>`
  s = s:gsub("%[%[([^%]]-)%]%]", function(t)
    return string.format('<a href="%s">%s</a>', t, t)
  end)
  -- Restore stashed math regions verbatim — MathJax processes them client-side.
  s = s:gsub("\1MATH(%d+)\1", function(idx)
    return subs[tonumber(idx)]
  end)
  s = s:gsub("\1CITE(%d+)\1", function(idx)
    return cite_stash[tonumber(idx)]
  end)
  return s
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

local function heading_level(node, src)
  local sr = node:start()
  local line = src[sr + 1] or ""
  return #(line:match("^(%*+)%s") or "")
end

local function emit_heading(node, src, out, opts)
  local level = math.max(1, math.min(6, heading_level(node, src)))
  local sr = node:start()
  local title = clean_title(src[sr + 1] or "", opts.todo_keywords)
  out[#out + 1] = string.format("<h%d>%s</h%d>", level, inline_to_html(title), level)
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
      lines[#lines + 1] = inline_to_html(src[r + 1])
    end
  end
  out[#out + 1] = "<p>" .. table.concat(lines, " ") .. "</p>"
end

local function emit_list(node, src, out, _level)
  out[#out + 1] = "<ul>"
  for child in node:iter_children() do
    if child:type() == "list_item" then
      local sr = child:start()
      local raw = src[sr + 1] or ""
      local _, _, after = raw:match("^(%s*)([%-%+%*]?%d*[.)]?)%s*(.*)$")
      after = after or ""
      local cbox, body = after:match("^%[([ Xx%-])%]%s*(.*)$")
      local content
      if cbox then
        local checked = (cbox == "X" or cbox == "x") and "checked " or ""
        content = string.format(
          '<input type="checkbox" %sdisabled> %s',
          checked,
          inline_to_html(body or "")
        )
      else
        content = inline_to_html(after)
      end
      local nested_open = false
      out[#out + 1] = "<li>" .. content
      for sub in child:iter_children() do
        if sub:type() == "list" then
          if not nested_open then
            nested_open = true
          end
          emit_list(sub, src, out)
        end
      end
      out[#out + 1] = "</li>"
    end
  end
  out[#out + 1] = "</ul>"
end

local function emit_src_block(node, src, out)
  local sr, _, er = node:range()
  local first = src[sr + 1] or ""
  local lang = first:match("[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+(%S+)") or ""
  local class = lang ~= "" and string.format(' class="language-%s"', lang) or ""
  out[#out + 1] = "<pre><code" .. class .. ">"
  for r = sr + 2, er do
    if src[r] and not src[r]:match("^%s*#%+[Ee][Nn][Dd]_") then
      out[#out + 1] = html_escape(src[r])
    end
  end
  out[#out + 1] = "</code></pre>"
end

local function emit_example_block(node, src, out)
  local sr, _, er = node:range()
  out[#out + 1] = "<pre><code>"
  for r = sr + 2, er do
    if src[r] and not src[r]:match("^%s*#%+[Ee][Nn][Dd]_") then
      out[#out + 1] = html_escape(src[r])
    end
  end
  out[#out + 1] = "</code></pre>"
end

local function emit_table(node, src, out)
  local sr, _, er = node:range()
  out[#out + 1] = "<table>"
  local in_body = false
  local seen_separator = false
  for r = sr + 1, er do
    local line = src[r] or ""
    if line:match("^%s*|%-") then
      seen_separator = true
      if not in_body then
        out[#out + 1] = "<tbody>"
        in_body = true
      end
    elseif line:match("^%s*|") then
      local cells = {}
      for c in (line .. "|"):gmatch("|([^|]*)") do
        cells[#cells + 1] = (c:match("^%s*(.-)%s*$") or "")
      end
      if cells[#cells] == "" then
        cells[#cells] = nil
      end
      local tag = (not seen_separator) and "th" or "td"
      if not seen_separator and not out[#out]:find("<thead>", 1, true) then
        out[#out + 1] = "<thead>"
      end
      local row = { "<tr>" }
      for _, cell in ipairs(cells) do
        row[#row + 1] = "<" .. tag .. ">" .. inline_to_html(cell) .. "</" .. tag .. ">"
      end
      row[#row + 1] = "</tr>"
      out[#out + 1] = table.concat(row, "")
      if not seen_separator then
        out[#out + 1] = "</thead>"
      end
    end
  end
  if in_body then
    out[#out + 1] = "</tbody>"
  end
  out[#out + 1] = "</table>"
end

local function emit_horizontal_rule(_, _, out)
  out[#out + 1] = "<hr>"
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
    emit_heading(node, src, out, opts)
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
  elseif t == "paragraph" or t == "footnote_definition" then
    emit_paragraph(node, src, out)
  elseif t == "list" then
    emit_list(node, src, out)
  elseif t == "src_block" then
    emit_src_block(node, src, out)
  elseif t == "example_block" or t == "verse_block" then
    emit_example_block(node, src, out)
  elseif t == "horizontal_rule" then
    emit_horizontal_rule(node, src, out)
  elseif t == "table" then
    emit_table(node, src, out)
  end
end

local DEFAULT_STYLE = [[
body { font-family: -apple-system, system-ui, sans-serif; max-width: 720px; margin: 2em auto; padding: 0 1em; line-height: 1.6; color: #222; }
pre { background: #f4f4f4; padding: 0.7em; overflow-x: auto; border-radius: 4px; }
code { background: #f4f4f4; padding: 0.1em 0.3em; border-radius: 3px; }
pre code { background: transparent; padding: 0; }
table { border-collapse: collapse; margin: 1em 0; }
th, td { border: 1px solid #ccc; padding: 0.4em 0.7em; }
th { background: #f4f4f4; }
hr { border: 0; border-top: 1px solid #ccc; margin: 2em 0; }
a { color: #0366d6; }
]]

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

  local native_ctx
  if opts.cite_native then
    text, native_ctx = require("organ.cite").preprocess_native(text, {
      style = opts.cite_style,
      bib_files = opts.bib_files,
      backend = "html",
    })
    lines = vim.split(text, "\n", { plain = true })
  end

  local parser = vim.treesitter.get_string_parser(text, "org")
  local root = parser:parse()[1]:root()

  local body = {}
  opts.todo_keywords = opts.todo_keywords
    or (require("organ").config.todo and require("organ").config.todo.sequence)
    or { "TODO", "|", "DONE" }
  -- Reset module-local math-region detector so the flag reflects this
  -- export only (otherwise repeated calls would cumulatively load MathJax).
  _math_used = false
  walk(root, lines, body, opts)

  -- Title: pull from `#+title:` keyword if present, else the first headline.
  local title = "Untitled"
  for _, l in ipairs(lines) do
    local v = l:match("^#%+[Tt][Ii][Tt][Ll][Ee]:%s*(.+)$")
    if v then
      title = v
      break
    end
  end
  if title == "Untitled" then
    for _, l in ipairs(lines) do
      local stars, t = l:match("^(%*+)%s+(.+)$")
      if stars then
        title = clean_title(l, opts.todo_keywords)
        break
      end
    end
  end

  local style_block = opts.minimal_style == false and "" or "<style>" .. DEFAULT_STYLE .. "</style>"

  -- MathJax: load when the buffer used any math (`$...$` / `\(...\)` /
  -- `\[...\]`) OR when opts/config explicitly forces it. Config:
  --   html = { mathjax = "cdn" | <url> | false } — defaults to "cdn".
  local cfg_html = (require("organ").config.html or {})
  local mj_opt = opts.mathjax
  if mj_opt == nil then
    mj_opt = cfg_html.mathjax
  end
  if mj_opt == nil then
    mj_opt = "cdn"
  end
  local mathjax_block = ""
  local should_load_mathjax = (_math_used or opts.force_mathjax) and mj_opt ~= false
  if should_load_mathjax then
    local mj_url = mj_opt == "cdn" and "https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"
      or tostring(mj_opt)
    mathjax_block = string.format(
      [==[<script>window.MathJax = { tex: { inlineMath: [['$','$'], ['\\(','\\)']], displayMath: [['\\[','\\]']] } };</script><script async src="%s"></script>]==],
      mj_url
    )
  end

  local doc = {
    "<!DOCTYPE html>",
    '<html lang="en">',
    "<head>",
    '  <meta charset="utf-8">',
    '  <meta name="viewport" content="width=device-width, initial-scale=1">',
    "  <title>" .. html_escape(title) .. "</title>",
    "  " .. style_block,
    "  " .. mathjax_block,
    "</head>",
    "<body>",
  }
  for _, l in ipairs(body) do
    doc[#doc + 1] = l
  end
  doc[#doc + 1] = "</body>"
  doc[#doc + 1] = "</html>"

  local result = table.concat(doc, "\n") .. "\n"
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
    path = name:gsub("%.org$", "") .. ".html"
  end
  local out = M.export_buffer(bufnr, opts)
  local ok, werr = require("organ.path").write_atomic(path, out)
  if not ok then
    return nil, "could not write " .. path .. ": " .. tostring(werr)
  end
  return path
end

return M
