-- OPML 2.0 outline-only export.
--
-- One <outline text="..."> element per headline, nested by org level. Body
-- content is dropped (OPML is an outline interchange format). Optional
-- `_note` attribute carries the first body line for opml readers that
-- display notes (e.g. mind-mapping apps).

local M = {}

local function escape_attr(s)
  if not s then
    return ""
  end
  s = s:gsub("&", "&amp;")
  s = s:gsub('"', "&quot;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub("\n", " ")
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

-- Walk the buffer building a list of { level, title, note }; OPML structure
-- emerges from the level chain.
local function scan(lines, todo_keywords)
  local out, last_hl_idx = {}, nil
  for i, ln in ipairs(lines) do
    local stars = ln:match("^(%*+)%s")
    if stars then
      out[#out + 1] = {
        level = #stars,
        title = clean_title(ln, todo_keywords),
        note = nil,
      }
      last_hl_idx = #out
    elseif
      last_hl_idx
      and not out[last_hl_idx].note
      and not ln:match("^%s*$")
      and not ln:match("^%s*:")
    then
      -- Capture the first non-blank, non-drawer-line as the note.
      out[last_hl_idx].note = ln:gsub("^%s+", "")
    end
  end
  return out
end

-- Convert the flat list into nested OPML <outline> tags. Stack-based: each
-- new level closes any open outlines whose level >= the new one.
local function emit_outlines(items)
  local out = {}
  local stack_level = {}
  local function close_to(target)
    while #stack_level > 0 and stack_level[#stack_level] >= target do
      out[#out + 1] = string.rep("  ", #stack_level + 1) .. "</outline>"
      stack_level[#stack_level] = nil
    end
  end
  for _, it in ipairs(items) do
    close_to(it.level)
    local indent = string.rep("  ", #stack_level + 2)
    local attrs = string.format('text="%s"', escape_attr(it.title))
    if it.note and it.note ~= "" then
      attrs = attrs .. string.format(' _note="%s"', escape_attr(it.note))
    end
    out[#out + 1] = indent .. "<outline " .. attrs .. ">"
    stack_level[#stack_level + 1] = it.level
  end
  close_to(0)
  return out
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
  local lines
  if type(src) == "string" then
    lines = vim.split(src, "\n", { plain = true })
  else
    lines = src
  end
  opts.todo_keywords = opts.todo_keywords
    or (require("organ").config.todo and require("organ").config.todo.sequence)
    or { "TODO", "|", "DONE" }

  local kw = scan_keywords(lines)
  local items = scan(lines, opts.todo_keywords)
  local body = emit_outlines(items)

  local out = {
    [[<?xml version="1.0" encoding="UTF-8"?>]],
    [[<opml version="2.0">]],
    "  <head>",
    "    <title>" .. escape_attr(kw.TITLE or "Org outline") .. "</title>",
    "  </head>",
    "  <body>",
  }
  for _, l in ipairs(body) do
    out[#out + 1] = l
  end
  out[#out + 1] = "  </body>"
  out[#out + 1] = "</opml>"
  return table.concat(out, "\n") .. "\n"
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
