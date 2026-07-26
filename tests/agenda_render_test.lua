-- Unit tests for agenda.render — pure function over records.
-- Run via: nvim --headless -l tests/agenda_render_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local agenda = require("organ.agenda")

local function mk(id, title, todo, prio, sched, dead, closed, tags, file, line)
  return {
    id = id,
    title = title,
    todo_state = todo,
    priority = prio,
    scheduled_date = sched,
    deadline_date = dead,
    closed_date = closed,
    tags = tags or {},
    file_path = file or "/x.org",
    line_start = line or 1,
    level = 1,
  }
end

-- Default view (group_by = "day", include_overdue = true).
do
  local rows = {
    mk("a", "Old overdue", "TODO", "A", nil, "2026-04-01", nil, { "work" }, "/a.org", 10),
    mk("b", "Tomorrow task", "TODO", "B", "2026-04-24", nil, nil, {}, "/b.org", 20),
    mk("c", "Next week", "NEXT", nil, "2026-04-28T09:30", nil, nil, { "x" }, "/c.org", 30),
    mk("d", "Done", "DONE", nil, nil, nil, "2026-04-20", {}, "/d.org", 40),
  }

  local out = agenda.render({
    {
      block = {
        from = "2026-04-23",
        to = "2026-04-30",
        group_by = "day",
        include_overdue = true,
        order_within_group = { { "priority", "asc" } },
      },
      rows = rows,
    },
  }, { now = "2026-04-23" })

  local joined = table.concat(out.lines, "\n")
  assert(joined:find("Overdue", 1, true), "no Overdue header:\n" .. joined)
  assert(joined:find("Old overdue", 1, true))
  -- Date headers now full Emacs style: "Friday      24 April 2026".
  assert(
    joined:find("24 April 2026", 1, true) or joined:find("2026-04-24", 1, true),
    "no 24 April 2026 header:\n" .. joined
  )
  assert(joined:find("28 April 2026", 1, true) or joined:find("2026-04-28", 1, true))
  -- Time format is now Emacs-style with no leading zero on the hour.
  assert(joined:find("9:30", 1, true), "time prefix missing")

  local has_done_row = joined:find("Done", 1, true)
  assert(
    not has_done_row or joined:find("(No date)", 1, true),
    "Done without scheduled/deadline and not in overdue must either omit or go under No date"
  )

  local any_mapped = false
  for lnum, r in pairs(out.line_index) do
    if r then
      any_mapped = true
      break
    end
  end
  assert(any_mapped, "line_index should have entries")
end

-- group_by = "none" produces a flat list.
do
  local rows = {
    mk("a", "alpha", "TODO", nil, "2026-04-24", nil, nil, {}, "/a.org", 1),
    mk("b", "bravo", "NEXT", nil, "2026-04-25", nil, nil, {}, "/b.org", 2),
  }
  local out = agenda.render({
    { block = {
      group_by = "none",
      include_overdue = false,
    }, rows = rows },
  }, { now = "2026-04-23" })
  local joined = table.concat(out.lines, "\n")
  assert(
    not joined:find("^Mon", 1, true) and not joined:find("^Tue", 1, true),
    "no day headers in 'none' grouping"
  )
end

io.write("agenda render ok\n")
os.exit(0)
