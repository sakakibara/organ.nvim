-- Agenda row grouping (org-super-agenda equivalent).
--
-- Within each day-bucket (or block), partition rows by user-defined
-- predicates. Each group renders with its own header. Rows that match
-- no group land in a final "Other" group (unless an explicit catch-
-- all is declared).
--
-- Each group spec is a Lua table with:
--   title   - header text (required)
--   tag     - string or list; matches if row carries any
--   todo    - string or list; matches if row.todo_state is in set
--   priority - string or list; matches if row.priority is in set
--   category - string or list; matches if row's resolved category is in
--   has_time - true → only timed rows (with HH:MM); false → only untimed
--   has_deadline / has_scheduled - true → row has that field
--   pred    - custom function(row) → boolean
--   discard - true → drop matching rows entirely
--
-- Predicates AND together within a single group (e.g. tag=X AND
-- priority=A means both). Multiple groups OR — first-match wins.
--
-- The catch-all group is automatic at the end iff no group has
-- `pred = function() return true end` AND the user didn't write one
-- with no predicates. Set agenda.groups_catch_all_title = "" to
-- suppress the catch-all entirely.

local M = {}

local function as_set(value)
  if value == nil then
    return nil
  end
  if type(value) ~= "table" then
    value = { value }
  end
  local set = {}
  for _, v in ipairs(value) do
    set[v] = true
  end
  return set
end

-- Compile a single group spec into a fast-eval predicate function.
local function compile_group(g)
  local tag_set = as_set(g.tag)
  local todo_set = as_set(g.todo)
  local prio_set = as_set(g.priority)
  local category_set = as_set(g.category)
  local has_pred = g.pred ~= nil
    or g.tag ~= nil
    or g.todo ~= nil
    or g.priority ~= nil
    or g.category ~= nil
    or g.has_time ~= nil
    or g.has_deadline ~= nil
    or g.has_scheduled ~= nil
  return function(row, category_for)
    -- A group with NO predicates always matches → catch-all.
    if not has_pred then
      return true
    end
    if g.pred then
      local ok, hit = pcall(g.pred, row)
      if not ok or not hit then
        return false
      end
    end
    if tag_set then
      local found = false
      for _, t in ipairs(row.tags or {}) do
        if tag_set[t] then
          found = true
          break
        end
      end
      if not found then
        return false
      end
    end
    if todo_set and not todo_set[row.todo_state or false] then
      return false
    end
    if prio_set and not prio_set[row.priority or false] then
      return false
    end
    if category_set then
      local cat = (category_for and category_for(row)) or "?"
      if not category_set[cat] then
        return false
      end
    end
    if g.has_time ~= nil then
      local t = row.scheduled_date and row.scheduled_date:match("T(%d%d:%d%d)")
      local has = t ~= nil
      if g.has_time ~= has then
        return false
      end
    end
    if g.has_deadline ~= nil then
      local has = row.deadline_date and row.deadline_date ~= ""
      if g.has_deadline ~= (has and true or false) then
        return false
      end
    end
    if g.has_scheduled ~= nil then
      local has = row.scheduled_date and row.scheduled_date ~= ""
      if g.has_scheduled ~= (has and true or false) then
        return false
      end
    end
    return true
  end
end

-- Public: partition `rows` by `groups` (list of specs). Returns:
--   { { title = "...", rows = {...} }, ... }
-- in user-declared order, with a final "Other" bucket appended iff
-- there are unmatched rows AND no user catch-all already exists.
function M.partition(rows, groups, opts)
  opts = opts or {}
  if not groups or #groups == 0 then
    return { { title = nil, rows = rows } }
  end
  local compiled = {}
  for _, g in ipairs(groups) do
    compiled[#compiled + 1] = {
      spec = g,
      fn = compile_group(g),
      title = g.title or "(unnamed)",
      rows = {},
    }
  end
  local other = {}
  for _, r in ipairs(rows) do
    local placed = false
    for _, c in ipairs(compiled) do
      if c.fn(r, opts.category_for) then
        if not c.spec.discard then
          c.rows[#c.rows + 1] = r
        end
        placed = true
        break
      end
    end
    if not placed then
      other[#other + 1] = r
    end
  end

  -- Build output in user-declared order; skip groups with `discard`.
  local out = {}
  for _, c in ipairs(compiled) do
    if not c.spec.discard then
      out[#out + 1] = { title = c.title, rows = c.rows }
    end
  end

  -- Catch-all unless the user wrote one OR they suppressed it.
  local has_catchall = false
  for _, c in ipairs(compiled) do
    -- A group is "catch-all" iff it has no filtering predicates set.
    local g = c.spec
    if
      not (
        g.tag
        or g.todo
        or g.priority
        or g.category
        or g.pred
        or g.has_time ~= nil
        or g.has_deadline ~= nil
        or g.has_scheduled ~= nil
      )
    then
      has_catchall = true
    end
  end
  if #other > 0 and not has_catchall then
    local title = opts.catch_all_title
    if title == nil then
      title = "Other"
    end
    if title ~= "" then
      out[#out + 1] = { title = title, rows = other }
    end
  end
  return out
end

return M
