-- tests/calendar_render_test.lua
-- Run via: nvim --headless -l tests/calendar_render_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local cal = require("organ.calendar")

local function find_cell(day_cells, n)
  return day_cells[n]
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

----------------------------------------------------------------------
-- Apr 2026 (Apr 1 is Wed) with week_start=mon places day 1 at col index 2.
do
  local out = cal._render_month(2026, 4, "2026-04-26", "2026-04-15", "mon")
  local cell = find_cell(out.day_cells, 1)
  assert(cell, "day 1 cell exists")
  -- The 7-column layout: cells are 4 chars wide (" DD ", fixed). Wed in
  -- Mon-start is at column index 2 → col_start = 2 * 4 = 8.
  assert_eq(cell.col_start, 8, "Wed column with mon-start: index 2 × 4-char cell")
end

----------------------------------------------------------------------
-- Apr 2026 with week_start=sun: Wed is index 3 → col_start = 3 * 4 = 12.
do
  local out = cal._render_month(2026, 4, "2026-04-26", nil, "sun")
  local cell = find_cell(out.day_cells, 1)
  assert_eq(cell.col_start, 12)
end

----------------------------------------------------------------------
-- February leap year (Feb 2024 has 29).
do
  local out = cal._render_month(2024, 2, nil, nil, "mon")
  assert(find_cell(out.day_cells, 29), "Feb 29 visible in leap year")
  assert_eq(find_cell(out.day_cells, 30), nil, "Feb 30 doesn't exist")
end

----------------------------------------------------------------------
-- February non-leap (Feb 2025).
do
  local out = cal._render_month(2025, 2, nil, nil, "mon")
  assert(find_cell(out.day_cells, 28), "Feb 28 visible")
  assert_eq(find_cell(out.day_cells, 29), nil, "Feb 29 doesn't exist in 2025")
end

----------------------------------------------------------------------
-- today + selected + holiday extmarks present on correct days.
do
  local holidays = { ["2026-04-10"] = true, ["2026-04-26"] = true }
  local out = cal._render_month(2026, 4, "2026-04-26", "2026-04-15", "mon", holidays)
  local has_today, has_selected, has_holiday = false, false, false
  for _, em in ipairs(out.extmarks) do
    if em.hl_group == "@organ.calendar.today" then
      local cell = find_cell(out.day_cells, 26)
      if em.row == cell.row and em.col_start == cell.col_start then
        has_today = true
      end
    end
    if em.hl_group == "@organ.calendar.selected" then
      local cell = find_cell(out.day_cells, 15)
      if em.row == cell.row and em.col_start == cell.col_start then
        has_selected = true
      end
    end
    if em.hl_group == "@organ.calendar.holiday" then
      local cell = find_cell(out.day_cells, 10)
      if em.row == cell.row and em.col_start == cell.col_start then
        has_holiday = true
      end
    end
  end
  assert(has_today, "today extmark on day 26 (precedence: today > holiday for the same cell)")
  assert(has_selected, "selected extmark on day 15")
  assert(has_holiday, "holiday extmark on day 10 (not today, not selected)")
  -- Day 26 is BOTH today AND holiday: today wins (precedence).
  for _, em in ipairs(out.extmarks) do
    if em.hl_group == "@organ.calendar.holiday" then
      local cell = find_cell(out.day_cells, 26)
      assert(
        not (em.row == cell.row and em.col_start == cell.col_start),
        "holiday must not be applied to today cell (today wins)"
      )
    end
  end
end

----------------------------------------------------------------------
-- _move_selection (pure): advance day forward / backward.
do
  local s = { selected_iso = "2026-04-15", year = 2026, month = 4, week_start = "mon" }
  local s2 = cal._move_selection(s, 7)
  assert_eq(s2.selected_iso, "2026-04-22")
  local s3 = cal._move_selection(s, -1)
  assert_eq(s3.selected_iso, "2026-04-14")
  -- Past month end: 2026-04-30 + 1 = 2026-05-01
  local s4 = cal._move_selection(
    { selected_iso = "2026-04-30", year = 2026, month = 4, week_start = "mon" },
    1
  )
  assert_eq(s4.selected_iso, "2026-05-01")
  assert_eq(s4.month, 5)
  assert_eq(s4.year, 2026)
end

----------------------------------------------------------------------
-- _move_month: advance with day clamp.
do
  local s = { selected_iso = "2026-01-31", year = 2026, month = 1, week_start = "mon" }
  local s2 = cal._move_month(s, 1)
  assert_eq(s2.selected_iso, "2026-02-28", "Jan 31 + 1 month → Feb 28 (2026 not leap)")
  assert_eq(s2.month, 2)
end

io.write("calendar render ok\n")
