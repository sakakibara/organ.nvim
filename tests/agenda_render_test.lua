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

-- Day buckets stay inside the requested window; past scheduled/deadline
-- items and deadline warnings sit on today's line (Emacs shows them only
-- in the today agenda), so they vanish when today is outside the window.
require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  agenda = { footer = false, tags_virt_align = false, time_grid = false, now_marker = false },
})

local function render_week(block, rows, now)
  local out = agenda.render({ { block = block, rows = rows } }, { now = now })
  return table.concat(out.lines, "\n")
end

local function lines_under(joined, header_prefix)
  local collected, active = {}, false
  for line in (joined .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%u%l+%s+%d+ %u") then
      active = line:sub(1, #header_prefix) == header_prefix
    elseif active and line ~= "" then
      collected[#collected + 1] = line
    end
  end
  return collected
end

local week = { from = "2026-05-04", to = "2026-05-10", kind = "agenda" }

-- A deadline beyond the window never opens a bucket outside it; an
-- overdue deadline lands on today's line.
do
  local joined = render_week(week, {
    mk("x", "deadline June 15", "TODO", nil, "2026-05-05", "2026-06-15"),
    mk("y", "deadline May 1", "TODO", nil, "2026-05-05", "2026-05-01"),
  }, "2026-05-06")
  assert(not joined:find("June 2026", 1, true), "bucket outside window:\n" .. joined)
  local monday = table.concat(lines_under(joined, "Monday      4 May"), "\n")
  assert(
    not monday:find("deadline May 1", 1, true),
    "overdue deadline on window start:\n" .. joined
  )
  local wednesday = table.concat(lines_under(joined, "Wednesday   6 May"), "\n")
  assert(
    wednesday:find("deadline May 1", 1, true),
    "overdue deadline missing from today:\n" .. joined
  )
  local tuesday = table.concat(lines_under(joined, "Tuesday     5 May"), "\n")
  assert(
    tuesday:find("Scheduled:  TODO deadline May 1", 1, true),
    "scheduled day lost:\n" .. joined
  )
  assert(
    tuesday:find("Scheduled:  TODO deadline June 15", 1, true),
    "scheduled day lost:\n" .. joined
  )
end

-- Deadline pre-warnings are a today-only reminder.
do
  local block = { from = "2026-05-11", to = "2026-05-17", kind = "agenda" }
  local joined = render_week(block, {
    mk("z", "deadline May 13", "TODO", nil, nil, "2026-05-13"),
  }, "2026-05-06")
  assert(not joined:find("In   ", 1, true), "warning rendered while today is outside:\n" .. joined)
  assert(joined:find("Deadline:   TODO deadline May 13", 1, true), "deadline day row:\n" .. joined)
  joined = render_week(week, {
    mk("z", "deadline May 13", "TODO", nil, nil, "2026-05-13"),
  }, "2026-05-06")
  local wednesday = table.concat(lines_under(joined, "Wednesday   6 May"), "\n")
  assert(
    wednesday:find("In   7 d.:  TODO deadline May 13", 1, true),
    "warning on today:\n" .. joined
  )
end

-- Overdue scheduled rows (repeating or not) sit on today's line only.
do
  local rows = {
    mk("r", "weekly from Apr 29", "TODO", nil, "2026-04-29"),
    mk("n", "plain from Apr 29", "TODO", nil, "2026-04-29"),
  }
  rows[1].scheduled = "<2026-04-29 Wed +1w>"
  rows[2].scheduled = "<2026-04-29 Wed>"
  local joined = render_week(week, rows, "2026-05-06")
  local monday = table.concat(lines_under(joined, "Monday      4 May"), "\n")
  assert(monday == "", "overdue rows on window start:\n" .. joined)
  local wednesday = lines_under(joined, "Wednesday   6 May")
  assert(#wednesday == 2, "today shows each overdue row once:\n" .. joined)
  assert(wednesday[1]:find("Sched. 7x:  TODO weekly from Apr 29", 1, true), wednesday[1])
  assert(wednesday[2]:find("Sched. 7x:  TODO plain from Apr 29", 1, true), wednesday[2])
  joined =
    render_week({ from = "2026-05-11", to = "2026-05-17", kind = "agenda" }, rows, "2026-05-06")
  assert(not joined:find("Sched.", 1, true), "overdue rows while today is outside:\n" .. joined)
  assert(joined:find("Scheduled:  TODO weekly from Apr 29", 1, true), "future repeat:\n" .. joined)
end

-- order_within_group descending compares numbers numerically.
do
  local rows = {}
  for _, lvl in ipairs({ 2, 10, 9 }) do
    local r = mk("l" .. lvl, "level " .. lvl, "TODO")
    r.level = lvl
    rows[#rows + 1] = r
  end
  local out = agenda.render({
    {
      block = { kind = "todo", group_by = "none", order_within_group = { { "level", "desc" } } },
      rows = rows,
    },
  }, { now = "2026-05-06" })
  local got = {}
  for _, l in ipairs(out.lines) do
    got[#got + 1] = l:match("level %d+")
  end
  assert(table.concat(got, ",") == "level 10,level 9,level 2", table.concat(got, ","))
end

-- The TODO column is padded by display width, not bytes.
do
  local a = mk("j", "japanese kw", "\228\189\156\230\165\173")
  local b = mk("t", "ascii kw", "TODO")
  local out = agenda.render({ { block = { kind = "todo", group_by = "none" }, rows = { a, b } } }, {
    now = "2026-05-06",
  })
  local cols = {}
  for _, line in ipairs(out.lines) do
    local s = line:find("japanese kw", 1, true) or line:find("ascii kw", 1, true)
    if s then
      cols[#cols + 1] = vim.fn.strdisplaywidth(line:sub(1, s - 1))
    end
  end
  assert(#cols == 2 and cols[1] == cols[2], "title columns differ: " .. vim.inspect(cols))
end

-- A `+0d` repeater is void (Emacs `org-closest-date`): the row renders
-- once and the expansion terminates.
do
  local r = mk("z", "zero repeater", "TODO", nil, "2026-05-01")
  r.scheduled = "<2026-05-01 Fri +0d>"
  jit.off()
  debug.sethook(function()
    error("instruction budget exceeded")
  end, "", 1e8)
  local ok, res = pcall(render_week, week, { r }, "2026-05-06")
  debug.sethook()
  jit.on()
  assert(ok, tostring(res))
  local wednesday = lines_under(res, "Wednesday   6 May")
  assert(#wednesday == 1 and wednesday[1]:find("Sched. 5x:  TODO zero repeater", 1, true), res)
end

-- A repeating entry shows on its base date, on today, and on repeats
-- strictly after today -- never on the days between its base date and
-- today.  Expectations transcribed from Emacs 30.2 `org-agenda-list`
-- over the same five entries, rendered for 2026-05-06.
do
  local function rep_row(id, title, date, raw)
    local r = mk(id, title, "TODO", nil, date)
    r.scheduled = raw
    return r
  end
  local joined = render_week(week, {
    rep_row("a", "daily from May 5", "2026-05-05", "<2026-05-05 Tue +1d>"),
    rep_row("b", "weekly from May 5", "2026-05-05", "<2026-05-05 Tue +1w>"),
    rep_row("c", "daily from May 4", "2026-05-04", "<2026-05-04 Mon +1d>"),
    rep_row("d", "threeday from May 5", "2026-05-05", "<2026-05-05 Tue +3d>"),
    rep_row("e", "daily from Apr 29", "2026-04-29", "<2026-04-29 Wed +1d>"),
  }, "2026-05-06")
  local expected = {
    ["Monday      4 May"] = { "Scheduled:  TODO daily from May 4" },
    ["Tuesday     5 May"] = {
      "Scheduled:  TODO daily from May 5",
      "Scheduled:  TODO threeday from May 5",
      "Scheduled:  TODO weekly from May 5",
    },
    ["Wednesday   6 May"] = {
      "Sched. 1x:  TODO daily from May 5",
      "Sched. 1x:  TODO threeday from May 5",
      "Sched. 1x:  TODO weekly from May 5",
      "Sched. 2x:  TODO daily from May 4",
      "Sched. 7x:  TODO daily from Apr 29",
    },
    ["Thursday    7 May"] = {
      "Scheduled:  TODO daily from Apr 29",
      "Scheduled:  TODO daily from May 4",
      "Scheduled:  TODO daily from May 5",
    },
    ["Friday      8 May"] = {
      "Scheduled:  TODO daily from Apr 29",
      "Scheduled:  TODO daily from May 4",
      "Scheduled:  TODO daily from May 5",
      "Scheduled:  TODO threeday from May 5",
    },
    ["Saturday    9 May"] = {
      "Scheduled:  TODO daily from Apr 29",
      "Scheduled:  TODO daily from May 4",
      "Scheduled:  TODO daily from May 5",
    },
    ["Sunday      10 May"] = {
      "Scheduled:  TODO daily from Apr 29",
      "Scheduled:  TODO daily from May 4",
      "Scheduled:  TODO daily from May 5",
    },
  }
  for header, want in pairs(expected) do
    local got = {}
    for _, line in ipairs(lines_under(joined, header)) do
      got[#got + 1] = line:gsub("^%s*%S+%s+", "")
    end
    table.sort(got)
    assert(
      table.concat(got, "\n") == table.concat(want, "\n"),
      header .. ":\nwant\n" .. table.concat(want, "\n") .. "\ngot\n" .. table.concat(got, "\n")
    )
  end
end

io.write("agenda render ok\n")
os.exit(0)
