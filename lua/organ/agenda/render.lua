-- Agenda rendering: blocks_with_rows -> { lines, extmarks, line_index, block_starts }.
-- Never writes buffers; reads agenda config, the clock, and window width, and
-- entry-text mode reads source org files.

local M = {}

local dates = require("organ.agenda.dates")
local format = require("organ.agenda.format")

local function compare_desc(a, b)
  return tostring(a) > tostring(b)
end

local function sort_records(records, order_spec)
  order_spec = order_spec or {}
  table.sort(records, function(a, b)
    for _, spec in ipairs(order_spec) do
      local col, dir = spec[1], (spec[2] or "asc"):lower()
      local av, bv = a[col], b[col]
      if av ~= bv then
        if av == nil then
          return dir ~= "asc"
        end
        if bv == nil then
          return dir == "asc"
        end
        if dir == "asc" then
          return av < bv
        else
          return compare_desc(av, bv)
        end
      end
    end
    return false
  end)
end

-- Auto-fit the TODO column to the widest keyword actually present, mirroring
-- Emacs (the column shrinks when e.g. no DONE state is in view).  Returns 0
-- when no row has a TODO state -- i.e. no TODO column at all.
local function fit_todo_width(rows)
  local kw_fmt = (require("organ.buf_config").read(nil, "agenda") or {}).todo_keyword_format or "%s"
  local max = 0
  for _, r in ipairs(rows) do
    if r.todo_state then
      local disp = r.todo_state
      if kw_fmt ~= "%s" then
        local ok, formatted = pcall(string.format, kw_fmt, r.todo_state)
        if ok then
          disp = formatted
        end
      end
      if #disp > max then
        max = #disp
      end
    end
  end
  return max
end

-- Auto-fit the category column to the widest category in the block so the
-- column reads as a true column row-to-row.  cfg.category_width is the lower
-- bound; +2 covers the trailing colon and a single-space separator.
local function fit_category_width(rows)
  local declared = (require("organ.buf_config").read(nil, "agenda") or {}).category_width or 12
  local max = declared
  for _, r in ipairs(rows) do
    local cat = format.category_for(r) or ""
    local w = vim.fn.strdisplaywidth(cat) + 2
    if w > max then
      max = w
    end
  end
  return max
end

-- Hide undated rows in the daily-agenda view (Emacs default).  Returns rows
-- unchanged unless the block is an agenda view without show_no_date.
local function filter_undated(rows, kind, show_no_date)
  if kind ~= "agenda" or show_no_date then
    return rows
  end
  local filtered = {}
  for _, r in ipairs(rows) do
    if r.scheduled_date or r.deadline_date or r.closed_date or r._bucket_date then
      filtered[#filtered + 1] = r
    end
  end
  return filtered
end

-- Repeater expansion: a row scheduled with `+Nd` / `++Nw` / `.+Nm` (and so
-- on) effectively occurs every N units. Without expansion, only the original
-- date appears in the agenda; users who track daily habits / weekly chores
-- see nothing on the days between. Toggle with `agenda.show_future_repeats`
-- (default true; matches Emacs `org-agenda-show-future-repeats`). Returns
-- `rows` unchanged when expansion does not apply.
local function expand_repeaters(rows, block)
  local show_repeats = (
    (require("organ.buf_config").read(nil, "agenda") or {}).show_future_repeats ~= false
  )
  local repeater_mod_ok, repeater_mod = pcall(require, "organ.todo.repeater")
  if not (show_repeats and repeater_mod_ok and block.from and block.to) then
    return rows
  end
  local q = require("organ.query")
  local from_ts = dates.iso_to_ts(q.parse_date and q.parse_date(block.from) or block.from)
  local to_ts = dates.iso_to_ts(q.parse_date and q.parse_date(block.to) or block.to)
  if not (from_ts and to_ts) then
    return rows
  end
  local function period_seconds(rep)
    local n = rep.value or 1
    if rep.unit == "d" then
      return n * 86400
    end
    if rep.unit == "w" then
      return n * 7 * 86400
    end
    return nil -- m/y handled separately (calendar math)
  end
  local function bump_calendar(ts, n, unit)
    local d = os.date("*t", ts)
    if unit == "m" then
      d.month = d.month + n
    elseif unit == "y" then
      d.year = d.year + n
    end
    return os.time(d)
  end
  local expanded = {}
  for _, r in ipairs(rows) do
    local rep = r.scheduled and r.scheduled ~= "" and repeater_mod.parse(r.scheduled) or nil
    local origin_ts = r.scheduled_date
        and r.scheduled_date ~= ""
        and dates.iso_to_ts(r.scheduled_date)
      or nil
    local emit_clones = false
    if rep and rep.value and rep.unit and origin_ts then
      local time_part = (r.scheduled_date and #r.scheduled_date >= 11 and r.scheduled_date:sub(11))
        or ""
      local cursor = origin_ts
      local sec_period = period_seconds(rep)
      -- Walk forward to first occurrence >= from_ts.
      while cursor < from_ts do
        if sec_period then
          cursor = cursor + sec_period
        else
          cursor = bump_calendar(cursor, rep.value, rep.unit)
        end
      end
      -- If origin is BEFORE the window, the first in-window clone
      -- represents an overdue carryover.  Emit it with the
      -- ORIGINAL scheduled_date so `sched_label_for` shows
      -- `Sched. Nx:` (for habits the cycle count, otherwise
      -- days late) -- matching Emacs.  The bucket-day is set via
      -- `_bucket_date` so the row lands on `from_ts` regardless.
      local origin_pre_window = origin_ts < from_ts
      local first = true
      while cursor <= to_ts do
        emit_clones = true
        local clone = vim.deepcopy(r)
        if first and origin_pre_window then
          -- Carryover row: keep original scheduled_date, but
          -- bucket on the today (cursor) day.
          clone._bucket_date = os.date("%Y-%m-%d", cursor)
        else
          clone.scheduled_date = os.date("%Y-%m-%d", cursor) .. time_part
          clone._synthetic_repeater = (cursor ~= origin_ts)
        end
        expanded[#expanded + 1] = clone
        first = false
        if sec_period then
          cursor = cursor + sec_period
        else
          cursor = bump_calendar(cursor, rep.value, rep.unit)
        end
      end
    end
    if not emit_clones then
      -- No expansion (no repeater, or m/y origin already-future): keep
      -- the row unchanged.
      expanded[#expanded + 1] = r
    end
  end
  return expanded
end

-- Overdue bucket: rows whose deadline is strictly before `today` and not yet
-- closed. Emits a "Overdue" header followed by the sorted rows. Mutates
-- nothing; emits via the supplied `emit_line` / `fmt` closures.
local function emit_overdue(rows, block, today, fmt, emit_line)
  if not block.include_overdue then
    return
  end
  local overdue = {}
  for _, r in ipairs(rows) do
    local dd = dates.date_only(r.deadline_date)
    if dd and dd < today and not r.closed_date then
      overdue[#overdue + 1] = r
    end
  end
  if #overdue > 0 then
    sort_records(overdue, block.order_within_group)
    emit_line("Overdue", { { "@organ.agenda.date_overdue", 0, 7 } }, nil)
    for _, r in ipairs(overdue) do
      local text, marks = fmt(r)
      emit_line(text, marks, r)
    end
    emit_line("", nil, nil)
  end
end

-- Build the per-bucket row comparator from the block's (or config's) Emacs-
-- style `sorting_strategy` token list. Each token returns -1 / 0 / +1; the
-- first non-zero wins, then a stable file+line tiebreak. Defaults to
-- time-up,priority-down,category-keep. Returns a function(rows) that sorts
-- in place.
local function make_sort_by_time(block)
  -- Time-only string is "9:00" / "23:45" -- no leading zero. Compare as
  -- minutes-of-day (integer) so "9:00" < "10:00" sorts correctly.
  local function tominutes(hhmm)
    if not hhmm then
      return nil
    end
    local h, m = hhmm:match("^(%d?%d):(%d%d)$")
    if not h then
      return nil
    end
    return tonumber(h) * 60 + tonumber(m)
  end
  -- Supported tokens (Emacs parity):
  --   time-up / time-down                untimed always after timed
  --   priority-up / priority-down        A < B < ... (up = ascending)
  --   category-up / category-down        category alphabetical
  --   category-keep                      preserve file + line order
  --   alpha-up / alpha-down              by title
  --   todo-state-up / todo-state-down    by todo_state alphabetical
  --   tag-up / tag-down                  by first tag
  --   effort-up / effort-down            by effort minutes
  --   scheduled-up / scheduled-down      by scheduled_date
  --   deadline-up / deadline-down        by deadline_date
  local TOKEN_FNS = {
    ["time-up"] = function(a, b)
      local ta, tb =
        tominutes(dates.time_only(a.scheduled_date)), tominutes(dates.time_only(b.scheduled_date))
      if ta and not tb then
        return -1
      end
      if tb and not ta then
        return 1
      end
      if ta and tb and ta ~= tb then
        return ta < tb and -1 or 1
      end
      return 0
    end,
    ["time-down"] = function(a, b)
      local ta, tb =
        tominutes(dates.time_only(a.scheduled_date)), tominutes(dates.time_only(b.scheduled_date))
      if ta and not tb then
        return -1
      end
      if tb and not ta then
        return 1
      end
      if ta and tb and ta ~= tb then
        return ta > tb and -1 or 1
      end
      return 0
    end,
    -- Emacs naming convention: "priority-up" = lowest-importance first
    -- (none, C, B, A); "priority-down" = highest-importance first
    -- (A, B, C, none). Naming is "from top of list, descending in
    -- importance" -- confusing but standard.
    ["priority-up"] = function(a, b)
      if a.priority == b.priority then
        return 0
      end
      if not a.priority then
        return -1
      end -- none = lowest = first
      if not b.priority then
        return 1
      end
      -- Lower-byte letter = higher importance (A=highest). For "up"
      -- (low-importance first), the higher-byte-value comes first.
      return a.priority > b.priority and -1 or 1
    end,
    ["priority-down"] = function(a, b)
      if a.priority == b.priority then
        return 0
      end
      if not a.priority then
        return 1
      end -- none = lowest = last
      if not b.priority then
        return -1
      end
      return a.priority < b.priority and -1 or 1 -- A < B -> A first
    end,
    ["category-up"] = function(a, b)
      local ca, cb = format.category_for(a), format.category_for(b)
      if ca == cb then
        return 0
      end
      return ca < cb and -1 or 1
    end,
    ["category-down"] = function(a, b)
      local ca, cb = format.category_for(a), format.category_for(b)
      if ca == cb then
        return 0
      end
      return ca > cb and -1 or 1
    end,
    ["category-keep"] = function(a, b)
      if a.file_path ~= b.file_path then
        return (a.file_path or "") < (b.file_path or "") and -1 or 1
      end
      local la, lb = a.line_start or 0, b.line_start or 0
      if la == lb then
        return 0
      end
      return la < lb and -1 or 1
    end,
    ["alpha-up"] = function(a, b)
      local ta, tb = a.title or "", b.title or ""
      if ta == tb then
        return 0
      end
      return ta < tb and -1 or 1
    end,
    ["alpha-down"] = function(a, b)
      local ta, tb = a.title or "", b.title or ""
      if ta == tb then
        return 0
      end
      return ta > tb and -1 or 1
    end,
    ["todo-state-up"] = function(a, b)
      local ta, tb = a.todo_state or "", b.todo_state or ""
      if ta == tb then
        return 0
      end
      return ta < tb and -1 or 1
    end,
    ["todo-state-down"] = function(a, b)
      local ta, tb = a.todo_state or "", b.todo_state or ""
      if ta == tb then
        return 0
      end
      return ta > tb and -1 or 1
    end,
  }
  local DEFAULT_STRATEGY = { "time-up", "priority-down", "category-keep" }
  local strategy = block.sorting_strategy
    or (require("organ.buf_config").read(nil, "agenda") or {}).sorting_strategy
    or DEFAULT_STRATEGY
  return function(rows)
    table.sort(rows, function(a, b)
      for _, tok in ipairs(strategy) do
        local fn = TOKEN_FNS[tok]
        if fn then
          local cmp = fn(a, b)
          if cmp ~= 0 then
            return cmp < 0
          end
        end
      end
      -- Final stable tiebreak so tests are deterministic.
      if a.file_path ~= b.file_path then
        return (a.file_path or "") < (b.file_path or "")
      end
      return (a.line_start or 0) < (b.line_start or 0)
    end)
  end
end

-- Partition `effective` rows into per-day buckets keyed by ISO date, plus a
-- no-date list. Handles the scheduled-vs-deadline double-bucketing, the
-- early-warning deadline fanout, optional overdue roll-forward, and backfill
-- of empty days across the [block.from, block.to] window. Returns
-- `buckets, order, no_date` with `order` sorted ascending. Pure: emits
-- nothing, mutates only the row clones it creates.
local function build_day_buckets(effective, block, today)
  -- Optional: items whose scheduled date is BEFORE the visible
  -- window collapse into the today bucket. Emacs default does NOT
  -- do this for non-repeating SCHEDULED items (they just disappear
  -- from the window -- users see "Sched. Nx:" only for repeating
  -- ones). Toggle via `agenda.show_overdue_scheduled = true` for
  -- the more user-friendly "stale items keep showing" behavior.
  local roll_overdue = (require("organ.buf_config").read(nil, "agenda") or {}).show_overdue_scheduled
    == true
  local window_from = block.from
    and dates.date_only(
      (require("organ.query").parse_date and require("organ.query").parse_date(block.from))
        or block.from
    )
  local buckets, order, no_date = {}, {}, {}
  local function add_to_bucket(r, key)
    if roll_overdue and key and window_from and key < window_from then
      key = window_from
    end
    if key then
      if not buckets[key] then
        buckets[key] = {}
        order[#order + 1] = key
      end
      table.insert(buckets[key], r)
    else
      no_date[#no_date + 1] = r
    end
  end
  -- Deadline-warning fanout: a row whose deadline is N days from
  -- today (1 <= N <= deadline_warning_days, default 14) gets an
  -- extra entry in today's bucket with an "In   N d.:" label.  The
  -- row's natural deadline-day bucket entry stays.  Mirrors Emacs's
  -- `org-deadline-warning-days` early-warning behavior -- without
  -- this, deadlines drop off the user's radar until they're due.
  local agenda_cfg_b = (require("organ.buf_config").read(nil, "agenda") or {})
  local warning_days = agenda_cfg_b.deadline_warning_days or 14
  -- Skip pair rules.  Both default to true (matches Emacs's
  -- typical org-agenda behavior) and may be turned off to surface
  -- both events.
  local skip_sched_if_dl_shown
  if block.skip_scheduled_if_deadline_shown ~= nil then
    skip_sched_if_dl_shown = block.skip_scheduled_if_deadline_shown
  else
    skip_sched_if_dl_shown = agenda_cfg_b.skip_scheduled_if_deadline_shown
  end
  if skip_sched_if_dl_shown == nil then
    skip_sched_if_dl_shown = false
  end
  local skip_dl_prewarn_if_sched
  if block.skip_deadline_prewarning_if_scheduled ~= nil then
    skip_dl_prewarn_if_sched = block.skip_deadline_prewarning_if_scheduled
  else
    skip_dl_prewarn_if_sched = agenda_cfg_b.skip_deadline_prewarning_if_scheduled
  end
  if skip_dl_prewarn_if_sched == nil then
    skip_dl_prewarn_if_sched = true
  end
  for _, r in ipairs(effective) do
    local sched_key = dates.date_only(r.scheduled_date)
    local dead_key = dates.date_only(r.deadline_date)
    if r._bucket_date then
      -- `_bucket_date` is set by the repeater-overdue carryover path
      -- to force the row onto today's bucket while preserving the
      -- original scheduled_date for the `Sched. Nx:` label.
      add_to_bucket(r, r._bucket_date)
    elseif sched_key and dead_key and sched_key ~= dead_key then
      -- Mirrors Emacs: a row with BOTH scheduled and deadline
      -- appears in BOTH buckets (different prefixes per bucket via
      -- bucket-relative sched_label_for).  The two events are
      -- distinct calendar entries -- start day and must-finish day --
      -- and the user wants to see both in the agenda.
      --
      -- `skip_scheduled_if_deadline_shown` (Emacs `org-agenda-skip-
      -- scheduled-if-deadline-is-shown`) suppresses the scheduled-
      -- day occurrence for rows that ALSO render on the deadline
      -- day, eliminating the duplicate when the deadline is the
      -- "real" event the user cares about.
      if not skip_sched_if_dl_shown then
        add_to_bucket(r, sched_key)
      end
      add_to_bucket(r, dead_key)
    else
      add_to_bucket(r, sched_key or dead_key)
    end
    -- Early-warning: deadline within the warning window AND the row
    -- has no scheduled_date (so it wouldn't otherwise appear before
    -- the deadline day) -> add a copy to today's bucket with an
    -- `In N d.:` label.  Mirrors Emacs `org-agenda-skip-deadline-
    -- prewarning-if-scheduled` (default true): if the row is already
    -- scheduled within the visible window, the user sees it on the
    -- scheduled day and the deadline-warning is redundant -- set
    -- `skip_deadline_prewarning_if_scheduled = false` to opt back in.
    if dead_key and warning_days > 0 and (not r.scheduled_date or not skip_dl_prewarn_if_sched) then
      local d = dates.days_diff(today, dead_key)
      if d and d > 0 and d <= warning_days and dead_key ~= today then
        local clone = vim.tbl_extend("force", {}, r)
        clone._deadline_warning = true
        add_to_bucket(clone, today)
      end
    end
  end
  -- Backfill empty days in the [block.from, block.to] window so the
  -- agenda renders a header for every day (matches Emacs's
  -- `org-agenda-show-all-dates = t` default -- Fri / Sat without
  -- items still get a `Friday    8 May 2026` header).
  if block.from and block.to then
    local q = require("organ.query")
    local from_iso = (q.parse_date and q.parse_date(block.from)) or block.from
    local to_iso = (q.parse_date and q.parse_date(block.to)) or block.to
    if from_iso and to_iso and #from_iso >= 10 and #to_iso >= 10 then
      local function iso_to_t(iso)
        local y, mo, da = iso:sub(1, 4), iso:sub(6, 7), iso:sub(9, 10)
        return os.time({
          year = tonumber(y),
          month = tonumber(mo),
          day = tonumber(da),
          hour = 12,
        })
      end
      local seen = {}
      for _, k in ipairs(order) do
        seen[k] = true
      end
      local cur, stop = iso_to_t(from_iso:sub(1, 10)), iso_to_t(to_iso:sub(1, 10))
      while cur <= stop do
        local iso = os.date("%Y-%m-%d", cur)
        if not seen[iso] then
          buckets[iso] = buckets[iso] or {}
          order[#order + 1] = iso
          seen[iso] = true
        end
        cur = cur + 86400
      end
    end
  end
  table.sort(order)
  return buckets, order, no_date
end

-- Render one day-bucket: sort it, emit its date header, the optional "<- now"
-- marker, and the bucket's rows via the groups / time-grid / plain path. All
-- per-block state is threaded through `ctx`; lines are emitted via the
-- captured `emit_line` closure. The trailing blank line after each bucket is
-- emitted here too.
local function emit_day_bucket(key, ctx, emit_line)
  local block = ctx.block
  local block_opts = ctx.block_opts
  local today = ctx.today
  local buckets = ctx.buckets
  local now_hhmm = ctx.now_hhmm
  local show_now = ctx.show_now
  local agenda_cfg_local = ctx.agenda_cfg

  ctx.sort_by_time(buckets[key])
  -- Per-bucket fmt: relative-time prefix is computed against the
  -- BUCKET's date, not the renderer's global today. So a row
  -- shown under Tuesday's header gets "Scheduled:" (its scheduled
  -- date matches its bucket), not "In 1 d.:" (which would apply
  -- in a flat / non-grouped view).
  local bucket_block_opts = vim.tbl_extend("force", {}, block_opts, { today = key })
  local bucket_fmt = function(r)
    return format.format_line(r, bucket_block_opts)
  end
  if type(block.line_format) == "function" then
    local user_fmt = block.line_format
    bucket_fmt = function(r)
      local ok, line = pcall(user_fmt, r)
      if ok then
        return line, nil
      end
      return format.format_line(r, bucket_block_opts)
    end
  end
  local hl = key == today and "@organ.agenda.date_today" or "@organ.agenda.header"
  local hdr = dates.date_header(key)
  emit_line(hdr, { { hl, 0, #hdr } }, nil)

  -- "<- now" marker: insert in the today-bucket between rows
  -- whose times bracket the current wall-clock time. Renders as
  -- a single dim line so it doesn't visually compete with item
  -- rows.
  -- Decide whether this day-bucket gets the time grid.
  local emit_grid_for_day = ctx.time_grid_on and (ctx.time_grid_scope == "all" or key == today)

  -- Configurable now-marker text. agenda.current_time_string is
  -- expanded with `%s` -> the wall-clock HH:MM. Default mirrors
  -- Emacs's `org-agenda-current-time-string` shape. Users can
  -- pass any string with optional `%s` placeholder.
  --
  -- The default has NO leading whitespace; we prepend the proper
  -- indent at emit time so the marker's time column lines up with
  -- the grid hours (or with item time columns when there's no
  -- grid). That keeps the user's override interpretable: they
  -- write the *content*, we handle the alignment.
  local now_template = agenda_cfg_local.current_time_string
    or "%5s ┄┄┄┄┄ ← now ─────────────────────────────"
  -- Time column starts at 2 (leading) + category_width + 1 (sep).
  -- Use block_opts.category_width (auto-fit value computed above)
  -- so the time grid aligns with the actually-rendered category
  -- column, not the config default that may have been widened.
  local time_col_indent = string.rep(" ", 2 + (block_opts.category_width or 12))
  local inserted_now = false
  -- Convert "H:MM" / "HH:MM" -> minutes-since-midnight, so we can
  -- do real ordering instead of lexical (which gets `"11:53" <
  -- "8:00"` wrong because '1' sorts before '8').
  local function hhmm_to_min(s)
    if not s then
      return nil
    end
    local h, m = s:match("^(%d?%d):(%d%d)$")
    if not h then
      return nil
    end
    return tonumber(h) * 60 + tonumber(m)
  end
  local now_min = hhmm_to_min(now_hhmm)
  local function maybe_emit_now(before_time)
    if inserted_now or not show_now or key ~= today then
      return
    end
    local before_min = hhmm_to_min(before_time)
    if not before_min or (now_min and now_min < before_min) then
      local body = now_template:find("%%s") and string.format(now_template, now_hhmm)
        or now_template
      -- Strip any leading whitespace the template carries so we
      -- can re-impose the alignment indent: existing user configs
      -- (and our previous default) carry a 2-space prefix that
      -- would compound with the new indent into a misalignment.
      body = body:gsub("^%s+", "")
      -- In grid mode, indent so `<time> ┄┄...` aligns with the
      -- grid hour rows. Outside grid mode, the default 2-space
      -- prefix is retained for backwards compatibility.
      local prefix = emit_grid_for_day and time_col_indent or "  "
      local text = prefix .. body
      local pos_now = text:find("← now", 1, true) or text:find("now", 1, true)
      local marks = {}
      if pos_now then
        local marker_word = text:sub(pos_now):match("^(%S+%s*%S*)") or "now"
        marks[#marks + 1] = {
          "@organ.agenda.now_marker",
          pos_now - 1,
          pos_now - 1 + #marker_word,
        }
      end
      emit_line(text, marks, nil)
      inserted_now = true
    end
  end

  -- Grouping path: when the user configured agenda.groups (or the
  -- block has its own groups list), partition the bucket's rows
  -- into named groups and emit each with its own sub-header.
  -- Skips the time-grid path (groups + grid would visually fight
  -- for vertical space).
  if ctx.groups_mod and not emit_grid_for_day then
    local agenda_cfg_g = (require("organ.buf_config").read(nil, "agenda") or {})
    local partitions = ctx.groups_mod.partition(buckets[key], ctx.groups_spec, {
      category_for = format.category_for,
      catch_all_title = agenda_cfg_g.groups_catch_all_title,
    })
    for _, p in ipairs(partitions) do
      if #p.rows > 0 then
        if p.title then
          local sub_hdr = string.format("  %s (%d)", p.title, #p.rows)
          emit_line(sub_hdr, { { "@organ.agenda.block_header", 0, #sub_hdr } }, nil)
        end
        for _, r in ipairs(p.rows) do
          local row_time = dates.time_only(r.scheduled_date)
          if row_time then
            maybe_emit_now(row_time)
          end
          local text, marks = bucket_fmt(r)
          emit_line(text, marks, r)
        end
      end
    end
  elseif emit_grid_for_day then
    -- Build a sorted list of (HH:MM, kind, payload) events and
    -- emit them in time order. kind in "grid" | "row". Rows with
    -- the same HH:MM as a grid hour replace that grid line.
    local events = {}
    for _, h in ipairs(ctx.time_grid_hours) do
      -- `sortkey` is zero-padded so "08:00" < "10:00" lexically;
      -- `display` is the stripped form Emacs prints ("8:00").
      events[#events + 1] = {
        sortkey = string.format("%02d:00", h),
        display = string.format("%d:00", h),
        kind = "grid",
      }
    end
    local untimed = {}
    for _, r in ipairs(buckets[key]) do
      local rt = dates.time_only(r.scheduled_date)
      if rt then
        local hh, mm = rt:match("^(%d?%d):(%d%d)$")
        if hh and mm then
          events[#events + 1] = {
            sortkey = string.format("%02d:%s", tonumber(hh), mm),
            display = rt,
            kind = "row",
            row = r,
            raw_time = rt,
          }
        else
          untimed[#untimed + 1] = r
        end
      else
        untimed[#untimed + 1] = r
      end
    end
    table.sort(events, function(a, b)
      if a.sortkey ~= b.sortkey then
        return a.sortkey < b.sortkey
      end
      -- Row beats grid at the same time (so the row's content shows).
      return a.kind == "row" and b.kind == "grid"
    end)
    -- De-dupe grid lines that collide with rows at the same HH:MM.
    local seen_at_time = {}
    for _, e in ipairs(events) do
      if e.kind == "row" then
        seen_at_time[e.sortkey] = true
      end
    end
    -- The now-marker also occupies its time slot; suppress any
    -- grid line at that same HH:MM so we don't render both
    -- "12:00 ┄ ← now ─" and "12:00 ┄ ┄┄" back-to-back.
    if show_now and key == today and now_hhmm then
      local hh, mm = now_hhmm:match("^(%d%d):(%d%d)$")
      if hh and mm == "00" then
        seen_at_time[hh .. ":00"] = true
      end
    end
    for _, e in ipairs(events) do
      if e.kind == "row" then
        local rt = e.raw_time
        if rt then
          maybe_emit_now(rt)
        end
        local text, marks = bucket_fmt(e.row)
        emit_line(text, marks, e.row)
      else
        if not seen_at_time[e.sortkey] then
          maybe_emit_now(e.display)
          -- Empty grid lines indent to the time column AND
          -- right-align the hour to 5 chars so single-digit
          -- hours (` 8:00`) and double-digit (`10:00`) end at
          -- the same column.  Indent = `2 (leading) + cat_width`
          -- (NO separator between cat and time -- Emacs's `:c`
          -- modifier produces "Tasks:      " filling the cat
          -- field, then time directly follows).
          -- Use block_opts.category_width (auto-fit) so empty
          -- grid lines align with the actually-rendered category
          -- column, not the un-widened config default.
          local indent = string.rep(" ", 2 + (block_opts.category_width or 12))
          local text = string.format(
            "%s%5s ┄┄┄┄┄ ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄",
            indent,
            e.display
          )
          local pad = 5 - #e.display
          local marks = { { "@organ.agenda.now_marker", #indent + pad, #indent + 5 } }
          emit_line(text, marks, nil)
        end
      end
    end
    -- Now marker: when wall-clock is past the last grid hour but
    -- the bucket still has untimed rows below the grid, place the
    -- marker BETWEEN them -- matches Emacs's `20:00 ┄┄┄ / 22:49 <-
    -- now / <untimed rows>` layout instead of letting `untimed`
    -- emit first and the marker fall at end-of-bucket.
    maybe_emit_now(nil)
    -- Untimed rows after the grid.
    for _, r in ipairs(untimed) do
      local text, marks = bucket_fmt(r)
      emit_line(text, marks, r)
    end
  else
    for _, r in ipairs(buckets[key]) do
      local row_time = dates.time_only(r.scheduled_date)
      if row_time then
        maybe_emit_now(row_time)
      end
      local text, marks = bucket_fmt(r)
      emit_line(text, marks, r)
    end
  end
  -- If "now" hasn't been emitted yet (every row was earlier than
  -- now, or no timed rows at all), emit at the end of the day's bucket.
  maybe_emit_now(nil)
  emit_line("", nil, nil)
end

-- Per-block primitive: overdue bucket, group_by day/none, sort, format_line.
local function render_block(rows, block, now_override)
  block = block or {}
  local today = now_override or dates.today_iso()
  local opts = format.render_opts()

  -- Auto-fit TODO column to the longest keyword actually present in this
  -- block. Mirrors Emacs's behavior -- column shrinks when no DONE state
  -- is in view, etc. Set agenda.todo_width in config to override.
  local block_opts = {
    todo_width = opts.todo_width,
    prefix_format = format.resolve_prefix_format(opts.prefix_format, block),
    today = today,
  }
  if not block_opts.todo_width then
    block_opts.todo_width = fit_todo_width(rows) -- 0 -> no TODO column (clean view)
  end

  -- Auto-fit category column.  format_line's `%-N:c` only pads to N;
  -- a longer category pushes successive columns right and breaks
  -- alignment row-to-row (a 12-char category prints fine, but a row
  -- with `refile_source:` from a long-basename file shifts the
  -- "Sched.:" column 2 cells right).  Compute the actual max for
  -- this block once and have format_line use that as the effective
  -- minimum width for every row, so the column reads as a true
  -- column.  cfg.category_width still acts as the lower bound.
  block_opts.category_width = fit_category_width(rows)

  -- Hide undated rows in the daily-agenda view (mirrors Emacs default).
  -- Activated when block.kind explicitly says "agenda" OR when block has
  -- a date window (block.from set). Override with agenda.show_no_date=true.
  local kind = block.kind or (block.from and "agenda" or "todo")
  rows = filter_undated(rows, kind, opts.show_no_date)

  local fmt = function(r)
    return format.format_line(r, block_opts)
  end
  if type(block.line_format) == "function" then
    local user_fmt = block.line_format
    fmt = function(r)
      local ok, line = pcall(user_fmt, r)
      if ok then
        return line, nil
      end
      -- Fall back to default formatter for this row; surface the error
      -- once per refresh via the buffer-level _line_format_error sink.
      block._line_format_error = block._line_format_error or tostring(line)
      return format.format_line(r, block_opts)
    end
  end

  local lines, extmarks, line_index = {}, {}, {}
  local function emit_line(text, marks, row)
    lines[#lines + 1] = text
    local lnum = #lines
    if marks then
      for _, mk in ipairs(marks) do
        -- Preserve the optional 4th element (extra extmark opts --
        -- used by the virt_text right-align tag column path).
        extmarks[#extmarks + 1] = { lnum, mk[1], mk[2], mk[3], mk[4] }
      end
    end
    line_index[lnum] = row
  end

  if #rows == 0 then
    if block.label ~= nil then
      emit_line("  (nothing)", nil, nil)
    end
    return { lines = lines, extmarks = extmarks, line_index = line_index }
  end

  rows = expand_repeaters(rows, block)

  -- 1. Overdue bucket
  emit_overdue(rows, block, today, fmt, emit_line)

  local effective = {}
  for _, r in ipairs(rows) do
    if
      not (
        block.include_overdue
        and r.deadline_date
        and dates.date_only(r.deadline_date) < today
        and not r.closed_date
      )
    then
      effective[#effective + 1] = r
    end
  end

  -- Default group_by is kind-aware: agenda views group by day (Emacs's
  -- daily agenda); todo lists are flat (Emacs's global TODO list).
  local group_by = block.group_by or (kind == "agenda" and "day" or "none")
  if group_by == "none" then
    sort_records(effective, block.order_within_group)
    for _, r in ipairs(effective) do
      local text, marks = fmt(r)
      emit_line(text, marks, r)
    end
  else
    local buckets, order, no_date = build_day_buckets(effective, block, today)
    -- Wall-clock time for the "<- now" marker. now_override is a
    -- date-only ISO string ("2026-05-04") used by tests + the daily
    -- today/not-today comparison; it does NOT carry an hour, so we
    -- can't derive HH:MM from it for live use. Always pull HH:MM
    -- from os.time() for interactive renders. Tests that want a
    -- fixed wall-clock for the marker can pass a full ISO timestamp
    -- ("2026-05-04T12:00") via now_override.
    local now_hhmm
    if now_override and #now_override > 10 then
      now_hhmm = os.date("%H:%M", dates.iso_to_ts(now_override))
    else
      now_hhmm = os.date("%H:%M", os.time())
    end
    local agenda_cfg_local = (require("organ.buf_config").read(nil, "agenda") or {})
    local show_now = agenda_cfg_local.now_marker ~= false

    -- Time grid (Emacs `org-agenda-use-time-grid`). Off by default;
    -- opt-in via agenda.time_grid = true (uses default 2h hours) or
    -- a table { hours = {...}, on = "today" | "all" }. When on, today's
    -- bucket gets a row per grid hour; rows scheduled at grid hours
    -- "occupy" the line, others appear at their own time.
    local time_grid_cfg = agenda_cfg_local.time_grid
    local time_grid_on = false
    local time_grid_hours
    local time_grid_scope = "today"
    if time_grid_cfg == true then
      time_grid_on = true
      time_grid_hours = { 8, 10, 12, 14, 16, 18, 20 }
    elseif type(time_grid_cfg) == "table" then
      time_grid_on = time_grid_cfg.enabled ~= false
      time_grid_hours = time_grid_cfg.hours or { 8, 10, 12, 14, 16, 18, 20 }
      time_grid_scope = time_grid_cfg.on or "today"
    end
    -- Within each day bucket, sort by TIME first (timed rows ascending),
    -- with untimed rows pushed to the end. Emacs `org-agenda-sorting-
    -- strategy` defaults to time-up,priority-down,category-keep -- the
    -- "time first" rule is the load-bearing one for daily agendas
    -- because users read top-to-bottom and expect a chronological
    -- timeline. Within ties (same time, or both untimed), fall back to
    -- the user's `order_within_group` (priority / state / title).
    local sort_by_time = make_sort_by_time(block)

    -- Optional row grouping (org-super-agenda equivalent). Per-block
    -- override via block.groups; falls back to agenda.groups.
    local groups_spec = block.groups
      or (require("organ.buf_config").read(nil, "agenda") or {}).groups
    local groups_mod = nil
    if groups_spec and #groups_spec > 0 then
      local ok_g, m = pcall(require, "organ.agenda.groups")
      if ok_g then
        groups_mod = m
      end
    end

    local bucket_ctx = {
      buckets = buckets,
      block = block,
      block_opts = block_opts,
      today = today,
      agenda_cfg = agenda_cfg_local,
      now_hhmm = now_hhmm,
      show_now = show_now,
      sort_by_time = sort_by_time,
      groups_mod = groups_mod,
      groups_spec = groups_spec,
      time_grid_on = time_grid_on,
      time_grid_scope = time_grid_scope,
      time_grid_hours = time_grid_hours,
    }
    for _, key in ipairs(order) do
      emit_day_bucket(key, bucket_ctx, emit_line)
    end
    if #no_date > 0 then
      emit_line("(No date)", { { "@organ.agenda.header", 0, 9 } }, nil)
      sort_records(no_date, block.order_within_group)
      for _, r in ipairs(no_date) do
        local text, marks = fmt(r)
        emit_line(text, marks, r)
      end
    end
  end

  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return { lines = lines, extmarks = extmarks, line_index = line_index }
end

-- Empty-state lines shown when the agenda renders zero rows across all
-- blocks. Tells the user what to try next instead of a blank buffer.
local function empty_state_lines()
  -- Detect likely cause to give a more actionable hint.
  local query_ok, query = pcall(require, "organ.query")
  local indexed = 0
  if query_ok then
    local ok, files = pcall(query.files)
    if ok and type(files) == "table" then
      indexed = #files
    end
  end
  if indexed == 0 then
    return {
      "(empty agenda)",
      "",
      "  Your org_dir hasn't been indexed yet.",
      "  Try `:Org scan` to index every .org file under "
        .. vim.fn.fnamemodify((require("organ.buf_config").read(nil, "org_dir") or ""), ":~"),
      "  Then `r` to refresh this view.",
    }
  end
  return {
    "(empty agenda)",
    "",
    string.format("  %d file(s) indexed but nothing matches the current view's filters.", indexed),
    "",
    "  The default view shows only headlines with a SCHEDULED or DEADLINE",
    "  timestamp in the next 7 days. Plain TODOs without a timestamp don't",
    "  appear here — that's Emacs's behavior too.",
    "",
    "  Try one of the built-in named views:",
    "    :Org agenda todos     every TODO-state headline (no timestamp filter)",
    "    :Org agenda today     only items scheduled or due today",
    "    :Org agenda next      only headlines in NEXT state",
    "    :Org agenda overview  today + every TODO, side-by-side",
    "",
    "  Or add `SCHEDULED: <today>` under a headline and `r` to refresh.",
  }
end

local FOOTER_LINES = {
  "─────────────────────────────────────────────────────────────────────────────",
  "  <CR> jump   gs/gv split/vsplit   r refresh   u undo   q close   / filter",
  "  t/T TODO cycle/set   +/-/= priority   s/D schedule/deadline   I/O clock",
  "  <Space> mark   gB bulk   gT tags   A archive   gA show/hide archived",
  "  R refile   gC clock report",
  "  f/b period   . today   gj jump   gd/gw day/week   e effort   g? help",
}

-- Compute "Day-agenda (Wnn):" / "Week-agenda (Wnn-Wmm):" / "agenda
-- (Wnn):" buffer header from the visible date window. Returns a string
-- or nil when the view isn't a time-windowed agenda.
--
-- The header reflects the WINDOW's week, not today's week. A
-- back-shifted view of "last Monday -> next Sunday" gets the header
-- of last Monday's W, regardless of when "today" is.
local function compute_view_header(blocks_with_rows, _opts)
  local first
  for _, item in ipairs(blocks_with_rows) do
    if item.block and item.block.from then
      first = item.block
      break
    end
  end
  if not first then
    return nil
  end
  local q = require("organ.query")
  local from_iso = (q.parse_date and q.parse_date(first.from)) or first.from
  local from_ts = dates.iso_to_ts(from_iso)
  if not from_ts then
    return nil
  end
  local from_w = dates.iso_week_of(from_ts)
  local span = "Day"
  if first.to and first.to ~= first.from then
    span = "Week"
    local to_iso = (q.parse_date and q.parse_date(first.to)) or first.to
    local to_ts = dates.iso_to_ts(to_iso)
    if to_ts then
      local to_w = dates.iso_week_of(to_ts)
      if to_w ~= from_w then
        return string.format("%s-agenda (W%02d-W%02d):", span, from_w, to_w)
      end
    end
  end
  return string.format("%s-agenda (W%02d):", span, from_w)
end

-- Public orchestrator. Iterates blocks, prepends a header line for labeled
-- blocks, concatenates per-block output with cumulative line-number offsets,
-- and returns a block_starts map for navigation keymaps.
local function render(blocks_with_rows, opts)
  opts = opts or {}
  -- Drop per-pass caches so a live `#+CATEGORY:` edit shows on this render.
  format.reset_caches()
  local lines, extmarks, line_index, block_starts = {}, {}, {}, {}

  -- Top-of-buffer header: "Week-agenda (W18):" / "Day-agenda (W18):" /
  -- etc. Mirrors Emacs's first line. Suppressed when the user disables
  -- the buffer header (agenda.view_header = false) or when no block
  -- has a from/to window.
  local view_hdr_cfg = (require("organ.buf_config").read(nil, "agenda") or {}).view_header
  if view_hdr_cfg ~= false then
    local hdr = compute_view_header(blocks_with_rows, opts)
    if hdr then
      lines[#lines + 1] = hdr
      extmarks[#extmarks + 1] = { #lines, "@organ.agenda.view_header", 0, #hdr }
    end
  end

  for bi, item in ipairs(blocks_with_rows) do
    local block, rows = item.block, item.rows
    local effective_now = opts.now
    block._line_format_error = nil -- clear any stale error from a previous render
    local block_out = render_block(rows, block, effective_now)
    if item.query_error then
      block_out = {
        lines = { "  (query error: " .. item.query_error .. ")" },
        extmarks = {},
        line_index = {},
      }
    end

    -- Skip blocks with zero rows when agenda.hide_empty_blocks is on
    -- (Emacs `org-agenda-hide-empty-blocks`). Useful for multi-block
    -- agendas where some blocks are empty on a given day.
    local agenda_cfg_top = (require("organ.buf_config").read(nil, "agenda") or {})
    if agenda_cfg_top.hide_empty_blocks and #rows == 0 and not item.query_error then
      goto continue_block
    end

    local offset = #lines

    if block.label ~= nil then
      local hdr = ("══ %s (%d) ══"):format(block.label, #rows)
      lines[#lines + 1] = hdr
      block_starts[#lines] = bi
      extmarks[#extmarks + 1] = { #lines, "@organ.agenda.block_header", 0, #hdr }
      offset = #lines
    end

    for _, l in ipairs(block_out.lines) do
      lines[#lines + 1] = l
    end
    for _, mk in ipairs(block_out.extmarks) do
      -- Preserve the optional 5th element (extra extmark opts) so
      -- the virt_text right-align tag column survives the per-block
      -- to top-level extmark merge.
      extmarks[#extmarks + 1] = { mk[1] + offset, mk[2], mk[3], mk[4], mk[5] }
    end
    for lnum, row in pairs(block_out.line_index) do
      line_index[lnum + offset] = row
    end

    -- Inter-block separator: Emacs renders ═ across the row between
    -- agenda sections.  Skipped after the last block.  Configure via
    -- `agenda.block_separator` (false -> blank line; true/nil ->
    -- default `═`; single char -> that char repeated; multi-char -> the
    -- literal string padded/clipped to width).
    if bi < #blocks_with_rows then
      local sep_cfg = format.render_opts().block_separator
      if sep_cfg == false then
        lines[#lines + 1] = ""
      else
        local width = format.content_width()
        if width <= 0 then
          width = 75
        end
        local sep
        if type(sep_cfg) == "string" and sep_cfg ~= "" then
          if vim.fn.strdisplaywidth(sep_cfg) == 1 then
            sep = string.rep(sep_cfg, width)
          else
            sep = sep_cfg
            local sw = vim.fn.strdisplaywidth(sep)
            if sw < width then
              sep = sep .. string.rep(" ", width - sw)
            elseif sw > width then
              sep = sep:sub(1, width)
            end
          end
        else
          sep = string.rep("═", width)
        end
        lines[#lines + 1] = sep
        extmarks[#extmarks + 1] = {
          #lines,
          "@organ.agenda.block_separator",
          0,
          #sep,
        }
      end
    end
    ::continue_block::
  end

  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end

  -- Entry-text injection (Emacs `org-agenda-entry-text-mode`).  When
  -- enabled, append up to `max_lines` body lines from each item's
  -- source headline as indented "preview" rows directly under the
  -- agenda row.  Toggled per-buffer by the `E` keymap; default
  -- governed by `agenda.entry_text.on_start` (false).  We do this
  -- after the main render so the per-block emit logic stays clean.
  do
    local agenda_cfg = (require("organ.buf_config").read(nil, "agenda") or {})
    local et_cfg = agenda_cfg.entry_text or {}
    local et_on = (opts and opts.entry_text)
    if et_on == nil then
      et_on = et_cfg.on_start == true
    end
    if et_on and #lines > 0 then
      local max_lines = math.max(1, et_cfg.max_lines or 5)
      local indent = string.rep(" ", 4)
      local new_lines, new_marks, new_index = {}, {}, {}
      local mark_by_lnum = {}
      for _, mk in ipairs(extmarks) do
        local list = mark_by_lnum[mk[1]]
        if not list then
          list = {}
          mark_by_lnum[mk[1]] = list
        end
        list[#list + 1] = mk
      end
      for i = 1, #lines do
        new_lines[#new_lines + 1] = lines[i]
        local out_lnum = #new_lines
        if mark_by_lnum[i] then
          for _, mk in ipairs(mark_by_lnum[i]) do
            new_marks[#new_marks + 1] = { out_lnum, mk[2], mk[3], mk[4], mk[5] }
          end
        end
        if line_index[i] then
          new_index[out_lnum] = line_index[i]
        end
        local r = line_index[i]
        if
          r
          and type(r) == "table"
          and r.file_path
          and r.line_start
          and vim.uv.fs_stat(r.file_path)
        then
          local body_start = r.line_start + 1 -- skip the heading line itself
          local fd = io.open(r.file_path, "r")
          if fd then
            local n, taken = 0, 0
            local in_drawer = false
            for raw in fd:lines() do
              n = n + 1
              if n > body_start then
                local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
                -- Stop at the next heading.
                if trimmed:match("^%*+%s") then
                  break
                end
                -- Skip planning lines (SCHEDULED / DEADLINE / CLOSED)
                -- and drawer interiors so the preview shows real
                -- prose, not metadata the user can already read in
                -- the agenda row prefix.
                local is_planning = trimmed:match("^SCHEDULED:")
                  or trimmed:match("^DEADLINE:")
                  or trimmed:match("^CLOSED:")
                if trimmed:match("^:[%w_]+:$") and trimmed ~= ":END:" then
                  in_drawer = true
                elseif trimmed == ":END:" then
                  in_drawer = false
                elseif not in_drawer and not is_planning and trimmed ~= "" then
                  new_lines[#new_lines + 1] = indent .. trimmed
                  new_marks[#new_marks + 1] =
                    { #new_lines, "@organ.agenda.entry_text", 0, #new_lines[#new_lines] }
                  taken = taken + 1
                  if taken >= max_lines then
                    break
                  end
                end
              end
            end
            fd:close()
          end
        end
      end
      lines, extmarks, line_index = new_lines, new_marks, new_index
    end
  end

  -- Surface any line_format errors collected during rendering (once per call).
  -- The _line_format_error field is left set so callers / tests can inspect it;
  -- it will be cleared at the top of the next render cycle (see above).
  for _, item in ipairs(blocks_with_rows) do
    if item.block._line_format_error then
      require("organ.notify").warn(
        "organ: agenda line_format error: " .. item.block._line_format_error
      )
    end
  end

  return { lines = lines, extmarks = extmarks, line_index = line_index, block_starts = block_starts }
end

M.render = render
M.empty_state_lines = empty_state_lines
M.FOOTER_LINES = FOOTER_LINES

return M
