-- Document AST -> org text.
--
-- Companion to from_org.lua.  Renders every AST kind that from_org
-- emits, so the round trip `from_org(to_org(doc))` produces a
-- semantically equivalent AST (whitespace, comment-trimming, and
-- inline-form normalization apart).

local M = {}

local function emit_inline(nodes)
  if not nodes or #nodes == 0 then
    return ""
  end
  local out = {}
  for _, n in ipairs(nodes) do
    if n.kind == "text" then
      out[#out + 1] = n.text or ""
    elseif n.kind == "emphasis" then
      local delim = ({
        bold = "*",
        italic = "/",
        underline = "_",
        strike = "+",
        verbatim = "=",
        code = "~",
      })[n.style] or "*"
      out[#out + 1] = delim .. emit_inline(n.content) .. delim
    elseif n.kind == "link" then
      if n.description and #n.description > 0 then
        out[#out + 1] = "[[" .. (n.target or "") .. "][" .. emit_inline(n.description) .. "]]"
      else
        out[#out + 1] = "[[" .. (n.target or "") .. "]]"
      end
    elseif n.kind == "linebreak" then
      out[#out + 1] = "\n"
    elseif n.kind == "image" then
      out[#out + 1] = "[[" .. (n.target or "") .. "]]"
    elseif n.kind == "entity" then
      out[#out + 1] = "\\" .. (n.name or "")
    elseif n.kind == "subscript" then
      out[#out + 1] = "_{" .. emit_inline(n.content) .. "}"
    elseif n.kind == "superscript" then
      out[#out + 1] = "^{" .. emit_inline(n.content) .. "}"
    elseif n.kind == "statistics_cookie" then
      out[#out + 1] = n.value or ""
    elseif n.kind == "timestamp" then
      out[#out + 1] = n.value or ""
    elseif n.kind == "target" then
      out[#out + 1] = "<<" .. (n.name or "") .. ">>"
    elseif n.kind == "macro" then
      if n.args and #n.args > 0 then
        out[#out + 1] = "{{{" .. (n.name or "") .. "(" .. table.concat(n.args, ",") .. ")}}}"
      else
        out[#out + 1] = "{{{" .. (n.name or "") .. "}}}"
      end
    elseif n.kind == "footnote_ref" then
      if n.content and #n.content > 0 then
        if n.label then
          out[#out + 1] = "[fn:" .. n.label .. ":" .. emit_inline(n.content) .. "]"
        else
          out[#out + 1] = "[fn::" .. emit_inline(n.content) .. "]"
        end
      else
        out[#out + 1] = "[fn:" .. (n.label or "") .. "]"
      end
    elseif n.kind == "raw_inline" then
      out[#out + 1] = n.text or ""
    elseif n.kind == "math" then
      local style = n.style or "dollar"
      if style == "paren" then
        out[#out + 1] = "\\(" .. (n.body or "") .. "\\)"
      elseif style == "bracket" then
        out[#out + 1] = "\\[" .. (n.body or "") .. "\\]"
      elseif n.display then
        out[#out + 1] = "$$" .. (n.body or "") .. "$$"
      else
        out[#out + 1] = "$" .. (n.body or "") .. "$"
      end
    end
  end
  return table.concat(out)
end

local function emit_paragraph(node, out)
  out[#out + 1] = emit_inline(node.inline)
  out[#out + 1] = ""
end

local function emit_code_block(node, out)
  local header = "#+begin_src " .. (node.language or "")
  if node.params and node.params ~= "" then
    header = header .. " " .. node.params
  end
  out[#out + 1] = header
  for line in (node.body or ""):gmatch("([^\n]*)\n?") do
    out[#out + 1] = line
  end
  -- The gmatch above appends a trailing empty after the final newline;
  -- if the body ended without newline that's fine too -- the `#+end`
  -- still lands on its own line.
  if out[#out] == "" then
    out[#out] = nil
  end
  out[#out + 1] = "#+end_src"
  out[#out + 1] = ""
end

local function emit_list(node, out, depth)
  depth = depth or 0
  local indent = string.rep("  ", depth)
  local n = 1
  for _, item in ipairs(node.items or {}) do
    local marker = node.ordered and (n .. ".") or "-"
    local checkbox = ""
    if item.checkbox == "todo" then
      checkbox = "[ ] "
    elseif item.checkbox == "done" then
      checkbox = "[X] "
    elseif item.checkbox == "part" then
      checkbox = "[-] "
    end
    -- A list_item.content is a list of blocks; render them, prefixing
    -- the first paragraph's first line with the marker.
    local first = true
    for _, b in ipairs(item.content or {}) do
      if b.kind == "paragraph" then
        local txt = emit_inline(b.inline)
        if first then
          out[#out + 1] = indent .. marker .. " " .. checkbox .. txt
          first = false
        else
          out[#out + 1] = indent .. "  " .. txt
        end
      elseif b.kind == "list" then
        emit_list(b, out, depth + 1)
      end
    end
    n = n + 1
  end
  out[#out + 1] = ""
end

local function emit_table(node, out)
  local ncols = #(node.alignments or {})
  if ncols == 0 and node.rows and node.rows[1] then
    ncols = #(node.rows[1].cells or {})
  end
  for _, row in ipairs(node.rows or {}) do
    if row.sep then
      local sep_cells = {}
      for _ = 1, math.max(1, ncols) do
        sep_cells[#sep_cells + 1] = "----"
      end
      out[#out + 1] = "|" .. table.concat(sep_cells, "+") .. "|"
    else
      local cells = {}
      for _, cell in ipairs(row.cells or {}) do
        cells[#cells + 1] = " " .. emit_inline(cell) .. " "
      end
      out[#out + 1] = "|" .. table.concat(cells, "|") .. "|"
    end
  end
  if node.tblfm then
    for _, f in ipairs(node.tblfm) do
      out[#out + 1] = "#+TBLFM: " .. f
    end
  end
  out[#out + 1] = ""
end

local function emit_headline(node, out)
  local stars = string.rep("*", node.level or 1)
  local pieces = { stars }
  if node.todo then
    pieces[#pieces + 1] = node.todo
  end
  if node.priority then
    pieces[#pieces + 1] = "[#" .. node.priority .. "]"
  end
  pieces[#pieces + 1] = emit_inline(node.title)
  local left = table.concat(pieces, " ")
  local block = ""
  if node.tags and #node.tags > 0 then
    block = ":" .. table.concat(node.tags, ":") .. ":"
  end
  local format = require("organ.format")
  out[#out + 1] = format.align_tag_block(left, block)
  -- Planning, one keyword per line in canonical order; timestamp strings
  -- already carry their <...> / [...] brackets.
  if node.planning then
    if node.planning.scheduled then
      out[#out + 1] = "SCHEDULED: " .. node.planning.scheduled
    end
    if node.planning.deadline then
      out[#out + 1] = "DEADLINE: " .. node.planning.deadline
    end
    if node.planning.closed then
      out[#out + 1] = "CLOSED: " .. node.planning.closed
    end
  end
  -- Properties drawer; keys sorted for deterministic output (the AST
  -- models properties as an unordered map).
  if node.properties and next(node.properties) then
    out[#out + 1] = ":PROPERTIES:"
    local keys = {}
    for k in pairs(node.properties) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      out[#out + 1] = ":" .. k .. ": " .. node.properties[k]
    end
    out[#out + 1] = ":END:"
  end
  for _, c in ipairs(node.children or {}) do
    M._emit_block(c, out)
  end
end

local function emit_block(node, out)
  if node.affiliated then
    for _, kw in ipairs(node.affiliated) do
      out[#out + 1] = "#+" .. kw.name .. ": " .. (kw.value or "")
    end
  end
  if node.kind == "headline" then
    emit_headline(node, out)
  elseif node.kind == "paragraph" then
    emit_paragraph(node, out)
  elseif node.kind == "code_block" then
    emit_code_block(node, out)
  elseif node.kind == "list" then
    emit_list(node, out, 0)
  elseif node.kind == "rule" then
    out[#out + 1] = "-----"
    out[#out + 1] = ""
  elseif node.kind == "directive" then
    out[#out + 1] = "#+" .. node.name .. ": " .. (node.value or "")
  elseif node.kind == "block" then
    local style = node.style or "quote"
    local begin = "#+begin_" .. style
    if style == "export" and node.backend and node.backend ~= "" then
      begin = begin .. " " .. node.backend
    end
    out[#out + 1] = begin
    if node.body then
      for line in (node.body or ""):gmatch("([^\n]*)\n?") do
        out[#out + 1] = line
      end
      -- gmatch appends a trailing empty after the final newline-less body;
      -- drop it so #+end_<style> lands immediately after the last body line.
      if out[#out] == "" then
        out[#out] = nil
      end
    elseif node.content then
      for _, c in ipairs(node.content) do
        emit_block(c, out)
      end
    end
    out[#out + 1] = "#+end_" .. style
    out[#out + 1] = ""
  elseif node.kind == "table" then
    emit_table(node, out)
  elseif node.kind == "image" then
    -- Block-level image: render the link form on its own line.
    if node.alt and node.alt ~= "" then
      out[#out + 1] = "[[" .. (node.target or "") .. "][" .. node.alt .. "]]"
    else
      out[#out + 1] = "[[" .. (node.target or "") .. "]]"
    end
    out[#out + 1] = ""
  elseif node.kind == "footnote_definition" then
    -- Render as `[fn:LABEL] <paragraph content>` on one line, then blank.
    local first_body = ""
    if node.content and node.content[1] and node.content[1].kind == "paragraph" then
      first_body = emit_inline(node.content[1].inline)
    end
    out[#out + 1] = "[fn:" .. (node.label or "") .. "] " .. first_body
    -- Additional paragraphs in content render below, indented like
    -- continuation lines.
    if node.content and #node.content > 1 then
      for i = 2, #node.content do
        local b = node.content[i]
        if b.kind == "paragraph" then
          out[#out + 1] = "  " .. emit_inline(b.inline)
        end
      end
    end
    out[#out + 1] = ""
  elseif node.kind == "drawer" then
    out[#out + 1] = ":" .. (node.name or "") .. ":"
    if node.body and node.body ~= "" then
      for _, line in ipairs(vim.split(node.body, "\n", { plain = true })) do
        out[#out + 1] = line
      end
    end
    out[#out + 1] = ":END:"
    out[#out + 1] = ""
  elseif node.kind == "comment" then
    -- Each body line becomes `#<line>`; the captured body already
    -- includes the leading space after `#`.
    for _, line in ipairs(vim.split(node.body or "", "\n", { plain = true })) do
      out[#out + 1] = "#" .. line
    end
    out[#out + 1] = ""
  end
  -- Other kinds drop silently (unimplemented in this renderer).
end
M._emit_block = emit_block

function M.render(doc)
  local out = {}
  for _, c in ipairs(doc.children or {}) do
    emit_block(c, out)
  end
  -- Trim trailing empties.
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return table.concat(out, "\n") .. "\n"
end

return M
