-- Calendar date picker.
--
-- A floating-window mini-calendar used by :Org schedule / :Org deadline /
-- :Org roam daily / capture date prompts.
--
-- Design notes (in response to UX feedback):
--   * Cells are fixed-width (4 chars: " DD ") so the cursor lands on the
--     same column for every day. No more horizontal scroll on selection.
--   * Window width matches the rendered grid exactly so EOL is never
--     beyond the cursor target column.
--   * Every cell is padded with trailing space inside its highlight range,
--     making `selected` / `today` highlights visible across the full cell.
--   * Cursor is hidden via `winhl=Cursor:OrganCalendarCursor` (transparent
--     fg/bg). The selection is shown by the cell's own highlight.
--   * Footer line shows keymaps; toggleable via opt.footer = false.
--   * Optional 3-month layout (opts.three_months = true) renders prev /
--     current / next side-by-side, mirroring Emacs `calendar`.

local M = {}

local WEEKDAY_NAMES_MON = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }
local WEEKDAY_NAMES_SUN = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }

-- Each cell is 4 columns: " DD " (or "    " for padding). 7 cells = 28 cols.
local CELL_WIDTH = 4
local GRID_WIDTH = CELL_WIDTH * 7 -- 28
local INTER_MONTH_GAP = 2
local FOOTER_LINES = {
  "h/l j/k  day  </>  month  t  today  <CR>  pick  q/<Esc>  cancel",
}

local function days_in_month(year, month)
  if month == 2 then
    local leap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
    return leap and 29 or 28
  end
  if month == 4 or month == 6 or month == 9 or month == 11 then
    return 30
  end
  return 31
end

-- 0-based day-of-week for the 1st of (year, month). Mon=0, Sun=6.
local function dow_of_first(year, month, week_start)
  local t = os.time({ year = year, month = month, day = 1, hour = 12 })
  local sun_based = tonumber(os.date("%w", t))
  if week_start == "mon" then
    return (sun_based + 6) % 7
  else
    return sun_based
  end
end

local function parse_iso(iso)
  local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
end

local function format_iso(year, month, day)
  return string.format("%04d-%02d-%02d", year, month, day)
end

-- Render one month into a grid. Returns { lines, extmarks, day_cells } where
-- day_cells[day_number] = { row, col_start, col_end } (1-based row).
function M._render_month(year, month, today_iso, selected_iso, week_start, holiday_set, col_offset)
  week_start = week_start or "mon"
  holiday_set = holiday_set or {}
  col_offset = col_offset or 0
  local names = week_start == "sun" and WEEKDAY_NAMES_SUN or WEEKDAY_NAMES_MON
  local first_dow = dow_of_first(year, month, week_start)
  local total_days = days_in_month(year, month)

  local month_names = {
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
  }
  local title = string.format("%s %d", month_names[month], year)
  -- Pad title to GRID_WIDTH so it occupies the same horizontal slice as the grid.
  local pad_l = math.max(0, math.floor((GRID_WIDTH - #title) / 2))
  local title_line = string.rep(" ", pad_l) .. title
  title_line = title_line .. string.rep(" ", math.max(0, GRID_WIDTH - #title_line))

  -- Weekday header: each name is 2 chars; pad each to 4 to match cell width.
  local wd_cells = {}
  for _, n in ipairs(names) do
    wd_cells[#wd_cells + 1] = string.format(" %s ", n) -- 4 chars
  end
  local wd_line = table.concat(wd_cells)

  local lines = { title_line, wd_line }
  local extmarks = {}
  local day_cells = {}

  -- Day rows. Each day cell is 4 chars (" DD ").
  local row_idx = #lines + 1 -- next row to emit
  local current_row = ""
  local col = 0 -- weekday column (0..6)

  -- Title highlight covers the whole title row.
  extmarks[#extmarks + 1] = {
    row = 1,
    col_start = col_offset,
    col_end = col_offset + GRID_WIDTH,
    hl_group = "@organ.calendar.title",
  }
  -- Weekday names highlight.
  extmarks[#extmarks + 1] = {
    row = 2,
    col_start = col_offset,
    col_end = col_offset + GRID_WIDTH,
    hl_group = "@organ.calendar.weekday",
  }

  for _ = 1, first_dow do
    current_row = current_row .. string.rep(" ", CELL_WIDTH)
    col = col + 1
  end

  for day = 1, total_days do
    local cell_text = string.format(" %2d ", day)
    local cell_col_start = #current_row
    current_row = current_row .. cell_text
    local cell_col_end = cell_col_start + CELL_WIDTH

    day_cells[day] = {
      row = row_idx,
      col_start = cell_col_start + col_offset,
      col_end = cell_col_end + col_offset,
    }

    local is_weekend
    if week_start == "mon" then
      is_weekend = (col == 5 or col == 6)
    else
      is_weekend = (col == 0 or col == 6)
    end

    local iso = format_iso(year, month, day)
    local hl
    if iso == selected_iso then
      hl = "@organ.calendar.selected"
    elseif iso == today_iso then
      hl = "@organ.calendar.today"
    elseif holiday_set[iso] then
      hl = "@organ.calendar.holiday"
    elseif is_weekend then
      hl = "@organ.calendar.weekend"
    end
    if hl then
      extmarks[#extmarks + 1] = {
        row = row_idx,
        col_start = cell_col_start + col_offset,
        col_end = cell_col_end + col_offset,
        hl_group = hl,
      }
    end

    col = col + 1
    if col == 7 then
      lines[#lines + 1] = current_row
      current_row = ""
      col = 0
      row_idx = row_idx + 1
    end
  end
  if current_row ~= "" then
    -- Pad partial last row to GRID_WIDTH.
    current_row = current_row .. string.rep(" ", GRID_WIDTH - #current_row)
    lines[#lines + 1] = current_row
  end
  -- Pad to a fixed 8 grid lines (title + weekday + 6 weeks max) so 3-month
  -- layouts align horizontally.
  while #lines < 8 do
    lines[#lines + 1] = string.rep(" ", GRID_WIDTH)
  end

  return { lines = lines, extmarks = extmarks, day_cells = day_cells }
end

-- Render either a single month or three months side-by-side.
function M._render_layout(state, today_iso, week_start, holiday_set_for)
  if not state.three_months then
    local out = M._render_month(
      state.year,
      state.month,
      today_iso,
      state.selected_iso,
      week_start,
      holiday_set_for(state.year, state.month),
      0
    )
    return out
  end
  -- Three months: prev | current | next.
  local pm, py = state.month - 1, state.year
  if pm < 1 then
    pm = 12
    py = py - 1
  end
  local nm, ny = state.month + 1, state.year
  if nm > 12 then
    nm = 1
    ny = ny + 1
  end

  local left =
    M._render_month(py, pm, today_iso, state.selected_iso, week_start, holiday_set_for(py, pm), 0)
  local mid = M._render_month(
    state.year,
    state.month,
    today_iso,
    state.selected_iso,
    week_start,
    holiday_set_for(state.year, state.month),
    GRID_WIDTH + INTER_MONTH_GAP
  )
  local right = M._render_month(
    ny,
    nm,
    today_iso,
    state.selected_iso,
    week_start,
    holiday_set_for(ny, nm),
    (GRID_WIDTH + INTER_MONTH_GAP) * 2
  )

  -- Concatenate row-by-row (gap of INTER_MONTH_GAP spaces between months).
  local n_rows = math.max(#left.lines, #mid.lines, #right.lines)
  local lines = {}
  local gap = string.rep(" ", INTER_MONTH_GAP)
  for i = 1, n_rows do
    lines[i] = (left.lines[i] or string.rep(" ", GRID_WIDTH))
      .. gap
      .. (mid.lines[i] or string.rep(" ", GRID_WIDTH))
      .. gap
      .. (right.lines[i] or string.rep(" ", GRID_WIDTH))
  end

  local extmarks = {}
  for _, e in ipairs(left.extmarks) do
    extmarks[#extmarks + 1] = e
  end
  for _, e in ipairs(mid.extmarks) do
    extmarks[#extmarks + 1] = e
  end
  for _, e in ipairs(right.extmarks) do
    extmarks[#extmarks + 1] = e
  end

  -- Only the centre month is navigable; merge its day_cells.
  return { lines = lines, extmarks = extmarks, day_cells = mid.day_cells }
end

-- State mutation helpers (pure).

function M._move_selection(state, delta_days)
  local p = parse_iso(state.selected_iso)
  if not p then
    return state
  end
  local t = os.time({ year = p.year, month = p.month, day = p.day, hour = 12 })
  t = t + delta_days * 86400
  local nt = os.date("*t", t)
  local out = {}
  for k, v in pairs(state) do
    out[k] = v
  end
  out.selected_iso = format_iso(nt.year, nt.month, nt.day)
  out.year = nt.year
  out.month = nt.month
  return out
end

function M._move_month(state, delta_months)
  local p = parse_iso(state.selected_iso) or { year = state.year, month = state.month, day = 1 }
  local m = p.month + delta_months
  local y = p.year
  while m > 12 do
    m = m - 12
    y = y + 1
  end
  while m < 1 do
    m = m + 12
    y = y - 1
  end
  local maxd = days_in_month(y, m)
  local d = math.min(p.day, maxd)
  local out = {}
  for k, v in pairs(state) do
    out[k] = v
  end
  out.selected_iso = format_iso(y, m, d)
  out.year = y
  out.month = m
  return out
end

local NS = vim.api.nvim_create_namespace("organ_calendar")

local hl_registered = false
local function register_highlights()
  if hl_registered then
    return
  end
  hl_registered = true
  local hls = {
    ["@organ.calendar.title"] = "Title",
    ["@organ.calendar.weekday"] = "Type",
    ["@organ.calendar.today"] = "MoreMsg",
    ["@organ.calendar.selected"] = "Visual",
    ["@organ.calendar.holiday"] = "WarningMsg",
    ["@organ.calendar.weekend"] = "Comment",
    ["@organ.calendar.footer"] = "Comment",
  }
  for g, link in pairs(hls) do
    vim.api.nvim_set_hl(0, g, { link = link, default = true })
  end
  -- Hide the cursor inside the calendar window via guicursor masking.
  -- (Done per-window in pick().)
end

local function _today_iso()
  local t = os.date("*t")
  return format_iso(t.year, t.month, t.day)
end

local function _holiday_set_for_month(year, month)
  local ok, h = pcall(require, "organ.holidays")
  if not ok then
    return {}
  end
  local cfg = (require("organ").config.todo or {})
  local set = {}
  for _, name in ipairs(cfg.calendars or {}) do
    local entries = h.load_calendar(name) or {}
    for _, e in ipairs(entries) do
      local y, m = e.date:match("^(%d%d%d%d)%-(%d%d)")
      if tonumber(y) == year and tonumber(m) == month then
        set[e.date] = true
      end
    end
  end
  if cfg.default_country and cfg.default_country ~= "" then
    local entries = h.load_calendar(cfg.default_country) or {}
    for _, e in ipairs(entries) do
      local y, m = e.date:match("^(%d%d%d%d)%-(%d%d)")
      if tonumber(y) == year and tonumber(m) == month then
        set[e.date] = true
      end
    end
  end
  return set
end

local function _refresh(bufnr)
  local state = vim.b[bufnr].organ_calendar
  if not state then
    return
  end
  local out = M._render_layout(state, _today_iso(), state.week_start, _holiday_set_for_month)
  -- Footer.
  local lines = vim.list_extend({}, out.lines)
  if state.show_footer then
    lines[#lines + 1] = ""
    for _, l in ipairs(FOOTER_LINES) do
      lines[#lines + 1] = l
    end
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for _, em in ipairs(out.extmarks) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, em.row - 1, em.col_start, {
      end_col = em.col_end,
      hl_group = em.hl_group,
    })
  end
  if state.show_footer then
    local footer_row = #out.lines + 2 -- after the blank separator
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, footer_row - 1, 0, {
      end_col = #lines[footer_row],
      hl_group = "@organ.calendar.footer",
    })
  end

  -- Move cursor to the selected day's cell. Cursor sits ON the cell so
  -- 'h'/'l'/'j'/'k' user-mode motions are intercepted by our keymaps; the
  -- transparent guicursor mask hides the actual block.
  local p = state.selected_iso:match("^%d%d%d%d%-%d%d%-(%d%d)$")
  local day = tonumber(p) or 1
  local cell = out.day_cells[day]
  if cell then
    pcall(vim.api.nvim_win_set_cursor, 0, { cell.row, cell.col_start })
  end
end

local function _close_and_callback(bufnr, iso_or_nil)
  local state = vim.b[bufnr].organ_calendar
  if not state or state.fired then
    return
  end
  state.fired = true
  vim.b[bufnr].organ_calendar = state
  local cb = state.callback
  -- Restore guicursor before closing.
  if state.saved_guicursor then
    vim.o.guicursor = state.saved_guicursor
  end
  local win = vim.fn.bufwinid(bufnr)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  if cb then
    pcall(cb, iso_or_nil)
  end
end

local function install_keymaps(bufnr)
  local function map(lhs, action)
    vim.api.nvim_buf_set_keymap(bufnr, "n", lhs, "", {
      noremap = true,
      silent = true,
      callback = action,
    })
  end
  local function move(delta)
    return function()
      local s = vim.b[bufnr].organ_calendar
      if not s then
        return
      end
      vim.b[bufnr].organ_calendar = M._move_selection(s, delta)
      _refresh(bufnr)
    end
  end
  local function move_month(delta)
    return function()
      local s = vim.b[bufnr].organ_calendar
      if not s then
        return
      end
      vim.b[bufnr].organ_calendar = M._move_month(s, delta)
      _refresh(bufnr)
    end
  end
  map("h", move(-1))
  map("l", move(1))
  map("k", move(-7))
  map("j", move(7))
  map("<Left>", move(-1))
  map("<Right>", move(1))
  map("<Up>", move(-7))
  map("<Down>", move(7))
  map("<", move_month(-1))
  map(">", move_month(1))
  map("[", move_month(-1))
  map("]", move_month(1))
  map("t", function()
    local s = vim.b[bufnr].organ_calendar
    if not s then
      return
    end
    s.selected_iso = _today_iso()
    s.year = tonumber(s.selected_iso:sub(1, 4))
    s.month = tonumber(s.selected_iso:sub(6, 7))
    vim.b[bufnr].organ_calendar = s
    _refresh(bufnr)
  end)
  map("3", function() -- toggle 3-month layout on the fly
    local s = vim.b[bufnr].organ_calendar
    if not s then
      return
    end
    s.three_months = not s.three_months
    vim.b[bufnr].organ_calendar = s
    -- Also resize the window.
    local cur_win = vim.fn.bufwinid(bufnr)
    if cur_win and vim.api.nvim_win_is_valid(cur_win) then
      local target_w = s.three_months and (GRID_WIDTH * 3 + INTER_MONTH_GAP * 2) or GRID_WIDTH
      pcall(vim.api.nvim_win_set_config, cur_win, { width = target_w })
    end
    _refresh(bufnr)
  end)
  map("<CR>", function()
    local s = vim.b[bufnr].organ_calendar
    if not s then
      return
    end
    _close_and_callback(bufnr, s.selected_iso)
  end)
  map("q", function()
    _close_and_callback(bufnr, nil)
  end)
  map("<Esc>", function()
    _close_and_callback(bufnr, nil)
  end)
end

function M.pick(opts, callback)
  assert(type(callback) == "function", "calendar.pick: callback must be a function")
  opts = opts or {}
  register_highlights()

  local week_start = opts.week_start or (require("organ").config.calendar or {}).week_start or "mon"
  local initial = opts.initial or _today_iso()
  local p = initial:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$") and initial or _today_iso()
  local year = tonumber(p:sub(1, 4))
  local month = tonumber(p:sub(6, 7))

  local three_months = opts.three_months
  if three_months == nil then
    three_months = (require("organ").config.calendar or {}).three_months == true
  end
  local show_footer = opts.footer
  if show_footer == nil then
    local v = (require("organ").config.calendar or {}).footer
    if v == nil then
      show_footer = true
    else
      show_footer = v
    end
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "wipe"

  local lines_ui = vim.o.lines
  local cols_ui = vim.o.columns
  local width = three_months and (GRID_WIDTH * 3 + INTER_MONTH_GAP * 2) or GRID_WIDTH
  local height = 8 + (show_footer and 2 or 0)
  local row = math.max(0, math.floor((lines_ui - height) / 2))
  local col = math.max(0, math.floor((cols_ui - width) / 2))
  local win_opts = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    noautocmd = true,
  }
  if opts.title and opts.title ~= "" then
    win_opts.title = opts.title
    win_opts.title_pos = "center"
  end
  local win = vim.api.nvim_open_win(bufnr, true, win_opts)

  -- Hide the cursor inside the calendar (selection highlight stands in for it).
  local saved_guicursor = vim.o.guicursor
  vim.o.guicursor = "a:OrganCalendarCursor"
  vim.api.nvim_set_hl(0, "OrganCalendarCursor", { blend = 100 })

  -- Pin the window so cursor moves don't horizontally scroll. With
  -- `style = "minimal"` and a width that exactly matches the rendered
  -- content, there's nothing to scroll into; this is belt+braces.
  vim.wo[win].scrolloff = 0
  vim.wo[win].sidescrolloff = 0
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false

  vim.b[bufnr].organ_calendar = {
    selected_iso = p,
    year = year,
    month = month,
    week_start = week_start,
    three_months = three_months,
    show_footer = show_footer,
    callback = callback,
    fired = false,
    saved_guicursor = saved_guicursor,
  }

  install_keymaps(bufnr)
  _refresh(bufnr)
  return bufnr, win
end

return M
