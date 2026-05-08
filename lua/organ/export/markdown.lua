-- Markdown (CommonMark) exporter for org buffers.
-- Pure: takes a buffer-or-source string + the parser, returns a string.
-- Uses the org tree-sitter grammar, plus the org_inline injection grammar.

local M = {}

local function get_text(node, src)
  local sr, sc, er, ec = node:range()
  if sr == er then
    return src[sr + 1] and src[sr + 1]:sub(sc + 1, ec) or ""
  end
  local out = { src[sr + 1] and src[sr + 1]:sub(sc + 1) or "" }
  for r = sr + 2, er do
    out[#out + 1] = src[r] or ""
  end
  out[#out + 1] = src[er + 1] and src[er + 1]:sub(1, ec) or ""
  return table.concat(out, "\n")
end

local function lstrip(s)
  return s:gsub("^%s+", "")
end

local function children(node)
  local out = {}
  for c in node:iter_children() do
    out[#out + 1] = c
  end
  return out
end

-- Given a `headline` (block-grammar node), return the level (number of stars)
-- by counting `*` characters at the start of the heading line.
local function heading_level(node, src)
  local sr, sc = node:start()
  local line = src[sr + 1] or ""
  local stars = line:match("^(%*+)%s") or ""
  return #stars
end

-- Strip leading "TODO " / "DONE " etc. and trailing tags ":a:b:" from
-- a headline title line.
local function clean_title(line, todo_keywords)
  -- Drop leading stars.
  line = line:gsub("^%*+%s+", "")
  -- Drop leading TODO keyword.
  for _, kw in ipairs(todo_keywords or {}) do
    if kw ~= "|" then
      local pat = "^" .. kw .. "%s+"
      if line:match(pat) then
        line = line:gsub(pat, "")
        break
      end
    end
  end
  -- Drop priority `[#A]`.
  line = line:gsub("^%[#%w%]%s*", "")
  -- Drop trailing tags.
  line = line:gsub("%s+:[%w_:@]+:%s*$", "")
  return line
end

local function emit_headline(node, src, out, opts)
  local level = heading_level(node, src)
  local sr = node:start()
  local title = clean_title(src[sr + 1] or "", opts.todo_keywords)
  out[#out + 1] = string.rep("#", math.max(1, math.min(6, level))) .. " " .. title
  out[#out + 1] = ""
end

local INLINE_BOLD_OPEN = "**"
local INLINE_BOLD_CLOSE = "**"
local INLINE_ITALIC_OPEN = "*"
local INLINE_ITALIC_CLOSE = "*"
local INLINE_UND_OPEN = "<u>"
local INLINE_UND_CLOSE = "</u>"
local INLINE_STRIKE_OPEN = "~~"
local INLINE_STRIKE_CLOSE = "~~"

-- Convert a single org inline-text line to markdown.  We do NOT depend on
-- the inline grammar here — we use a small set of regex replacements that
-- cover the everyday emphasis + link forms.  Edge cases (nested emphasis,
-- mid-word `_`) are intentionally permissive.
local function inline_to_md(s)
  -- `=verb=` and `~code~` → `code`
  s = s:gsub("=([^=\n]+)=", "`%1`")
  s = s:gsub("~([^~\n]+)~", "`%1`")
  -- `*bold*`
  s = s:gsub("%*([^%*\n]+)%*", INLINE_BOLD_OPEN .. "%1" .. INLINE_BOLD_CLOSE)
  -- `/italic/`  (only when preceded by start-of-line / space and the
  --              closer is followed by space / EOL / punctuation)
  s = s:gsub("(^[%s%p])/([^/\n]+)/", function(prefix, body)
    return prefix .. INLINE_ITALIC_OPEN .. body .. INLINE_ITALIC_CLOSE
  end)
  s = s:gsub("^/([^/\n]+)/", INLINE_ITALIC_OPEN .. "%1" .. INLINE_ITALIC_CLOSE)
  -- `_underline_`
  s = s:gsub("_([%w][^_\n]*)_", INLINE_UND_OPEN .. "%1" .. INLINE_UND_CLOSE)
  -- `+strike+`
  s = s:gsub("%+([^%+\n]+)%+", INLINE_STRIKE_OPEN .. "%1" .. INLINE_STRIKE_CLOSE)
  -- `[[target][desc]]` → `[desc](target)`
  s = s:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "[%2](%1)")
  -- `[[target]]`        → `[target](target)`
  s = s:gsub("%[%[([^%]]-)%]%]", "[%1](%1)")
  -- Citations: render every `[cite:@key]` / `[cite/style:@k1;@k2]` as
  -- pandoc-style `[@key1; @key2]`. Done last so other regexes don't touch
  -- the bracket form first.
  s = require("organ.cite").replace_in(s, "markdown")
  return s
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
      lines[#lines + 1] = inline_to_md(src[r + 1])
    end
  end
  -- Emacs paragraph -> a single MD paragraph; preserve hard breaks via two
  -- spaces at end if user had explicit line breaks (skipped for simplicity).
  out[#out + 1] = table.concat(lines, " ")
  out[#out + 1] = ""
end

local function emit_list(node, src, out, indent_level)
  indent_level = indent_level or 0
  for child in node:iter_children() do
    if child:type() == "list_item" then
      local sr = child:start()
      local raw = src[sr + 1] or ""
      local indent, bullet, after = raw:match("^(%s*)([%-%+%*]?%d*[.)]?)%s*(.*)$")
      indent = indent or ""
      bullet = bullet or "-"
      local md_bullet = bullet:match("^%d+[.)]?$") and (bullet:gsub("[)]$", ".")) or "-"
      -- Capture checkbox.
      local cbox, body = (after or ""):match("^%[([ Xx%-])%]%s*(.*)$")
      local prefix = string.rep("  ", indent_level) .. md_bullet .. " "
      if cbox then
        local mark = (cbox == "X" or cbox == "x") and "x" or " "
        prefix = prefix .. "[" .. mark .. "] "
        out[#out + 1] = prefix .. inline_to_md(body or "")
      else
        out[#out + 1] = prefix .. inline_to_md(after or "")
      end
      -- Recurse into nested lists (paragraph / list children).
      for sub in child:iter_children() do
        if sub:type() == "list" then
          emit_list(sub, src, out, indent_level + 1)
        end
      end
    elseif child:type() == "list" then
      emit_list(child, src, out, indent_level + 1)
    end
  end
  out[#out + 1] = ""
end

local function emit_src_block(node, src, out)
  local sr, _, er = node:range()
  local first = src[sr + 1] or ""
  -- `#+begin_src LANG …`
  local lang = first:match("[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+(%S+)") or ""
  out[#out + 1] = "```" .. lang
  for r = sr + 2, er do
    if src[r] and not src[r]:match("^%s*#%+[Ee][Nn][Dd]_") then
      out[#out + 1] = src[r]
    end
  end
  out[#out + 1] = "```"
  out[#out + 1] = ""
end

local function emit_example_block(node, src, out)
  local sr, _, er = node:range()
  out[#out + 1] = "```"
  for r = sr + 2, er do
    if src[r] and not src[r]:match("^%s*#%+[Ee][Nn][Dd]_") then
      out[#out + 1] = src[r]
    end
  end
  out[#out + 1] = "```"
  out[#out + 1] = ""
end

local function emit_table(node, src, out)
  local sr, _, er = node:range()
  local rows, divider_at = {}, nil
  for r = sr + 1, er do
    local line = src[r] or ""
    if line:match("^%s*|%-") then
      divider_at = #rows + 1 -- divider goes between header and body
    elseif line:match("^%s*|") then
      local cells = {}
      -- Don't append `|` here -- org rows already end with `|`, so the
      -- pattern naturally produces one trailing-empty capture from
      -- that closing pipe.  Appending an extra `|` produced TWO
      -- trailing empties; the single-pop drop below only removed one,
      -- leaking a phantom column into the rendered markdown.
      for c in line:gmatch("|([^|]*)") do
        cells[#cells + 1] = lstrip(c):gsub("%s+$", "")
      end
      -- Last gmatch capture is empty trailing — drop it.
      if cells[#cells] == "" then
        cells[#cells] = nil
      end
      rows[#rows + 1] = "| " .. table.concat(cells, " | ") .. " |"
    end
  end
  if divider_at then
    -- Insert a markdown header divider after the row at divider_at-1.
    local first = rows[1] or ""
    local n = 0
    for _ in first:gmatch("|") do
      n = n + 1
    end
    n = math.max(1, n - 1)
    local divider = "| "
      .. table.concat(
        (function()
          local d = {}
          for i = 1, n do
            d[i] = "---"
          end
          return d
        end)(),
        " | "
      )
      .. " |"
    table.insert(rows, divider_at, divider)
  end
  for _, line in ipairs(rows) do
    out[#out + 1] = line
  end
  out[#out + 1] = ""
end

local function emit_horizontal_rule(_, _, out)
  out[#out + 1] = "---"
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
  footnote_definition = false,
  diary_sexp = true,
}

local function walk(node, src, out, opts)
  local t = node:type()
  if DROP_TYPES[t] then
    return
  end
  if t == "headline" then
    emit_headline(node, src, out, opts)
    -- Recurse into the section + any nested headlines.
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
  elseif t == "src_block" then
    emit_src_block(node, src, out)
  elseif t == "example_block" or t == "verse_block" then
    emit_example_block(node, src, out)
  elseif t == "horizontal_rule" then
    emit_horizontal_rule(node, src, out)
  elseif t == "table" then
    emit_table(node, src, out)
  elseif t == "footnote_definition" then
    emit_paragraph(node, src, out)
  end
end

-- Public API.  src can be a string or a list of lines; returns a string.
--
-- opts.cite_native (bool)  — pre-render `[cite:...]` blocks and the
--                            `#+print_bibliography:` directive using
--                            the native CSL processor before the
--                            export pass. Output replaces pandoc-style
--                            `[@key]` with `(Doe, 2020)` etc.
-- opts.cite_style          — APA/Chicago/IEEE; defaults to #+cite_export:.
-- opts.bib_files           — explicit bibliography paths.
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
      backend = "markdown",
    })
    lines = vim.split(text, "\n", { plain = true })
  end

  local parser = vim.treesitter.get_string_parser(text, "org")
  local root = parser:parse()[1]:root()

  local out = {}
  opts.todo_keywords = opts.todo_keywords
    or (require("organ").config.todo and require("organ").config.todo.sequence)
    or { "TODO", "|", "DONE" }
  walk(root, lines, out, opts)

  -- Collapse runs of >2 blank lines into 1.
  local collapsed = {}
  local prev_blank = false
  for _, l in ipairs(out) do
    if l == "" then
      if not prev_blank then
        collapsed[#collapsed + 1] = ""
      end
      prev_blank = true
    else
      collapsed[#collapsed + 1] = l
      prev_blank = false
    end
  end
  while #collapsed > 0 and collapsed[#collapsed] == "" do
    collapsed[#collapsed] = nil
  end
  local result = table.concat(collapsed, "\n") .. "\n"
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

-- Write export to `path`.  If path is nil, derive from bufnr's name.
function M.export_buffer_to_file(bufnr, path, opts)
  bufnr = bufnr or 0
  if not path or path == "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return nil, "no buffer name; specify a path"
    end
    path = name:gsub("%.org$", "") .. ".md"
  end
  local out = M.export_buffer(bufnr, opts)
  local ok, werr = require("organ.path").write_atomic(path, out)
  if not ok then
    return nil, "could not write " .. path .. ": " .. tostring(werr)
  end
  return path
end

return M
