-- ASCII / plain-text exporter for org buffers.
--
-- Produces a faithful but bare rendition: headlines underlined with =/-/~,
-- bullets normalised to "-", tables drawn with `+--+--+`, src/example blocks
-- indented by 2 spaces, links shown as `text (url)`, emphasis markers stripped.

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

-- Stripped inline conversion: keep visible text, drop markup, render links.
local function inline_to_ascii(s)
  -- Links: `[[target][desc]]` → "desc (target)"; `[[target]]` → "target"
  s = s:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", function(target, desc)
    return desc .. " (" .. target .. ")"
  end)
  s = s:gsub("%[%[([^%]]-)%]%]", "%1")
  -- Strip emphasis markers (preserve content).
  s = s:gsub("=([^=\n]+)=", "%1") -- verbatim
  s = s:gsub("~([^~\n]+)~", "%1") -- code
  s = s:gsub("%*([^%*\n]+)%*", "%1") -- bold
  s = s:gsub("(^[%s%p])/([^/\n]+)/", function(prefix, body)
    return prefix .. body
  end)
  s = s:gsub("^/([^/\n]+)/", "%1") -- italic
  s = s:gsub("_([%w][^_\n]*)_", "%1") -- underline
  s = s:gsub("%+([^%+\n]+)%+", "%1") -- strikethrough
  s = require("organ.cite").replace_in(s, "ascii")
  return s
end

local UNDERLINES = { "=", "-", "~", ".", "_" }

local function emit_headline(node, src, out, opts)
  local level = heading_level(node, src)
  local title = clean_title(src[node:start() + 1] or "", opts.todo_keywords)
  title = inline_to_ascii(title)
  out[#out + 1] = title
  if level <= #UNDERLINES then
    out[#out + 1] = string.rep(UNDERLINES[level], math.max(1, vim.fn.strdisplaywidth(title)))
  end
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
      lines[#lines + 1] = inline_to_ascii(src[r + 1])
    end
  end
  out[#out + 1] = table.concat(lines, " ")
  out[#out + 1] = ""
end

local function emit_list(node, src, out, indent_level)
  indent_level = indent_level or 0
  for child in node:iter_children() do
    if child:type() == "list_item" then
      local sr = child:start()
      local raw = src[sr + 1] or ""
      local _, _, after = raw:match("^(%s*)([%-%+%*]?%d*[.)]?)%s*(.*)$")
      after = after or ""
      local cbox, body = after:match("^%[([ Xx%-])%]%s*(.*)$")
      local pad = string.rep("  ", indent_level)
      if cbox then
        local mark = (cbox == "X" or cbox == "x") and "[X]" or (cbox == "-" and "[-]" or "[ ]")
        out[#out + 1] = pad .. "- " .. mark .. " " .. inline_to_ascii(body or "")
      else
        out[#out + 1] = pad .. "- " .. inline_to_ascii(after)
      end
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

local function indent_block(node, src, out, indent)
  local sr, _, er = node:range()
  for r = sr + 2, er do
    if src[r] and not src[r]:match("^%s*#%+[Ee][Nn][Dd]_") then
      out[#out + 1] = indent .. src[r]
    end
  end
  out[#out + 1] = ""
end

local function emit_src_block(node, src, out)
  indent_block(node, src, out, "    ")
end
local function emit_example_block(node, src, out)
  indent_block(node, src, out, "    ")
end
local function emit_quote_block(node, src, out)
  indent_block(node, src, out, "  > ")
end

local function emit_table(node, src, out)
  local sr, _, er = node:range()
  local rows = {}
  for r = sr + 1, er do
    local line = src[r] or ""
    if line:match("^%s*|%-") then
      if rows[#rows] then
        rows[#rows].divider_after = true
      end
    elseif line:match("^%s*|") then
      local cells = {}
      for c in (line .. "|"):gmatch("|([^|]*)") do
        cells[#cells + 1] = lstrip(c):gsub("%s+$", "")
      end
      if cells[#cells] == "" then
        cells[#cells] = nil
      end
      rows[#rows + 1] = { cells = cells }
    end
  end
  if #rows == 0 then
    return
  end
  local ncols = #rows[1].cells
  local widths = {}
  for c = 1, ncols do
    widths[c] = 0
  end
  for _, r in ipairs(rows) do
    for c, cell in ipairs(r.cells) do
      local w = vim.fn.strdisplaywidth(cell or "")
      if w > widths[c] then
        widths[c] = w
      end
    end
  end
  local function divider()
    local parts = {}
    for c = 1, ncols do
      parts[c] = string.rep("-", widths[c] + 2)
    end
    return "+" .. table.concat(parts, "+") .. "+"
  end
  local function row_line(cells)
    local parts = {}
    for c = 1, ncols do
      local cell = cells[c] or ""
      parts[c] = " " .. cell .. string.rep(" ", widths[c] - vim.fn.strdisplaywidth(cell)) .. " "
    end
    return "|" .. table.concat(parts, "|") .. "|"
  end
  out[#out + 1] = divider()
  for _, r in ipairs(rows) do
    out[#out + 1] = row_line(r.cells)
    if r.divider_after then
      out[#out + 1] = divider()
    end
  end
  out[#out + 1] = divider()
  out[#out + 1] = ""
end

local function emit_horizontal_rule(_, _, out)
  out[#out + 1] = string.rep("-", 60)
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
  elseif t == "src_block" then
    emit_src_block(node, src, out)
  elseif t == "example_block" or t == "verse_block" then
    emit_example_block(node, src, out)
  elseif t == "quote_block" then
    emit_quote_block(node, src, out)
  elseif t == "horizontal_rule" then
    emit_horizontal_rule(node, src, out)
  elseif t == "table" then
    emit_table(node, src, out)
  elseif t == "footnote_definition" then
    emit_paragraph(node, src, out)
  end
end

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
      backend = "ascii",
    })
    lines = vim.split(text, "\n", { plain = true })
  end

  local parser = vim.treesitter.get_string_parser(text, "org")
  local root = parser:parse()[1]:root()

  opts.todo_keywords = opts.todo_keywords
    or (require("organ").config.todo and require("organ").config.todo.sequence)
    or { "TODO", "|", "DONE" }

  local out = {}
  walk(root, lines, out, opts)

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
