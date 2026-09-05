-- Drawer helpers shared by todo.lua / clock/writer.lua / logbook.lua.
-- Tree-sitter walks via `element.lua` when the parser is loaded;
-- regex fallback when not (e.g. early boot, scratch buffers).

local M = {}

-- Walk the section under headline at row `hl_row` (0-based) for a
-- drawer named `drawer_name` (case-insensitive).  Returns the node
-- or nil.
local function find_named_drawer_node(bufnr, hl_row, drawer_name)
  local element = require("organ.element")
  if not element.parser_loaded(bufnr) then
    return nil
  end
  local h = element.headline_at(bufnr, hl_row)
  if not (h and h.node) then
    return nil
  end
  local target = drawer_name:upper()
  for child in h.node:iter_children() do
    if child:type() == "section" then
      for c in child:iter_children() do
        if c:type() == "drawer" then
          for f in c:iter_children() do
            if f:type() == "drawer_name" then
              local sr, sc, _, ec = f:range()
              local txt = vim.api.nvim_buf_get_text(bufnr, sr, sc, sr, ec, {})[1] or ""
              if txt:upper() == target then
                return c
              end
              break
            end
          end
        end
      end
      return nil -- section seen, no match
    end
  end
  return nil
end

-- Find the named drawer's open and end line indices (1-based, inclusive)
-- under the headline at 1-based `hl_line`.  `bufnr` may be nil — in
-- that case we use the regex fallback path on `buf_lines`.  Skips
-- planning lines + the property drawer.  Returns (start, end) or
-- (nil, nil).
function M.find(buf_lines, hl_line, drawer_name, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local node = find_named_drawer_node(bufnr, hl_line - 1, drawer_name)
  if node then
    local sr, _, er = node:range()
    return sr + 1, er
  end
  -- Regex fallback: walk forward, skip planning + property drawer.
  local i = hl_line + 1
  while
    i <= #buf_lines
    and (
      buf_lines[i]:match("^%s*SCHEDULED:")
      or buf_lines[i]:match("^%s*DEADLINE:")
      or buf_lines[i]:match("^%s*CLOSED:")
    )
  do
    i = i + 1
  end
  if buf_lines[i] and buf_lines[i]:match("^%s*:PROPERTIES:") then
    i = i + 1
    -- Stop at the next headline: an unterminated drawer must not consume
    -- the following section.
    while
      i <= #buf_lines
      and not buf_lines[i]:match("^%s*:END:")
      and not buf_lines[i]:match("^%*+ ")
    do
      i = i + 1
    end
    if buf_lines[i] and buf_lines[i]:match("^%s*:END:") then
      i = i + 1
    end
  end
  if buf_lines[i] and buf_lines[i]:match("^%s*:" .. drawer_name .. ":") then
    local start = i
    i = i + 1
    while
      i <= #buf_lines
      and not buf_lines[i]:match("^%s*:END:")
      and not buf_lines[i]:match("^%*+ ")
    do
      i = i + 1
    end
    -- A drawer with no :END: before the next headline is malformed; not a
    -- range we can safely report.
    if buf_lines[i] and buf_lines[i]:match("^%s*:END:") then
      return start, i
    end
    return nil, nil
  end
  return nil, nil
end

-- 1-based line index where a fresh drawer should be inserted (after
-- planning + after any property drawer).
--
-- When `bufnr` is nil, the regex fallback runs against `buf_lines`.
-- (Don't default to the current buffer — that risks running tree-
-- sitter against an unrelated buffer when the caller is only passing
-- in a Lua array of lines.)
function M.insert_position(buf_lines, hl_line, bufnr)
  local element = require("organ.element")
  if bufnr and element.parser_loaded(bufnr) then
    local pd = element.property_drawer_range(bufnr, hl_line - 1)
    if pd then
      return pd.end_line + 1
    end
    return element.planning_end_line(bufnr, hl_line - 1)
  end
  -- Regex fallback.
  local i = hl_line + 1
  while
    i <= #buf_lines
    and (
      buf_lines[i]:match("^%s*SCHEDULED:")
      or buf_lines[i]:match("^%s*DEADLINE:")
      or buf_lines[i]:match("^%s*CLOSED:")
    )
  do
    i = i + 1
  end
  if buf_lines[i] and buf_lines[i]:match("^%s*:PROPERTIES:") then
    i = i + 1
    -- Stop at the next headline so an unterminated property drawer puts
    -- the insert position at the end of this section, not past the buffer.
    while
      i <= #buf_lines
      and not buf_lines[i]:match("^%s*:END:")
      and not buf_lines[i]:match("^%*+ ")
    do
      i = i + 1
    end
    if buf_lines[i] and buf_lines[i]:match("^%s*:END:") then
      i = i + 1
    end
  end
  return i
end

return M
