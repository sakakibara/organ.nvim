-- agenda.render uses opts.line_format(record) when supplied, replacing the
-- built-in formatter for record rows.
-- Run via: nvim --headless -l tests/agenda_line_format_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local agenda = require("organ.agenda")

local function mk(id, title, sched)
  return {
    id = id,
    title = title,
    todo_state = nil,
    priority = nil,
    scheduled_date = sched,
    deadline_date = nil,
    closed_date = nil,
    tags = {},
    file_path = "/x.org",
    line_start = 1,
    level = 1,
  }
end

local rows = {
  mk("a", "Alpha", "2026-04-26"),
  mk("b", "Beta", "2026-04-26"),
}

-- Without line_format: built-in formatter is used. The default render
-- mirrors Emacs (`org-agenda-prefix-format` = "  %-12c %?-12t "), so each
-- row begins with the category name (defaulting to filename stem).
do
  local out = agenda.render({
    { block = { group_by = "day" }, rows = rows },
  }, { now = "2026-04-26" })
  local has_category = false
  for _, line in ipairs(out.lines) do
    -- Category for /x.org rows is "x". Look for the row indent + "x".
    if line:match("^%s+x:") then
      has_category = true
      break
    end
  end
  assert(
    has_category,
    "default formatter should emit a category column; lines:\n" .. table.concat(out.lines, "\n")
  )
end

-- With line_format: override returns plain strings. No category prefix
-- emitted by the formatter; only the user's literal text.
do
  local fmt = function(r)
    return ">>> " .. (r.title or "?")
  end
  local out = agenda.render({
    { block = { group_by = "day", line_format = fmt }, rows = rows },
  }, { now = "2026-04-26" })
  local joined = table.concat(out.lines, "\n")
  assert(joined:find(">>> Alpha", 1, true), "custom formatter not used:\n" .. joined)
  assert(joined:find(">>> Beta", 1, true), "custom formatter not used:\n" .. joined)
  -- Headers (date row) still use the built-in markers — only record-row text changes.
  -- New header format: "Sunday    26 April 2026".
  assert(joined:find("26 April 2026", 1, true), "header row should still appear:\n" .. joined)
end

----------------------------------------------------------------------
-- A line_format that raises falls back to the default formatter for
-- that row; render does not crash. The error is recorded for surfacing.
do
  local crash_rows = {
    {
      id = "a",
      title = "T",
      todo_state = "TODO",
      priority = "A",
      scheduled_date = "2026-04-26",
      tags = {},
      file_path = "/x.org",
      line_start = 1,
      level = 1,
    },
  }
  local raises = function(_)
    error("user format crash")
  end
  local block = { label = "X", group_by = "none", line_format = raises }
  local out = agenda.render({ { block = block, rows = crash_rows } }, { now = "2026-04-26" })
  assert(#out.lines >= 2, "header + at least one row")
  assert(
    block._line_format_error and block._line_format_error:find("user format crash"),
    "error sink populated, got: " .. tostring(block._line_format_error)
  )
  -- The row line should be the default formatter's output (contains "TODO"
  -- and the category column "x" derived from /x.org).
  local has_default = false
  for _, l in ipairs(out.lines) do
    if l:find("TODO") and l:match("^%s+x:") then
      has_default = true
    end
  end
  assert(has_default, "default formatter applied for the failing row")
end

io.write("agenda line_format ok\n")
os.exit(0)
