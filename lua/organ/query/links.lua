-- Links and roam API: links_from / links_to by headline id or target,
-- title references, and id lookup.

local M = {}

local exec = require("organ.query.exec")

function M.get_by_id(id, opts)
  opts = opts or {}
  local h = exec.resolve_db(opts)
  local stmt = exec.prepare(
    h,
    "SELECT id, file_path, parent_id, level, title, todo_state, priority, "
      .. "scheduled, deadline, closed, scheduled_date, deadline_date, closed_date, "
      .. "line_start, line_end, commented FROM headlines WHERE id = ?"
  )
  stmt:bind_text(1, id)
  local db = require("organ.db")
  local rc = stmt:step()
  if rc ~= db.SQLITE_ROW then
    stmt:finalize()
    return nil
  end
  local rec = {
    id = stmt:column_text(0),
    file_path = stmt:column_text(1),
    parent_id = stmt:column_text(2),
    level = stmt:column_int(3),
    title = stmt:column_text(4),
    todo_state = stmt:column_text(5),
    priority = stmt:column_text(6),
    scheduled = stmt:column_text(7),
    deadline = stmt:column_text(8),
    closed = stmt:column_text(9),
    scheduled_date = stmt:column_text(10),
    deadline_date = stmt:column_text(11),
    closed_date = stmt:column_text(12),
    line_start = stmt:column_int(13),
    line_end = stmt:column_int(14),
    commented = stmt:column_int(15) == 1,
    tags = {},
  }
  stmt:finalize()
  return rec
end

function M.links_from(headline_id, opts)
  opts = opts or {}
  local h = exec.resolve_db(opts)
  local stmt = exec.prepare(
    h,
    [[
    SELECT l.target_type, l.target, l.description, l.line,
           h.id, h.file_path, h.title, h.line_start,
           h.todo_state, h.priority
      FROM links l
      LEFT JOIN headlines h
        ON l.target_type = 'id' AND l.target = h.id
     WHERE l.source_headline_id = ?
     ORDER BY l.line
  ]]
  )
  stmt:bind_text(1, headline_id)
  local db = require("organ.db")
  local rows = {}
  while stmt:step() == db.SQLITE_ROW do
    local target_headline
    local th_id = stmt:column_text(4)
    if th_id and th_id ~= "" then
      target_headline = {
        id = th_id,
        file_path = stmt:column_text(5),
        title = stmt:column_text(6),
        line_start = stmt:column_int(7),
        todo_state = stmt:column_text(8),
        priority = stmt:column_text(9),
      }
    end
    rows[#rows + 1] = {
      target_type = stmt:column_text(0),
      target = stmt:column_text(1),
      description = stmt:column_text(2),
      line = stmt:column_int(3),
      target_headline = target_headline,
    }
  end
  stmt:finalize()
  return rows
end

function M.links_to(target, opts)
  opts = opts or {}
  local h = exec.resolve_db(opts)
  local id
  if type(target) == "string" then
    id = target
  elseif type(target) == "table" and target.id then
    id = target.id
  else
    error("query.links_to: target must be id string or headline record")
  end
  local stmt = exec.prepare(
    h,
    [[
    SELECT l.description, l.line, l.target_type, l.target,
           h.id, h.file_path, h.title, h.line_start,
           h.todo_state, h.priority
      FROM links l
      INNER JOIN headlines h ON h.id = l.source_headline_id
     WHERE l.target_type = 'id' AND l.target = ?
     ORDER BY h.file_path, h.line_start
  ]]
  )
  stmt:bind_text(1, id)
  local db = require("organ.db")
  local rows = {}
  while stmt:step() == db.SQLITE_ROW do
    rows[#rows + 1] = {
      description = stmt:column_text(0),
      line = stmt:column_int(1),
      target_type = stmt:column_text(2),
      target = stmt:column_text(3),
      source_headline = {
        id = stmt:column_text(4),
        file_path = stmt:column_text(5),
        title = stmt:column_text(6),
        line_start = stmt:column_int(7),
        todo_state = stmt:column_text(8),
        priority = stmt:column_text(9),
      },
    }
  end
  stmt:finalize()
  return rows
end

-- Title-based references: every `[[*Title]]` link whose target matches
-- `title` (exact-string, case-sensitive -- Emacs's default behavior).
-- Returned shape mirrors `M.links_to` so callers can union the two.
function M.title_refs(title, opts)
  opts = opts or {}
  if type(title) ~= "string" or title == "" then
    return {}
  end
  local h = exec.resolve_db(opts)
  local stmt = exec.prepare(
    h,
    [[
    SELECT l.description, l.line, l.target_type, l.target,
           h.id, h.file_path, h.title, h.line_start,
           h.todo_state, h.priority
      FROM links l
      INNER JOIN headlines h ON h.id = l.source_headline_id
     WHERE l.target_type = 'headline' AND l.target = ?
     ORDER BY h.file_path, h.line_start
  ]]
  )
  stmt:bind_text(1, title)
  local db = require("organ.db")
  local rows = {}
  while stmt:step() == db.SQLITE_ROW do
    rows[#rows + 1] = {
      description = stmt:column_text(0),
      line = stmt:column_int(1),
      target_type = stmt:column_text(2),
      target = stmt:column_text(3),
      source_headline = {
        id = stmt:column_text(4),
        file_path = stmt:column_text(5),
        title = stmt:column_text(6),
        line_start = stmt:column_int(7),
        todo_state = stmt:column_text(8),
        priority = stmt:column_text(9),
      },
    }
  end
  stmt:finalize()
  return rows
end

function M.resolve(target_text)
  return require("organ.link").resolve(target_text)
end

function M.links(filter, opts)
  filter = filter or {}
  opts = opts or {}
  local h = exec.resolve_db(opts)

  local where, params = {}, {}
  if filter.target_type then
    local types = vim.split(filter.target_type, ",", { trimempty = true })
    local placeholders = {}
    for _, t in ipairs(types) do
      placeholders[#placeholders + 1] = "?"
      params[#params + 1] = t
    end
    where[#where + 1] = "l.target_type IN (" .. table.concat(placeholders, ",") .. ")"
  end
  if filter.source_id then
    where[#where + 1] = "l.source_headline_id = ?"
    params[#params + 1] = filter.source_id
  end
  if filter.target then
    where[#where + 1] = "l.target = ?"
    params[#params + 1] = filter.target
  end

  local where_sql = (#where > 0) and ("\nWHERE " .. table.concat(where, " AND ")) or ""

  local sql = [[
    SELECT
      l.source_headline_id,
      l.target_type,
      l.target,
      l.description,
      l.line,
      sh.title      AS source_title,
      sh.file_path  AS source_file,
      sh.line_start AS source_line_start,
      th.id         AS target_headline_id,
      th.title      AS target_headline_title,
      th.file_path  AS target_headline_file,
      th.line_start AS target_headline_line_start
    FROM links l
    INNER JOIN headlines sh ON sh.id = l.source_headline_id
    LEFT  JOIN headlines th ON l.target_type = 'id' AND l.target = th.id
  ]] .. where_sql .. "\nORDER BY sh.file_path, sh.line_start, l.line"

  local rows = {}
  local stmt = exec.prepare(h, sql)
  for i, p in ipairs(params) do
    stmt:bind_text(i, p)
  end
  local db = require("organ.db")
  while stmt:step() == db.SQLITE_ROW do
    local target_headline
    local thid = stmt:column_text(8)
    if thid and thid ~= "" then
      target_headline = {
        id = thid,
        title = stmt:column_text(9),
        file_path = stmt:column_text(10),
        line_start = stmt:column_int(11),
      }
    end
    rows[#rows + 1] = {
      source_headline_id = stmt:column_text(0),
      target_type = stmt:column_text(1),
      target = stmt:column_text(2),
      description = stmt:column_text(3),
      line = stmt:column_int(4),
      source_headline = {
        id = stmt:column_text(0),
        title = stmt:column_text(5),
        file_path = stmt:column_text(6),
        line_start = stmt:column_int(7),
      },
      target_headline = target_headline,
    }
  end
  stmt:finalize()
  return rows
end

return M
