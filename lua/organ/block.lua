-- Line-based `#+begin_X` / `#+end_X` scope, shared by the formatter and
-- by list structure parsing.  A `#+begin_X` opens a block only when a
-- matching `#+end_X` follows before the next headline; without one, org
-- reads the line and everything under it as ordinary text -- verified
-- against `org-element-at-point`.

local M = {}

-- Blocks whose body org-element parses as raw text rather than as
-- elements, so a `|` or `1.` line inside one is NOT a table or a list
-- item.  Every other block name is a special block (a greater element),
-- and drawers hold elements too -- verified against
-- `org-element-at-point` / `org-at-table-p` / `org-at-item-p`.
M.VERBATIM = {
  comment = true,
  example = true,
  export = true,
  src = true,
  verse = true,
}

-- The subset of `VERBATIM` whose body holds no objects either, so a
-- timestamp or an emphasis marker inside one is inert text.  `verse` is
-- absent: org parses the objects in a verse body -- verified against
-- `org-element-context`.
M.NO_OBJECTS = {
  comment = true,
  example = true,
  export = true,
  src = true,
}

-- Lowercased name of the block `line` would open, or nil.
function M.open_name(line)
  local name = line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_([%a][%w-]*)")
  return name and name:lower() or nil
end

-- Row of the `#+end_X` closing the block opened at row `i`, or nil when
-- `i` opens nothing.  `tail` continues `lines` past its end, so a range
-- can see a close that sits below it.
function M.close_row(lines, i, tail)
  local name = M.open_name(lines[i] or "")
  if not name then
    return nil
  end
  local n = #lines + #(tail or {})
  for j = i + 1, n do
    local l = j <= #lines and lines[j] or tail[j - #lines]
    if l:match("^%*+ ") then
      return nil
    end
    local close = l:match("^%s*#%+[Ee][Nn][Dd]_([%a][%w-]*)%s*$")
    if close and close:lower() == name then
      return j
    end
  end
  return nil
end

-- Set of 1-based row numbers that fall inside the body of a block whose
-- name is in `names` (default `VERBATIM`).
function M.verbatim_rows(lines, names)
  names = names or M.VERBATIM
  local rows = {}
  local i, n = 1, #lines
  while i <= n do
    local name = M.open_name(lines[i])
    local close = name and names[name] and M.close_row(lines, i)
    if close then
      for j = i + 1, close - 1 do
        rows[j] = true
      end
      i = close + 1
    else
      i = i + 1
    end
  end
  return rows
end

return M
