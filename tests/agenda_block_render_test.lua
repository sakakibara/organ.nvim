-- Unit tests for agenda.render orchestrator (block-list shape).
-- Run via: nvim --headless -l tests/agenda_block_render_test.lua

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

local function find_line(lines, prefix)
  for i, l in ipairs(lines) do
    if l:sub(1, #prefix) == prefix then
      return i, l
    end
  end
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

----------------------------------------------------------------------
-- Two labeled blocks, disjoint rows.
do
  local r1 = { mk("a", "T1", "TODO", "A", "2026-04-26", nil, nil, {}, "/a.org", 1) }
  local r2 = { mk("b", "T2", "NEXT", nil, nil, nil, nil, {}, "/b.org", 2) }
  local out = agenda.render({
    { block = { label = "Today", group_by = "day" }, rows = r1 },
    { block = { label = "Inbox", group_by = "none" }, rows = r2 },
  }, { now = "2026-04-26" })

  -- Two block headers in the right order.
  local i1, l1 = find_line(out.lines, "══ Today")
  local i2, l2 = find_line(out.lines, "══ Inbox")
  assert(i1 and i2, "both block headers present")
  assert(i1 < i2, "Today appears before Inbox")
  assert(l1:find("%(1%)"), "Today count is 1")
  assert(l2:find("%(1%)"), "Inbox count is 1")

  -- block_starts map.
  assert_eq(out.block_starts[i1], 1)
  assert_eq(out.block_starts[i2], 2)
end

----------------------------------------------------------------------
-- Empty block renders header + (nothing) placeholder.
do
  local out = agenda.render({
    { block = { label = "Empty", group_by = "none" }, rows = {} },
  }, { now = "2026-04-26" })
  local hi, hline = find_line(out.lines, "══ Empty")
  assert(hi, "header rendered for empty block")
  assert(hline:find("%(0%)"), "count is 0")
  local pi = find_line(out.lines, "  (nothing)")
  assert(pi == hi + 1, "(nothing) line directly under header")
end

----------------------------------------------------------------------
-- Labelless block (wrapped-flat case): no block-header line.
do
  local r = { mk("a", "T", "TODO", "A", "2026-04-26", nil, nil, {}, "/a.org", 1) }
  local out = agenda.render({
    { block = { group_by = "day" }, rows = r },
  }, { now = "2026-04-26" })
  for _, l in ipairs(out.lines) do
    if l:sub(1, 6) == "══" then
      error("labelless block must not emit ══ header line")
    end
  end
  -- block_starts is empty (no labeled blocks).
  assert_eq(next(out.block_starts), nil, "block_starts empty for labelless single block")
end

----------------------------------------------------------------------
-- Per-block include_overdue: bucket appears INSIDE the block, not at buffer top.
do
  local overdue = mk("od", "Old", "TODO", "A", nil, "2026-04-01", nil, {}, "/a.org", 1)
  local upcoming = mk("up", "New", "TODO", "B", "2026-04-26", nil, nil, {}, "/b.org", 2)
  local out = agenda.render({
    {
      block = { label = "Future", group_by = "day", include_overdue = false },
      rows = { upcoming },
    },
    { block = { label = "Past", group_by = "day", include_overdue = true }, rows = { overdue } },
  }, { now = "2026-04-26" })

  local fi = find_line(out.lines, "══ Future")
  local pi = find_line(out.lines, "══ Past")
  local oi = find_line(out.lines, "Overdue")
  assert(fi and pi and oi, "all headers present")
  assert(oi > pi, "Overdue appears AFTER the Past block header (i.e. inside Past, not at top)")
end

----------------------------------------------------------------------
-- Mixed group_by: block A flat (none), block B day-grouped.
do
  local r1 = { mk("a", "T1", "TODO", "A", nil, nil, nil, {}, "/a.org", 1) }
  local r2 = { mk("b", "T2", "TODO", "B", "2026-04-26", nil, nil, {}, "/b.org", 2) }
  local out = agenda.render({
    { block = { label = "Flat", group_by = "none" }, rows = r1 },
    { block = { label = "Days", group_by = "day" }, rows = r2 },
  }, { now = "2026-04-26" })
  -- Flat block has no date headers.
  local fi = find_line(out.lines, "══ Flat")
  local di = find_line(out.lines, "══ Days")
  for i = fi + 1, di - 1 do
    assert(not out.lines[i]:match("^%a+%s+%d+%s+%a+%s+2026"), "no date header inside Flat block")
  end
  -- Days block has at least one date header.
  local has_day = false
  for i = di + 1, #out.lines do
    if out.lines[i]:match("^%a+%s+%d+%s+%a+%s+2026") then
      has_day = true
      break
    end
  end
  assert(has_day, "Days block has a date header")
end

----------------------------------------------------------------------
-- line_index spans rows across blocks; header / (nothing) lines have no entry.
do
  local r1 = { mk("a", "T1", "TODO", "A", "2026-04-26", nil, nil, {}, "/a.org", 11) }
  local r2 = { mk("b", "T2", "TODO", "B", "2026-04-26", nil, nil, {}, "/b.org", 22) }
  local out = agenda.render({
    { block = { label = "A", group_by = "none" }, rows = r1 },
    { block = { label = "B", group_by = "none" }, rows = {} },
    { block = { label = "C", group_by = "none" }, rows = r2 },
  }, { now = "2026-04-26" })
  local count = 0
  for lnum, row in pairs(out.line_index) do
    count = count + 1
    assert(row.id == "a" or row.id == "b", "line_index entries are real rows")
    -- Header lines must not be in line_index.
    assert(not out.lines[lnum]:match("^══"), "header line not in line_index")
    assert(not out.lines[lnum]:match("^  %(nothing%)"), "(nothing) not in line_index")
  end
  assert_eq(count, 2, "two row entries total")
end

----------------------------------------------------------------------
-- Calling render twice with different `opts.now` does not pin the
-- block to the first call's now. Regression for #now-mutation bug.
do
  local r = { mk("a", "T", "TODO", "A", "2026-04-26", nil, nil, {}, "/a.org", 1) }
  local block = { label = "Today", group_by = "day", include_overdue = true }
  local items = { { block = block, rows = r } }

  agenda.render(items, { now = "2026-04-26" })
  -- The block table itself must not have been mutated.
  assert_eq(block.now, nil, "render must not write opts.now into block")

  -- Second render with a different now is observable: row sched=2026-04-26
  -- is "today" relative to 2026-04-26 but neither today nor overdue relative
  -- to 2026-04-25. The day-header for the row's date is "Sun 2026-04-26"
  -- in both, so we just confirm the call doesn't crash and the block stays clean.
  agenda.render(items, { now = "2026-04-25" })
  assert_eq(block.now, nil, "render must still not write opts.now into block")
end

----------------------------------------------------------------------
-- Labelless empty block produces no output (no (nothing) placeholder
-- without a label to anchor it). Preserves flat-view byte-equivalence.
do
  local out = agenda.render({
    { block = { group_by = "day" }, rows = {} },
  }, { now = "2026-04-26" })
  assert_eq(#out.lines, 0, "labelless empty block emits no lines")
  assert_eq(next(out.line_index), nil, "no line_index entries")
  assert_eq(next(out.block_starts), nil, "no block_starts entries")
end

----------------------------------------------------------------------
-- Per-block query error: failing block renders error line, sibling unaffected.
do
  local good = mk("a", "T", "TODO", "A", "2026-04-26", nil, nil, {}, "/a.org", 1)
  local out = agenda.render({
    { block = { label = "Failed", group_by = "none" }, rows = {}, query_error = "DB locked" },
    { block = { label = "OK", group_by = "none" }, rows = { good } },
  }, { now = "2026-04-26" })

  -- Failed block: header with count 0, then a "(query error: DB locked)" line.
  local fi = find_line(out.lines, "══ Failed")
  local oki = find_line(out.lines, "══ OK")
  assert(fi and oki, "both block headers present")
  local err_line = out.lines[fi + 1]
  assert(
    err_line and err_line:find("query error"),
    "query error line present, got: " .. tostring(err_line)
  )
  assert(err_line:find("DB locked"), "error includes the original reason")

  -- Sibling block "OK" still has its row.
  local row_count = 0
  for _, _ in pairs(out.line_index) do
    row_count = row_count + 1
  end
  assert_eq(row_count, 1, "sibling block has its row")
end

io.write("agenda block render ok\n")
