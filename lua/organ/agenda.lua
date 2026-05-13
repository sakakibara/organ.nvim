-- Agenda buffer for organ.nvim.
--
-- This module is split into:
--   * Pure rendering: render(records, view_opts) -> { lines, extmarks, line_index }
--   * Buffer machinery: open(view_opts), refresh(bufnr), filetype setup (Task 10)
--   * Keymaps + autocmds (Task 11)
--
-- The renderer takes records already produced by query.headlines / query.agenda.
-- It does no I/O, no DB access — just formatting.

local M = {}

local obuf = require("organ.buf")
-- Clock reads — funnel through these so the snapshot test (and any
-- other harness that wants a deterministic agenda) can pin "now" via
-- `config.agenda.now_override`.  The override accepts:
--
--   "YYYY-MM-DD"            → date only; HH:MM derived from os.time()
--                            (use the timestamp form for full
--                            determinism)
--   "YYYY-MM-DDTHH:MM"      → date + time of day
--
-- Production agenda renders leave it nil and use the wall clock.

local function _now_iso()
  local override = (require("organ.buf_config").read(nil, "agenda") or {}).now_override
  if override then
    return override
  end
  return os.date("%Y-%m-%dT%H:%M")
end

local function _today_iso()
  return _now_iso():sub(1, 10)
end

local function _now_ts()
  local override = (require("organ.buf_config").read(nil, "agenda") or {}).now_override
  if not override then
    return os.time()
  end
  local y, mo, d, h, mi = override:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
  if not y then
    y, mo, d = override:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    h, mi = "12", "00"
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
  })
end

-- Date-header format mirrors Emacs's `org-agenda-format-date`:
--   "Sunday      3 May 2026" — full weekday name (left-padded to 9 chars
--   so all weekdays line up), day-of-month with no leading zero, full
--   month name, year.
local WDAY_FULL = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTH_FULL = {
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

-- ISO week number per ISO 8601 (week-of-year for date in `t`).
local function iso_week_of(t)
  -- %V = ISO 8601 week number, available on most modern strftime
  -- implementations (Lua 5.1 + LuaJIT use the C library's strftime).
  local w = tonumber(os.date("%V", t))
  if w then
    return w
  end
  -- Defensive fallback: derive via Thursday-of-week trick.
  local wday = tonumber(os.date("%w", t)) -- 0=Sun..6=Sat
  local thurs = t + (4 - (wday == 0 and 7 or wday)) * 86400
  local y0 = tonumber(os.date("%Y", thurs))
  local jan4 = os.time({ year = y0, month = 1, day = 4, hour = 12 })
  return math.floor((thurs - jan4) / (86400 * 7)) + 1
end

-- "2026-05-03" → "Sunday      3 May 2026 W18".  Day name left-padded
-- to 11 chars (matches Emacs `org-agenda-format-date` default —
-- Wednesday is 9 chars, so the longer names get 2 trailing spaces and
-- the shorter ones pad up; everything aligns at column 13).
local function date_header(iso_date)
  local y, m, d = iso_date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return iso_date
  end
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local wday = WDAY_FULL[tonumber(os.date("%w", t)) + 1]
  local month = MONTH_FULL[tonumber(m)]
  return string.format("%-11s %d %s %s W%02d", wday, tonumber(d), month, y, iso_week_of(t))
end

local function date_only(iso)
  if not iso then
    return nil
  end
  return iso:sub(1, 10)
end

-- Returns "9:00" / "23:45" — no leading zero on the hour, mirroring
-- Emacs's default `org-agenda-time-leading-zero = nil`.
local function time_only(iso)
  if not iso or #iso < 16 then
    return nil
  end
  if iso:sub(11, 11) ~= "T" then
    return nil
  end
  local hh, mm = iso:sub(12, 13), iso:sub(15, 16)
  -- `agenda.time_leading_zero` (Emacs `org-agenda-time-leading-zero`):
  --   false (default) → strip leading zero  ` 9:00` (compact, Emacs default)
  --   true            → keep `09:00`        (uniform 5-cell column)
  local lead = (require("organ.buf_config").read(nil, "agenda") or {}).time_leading_zero
  if lead == true then
    return hh .. ":" .. mm
  end
  return tostring(tonumber(hh)) .. ":" .. mm
end

local function append_effort(parts, marks, col_start, r)
  local cfg_effort = (require("organ.buf_config").read(nil, "effort") or {})
  if cfg_effort.show_in_agenda == false then
    return col_start
  end
  if not r.properties then
    return col_start
  end
  local effort = require("organ.effort")
  local est = effort.row_effort_minutes(r)
  if not est and not r.clocked_minutes then
    return col_start
  end
  local body
  if est and r.clocked_minutes then
    body =
      string.format("[%s/%s]", effort.format(r.clocked_minutes, "hm"), effort.format(est, "hm"))
  elseif est then
    body = string.format("[%s]", effort.format(est, "hm"))
  else
    body = string.format("[%s/?]", effort.format(r.clocked_minutes, "hm"))
  end
  table.insert(parts, "  " .. body)
  marks[#marks + 1] = { "@organ.agenda.effort", col_start + 2, col_start + 2 + #body }
  return col_start + 2 + #body
end

local function append_habit_glyphs(parts, marks, col_start, r)
  if not r.is_habit then
    return col_start
  end
  local habit = require("organ.habit")
  local row = habit.glyph_row({
    completions = r.completions or {},
    scheduled_date = r.scheduled_date and r.scheduled_date:sub(1, 10) or nil,
    period_days = r.habit_period_days or 1,
    alarm_days = r.habit_alarm_days,
  }, r._today, r.habit_glyph_days or 14)
  local col = col_start
  table.insert(parts, "  ")
  col = col + 2
  for _, e in ipairs(row) do
    table.insert(parts, e.char)
    marks[#marks + 1] = { e.hl, col, col + #e.char }
    col = col + #e.char
  end
  return col
end

-- Compute a category for an agenda row, mirroring Emacs:
--   1. Explicit `r.category` if the indexer/query already set one.
--   2. Otherwise, the file's basename without `.org`.
--   3. Falls back to "?" for synthetic rows with no file.
-- Per-render cache of file_path → CATEGORY (via `#+CATEGORY:` directive
-- read from the file's leading comment block). Cleared on each render
-- so a category change becomes visible without a restart.
local _category_cache = setmetatable({}, { __mode = "k" })
local _category_cache_token

-- Read the first ~30 lines of `path` and return the `#+CATEGORY:` value
-- if present (case-insensitive directive name). Cheap; cached per
-- render via _category_cache.
local function file_category(path)
  if _category_cache[path] ~= nil then
    return _category_cache[path]
  end
  local fd = io.open(path, "r")
  if not fd then
    _category_cache[path] = false
    return nil
  end
  local found
  for _ = 1, 30 do
    local line = fd:read("*l")
    if not line then
      break
    end
    local v = line:match("^[#][+][Cc][Aa][Tt][Ee][Gg][Oo][Rr][Yy]%s*:%s*(.+)$")
    if v then
      found = v:gsub("%s+$", "")
      break
    end
  end
  fd:close()
  _category_cache[path] = found or false
  return found
end

local function category_for(r)
  -- Per-headline :CATEGORY: property wins (Emacs precedence).
  if r.category and r.category ~= "" then
    return r.category
  end
  if r.properties and r.properties.CATEGORY and r.properties.CATEGORY ~= "" then
    return r.properties.CATEGORY
  end
  -- Then file's `#+CATEGORY:` keyword.
  if r.file_path and r.file_path ~= "" then
    local v = file_category(r.file_path)
    if v then
      return v
    end
  end
  -- Finally, the file's basename without `.org`.
  if not r.file_path or r.file_path == "" then
    return "?"
  end
  local base = r.file_path:match("([^/]+)%.org$") or r.file_path:match("([^/]+)$")
  return base or "?"
end

local function get_agenda_cfg()
  return (require("organ.buf_config").read(nil, "agenda") or {})
end

-- Render configuration. Mirrors Emacs's `org-agenda-prefix-format` and
-- `org-agenda-tags-column` in spirit; users can override any single field
-- via `organ.config.agenda.*`.
--
-- prefix_format is one of:
--   * a string — applied to every block regardless of kind. Same mini-
--     format-language as Emacs (see format_prefix below for tokens).
--   * a table keyed by view kind: { agenda = "...", todo = "...",
--     stuck = "...", default = "..." } — picked per block. Mirrors
--     Emacs's per-view-type defaults.
--   * a function `function(record, ctx) -> string` — full control.
--
-- Defaults mirror Emacs's `org-agenda-prefix-format`:
--   agenda (daily/weekly): "  %-12:c %?-12t %?s "
--     → category-with-colon padded to 12, time dot-padded to 12 (or
--       12 spaces when un-timed), Scheduled:/Deadline: tag (blank when
--       neither). Matches Emacs's daily-agenda visual style.
--   todo (global TODO list): "  %-12:c "
--     → category-with-colon only; time/sched/dl noise is dropped because
--       the global TODO list isn't date-window-scoped.
local DEFAULT_PREFIX_FORMAT = {
  -- Matches Emacs's `org-agenda-prefix-format` default:
  --   `  %-12:c%?-12t %?-11s `
  -- Layout is three fixed-width fields:
  --   - cat:   12 chars (Tasks: → "Tasks:      ")
  --   - time:  12 chars (timed: ` 9:00 ┄┄┄┄┄ `; untimed: 12 spaces)
  --   - sched: 12 chars (with-label: "Scheduled:  "; without: 12 sp)
  -- NO separator between cat and time — the right-aligned hour
  -- provides the visual gap when the time string is short
  -- (` 9:00 ┄` vs `17:00 ┄`).  Single-space separator between time
  -- and sched.
  agenda = "  %-12:c%?-12t %?-11s ",
  todo = "  %-12:c ",
  stuck = "  %-12:c ",
  default = "  %-12:c ",
}

local function render_opts()
  local cfg = get_agenda_cfg()
  return {
    category_width = cfg.category_width or 12,
    time_width = cfg.time_width or 12,
    todo_width = cfg.todo_width, -- nil → auto-fit per block
    -- Tag right-align column. Default `-1` = "right edge minus 1
    -- char" (window-relative, matches Emacs's `org-agenda-tags-column`
    -- default of -2 closely — Emacs uses -2 to leave 2-char gap;
    -- we use -1 to push tags hard right because our terminal often
    -- wraps to the visible column count).  Override via positive
    -- value (fixed column) or other negative (offset from edge).
    tags_column = cfg.tags_column or -1,
    prefix_format = cfg.prefix_format or DEFAULT_PREFIX_FORMAT,
    -- Hide rows that have no scheduled/deadline date in the daily-agenda
    -- view (mirrors Emacs `org-agenda-include-all-todo = nil`). Set to
    -- true to surface a "(No date)" group instead.
    show_no_date = cfg.show_no_date == true,
    -- Inter-block separator (Emacs `org-agenda-block-separator`).
    -- Accepted shapes:
    --   false        → no separator (just a blank line)
    --   true / nil   → default `═` repeated to the content width
    --   string "X"   → that single char repeated to the content width
    --   string "..." → multi-char strings render as the literal string
    --                  (no rep), trimmed/padded to the content width
    block_separator = cfg.block_separator,
  }
end

-- Pick the right format string for a given block, given a per-kind
-- prefix_format table. Heuristic for kind-detection when the user didn't
-- set `block.kind` explicitly: `from` set → daily-agenda; else → todo.
local function resolve_prefix_format(prefix_format, block)
  if type(prefix_format) ~= "table" then
    return prefix_format
  end
  local kind = block.kind or (block.from and "agenda" or "todo")
  return prefix_format[kind] or prefix_format.default or prefix_format.todo or "  %-12:c "
end

-- Tiny formatter for the prefix string. Mirrors Emacs's
-- `org-agenda-prefix-format` mini-format-language. Supported tokens:
--   %c           category (filename stem unless `#+CATEGORY:` set)
--   %-Nc         category, left-padded to N chars
--   %-N:c        category followed by `:`, padded to N chars total
--                (matches Emacs's `%-12:c` modifier)
--   %t           scheduled time, e.g. `9:00` (no leading zero — Emacs default)
--   %-Nt         time, dot-padded to N chars (Emacs's distinctive style:
--                `9:00......`)
--   %?-Nt        time, rendered as N spaces when empty (so the column
--                stays aligned even for un-timed rows; matches Emacs `%?`)
--   %s           scheduling tag: "Scheduled:", "In N d.:", "Deadline:", etc.
--                Computed per row relative to `opts.today` (which the
--                renderer passes in). Mirrors Emacs `org-agenda-format-
--                date-aligned`'s relative form: today's items show
--                "Scheduled:"; future items show "In N d.:"; deadlines
--                always show "Deadline:".
--   %?s          same, blank when empty
local function date_only_str(iso)
  if type(iso) ~= "string" then
    return nil
  end
  return iso:match("^(%d%d%d%d%-%d%d%-%d%d)")
end

local function iso_to_ts(iso)
  local d = date_only_str(iso)
  if not d then
    return nil
  end
  local y, mo, da = d:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(da),
    hour = 12,
    min = 0,
    sec = 0,
  })
end

local function days_diff(from_iso, to_iso)
  local a, b = iso_to_ts(from_iso), iso_to_ts(to_iso)
  if not a or not b then
    return nil
  end
  return math.floor((b - a) / 86400 + 0.5)
end

-- Compute the per-row scheduling label. `today` is an ISO yyyy-mm-dd
-- string (the renderer's reference point, may be back-dated for tests).
local function sched_label_for(r, today)
  if not today then
    today = _today_iso()
  end
  -- Log-mode synthetic rows carry their own labels (closed / clock /
  -- state) so the prefix reads naturally instead of "Scheduled:".
  if r._log_mode == "closed" then
    return "Closed:"
  elseif r._log_mode == "clock" then
    local mins = r._log_clock_minutes or 0
    return string.format("Clocked: %d:%02d", math.floor(mins / 60), mins % 60)
  elseif r._log_mode == "state" then
    local from = r._log_state_from or "(none)"
    return string.format("State: %s -> %s", from, r._log_state_to or "?")
  end
  -- Format conventions match Emacs's org-agenda for column alignment:
  --   "In   N d.:"    %3d (right-padded) so N=1..999 lines up
  --   "Sched. Nx:"    space after dot (Emacs's literal form)
  --
  -- When a row has BOTH scheduled and deadline, the bucket-day
  -- determines which prefix wins:
  --   * scheduled date == today (the bucket date) → "Scheduled:"
  --   * deadline  date == today                   → "Deadline:"
  --   * else fall through to whichever is sooner / present
  -- Mirrors Emacs's per-bucket precedence (Tuesday's "Submit expense"
  -- row reads "Scheduled:" because Tuesday is its scheduled day, not
  -- "In 2 d.:" because the deadline is later in the week).
  local has_sched = r.scheduled_date and r.scheduled_date ~= ""
  local has_dead = r.deadline_date and r.deadline_date ~= ""
  local sched_d = has_sched and days_diff(today, r.scheduled_date) or nil
  local dead_d = has_dead and days_diff(today, r.deadline_date) or nil
  -- Habit rows projected forward to a future cycle (`_synthetic_repeater`)
  -- get NO sched-label, matching Emacs's style: only the carryover
  -- (Sched.Nx) and the row's own scheduled-day get a label, every
  -- other in-window cycle just shows `TODO Foo`.
  if r.is_habit and r._synthetic_repeater and sched_d == 0 then
    return ""
  end

  -- Priority order for the sched-label (matches Emacs's
  -- org-agenda-format priority — overdue-scheduled wins over
  -- deadline-warning when both apply, because the overdue scheduled
  -- is the primary view of the row):
  --   1. scheduled today          → "Scheduled:"
  --   2. deadline today           → "Deadline:"
  --   3. scheduled overdue        → "Sched. Nx:" (carryover label)
  --   4. deadline within 14 days  → "In   N d.:"  (early warning)
  --   5. scheduled within 14 days → "In   N d.:"
  --   6. fallback                 → "Scheduled:" / "Deadline:" / ""
  if sched_d == 0 then
    return "Scheduled:"
  end
  if dead_d == 0 then
    return "Deadline:"
  end
  if has_sched and sched_d and sched_d < 0 then
    -- Overdue: Emacs shows "Sched.Nx" — N is repeat cycles late for
    -- habit-style rows, raw days late otherwise.  Falls through to
    -- the cycle-computation logic below.
    local d = sched_d
    local cycles = -d
    if r.is_habit and r.scheduled and r.scheduled ~= "" then
      local ok, rep_mod = pcall(require, "organ.todo.repeater")
      if ok then
        local rep = rep_mod.parse(r.scheduled)
        local ok_h, habit = pcall(require, "organ.habit")
        if rep and ok_h and habit.period_days then
          local period = habit.period_days(rep)
          if period and period > 0 then
            cycles = math.max(1, math.floor(-d / period))
          end
        end
      end
    end
    return string.format("Sched.%2dx:", cycles)
  end
  -- Future cases after the overdue check has fallen through.
  if has_dead then
    local d = dead_d
    if d == nil then
      return "Deadline:"
    end
    if d < 0 then
      return "Past due:"
    end
    if d <= 14 then
      return string.format("In %3d d.:", d)
    end
    return "Deadline:"
  end
  if has_sched then
    local d = sched_d
    if d == nil then
      return "Scheduled:"
    end
    if d > 0 then
      return string.format("In %3d d.:", d)
    end
    return "Scheduled:"
  end
  return ""
end

local function format_prefix(spec, r, opts)
  local cat = category_for(r)
  local tstr = time_only(r.scheduled_date) or ""
  local sched = sched_label_for(r, opts and opts.today)
  -- Note: Emacs's org-agenda DOES emit "Scheduled:" / "Sched. Nx:"
  -- on habit rows; the habit consistency graph appears AFTER the
  -- normal row content rather than replacing the sched label.

  local function pad_with(value, width, opt_optional, pad_char)
    pad_char = pad_char or " "
    -- Emacs `%?` semantics: optional + empty value collapses to NO
    -- output (and the format-string separator after the field is
    -- swallowed by the outer loop).  This is what makes Emacs's
    -- habit untimed row render as `Habits:     TODO Morning walk`
    -- instead of `Habits:                               TODO Morning
    -- walk` — empty time + empty sched columns disappear entirely.
    if (not value or value == "") and opt_optional then
      return ""
    end
    if width <= 0 then
      return value
    end
    -- Multi-byte-safe: measure value by display width (so a `┄`-padded
    -- "9:00 ┄┄┄┄┄┄┄" lines up the same as a "9:00........").  Each
    -- pad-char copy adds 1 column regardless of its byte length.
    local val_w = vim.fn.strdisplaywidth(value)
    if val_w >= width then
      return value
    end
    return value .. string.rep(pad_char, width - val_w)
  end

  -- When an optional field collapses to "" (Emacs `%?` semantics for
  -- empty value), swallow the immediately-following literal space so
  -- successive empty optionals don't accumulate stray separators.
  local out, i = {}, 1
  local last_collapsed = false
  while i <= #spec do
    local c = spec:sub(i, i)
    if c ~= "%" then
      if last_collapsed and c == " " then
        last_collapsed = false
      else
        out[#out + 1] = c
        last_collapsed = false
      end
      i = i + 1
    else
      -- Match `%[?][-]?[0-9]*[:]?[ctsT]`.
      local j = i + 1
      local optional = false
      if spec:sub(j, j) == "?" then
        optional = true
        j = j + 1
      end
      local sign_pos = j
      if spec:sub(j, j) == "-" then
        j = j + 1
      end
      while spec:sub(j, j):match("%d") do
        j = j + 1
      end
      local colon_modifier = false
      if spec:sub(j, j) == ":" then
        colon_modifier = true
        j = j + 1
      end
      local fmt_specifier = spec:sub(j, j)
      local width_str = (spec:sub(sign_pos, j - 1):gsub("^-", ""):gsub(":", ""))
      local width = tonumber(width_str)
      local value
      local pad_char = " "
      if fmt_specifier == "c" then
        value = cat
        -- Category icons (Emacs `org-agenda-category-icon-alist`):
        -- prepend a configured icon/sigil when the category matches.
        -- Map: { category_name = "icon ", … }.  No-op when unset.
        local icons = (require("organ.buf_config").read(nil, "agenda") or {}).category_icons
        if type(icons) == "table" and icons[cat] then
          value = icons[cat] .. value
        end
        if colon_modifier then
          value = value .. ":"
        end
        -- Auto-fit override: render_block computes the max actual
        -- category width across all rows in this block so a long
        -- category doesn't push successive columns right on one row
        -- while leaving them un-pushed on others.  Use it as the
        -- effective minimum width when it exceeds the spec's
        -- declared width.  `opts` is what render_block calls
        -- block_opts -- format_prefix takes it as its third arg.
        if opts and opts.category_width and opts.category_width > (width or 0) then
          width = opts.category_width
        end
      elseif fmt_specifier == "t" then
        value = tstr
        -- Emacs right-aligns the time to a 5-char field so single-
        -- digit hours sit one column further right and `:00`
        -- aligns across rows: ` 9:00 ┄┄┄┄┄`, `17:00 ┄┄┄┄┄`.  The
        -- format-string trailing separator gives the single space
        -- between time and the next column.  Untimed rows fall
        -- through to the regular width-pad branch.
        if value ~= "" then
          out[#out + 1] = string.format("%5s ┄┄┄┄┄", value)
          i = j + 1
          goto continue
        end
      elseif fmt_specifier == "s" then
        value = sched
      else
        -- Unknown specifier: emit verbatim.
        out[#out + 1] = spec:sub(i, j)
        i = j + 1
        goto continue
      end
      if not width then
        if optional and value == "" then
          value = ""
        else
          value = value
        end
      else
        value = pad_with(value or "", width, optional, pad_char)
      end
      if value == "" and optional then
        last_collapsed = true
      else
        out[#out + 1] = value
        last_collapsed = false
      end
      i = j + 1
      ::continue::
    end
  end
  local _ = opts -- reserved for future use
  return table.concat(out)
end

-- Visible content width of the agenda window (gutter excluded).  We
-- subtract `textoff` from `getwininfo()[1].width` because sign column,
-- line numbers, and fold column don't count as text cells — padding
-- to the gutter-inclusive width pushes tags off the visible area by
-- exactly `textoff` chars.  Falls back to `textwidth` (or 80) when no
-- window context (headless / tests).
local function content_width()
  local edge
  local ok, wins = pcall(vim.fn.getwininfo, vim.api.nvim_get_current_win())
  if ok and wins and wins[1] then
    local total = wins[1].width or 0
    local off = wins[1].textoff or 0
    if total > 0 then
      edge = total - off
    end
  end
  if not edge or edge <= 0 then
    edge = (vim.o.textwidth ~= 0 and vim.o.textwidth) or 80
  end
  return edge
end

-- Right-align tags at column `tags_column`. If line is already wider than
-- the column, the tag block sits two spaces to its right. If `tags_column`
-- is negative, treat as offset from the right edge of the window's
-- content area. Mirrors Emacs `org-agenda-tags-column`.
local function tag_padding(line_len, tags_str, tags_column)
  if tags_column < 0 then
    tags_column = content_width() + tags_column -- tags_column is negative
  end
  local target_col = tags_column - #tags_str
  local pad = target_col - line_len
  if pad < 2 then
    pad = 2
  end
  return string.rep(" ", pad)
end

-- Format a single headline into a line string + a list of highlight ranges.
-- Returns (line_str, extmarks_list) where each extmark is
-- { hl_group, col_start, col_end }.
--
-- `block_opts.todo_width`: right-pad the TODO column to a width agreed
-- across all rows in this render block (auto-fit, mirrors Emacs).
-- `block_opts.prefix_format`: the resolved per-block prefix-format spec
-- (string or function). Caller looks it up via resolve_prefix_format()
-- so per-view-type tables work.
local function format_line(r, block_opts)
  block_opts = block_opts or {}
  local opts = render_opts()
  -- Thread the renderer's "today" into the prefix formatter so %s can
  -- compute relative-time labels (In N d., Sched. Nx, etc.) per row.
  opts.today = block_opts.today or opts.today
  -- Thread the per-block auto-fit category width (computed once over
  -- all rows in the block by render_block) so format_prefix's %c
  -- pads to the same column on every row.  Without this propagation
  -- format_prefix only sees the config default and a longer category
  -- on one row pushes successive columns right while leaving them
  -- un-pushed on others.
  opts.category_width = block_opts.category_width or opts.category_width
  local todo_width = block_opts.todo_width or opts.todo_width or 0
  local prefix_spec = block_opts.prefix_format or opts.prefix_format
  if type(prefix_spec) == "table" then
    -- Bare format_line call (no enclosing block) — pick the table's
    -- "default" entry as the safest fallback.
    prefix_spec = prefix_spec.default or prefix_spec.todo or "  %-12:c "
  end
  local parts, marks = {}, {}

  -- Prefix block (category + time + sched/dl tag) — mirrors Emacs's
  -- `org-agenda-prefix-format`.
  local prefix_str
  if type(prefix_spec) == "function" then
    local ok, s = pcall(prefix_spec, r, { category = category_for(r), today = opts.today })
    prefix_str = ok and s or ""
  else
    prefix_str = format_prefix(prefix_spec, r, opts)
  end
  table.insert(parts, prefix_str)
  -- Locate semantic substrings inside the prefix and highlight them.
  -- Category, time, and the Scheduled:/Deadline: tag all live in the
  -- prefix string so we colorize by string-search.
  do
    local cat = category_for(r)
    local cat_start = prefix_str:find(cat, 1, true)
    if cat_start then
      marks[#marks + 1] = { "@organ.agenda.category", cat_start - 1, cat_start - 1 + #cat }
    end
    local tstr = time_only(r.scheduled_date)
    if tstr then
      local t_start = prefix_str:find(tstr, 1, true)
      if t_start then
        marks[#marks + 1] = { "@organ.agenda.time", t_start - 1, t_start - 1 + #tstr }
      end
    end
    -- The %s token emits one of:
    --   "Scheduled:"   today's scheduled rows
    --   "In N d.:"     future scheduled / deadline within 14 days
    --   "Sched.Nx:"    overdue scheduled
    --   "Deadline:"    deadlines (today or far-future)
    --   "Past due:"    overdue deadlines
    -- Color each so the prefix doesn't read as a wall of repeated text.
    for _, pair in ipairs({
      { "Scheduled:", "@organ.agenda.scheduled" },
      { "Deadline:", "@organ.agenda.deadline" },
      { "Past due:", "@organ.agenda.deadline" },
    }) do
      local p = prefix_str:find(pair[1], 1, true)
      if p then
        marks[#marks + 1] = { pair[2], p - 1, p - 1 + #pair[1] }
      end
    end
    -- "In   N d.:" and "Sched. Nx:" — match by pattern (note the space
    -- after "Sched." now that we mirror Emacs's literal form).
    local in_s, in_e = prefix_str:find("In%s+%d+%s+d%.:")
    if in_s then
      marks[#marks + 1] = { "@organ.agenda.scheduled", in_s - 1, in_e }
    end
    local sx_s, sx_e = prefix_str:find("Sched%.%s+%d+x:")
    if sx_s then
      marks[#marks + 1] = { "@organ.agenda.deadline", sx_s - 1, sx_e }
    end
  end
  local col = #prefix_str

  -- TODO state (left-padded to `todo_width`; no padding if nothing in this
  -- block has a state).  When `agenda.todo_keyword_format` is set
  -- (Emacs `org-agenda-todo-keyword-format`, default `"%s"`), the
  -- keyword passes through `string.format` first so users can right-
  -- pad / left-pad / wrap it.  Examples: `"%-7s"` right-pads to 7
  -- chars so all rows align across `TODO` / `NEXT` / `WAITING`;
  -- `"[%s]"` wraps in brackets.
  if todo_width > 0 then
    local todo_raw = r.todo_state or ""
    local kw_fmt = (require("organ.buf_config").read(nil, "agenda") or {}).todo_keyword_format
      or "%s"
    local todo_disp = todo_raw
    if r.todo_state and kw_fmt ~= "%s" then
      local ok, formatted = pcall(string.format, kw_fmt, todo_raw)
      if ok then
        todo_disp = formatted
      end
    end
    local todo_padded = todo_disp
    if #todo_disp < todo_width then
      todo_padded = todo_disp .. string.rep(" ", todo_width - #todo_disp)
    end
    table.insert(parts, todo_padded)
    if r.todo_state then
      local hl = "@organ.agenda.todo_" .. r.todo_state:lower()
      marks[#marks + 1] = { hl, col, col + #todo_disp }
    end
    col = col + #todo_padded
    table.insert(parts, " ")
    col = col + 1
  end

  -- Priority cookie `[#A]` — matches the org-mode source format. Blank
  -- when unset (no `[ ]` placeholder; mirrors Emacs).
  if r.priority then
    local prio_text = "[#" .. r.priority .. "]"
    table.insert(parts, prio_text .. " ")
    marks[#marks + 1] = { "@organ.agenda.priority_" .. r.priority, col, col + #prio_text }
    col = col + #prio_text + 1
  end

  -- Title. Apply @organ.agenda.title so titles read distinctly from
  -- body text (Emacs uses org-agenda-structure-secondary-face / the
  -- per-todo-state face that bleeds into title bytes; we keep them
  -- separate so users can theme each independently).
  local title = r.title or ""
  if title ~= "" then
    table.insert(parts, title)
    marks[#marks + 1] = { "@organ.agenda.title", col, col + #title }
    col = col + #title
  end

  -- Effort estimate / clock budget.
  col = append_effort(parts, marks, col, r)

  -- Tags — right-aligned at `tags_column` (Emacs convention).  When
  -- inherited tags are present (n_direct_tags < #tags), Emacs emits
  -- `:inherited1:inherited2::direct1:direct2:` — the doubled colon
  -- between sections marks the inheritance boundary.  Pure-direct
  -- and pure-inherited rows just get `:tag1:tag2:`.
  if r.tags and #r.tags > 0 then
    local n_direct = r.n_direct_tags or #r.tags
    local tag_str
    -- Emacs's tag-marker convention:
    --   * pure-direct, no inherited        → `:tag1:tag2:`
    --   * pure-inherited, no direct        → `:tag1:tag2::`  (trailing `::`)
    --   * mixed                            → `:inh1::dir1:dir2:`
    if n_direct >= #r.tags then
      tag_str = ":" .. table.concat(r.tags, ":") .. ":"
    elseif n_direct == 0 then
      tag_str = ":" .. table.concat(r.tags, ":") .. "::"
    else
      local direct, inherited = {}, {}
      for i, t in ipairs(r.tags) do
        if i <= n_direct then
          direct[#direct + 1] = t
        else
          inherited[#inherited + 1] = t
        end
      end
      tag_str = ":" .. table.concat(inherited, ":") .. "::" .. table.concat(direct, ":") .. ":"
    end
    local agcfg = require("organ.buf_config").read(nil, "agenda") or {}
    local virt_align = (agcfg.tags_virt_align ~= false)
    -- Build per-tag virt_text chunks so `tags.faces[tag]` can color
    -- individual tags (Emacs `org-tag-faces`).  Fall back to the
    -- generic `@organ.agenda.tag` highlight for tags without a
    -- registered face.  When `faces` is empty, return a single chunk
    -- so we don't pay the split cost.
    local tags_cfg = (require("organ.buf_config").read(nil, "tags") or {})
    local faces = tags_cfg.faces or {}
    local function build_virt_chunks()
      if next(faces) == nil then
        return { { tag_str, "@organ.agenda.tag" } }
      end
      local chunks = {}
      -- Reuse the direct/inherited split derived above.
      local direct, inherited = {}, {}
      if n_direct >= #r.tags then
        direct = r.tags
      elseif n_direct == 0 then
        inherited = r.tags
      else
        for i, t in ipairs(r.tags) do
          if i <= n_direct then
            direct[#direct + 1] = t
          else
            inherited[#inherited + 1] = t
          end
        end
      end
      local function emit_tag_chunks(list)
        for _, t in ipairs(list) do
          chunks[#chunks + 1] = { ":", "@organ.agenda.tag" }
          if faces[t] then
            chunks[#chunks + 1] = { t, "@organ.agenda.tag_" .. t }
          else
            chunks[#chunks + 1] = { t, "@organ.agenda.tag" }
          end
        end
      end
      if n_direct >= #r.tags then
        emit_tag_chunks(direct)
        chunks[#chunks + 1] = { ":", "@organ.agenda.tag" }
      elseif n_direct == 0 then
        emit_tag_chunks(inherited)
        chunks[#chunks + 1] = { "::", "@organ.agenda.tag" }
      else
        emit_tag_chunks(inherited)
        chunks[#chunks + 1] = { "::", "@organ.agenda.tag" }
        -- emit_tag_chunks adds leading `:` for each tag, which becomes
        -- a third colon in a row — strip the first colon by passing
        -- direct chunks built manually.
        for i, t in ipairs(direct) do
          if faces[t] then
            chunks[#chunks + 1] = { t, "@organ.agenda.tag_" .. t }
          else
            chunks[#chunks + 1] = { t, "@organ.agenda.tag" }
          end
          if i < #direct then
            chunks[#chunks + 1] = { ":", "@organ.agenda.tag" }
          end
        end
        chunks[#chunks + 1] = { ":", "@organ.agenda.tag" }
      end
      return chunks
    end
    if virt_align then
      -- Tags rendered as a `virt_text_pos = "right_align"` extmark
      -- rather than written into the line.  Neovim's render layer
      -- positions virt-text against the window's right edge on
      -- every redraw, so window resizes / splits / Zen-mode toggles
      -- re-align the tag column for free with no buffer churn or
      -- flicker (same mechanism as winbar / statuscolumn).  Nothing
      -- in the line string itself changes; tags float
      -- independently.  Strictly better than Emacs's "re-align on
      -- refresh only" behavior.
      --
      -- Overflow guard: when the line text + a 2-char gap + tag
      -- block would not fit in the window's content area, the tag
      -- virt_text would visually overlap the END of the title.
      -- Title visibility wins — drop the tag and emit a single-cell
      -- marker (`tags_overflow_marker`, default `›`) so the user
      -- still knows tags exist on this row and can widen the
      -- window to see them.  Marks tuple's 5th element is an
      -- `extra_opts` table merged into the nvim_buf_set_extmark
      -- call by `apply_extmarks`.
      local overflow_marker = agcfg.tags_overflow_marker
      if overflow_marker == nil then
        overflow_marker = "›"
      end
      local needed = col + 2 + vim.fn.strdisplaywidth(tag_str)
      if needed > content_width() and overflow_marker ~= false then
        marks[#marks + 1] = {
          "_virt",
          col,
          col,
          {
            virt_text = { { overflow_marker, "@organ.agenda.tag_overflow" } },
            virt_text_pos = "right_align",
            hl_mode = "combine",
          },
        }
      else
        marks[#marks + 1] = {
          "_virt",
          col,
          col,
          {
            virt_text = build_virt_chunks(),
            virt_text_pos = "right_align",
            hl_mode = "combine",
          },
        }
      end
      -- col unchanged — virt_text doesn't occupy line cells.
    else
      -- Legacy inline-padding path: bake tag chars + spaces into
      -- the buffer line.  Use this when consumers need plain-text
      -- output (export, copy/paste, headless snapshot tests).
      --
      -- Overflow guard (same policy as virt_align mode): when the
      -- title + 2-char gap + tag block exceeds the visible content
      -- width, write a single-cell `tags_overflow_marker` (default
      -- `›`) instead of the full tag run.  Title stays readable,
      -- user knows tags exist.  Set `tags_overflow_marker = false`
      -- to keep the legacy behavior of always emitting full tags
      -- (which then get clipped at the window edge).
      local overflow_marker = agcfg.tags_overflow_marker
      if overflow_marker == nil then
        overflow_marker = "›"
      end
      local edge = content_width()
      if overflow_marker ~= false and (col + 2 + vim.fn.strdisplaywidth(tag_str)) > edge then
        local pad = math.max(2, edge - col - vim.fn.strdisplaywidth(overflow_marker))
        table.insert(parts, string.rep(" ", pad) .. overflow_marker)
        marks[#marks + 1] = {
          "@organ.agenda.tag_overflow",
          col + pad,
          col + pad + #overflow_marker,
        }
        col = col + pad + #overflow_marker
      else
        local pad = tag_padding(col, tag_str, opts.tags_column)
        table.insert(parts, pad .. tag_str)
        if next(faces) == nil then
          marks[#marks + 1] = { "@organ.agenda.tag", col + #pad, col + #pad + #tag_str }
        else
          -- Per-tag highlight: walk the chunks built for virt_text and
          -- emit one extmark per chunk at the corresponding byte
          -- offset inside the inlined tag_str.
          local off = col + #pad
          for _, chunk in ipairs(build_virt_chunks()) do
            local txt, hl = chunk[1], chunk[2]
            marks[#marks + 1] = { hl, off, off + #txt }
            off = off + #txt
          end
        end
        col = col + #pad + #tag_str
      end
    end
  end

  -- Habit consistency graph (`..............` after the tag).  Off by
  -- default: Emacs's `org-habit` ships disabled in most distributions
  -- and the typical agenda view doesn't show graphs, so for parity
  -- we don't either.  Users who explicitly want them set
  -- `agenda.show_habit_graphs = true`.
  local show_graphs = (require("organ.buf_config").read(nil, "agenda") or {}).show_habit_graphs
    == true
  if show_graphs then
    col = append_habit_glyphs(parts, marks, col, r)
  end

  return table.concat(parts), marks
end

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

-- Public pure helpers.

local FLAT_FIELDS = {
  "from",
  "to",
  "types",
  "todo",
  "tags",
  "priority",
  "title_match",
  "tag_match",
  "group_by",
  "include_overdue",
  "order_within_group",
  "line_format",
  "kind",
  "label",
  "sorting_strategy",
  "groups",
  -- Date-window controls (resolve to from/to in M.resolve_span).
  "span",
  "start_day",
  "week_starts_on",
}

-- Maps `week_starts_on` config strings to ISO weekday numbers.  The
-- sentinel "today" returns nil, which the caller interprets as "no
-- weekday anchor; the window starts on the anchor date as-is".
local WEEKDAY_NAME_TO_ISO = {
  monday = 1,
  tuesday = 2,
  wednesday = 3,
  thursday = 4,
  friday = 5,
  saturday = 6,
  sunday = 7,
}

local function resolve_week_anchor(value)
  if value == "today" then
    return nil
  end
  if type(value) == "string" then
    local n = WEEKDAY_NAME_TO_ISO[value:lower()]
    if n then
      return n
    end
  end
  return 1 -- default Monday for any unrecognized value
end

-- Resolve `span` + `start_day` + `week_starts_on` to absolute
-- `from` / `to` ISO dates.  Mirrors Emacs's `org-agenda-span`,
-- `org-agenda-start-day`, and `org-agenda-start-on-weekday`.
--
-- Resolution is non-destructive: returns nil when the block already
-- has explicit `from`/`to` (the block's literal window wins) or when
-- no span is specified.  Otherwise returns (from_iso, to_iso) computed
-- from:
--   * start_day: anchor (default "today"; accepts ISO or "+Nd"/"-Nd")
--   * span:      one of "day" | "week" | "fortnight" | "month" |
--                "year" | <integer N> (N days)
--   * week_starts_on: weekly-view anchor.  "monday".."sunday" pin the
--                first day of the week; "today" disables the anchor.
--
-- Public so a test can exercise it without going through the full
-- agenda buffer creation chain.
function M.resolve_span(block, agenda_cfg)
  if block.from or block.to then
    return nil
  end
  agenda_cfg = agenda_cfg or {}
  local span = block.span or agenda_cfg.span
  if not span then
    return nil
  end

  local start_day = block.start_day or agenda_cfg.start_day or "today"
  local function resolve_anchor(s)
    if s == "today" then
      return _today_iso()
    end
    local sign, n = s:match("^([%+%-])(%d+)d$")
    if sign and n then
      local off = tonumber(n) * 86400 * (sign == "-" and -1 or 1)
      return os.date("%Y-%m-%d", _now_ts() + off)
    end
    if s:match("^%d%d%d%d%-%d%d%-%d%d") then
      return s:sub(1, 10)
    end
    return _today_iso()
  end
  local anchor = resolve_anchor(start_day)
  local anchor_ts = iso_to_ts(anchor)
  if not anchor_ts then
    return nil
  end

  -- For "week" and "fortnight", shift the anchor backwards to the
  -- configured start-of-week day.  When the value is "today" (or any
  -- nil-resolving form), no shift happens -- the window starts on
  -- the anchor date itself.
  local function shift_to_weekstart(ts, dow_target)
    if dow_target == nil then
      return ts
    end
    local w = tonumber(os.date("%w", ts)) -- 0..6
    local iso = (w == 0) and 7 or w
    local back = (iso - dow_target) % 7
    return ts - back * 86400
  end

  local raw = block.week_starts_on
  if raw == nil then
    raw = agenda_cfg.week_starts_on
  end
  local sow = resolve_week_anchor(raw)

  local from_ts, to_ts
  if span == "day" or span == 1 then
    from_ts, to_ts = anchor_ts, anchor_ts
  elseif span == "week" then
    from_ts = shift_to_weekstart(anchor_ts, sow)
    to_ts = from_ts + 6 * 86400
  elseif span == "fortnight" then
    from_ts = shift_to_weekstart(anchor_ts, sow)
    to_ts = from_ts + 13 * 86400
  elseif span == "month" then
    local dt = os.date("*t", anchor_ts)
    from_ts = os.time({ year = dt.year, month = dt.month, day = 1, hour = 12 })
    -- Last day = day before the first of next month.
    local nm_y, nm_m = dt.year, dt.month + 1
    if nm_m > 12 then
      nm_y, nm_m = nm_y + 1, 1
    end
    to_ts = os.time({ year = nm_y, month = nm_m, day = 1, hour = 12 }) - 86400
  elseif span == "year" then
    local dt = os.date("*t", anchor_ts)
    from_ts = os.time({ year = dt.year, month = 1, day = 1, hour = 12 })
    to_ts = os.time({ year = dt.year, month = 12, day = 31, hour = 12 })
  elseif type(span) == "number" and span > 0 then
    from_ts = anchor_ts
    to_ts = anchor_ts + (span - 1) * 86400
  else
    return nil -- unknown span shape, fall through
  end
  return os.date("%Y-%m-%d", from_ts), os.date("%Y-%m-%d", to_ts)
end

function M.normalize_view(v, view_name)
  view_name = view_name or "default_view"
  if type(v) ~= "table" then
    return nil, ("agenda view '%s': expected a table, got %s"):format(view_name, type(v))
  end
  if v.blocks ~= nil then
    for _, k in ipairs(FLAT_FIELDS) do
      if v[k] ~= nil then
        return nil,
          ("agenda view '%s': cannot mix top-level filter fields with 'blocks'"):format(view_name)
      end
    end
    if type(v.blocks) ~= "table" then
      return nil,
        ("agenda view '%s': 'blocks' must be a table, got %s"):format(view_name, type(v.blocks))
    end
    if #v.blocks == 0 then
      return nil, ("agenda view '%s': blocks list is empty"):format(view_name)
    end
    for i, b in ipairs(v.blocks) do
      if type(b.label) ~= "string" or b.label == "" then
        return nil, ("agenda view '%s': block at index %d missing 'label'"):format(view_name, i)
      end
    end
    local blocks = {}
    for i, b in ipairs(v.blocks) do
      local copy = {}
      for k, val in pairs(b) do
        copy[k] = val
      end
      blocks[i] = copy
    end
    -- Resolve span → from/to for each block that asked for it.
    local agenda_cfg_n = (require("organ.buf_config").read(nil, "agenda") or {})
    for _, b in ipairs(blocks) do
      local rfrom, rto = M.resolve_span(b, agenda_cfg_n)
      if rfrom and rto then
        b.from, b.to = rfrom, rto
      end
    end
    return { blocks = blocks, refresh_debounce_ms = v.refresh_debounce_ms }
  end
  local block = {}
  for _, k in ipairs(FLAT_FIELDS) do
    block[k] = v[k]
  end
  -- Same span-resolve for the flat (single-block) view shape.
  local agenda_cfg_n = (require("organ.buf_config").read(nil, "agenda") or {})
  local rfrom, rto = M.resolve_span(block, agenda_cfg_n)
  if rfrom and rto then
    block.from, block.to = rfrom, rto
  end
  return { blocks = { block }, refresh_debounce_ms = v.refresh_debounce_ms }
end

-- Validate a path the user typed at the M-CR add-entry prompt.
-- Returns (true, nil) when safe, or (false, reason) otherwise.
--
-- Refuses two failure modes:
--   1. extension is not .org / .org_archive
--      (writefile OVERWRITES; a fat-finger accept of a wrong default
--       shouldn't clobber /etc/passwd or a binary file)
--   2. canonical path doesn't start with config.org_dir
--      (constrains the write to the user's workspace)
--
-- Public so a test can exercise the rules without going through the
-- M-CR keymap chain.
function M.add_entry_path_ok(file)
  if type(file) ~= "string" or file == "" then
    return false, "empty path"
  end
  if not file:match("%.org$") and not file:match("%.org_archive$") then
    return false, "refusing to write non-.org file: " .. file
  end
  local org_dir = require("organ.buf_config").read(nil, "org_dir")
  if org_dir and org_dir ~= "" then
    local canon = require("organ.path").canonical(file) or file
    local canon_dir = require("organ.path").canonical(org_dir) or org_dir
    if canon:sub(1, #canon_dir) ~= canon_dir then
      return false, "refusing to write outside org_dir: " .. file
    end
  end
  return true
end

-- Agenda fold model — three nesting levels for the multi-block view:
--   1. View header (`Week-agenda (W19):`) sits at level 0 (never folded).
--   2. Block separators (`════════════════`) start a level-1 fold.
--   3. Day headers (`Monday      4 May 2026 W19`) start a level-2 fold
--      so users can collapse a single day inside a multi-day block
--      while keeping siblings open.
-- All other lines inherit the most-recent header's level.
local function _is_block_sep(line)
  return line:sub(1, 6) == "══" or line:sub(1, 6) == "──" or line:sub(1, 2) == "=="
end

local function _is_day_header(line)
  return line:match("^%a+%s+%d+%s+%a+%s+%d%d%d%d") ~= nil
end

function M.foldexpr(lnum)
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
  -- Block separator: level-1 fold start.  Glyph variants: `══`
  -- (default), `──`, or ASCII `==` fallback.  Each unicode glyph is
  -- 3 bytes so 2 of them = 6 bytes; ASCII = 2 bytes.
  if _is_block_sep(line) then
    return ">1"
  end
  -- Day header: `Monday      4 May 2026 …` shape.  Level-2 fold start
  -- so each day collapses individually.
  if _is_day_header(line) then
    return ">2"
  end
  -- View header line (`Week-agenda (W19):`) — level 0, never folded.
  if line:match("^%a[%w%-]*%-agenda%s*%(W%d") then
    return "0"
  end
  -- The line immediately BEFORE a day header drops to level 1 so the
  -- next `>2` is a level-1→level-2 transition; without this, vim
  -- renders adjacent level-2 fold starts as one continuous fold and
  -- statuscolumn (which compares foldlevel against the prior line)
  -- only draws a chevron on the first day header.
  local next_line = vim.api.nvim_buf_get_lines(0, lnum, lnum + 1, false)[1]
  if next_line and _is_day_header(next_line) then
    return "1"
  end
  return "="
end

-- Public renderer.

-- Per-block primitive. Same logic as the previous M.render: overdue bucket,
-- group_by day/none, sort, format_line.
local function render_block(rows, block, now_override)
  block = block or {}
  local today = now_override or _today_iso()
  local opts = render_opts()

  -- Auto-fit TODO column to the longest keyword actually present in this
  -- block. Mirrors Emacs's behavior — column shrinks when no DONE state
  -- is in view, etc. Set agenda.todo_width in config to override.
  local block_opts = {
    todo_width = opts.todo_width,
    prefix_format = resolve_prefix_format(opts.prefix_format, block),
    today = today,
  }
  if not block_opts.todo_width then
    local kw_fmt = (require("organ.buf_config").read(nil, "agenda") or {}).todo_keyword_format
      or "%s"
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
    block_opts.todo_width = max -- 0 → no TODO column at all (clean view)
  end

  -- Auto-fit category column.  format_line's `%-N:c` only pads to N;
  -- a longer category pushes successive columns right and breaks
  -- alignment row-to-row (a 12-char category prints fine, but a row
  -- with `refile_source:` from a long-basename file shifts the
  -- "Sched.:" column 2 cells right).  Compute the actual max for
  -- this block once and have format_line use that as the effective
  -- minimum width for every row, so the column reads as a true
  -- column.  cfg.category_width still acts as the lower bound.
  do
    local declared = (require("organ.buf_config").read(nil, "agenda") or {}).category_width or 12
    local max = declared
    for _, r in ipairs(rows) do
      local cat = category_for(r) or ""
      -- +1 for the trailing colon, +1 more so the longest category
      -- still gets a single-space separator before the next column
      -- (otherwise `refile_source:Scheduled:` runs together while
      -- shorter categories like `agenda_demo:  Scheduled:` get a
      -- visible gap from the auto-pad).
      local w = vim.fn.strdisplaywidth(cat) + 2
      if w > max then
        max = w
      end
    end
    block_opts.category_width = max
  end

  -- Hide undated rows in the daily-agenda view (mirrors Emacs default).
  -- Activated when block.kind explicitly says "agenda" OR when block has
  -- a date window (block.from set). Override with agenda.show_no_date=true.
  local kind = block.kind or (block.from and "agenda" or "todo")
  if kind == "agenda" and not opts.show_no_date then
    local filtered = {}
    for _, r in ipairs(rows) do
      if r.scheduled_date or r.deadline_date or r.closed_date or r._bucket_date then
        filtered[#filtered + 1] = r
      end
    end
    rows = filtered
  end

  local fmt = function(r)
    return format_line(r, block_opts)
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
      return format_line(r, block_opts)
    end
  end

  local lines, extmarks, line_index = {}, {}, {}
  local function emit_line(text, marks, row)
    lines[#lines + 1] = text
    local lnum = #lines
    if marks then
      for _, mk in ipairs(marks) do
        -- Preserve the optional 4th element (extra extmark opts —
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

  -- Repeater expansion: a row scheduled with `+Nd` / `++Nw` / `.+Nm`
  -- (and so on) effectively occurs every N units. Without expansion,
  -- only the original date appears in the agenda; users who track
  -- daily habits / weekly chores see nothing on the days between.
  -- Toggle with `agenda.show_future_repeats` (default true; matches
  -- Emacs `org-agenda-show-future-repeats`).
  local show_repeats = (
    (require("organ.buf_config").read(nil, "agenda") or {}).show_future_repeats ~= false
  )
  do
    local repeater_mod_ok, repeater_mod = pcall(require, "organ.todo.repeater")
    if show_repeats and repeater_mod_ok and block.from and block.to then
      local q = require("organ.query")
      local from_ts = iso_to_ts(q.parse_date and q.parse_date(block.from) or block.from)
      local to_ts = iso_to_ts(q.parse_date and q.parse_date(block.to) or block.to)
      if from_ts and to_ts then
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
              and iso_to_ts(r.scheduled_date)
            or nil
          local emit_clones = false
          if rep and rep.value and rep.unit and origin_ts then
            local time_part = (
              r.scheduled_date
              and #r.scheduled_date >= 11
              and r.scheduled_date:sub(11)
            ) or ""
            local cursor = origin_ts
            local sec_period = period_seconds(rep)
            -- Walk forward to first occurrence ≥ from_ts.
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
            -- days late) — matching Emacs.  The bucket-day is set via
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
        rows = expanded
      end
    end
  end

  -- 1. Overdue bucket
  if block.include_overdue then
    local overdue = {}
    for _, r in ipairs(rows) do
      local dd = date_only(r.deadline_date)
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

  local effective = {}
  for _, r in ipairs(rows) do
    if
      not (
        block.include_overdue
        and r.deadline_date
        and date_only(r.deadline_date) < today
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
    -- Optional: items whose scheduled date is BEFORE the visible
    -- window collapse into the today bucket. Emacs default does NOT
    -- do this for non-repeating SCHEDULED items (they just disappear
    -- from the window — users see "Sched. Nx:" only for repeating
    -- ones). Toggle via `agenda.show_overdue_scheduled = true` for
    -- the more user-friendly "stale items keep showing" behavior.
    local roll_overdue = (require("organ.buf_config").read(nil, "agenda") or {}).show_overdue_scheduled
      == true
    local window_from = block.from
      and date_only(
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
    -- today (1 ≤ N ≤ deadline_warning_days, default 14) gets an
    -- extra entry in today's bucket with an "In   N d.:" label.  The
    -- row's natural deadline-day bucket entry stays.  Mirrors Emacs's
    -- `org-deadline-warning-days` early-warning behavior — without
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
      local sched_key = date_only(r.scheduled_date)
      local dead_key = date_only(r.deadline_date)
      if r._bucket_date then
        -- `_bucket_date` is set by the repeater-overdue carryover path
        -- to force the row onto today's bucket while preserving the
        -- original scheduled_date for the `Sched. Nx:` label.
        add_to_bucket(r, r._bucket_date)
      elseif sched_key and dead_key and sched_key ~= dead_key then
        -- Mirrors Emacs: a row with BOTH scheduled and deadline
        -- appears in BOTH buckets (different prefixes per bucket via
        -- bucket-relative sched_label_for).  The two events are
        -- distinct calendar entries — start day and must-finish day —
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
      -- the deadline day) → add a copy to today's bucket with an
      -- `In N d.:` label.  Mirrors Emacs `org-agenda-skip-deadline-
      -- prewarning-if-scheduled` (default true): if the row is already
      -- scheduled within the visible window, the user sees it on the
      -- scheduled day and the deadline-warning is redundant — set
      -- `skip_deadline_prewarning_if_scheduled = false` to opt back in.
      if
        dead_key
        and warning_days > 0
        and (not r.scheduled_date or not skip_dl_prewarn_if_sched)
      then
        local d = days_diff(today, dead_key)
        if d and d > 0 and d <= warning_days and dead_key ~= today then
          local clone = vim.tbl_extend("force", {}, r)
          clone._deadline_warning = true
          add_to_bucket(clone, today)
        end
      end
    end
    -- Backfill empty days in the [block.from, block.to] window so the
    -- agenda renders a header for every day (matches Emacs's
    -- `org-agenda-show-all-dates = t` default — Fri / Sat without
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
    -- Wall-clock time for the "← now" marker. now_override is a
    -- date-only ISO string ("2026-05-04") used by tests + the daily
    -- today/not-today comparison; it does NOT carry an hour, so we
    -- can't derive HH:MM from it for live use. Always pull HH:MM
    -- from os.time() for interactive renders. Tests that want a
    -- fixed wall-clock for the marker can pass a full ISO timestamp
    -- ("2026-05-04T12:00") via now_override.
    local now_hhmm
    if now_override and #now_override > 10 then
      now_hhmm = os.date("%H:%M", iso_to_ts(now_override))
    else
      now_hhmm = os.date("%H:%M", os.time())
    end
    local agenda_cfg_local = (require("organ.buf_config").read(nil, "agenda") or {})
    local show_now = agenda_cfg_local.now_marker ~= false

    -- Time grid (Emacs `org-agenda-use-time-grid`). Off by default;
    -- opt-in via agenda.time_grid = true (uses default 2h hours) or
    -- a table { hours = {…}, on = "today" | "all" }. When on, today's
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
    -- strategy` defaults to time-up,priority-down,category-keep — the
    -- "time first" rule is the load-bearing one for daily agendas
    -- because users read top-to-bottom and expect a chronological
    -- timeline. Within ties (same time, or both untimed), fall back to
    -- the user's `order_within_group` (priority / state / title).
    -- Time-only string is "9:00" / "23:45" — no leading zero. Compare
    -- as minutes-of-day (integer) so "9:00" < "10:00" sorts correctly.
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
    -- Sort according to the user's `agenda.sorting_strategy` (Emacs
    -- token syntax). Each token returns -1 / 0 / +1 in the standard
    -- comparator sense; the first non-zero wins. Falls back to the
    -- default time-up,priority-down,category-keep when not set.
    --
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
          tominutes(time_only(a.scheduled_date)), tominutes(time_only(b.scheduled_date))
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
          tominutes(time_only(a.scheduled_date)), tominutes(time_only(b.scheduled_date))
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
      -- importance" — confusing but standard.
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
        return a.priority < b.priority and -1 or 1 -- A < B → A first
      end,
      ["category-up"] = function(a, b)
        local ca, cb = category_for(a), category_for(b)
        if ca == cb then
          return 0
        end
        return ca < cb and -1 or 1
      end,
      ["category-down"] = function(a, b)
        local ca, cb = category_for(a), category_for(b)
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
    local function sort_by_time(rows)
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

    for _, key in ipairs(order) do
      sort_by_time(buckets[key])
      -- Per-bucket fmt: relative-time prefix is computed against the
      -- BUCKET's date, not the renderer's global today. So a row
      -- shown under Tuesday's header gets "Scheduled:" (its scheduled
      -- date matches its bucket), not "In 1 d.:" (which would apply
      -- in a flat / non-grouped view).
      local bucket_block_opts = vim.tbl_extend("force", {}, block_opts, { today = key })
      local bucket_fmt = function(r)
        return format_line(r, bucket_block_opts)
      end
      if type(block.line_format) == "function" then
        local user_fmt = block.line_format
        bucket_fmt = function(r)
          local ok, line = pcall(user_fmt, r)
          if ok then
            return line, nil
          end
          return format_line(r, bucket_block_opts)
        end
      end
      local hl = key == today and "@organ.agenda.date_today" or "@organ.agenda.header"
      local hdr = date_header(key)
      emit_line(hdr, { { hl, 0, #hdr } }, nil)

      -- "← now" marker: insert in the today-bucket between rows
      -- whose times bracket the current wall-clock time. Renders as
      -- a single dim line so it doesn't visually compete with item
      -- rows.
      -- Decide whether this day-bucket gets the time grid.
      local emit_grid_for_day = time_grid_on and (time_grid_scope == "all" or key == today)

      -- Configurable now-marker text. agenda.current_time_string is
      -- expanded with `%s` → the wall-clock HH:MM. Default mirrors
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
      -- Convert "H:MM" / "HH:MM" → minutes-since-midnight, so we can
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
      if groups_mod and not emit_grid_for_day then
        local agenda_cfg_g = (require("organ.buf_config").read(nil, "agenda") or {})
        local partitions = groups_mod.partition(buckets[key], groups_spec, {
          category_for = category_for,
          catch_all_title = agenda_cfg_g.groups_catch_all_title,
        })
        for _, p in ipairs(partitions) do
          if #p.rows > 0 then
            if p.title then
              local hdr = string.format("  %s (%d)", p.title, #p.rows)
              emit_line(hdr, { { "@organ.agenda.block_header", 0, #hdr } }, nil)
            end
            for _, r in ipairs(p.rows) do
              local row_time = time_only(r.scheduled_date)
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
        -- emit them in time order. kind ∈ "grid" | "row". Rows with
        -- the same HH:MM as a grid hour replace that grid line.
        local events = {}
        for _, h in ipairs(time_grid_hours) do
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
          local rt = time_only(r.scheduled_date)
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
              -- (NO separator between cat and time — Emacs's `:c`
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
        -- marker BETWEEN them — matches Emacs's `20:00 ┄┄┄ / 22:49 ←
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
          local row_time = time_only(r.scheduled_date)
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

-- Public orchestrator. Iterates blocks, prepends a header line for labeled
-- blocks, concatenates per-block output with cumulative line-number offsets,
-- and returns a block_starts map for navigation keymaps.
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
-- back-shifted view of "last Monday → next Sunday" gets the header
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
  local from_ts = iso_to_ts(from_iso)
  if not from_ts then
    return nil
  end
  local from_w = iso_week_of(from_ts)
  local span = "Day"
  if first.to and first.to ~= first.from then
    span = "Week"
    local to_iso = (q.parse_date and q.parse_date(first.to)) or first.to
    local to_ts = iso_to_ts(to_iso)
    if to_ts then
      local to_w = iso_week_of(to_ts)
      if to_w ~= from_w then
        return string.format("%s-agenda (W%02d-W%02d):", span, from_w, to_w)
      end
    end
  end
  return string.format("%s-agenda (W%02d):", span, from_w)
end

function M.render(blocks_with_rows, opts)
  opts = opts or {}
  -- Re-apply user-supplied keyword_faces / tag faces on every render
  -- so config changes take effect without a plugin reload.  Static
  -- defaults are guarded by `hl_registered` and only run once.
  M._register_highlights()
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
    -- `agenda.block_separator` (false → blank line; true/nil →
    -- default `═`; single char → that char repeated; multi-char → the
    -- literal string padded/clipped to width).
    if bi < #blocks_with_rows then
      local sep_cfg = render_opts().block_separator
      if sep_cfg == false then
        lines[#lines + 1] = ""
      else
        local width = content_width()
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

-- Buffer machinery: open, refresh, filetype, event-driven refresh.

local NS = vim.api.nvim_create_namespace("organ-agenda")

-- vim.b serialises sparse-int-keyed Lua tables by padding gaps with vim.NIL.
-- Re-key block_starts and line_index as strings before storing, then decode
-- back to integers on read. Other state fields are dense or scalar — safe.
local function encode_state(state)
  local enc = {}
  for k, v in pairs(state) do
    enc[k] = v
  end
  if state.block_starts then
    local s = {}
    for k, v in pairs(state.block_starts) do
      s[tostring(k)] = v
    end
    enc.block_starts = s
  end
  if state.line_index then
    local s = {}
    for k, v in pairs(state.line_index) do
      s[tostring(k)] = v
    end
    enc.line_index = s
  end
  return enc
end

local function decode_state(raw)
  if not raw then
    return {}
  end
  local dec = {}
  for k, v in pairs(raw) do
    dec[k] = v
  end
  if raw.block_starts then
    local s = {}
    for k, v in pairs(raw.block_starts) do
      s[tonumber(k) or k] = v
    end
    dec.block_starts = s
  end
  if raw.line_index then
    local s = {}
    for k, v in pairs(raw.line_index) do
      s[tonumber(k) or k] = v
    end
    dec.line_index = s
  end
  return dec
end

local function buf_state(bufnr)
  return decode_state(vim.b[bufnr].organ_agenda)
end

-- Public accessor so tests and keymaps can read decoded state (with integer
-- block_starts keys) without accessing vim.b directly.
function M.buf_state(bufnr)
  return buf_state(bufnr)
end

local function set_state(bufnr, state)
  vim.b[bufnr].organ_agenda = encode_state(state)
end

-- Public bulk-delete / undo / redo primitives.
--
-- The gB action menu and u / <C-r> keymaps in the agenda buffer
-- delegate to these. Extracting them keeps the keymap closures small
-- and lets tests drive the full round-trip without going through
-- vim.ui.select.
--
-- A "snapshot" is a list of { file = bufnr, lnum = N, lines = {...} }
-- describing one or more subtrees that were cut. delete_history
-- (LIFO) holds these so `u` can restore them; redo_history holds
-- the snapshots `u` undid so `<C-r>` can re-cut.

-- Cut the subtrees described by `marked_rows` (each must have file_path
-- + line_start, OR _source_bufnr + _source_lnum) and append the snapshot
-- to bufnr's delete_history. Invalidates the redo_history (vim
-- convention: new edit drops redo branch). Returns the snapshot.
function M.bulk_delete_apply(bufnr, marked_rows)
  local structure = require("organ.structure")
  local clipboard = require("organ.clipboard")
  local snapshot = {}
  for _, r in ipairs(marked_rows) do
    local target = r._source_bufnr or vim.fn.bufadd(r.file_path)
    vim.fn.bufload(target)
    local lnum = r._source_lnum or ((r.line_start or 0) + 1)
    local hl = structure._find_containing_headline(target, lnum)
    if hl then
      local subtree_end = structure._subtree_end(target, hl)
      local snap_lines = vim.api.nvim_buf_get_lines(target, hl.line - 1, subtree_end, false)
      snapshot[#snapshot + 1] = { file = target, lnum = hl.line, lines = snap_lines }
    end
  end
  table.sort(snapshot, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.lnum > b.lnum
  end)
  for _, s in ipairs(snapshot) do
    pcall(clipboard.cut, s.file, s.lnum)
  end
  local hstate = buf_state(bufnr) or {}
  hstate.delete_history = hstate.delete_history or {}
  hstate.delete_history[#hstate.delete_history + 1] = snapshot
  hstate.redo_history = {}
  set_state(bufnr, hstate)
  return snapshot
end

-- Pop the top of bufnr's delete_history and re-insert each subtree at
-- its captured (file, lnum). Pushes onto redo_history. Returns the
-- snapshot, or nil when the stack is empty.
function M.undo_last_delete(bufnr)
  local state = buf_state(bufnr) or {}
  local stack = state.delete_history or {}
  if #stack == 0 then
    return nil
  end
  local snap = stack[#stack]
  stack[#stack] = nil
  table.sort(snap, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.lnum < b.lnum
  end)
  for _, s in ipairs(snap) do
    if vim.api.nvim_buf_is_valid(s.file) then
      pcall(obuf.set_lines, s.file, s.lnum - 1, s.lnum - 1, s.lines)
    end
  end
  state.delete_history = stack
  state.redo_history = state.redo_history or {}
  state.redo_history[#state.redo_history + 1] = snap
  set_state(bufnr, state)
  return snap
end

-- Pop the top of bufnr's redo_history and re-cut. Pushes back onto
-- delete_history. Returns the snapshot or nil.
function M.redo_last_delete(bufnr)
  local state = buf_state(bufnr) or {}
  local stack = state.redo_history or {}
  if #stack == 0 then
    return nil
  end
  local snap = stack[#stack]
  stack[#stack] = nil
  local plan = {}
  for _, s in ipairs(snap) do
    plan[#plan + 1] = s
  end
  table.sort(plan, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.lnum > b.lnum
  end)
  for _, s in ipairs(plan) do
    if vim.api.nvim_buf_is_valid(s.file) then
      pcall(obuf.set_lines, s.file, s.lnum - 1, s.lnum - 1 + #s.lines, {})
    end
  end
  state.redo_history = stack
  state.delete_history = state.delete_history or {}
  state.delete_history[#state.delete_history + 1] = snap
  set_state(bufnr, state)
  return snap
end

-- Apply extmarks to a buffer. If `range_start` and `range_end_exclusive`
-- are given (0-based row numbers), only clear+re-apply marks in that
-- row range and leave marks outside it alone — avoids the full-buffer
-- repaint flicker that hit on every `t` toggle. Pass nil for both to
-- fall back to clear-all + re-add-all (used when line count changed).
-- Build the extmark-opts table for a single mark.  Default form is a
-- highlighted byte range (`{ end_col, hl_group }`); when the 2nd
-- element is the literal `"_virt"` sentinel, the 5th element of the
-- tuple is a full opts table passed through verbatim — used for
-- right-align virt-text (tag column) which is decorative, not a
-- buffer slice.
local function mark_opts(mk)
  local hl, col_end = mk[2], mk[4]
  if hl == "_virt" then
    -- Sentinel: pass-through opts table.  Caller built the full
    -- extmark spec including virt_text / virt_text_pos / etc.
    return mk[5] or {}
  end
  return { end_col = col_end, hl_group = hl }
end

local function apply_extmarks(bufnr, extmarks, range_start, range_end_exclusive)
  if range_start ~= nil and range_end_exclusive ~= nil then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, range_start, range_end_exclusive)
    for _, mk in ipairs(extmarks) do
      local row = mk[1] - 1 -- extmark rows are 0-based
      if row >= range_start and row < range_end_exclusive then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, mk[3], mark_opts(mk))
      end
    end
  else
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    for _, mk in ipairs(extmarks) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, mk[1] - 1, mk[3], mark_opts(mk))
    end
  end
end

local function annotate_clocked_minutes(rows)
  local cfg_effort = (require("organ.buf_config").read(nil, "effort") or {})
  if cfg_effort.show_in_agenda == false then
    return rows
  end
  local effort = require("organ.effort")
  local needs = {}
  for _, r in ipairs(rows) do
    if effort.row_effort_minutes(r) then
      needs[#needs + 1] = r
    end
  end
  if #needs == 0 then
    return rows
  end
  local query = require("organ.query")
  for _, r in ipairs(needs) do
    local ok, entries = pcall(query.clock_entries, {
      headline_id = r.id,
      group_by = "headline",
    })
    if ok and entries and entries[1] and entries[1].duration_seconds then
      r.clocked_minutes = effort.clocked_minutes({ entries[1] })
    end
  end
  return rows
end

local function annotate_habits(rows)
  if #rows == 0 then
    return rows
  end
  local habit = require("organ.habit")
  local repeater = require("organ.todo.repeater")
  local query = require("organ.query")
  local habit_ids = {}
  for _, r in ipairs(rows) do
    if r.properties and habit.is_habit(r.properties) then
      r.is_habit = true
      habit_ids[#habit_ids + 1] = r.id
      local rep = r.scheduled and repeater.parse(r.scheduled) or nil
      if rep then
        r.habit_period_days = habit.period_days(rep)
        r.habit_alarm_days = habit.alarm_days(rep)
      end
    end
  end
  if #habit_ids > 0 then
    local today = _today_iso()
    local from = os.date("%Y-%m-%d", _now_ts() - 13 * 86400)
    local comps = query.habit_completions({ headline_id = habit_ids, from = from, to = today })
    for _, r in ipairs(rows) do
      if r.is_habit then
        r.completions = comps[r.id] or {}
        r._today = today
      end
    end
  end
  return rows
end

-- Resolve `agenda_files` config (or per-block override) to a list of
-- canonical file paths.  Mirrors Emacs's `org-agenda-files` and
-- nvim-orgmode's glob-style at the same time:
--
--   nil               → no restriction (every indexed file)
--   "~/org/todo.org"  → single file
--   "~/org"           → directory; top-level `.org` / `.org_archive`
--                       files only (Emacs's "list-with-a-directory")
--   "~/org/**/*.org"  → vim glob; expanded recursively (the `**` and
--                       `*` make it a glob; nvim-orgmode's shape).
--                       Detected by presence of `*`, `?`, or `[`.
--   { "~/org/*.org",
--     "!~/org/private/*" }
--                     → list of strings.  An entry starting with `!`
--                       is an EXCLUSION glob applied to the union of
--                       everything else.  So you can say "all org
--                       files except these" without writing a
--                       function.
--   function          → called at resolve time; must return any of
--                       the above shapes (string, list, or another
--                       function — recursively resolved).  This is
--                       the full escape hatch when the user wants
--                       arbitrary include / exclude logic.  The
--                       built-in `organ.agenda.recurse_dir(path)`
--                       returns one such function.
local function resolve_one(entry, includes, excludes)
  if type(entry) == "function" then
    -- Recursively resolve whatever the function returns.
    local nested = entry()
    if type(nested) == "string" then
      resolve_one(nested, includes, excludes)
    elseif type(nested) == "table" then
      for _, e in ipairs(nested) do
        resolve_one(e, includes, excludes)
      end
    end
    return
  end
  if type(entry) ~= "string" then
    return
  end
  local exclude = false
  if entry:sub(1, 1) == "!" then
    exclude = true
    entry = entry:sub(2)
  end
  local target = exclude and excludes or includes
  -- Detect glob meta-chars on the ORIGINAL string before expansion —
  -- `vim.fn.expand` is itself a globbing call, so pre-expanding here
  -- would silently consume the wildcards.  `vim.fn.glob` handles `~` /
  -- env-var expansion alongside `*` / `?` / `[` / `**` matching.
  if entry:match("[*?%[]") then
    local matches = vim.fn.glob(entry, false, true)
    for _, m in ipairs(matches) do
      if m:match("%.org$") or m:match("%.org_archive$") then
        target[#target + 1] = m
      end
    end
    return
  end
  -- Non-glob: file or directory.  Stat to discriminate.
  local p = vim.fn.expand(entry)
  local stat = vim.uv.fs_stat(p)
  if not stat then
    return
  end
  if stat.type == "directory" then
    local h = vim.uv.fs_scandir(p)
    if not h then
      return
    end
    while true do
      local name, t = vim.uv.fs_scandir_next(h)
      if not name then
        break
      end
      if
        (t == "file" or t == "link")
        and (name:match("%.org$") or name:match("%.org_archive$"))
      then
        target[#target + 1] = p .. "/" .. name
      end
    end
  else
    target[#target + 1] = p
  end
end

function M.resolve_agenda_files(spec)
  if spec == nil then
    return nil
  end
  local includes, excludes = {}, {}
  if type(spec) == "function" or type(spec) == "string" then
    resolve_one(spec, includes, excludes)
  elseif type(spec) == "table" then
    for _, entry in ipairs(spec) do
      resolve_one(entry, includes, excludes)
    end
  else
    return nil
  end
  if #excludes == 0 then
    return includes
  end
  -- Subtract excludes from includes (set difference).
  local excluded = {}
  for _, p in ipairs(excludes) do
    excluded[p] = true
  end
  local out = {}
  for _, p in ipairs(includes) do
    if not excluded[p] then
      out[#out + 1] = p
    end
  end
  return out
end

local function run_query(block)
  if block.kind == "stuck" then
    local cfg = (require("organ.buf_config").read(nil, "stuck") or {})
    return require("organ.query").stuck_projects({
      project_filter = block.project_filter or cfg.project_filter,
      next_states = block.next_states or cfg.next_states,
    })
  end
  local query = require("organ.query")
  local cfg_disp = (require("organ.buf_config").read(nil, "tags") or {}).display_inherited
  -- Per-block `files` overrides the global `agenda_files` config.
  -- nil at both levels → no file filter (every indexed file).
  local files_spec = block.files or require("organ.buf_config").read(nil, "agenda_files")
  local files = files_spec and M.resolve_agenda_files(files_spec) or nil
  local rows
  if block.kind == "search" or block.kind == "tags" or block.kind == "todo" then
    -- Non-time-window views: query.headlines (no date filter), then apply
    -- view-specific filtering below.
    rows = query.headlines({
      title_match = block.title_match,
      todo = block.todo,
      tags = block.tags,
      priority = block.priority,
      files = files,
      include_properties = true,
      include_inherited_tags = cfg_disp,
    })
    -- TODO-list view filters (mirror Emacs `org-agenda-todo-ignore-*`
    -- and `org-agenda-todo-list-sublevels`).  Per-block override beats
    -- the global defaults so a single view can opt in/out.
    -- todo-ignore filters apply to the TODO-list view always, and to
    -- the tag-search view when `tags_todo_honor_ignore_options = true`
    -- (Emacs `org-agenda-tags-todo-honor-ignore-options`).  Per-block
    -- override beats the global defaults.
    local ag = require("organ.buf_config").read(nil, "agenda") or {}
    local function pick(name)
      if block[name] ~= nil then
        return block[name]
      end
      return ag[name]
    end
    local apply_filters = (block.kind == "todo")
    if block.kind == "tags" and pick("tags_todo_honor_ignore_options") then
      apply_filters = true
    end
    if apply_filters then
      local ignore_sched = pick("todo_ignore_scheduled")
      local ignore_dead = pick("todo_ignore_deadlines")
      local ignore_dated = pick("todo_ignore_with_date")
      local sublevels = pick("todo_list_sublevels")
      if sublevels == nil then
        sublevels = true
      end
      if ignore_sched or ignore_dead or ignore_dated or sublevels == false then
        local kept = {}
        for _, r in ipairs(rows) do
          local skip = false
          if sublevels == false and (r.level or 1) > 1 then
            skip = true
          end
          if ignore_sched and r.scheduled_date and r.scheduled_date ~= "" then
            skip = true
          end
          if ignore_dead and r.deadline_date and r.deadline_date ~= "" then
            skip = true
          end
          if
            ignore_dated
            and (
              (r.scheduled_date and r.scheduled_date ~= "")
              or (r.deadline_date and r.deadline_date ~= "")
            )
          then
            skip = true
          end
          if not skip then
            kept[#kept + 1] = r
          end
        end
        rows = kept
      end
    end
  else
    rows = query.agenda({
      from = block.from,
      to = block.to,
      types = block.types,
      todo = block.todo,
      tags = block.tags,
      priority = block.priority,
      title_match = block.title_match,
      files = files,
      include_properties = true,
      include_inherited_tags = cfg_disp,
    })
  end

  -- Skip COMMENT trees (Emacs `org-agenda-skip-comment-trees`).  A
  -- headline of the form `* COMMENT Foo` or `* TODO COMMENT Foo`
  -- excludes the entire subtree from the agenda.  Default `true`
  -- (Emacs default).  Per-block override via `block.skip_comment_trees`.
  --
  -- Implementation: build the set of commented headline IDs from the
  -- rows we have, then walk parent_id chains transitively so any
  -- descendant of a commented heading is also dropped.  Some rows
  -- come from `query.agenda`'s repeater-projection path and may carry
  -- only the headline (no parent_id chain), so we look up the parent
  -- chain in the DB on demand.
  do
    local agenda_cfg_c = (require("organ.buf_config").read(nil, "agenda") or {})
    local skip_c
    if block.skip_comment_trees ~= nil then
      skip_c = block.skip_comment_trees
    else
      skip_c = agenda_cfg_c.skip_comment_trees
    end
    if skip_c == nil then
      skip_c = true
    end
    if skip_c then
      local query2 = require("organ.query")
      local commented_cache = {}
      local function is_commented_chain(id)
        if not id or id == "" then
          return false
        end
        if commented_cache[id] ~= nil then
          return commented_cache[id]
        end
        local rec = query2.get_by_id(id)
        if not rec then
          commented_cache[id] = false
          return false
        end
        if rec.commented then
          commented_cache[id] = true
          return true
        end
        local up = is_commented_chain(rec.parent_id)
        commented_cache[id] = up
        return up
      end
      local kept = {}
      for _, r in ipairs(rows) do
        local skip = r.commented or is_commented_chain(r.parent_id)
        if not skip then
          kept[#kept + 1] = r
        end
      end
      rows = kept
    end
  end

  -- Per-type skip rules (Emacs `org-agenda-skip-scheduled-if-done`,
  -- `org-agenda-skip-deadline-if-done`). Finer than blanket
  -- todo.exclude — a row may be DONE for its scheduled date but still
  -- want surfacing under its deadline (or vice versa). Done-keyword
  -- detection comes from the configured todo sequence.
  do
    local agenda_cfg2 = (require("organ.buf_config").read(nil, "agenda") or {})
    if agenda_cfg2.skip_scheduled_if_done or agenda_cfg2.skip_deadline_if_done then
      -- Per-row done classification.  Files may declare their own
      -- `#+TODO:` directive that overrides global done keywords for
      -- their headlines (Emacs behavior).  Single batched DB query
      -- against the `file_todo_keywords` index — no per-row file I/O.
      local cfg_seq = (require("organ.buf_config").read(nil, "todo") or {}).sequences
        or (require("organ.buf_config").read(nil, "todo") or {}).sequence
        or {}
      local global_done = {}
      for _, seq in ipairs(require("organ.todo")._normalise_sequences(cfg_seq)) do
        local in_done = false
        for _, k in ipairs(seq) do
          if k == "|" then
            in_done = true
          elseif in_done then
            global_done[k] = true
          end
        end
      end
      local seen_paths, paths = {}, {}
      for _, r in ipairs(rows) do
        if r.file_path and not seen_paths[r.file_path] then
          seen_paths[r.file_path] = true
          paths[#paths + 1] = r.file_path
        end
      end
      local q = require("organ.query")
      local file_kw = (#paths > 0 and type(q.file_todo_keywords) == "function")
          and q.file_todo_keywords(paths)
        or {}
      -- For files open as modified buffers, the on-disk index is
      -- stale until BufWritePost re-runs the scan.  Override
      -- per-buffer with a live scan so a user editing a `#+TODO:`
      -- line sees correct done classification immediately.  Bounded:
      -- only fires when a buffer is BOTH loaded AND `&modified`,
      -- and only scans the first ~200 lines (where directives live).
      local todo = require("organ.todo")
      local live_overrides = {}
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
          local name = vim.api.nvim_buf_get_name(b)
          if name ~= "" and seen_paths[name] then
            local seqs = todo.buffer_sequences(b)
            if seqs then
              local active, done = {}, {}
              for _, seq in ipairs(seqs) do
                local in_done = false
                for _, k in ipairs(seq) do
                  if k == "|" then
                    in_done = true
                  elseif in_done then
                    done[k] = true
                  else
                    active[k] = true
                  end
                end
              end
              live_overrides[name] = { active = active, done = done }
            end
          end
        end
      end
      local function done_set_for(file_path)
        local live = file_path and live_overrides[file_path]
        if live then
          return live.done
        end
        local entry = file_path and file_kw[file_path]
        if entry then
          return entry.done
        end
        return global_done
      end
      local kept = {}
      for _, r in ipairs(rows) do
        local file_done = done_set_for(r.file_path)
        local is_done = r.todo_state and file_done[r.todo_state] == true
        local has_sched = r.scheduled_date and r.scheduled_date ~= ""
        local has_dead = r.deadline_date and r.deadline_date ~= ""
        local skip = false
        if is_done then
          if agenda_cfg2.skip_scheduled_if_done and has_sched and not has_dead then
            skip = true
          end
          if agenda_cfg2.skip_deadline_if_done and has_dead and not has_sched then
            skip = true
          end
        end
        if not skip then
          kept[#kept + 1] = r
        end
      end
      rows = kept
    end
  end

  -- Overdue scheduled items: a row scheduled BEFORE block.from won't
  -- be in the in-window query result. Opt-in via
  -- `agenda.show_overdue_scheduled = true` (matches Emacs default of
  -- NOT rolling these up). When on, fetch the overdue rows and the
  -- bucketing loop in render_block reroutes them to today's bucket.
  local show_overdue_sched = (require("organ.buf_config").read(nil, "agenda") or {}).show_overdue_scheduled
    == true
  if show_overdue_sched and block.from then
    local from_iso = query.parse_date and query.parse_date(block.from) or block.from
    local overdue_rows = query.agenda({
      from = "1900-01-01",
      to = from_iso,
      types = { "scheduled" },
      todo = block.todo,
      tags = block.tags,
      priority = block.priority,
      title_match = block.title_match,
      files = files,
      include_properties = true,
      include_inherited_tags = cfg_disp,
    })
    local seen = {}
    for _, r in ipairs(rows) do
      if r.id then
        seen[r.id] = true
      end
    end
    for _, r in ipairs(overdue_rows or {}) do
      local rd = date_only(r.scheduled_date)
      if rd and rd < from_iso and not seen[r.id] then
        rows[#rows + 1] = r
      end
    end
  end

  -- Tag-query view: filter rows through the org-match predicate.
  if block.kind == "tags" and block.tag_match and block.tag_match ~= "" then
    local ok, match = pcall(require, "organ.match")
    if ok and match.predicate then
      local pred = match.predicate(block.tag_match)
      local filtered = {}
      for _, r in ipairs(rows) do
        if pred(r) then
          filtered[#filtered + 1] = r
        end
      end
      rows = filtered
    end
  end

  -- Diary-sexp synthetic rows (opt-in via config.agenda.include_diary_sexp).
  -- Resolves block.from / block.to to ISO via query.parse_date so the day
  -- iterator can step through; honors `block.types` allowing scheduled-like
  -- entries to flow into the same render.
  local agenda_cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  if agenda_cfg.include_diary_sexp and block.from and block.to then
    local from_iso = query.parse_date(block.from)
    local to_iso = query.parse_date(block.to)
    if from_iso and to_iso then
      local extra = require("organ.diary_sexp").agenda_rows(from_iso, to_iso)
      for _, r in ipairs(extra) do
        rows[#rows + 1] = r
      end
    end
  end
  -- Log mode (Emacs `org-agenda-log-mode`).  When active, fetch
  -- closed/clocked/state-changed events whose date falls inside the
  -- visible window and inject them as synthetic rows under the day
  -- each event happened.  All three event types live in the index
  -- (closed_date column, clock_entries table, state_changes table)
  -- so this is a SQL-only fanout — no per-file rescan.
  do
    local log_mode = block._log_mode_active
    if log_mode and block.from and block.to then
      local items_set = {}
      for _, it in ipairs(block.log_mode_items or { "closed", "clock" }) do
        items_set[it] = true
      end
      local from_iso = query.parse_date(block.from) or block.from
      local to_iso = query.parse_date(block.to) or block.to

      if items_set.closed then
        local closed_rows = query.headlines({
          closed = { from = from_iso, to = to_iso },
          include_properties = false,
        }) or {}
        local seen = {}
        for _, r in ipairs(rows) do
          if r.id then
            seen[r.id] = true
          end
        end
        for _, r in ipairs(closed_rows) do
          if r.id and not seen[r.id] and r.closed_date then
            r._bucket_date = date_only(r.closed_date)
            r._log_mode = "closed"
            rows[#rows + 1] = r
          end
        end
      end

      if items_set.clock then
        local clk_rows = query.clock_entries({
          from = from_iso,
          to = to_iso,
          group_by = "headline_day",
          include_active = true,
        }) or {}
        for _, c in ipairs(clk_rows) do
          local hl = query.get_by_id(c.headline_id)
          if hl then
            local mins = math.floor((c.total_seconds or 0) / 60)
            local synthetic = vim.tbl_extend("force", hl, {
              _bucket_date = c.day,
              _log_mode = "clock",
              _log_clock_minutes = mins,
            })
            rows[#rows + 1] = synthetic
          end
        end
      end

      if items_set.state then
        local sc_rows = query.state_changes({ from = from_iso, to = to_iso }) or {}
        for _, sc in ipairs(sc_rows) do
          if sc.headline_id then
            local hl = query.get_by_id(sc.headline_id)
            if hl then
              local synthetic = vim.tbl_extend("force", hl, {
                _bucket_date = sc.day,
                _log_mode = "state",
                _log_state_from = sc.from_state,
                _log_state_to = sc.to_state,
                _log_state_ts = sc.ts,
              })
              rows[#rows + 1] = synthetic
            end
          end
        end
      end
    end
  end
  return annotate_habits(annotate_clocked_minutes(rows))
end

function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local state = buf_state(bufnr)
  local view = state.view or { blocks = {} }

  -- Capture the headline ID under cursor BEFORE refresh so we can restore
  -- the cursor to the same headline after re-render. Without this, sorting
  -- comparators that include todo_state/priority make the cursor jump to
  -- a random row whenever the user toggles a TODO state.
  local prev_id
  local prev_winid
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      prev_winid = w
      break
    end
  end
  if prev_winid and state.line_index then
    local prev_lnum = vim.api.nvim_win_get_cursor(prev_winid)[1]
    local row = state.line_index[prev_lnum]
    if row then
      prev_id = row.id
    end
  end

  -- Thread per-buffer log_mode flag into each block so run_query
  -- knows whether to inject CLOSED rows.  We mutate the block in
  -- place rather than copying; clear afterwards so a stale flag from
  -- a previous toggle doesn't leak across non-buffer renders.
  local log_cfg = ((require("organ.buf_config").read(nil, "agenda") or {}).log_mode or {})
  local log_active = state.log_mode
  if log_active == nil then
    log_active = log_cfg.on_start == true
  end
  local blocks_with_rows = {}
  for _, block in ipairs(view.blocks) do
    block._log_mode_active = log_active
    block.log_mode_items = log_cfg.items or { "closed", "clock" }
    local ok, rows = pcall(run_query, block)
    block._log_mode_active = nil
    if ok then
      blocks_with_rows[#blocks_with_rows + 1] = { block = block, rows = rows }
    else
      blocks_with_rows[#blocks_with_rows + 1] = {
        block = block,
        rows = {},
        query_error = tostring(rows),
      }
    end
  end

  -- Effort filter (set by the `e` keymap). Applies after run_query so
  -- it composes with all other filters and is cheap to clear.
  if state.effort_filter and state.effort_filter ~= "" then
    local effort = require("organ.effort")
    local pred = effort.parse_filter(state.effort_filter)
    if pred then
      for _, br in ipairs(blocks_with_rows) do
        local kept = {}
        for _, r in ipairs(br.rows) do
          local mins = effort.row_effort_minutes(r)
          if pred(mins) then
            kept[#kept + 1] = r
          end
        end
        br.rows = kept
      end
    end
  end

  -- Per-buffer toggle state lifted into the render opts so M.render
  -- doesn't have to reach into vim.b for every entry-text decision.
  local rstate = buf_state(bufnr)
  local out = M.render(blocks_with_rows, {
    now = _today_iso(),
    entry_text = rstate.entry_text,
  })

  -- Buffer-only UX additions: empty-state hint + footer keymap reference.
  -- Kept out of M.render so the pure renderer stays predictable for tests.
  local cfg_agenda = (require("organ.buf_config").read(nil, "agenda") or {})
  local total_rows = 0
  for _, br in ipairs(blocks_with_rows) do
    total_rows = total_rows + #br.rows
  end
  if total_rows == 0 then
    if #out.lines > 0 then
      out.lines[#out.lines + 1] = ""
    end
    local empty = empty_state_lines()
    local empty_start = #out.lines + 1
    for _, l in ipairs(empty) do
      out.lines[#out.lines + 1] = l
    end
    for i = empty_start, #out.lines do
      out.extmarks[#out.extmarks + 1] = { i, "Comment", 0, #(out.lines[i] or "") }
    end
  end
  -- Clock-report mode (toggled via gR). When on, append a clocktable
  -- showing total clocked time per headline within the visible date
  -- window. Mirrors Emacs `R` in agenda buffer.
  do
    local agenda_state = decode_state(vim.b[bufnr].organ_agenda) or {}
    -- `agenda.clockreport_mode = true` (Emacs `org-agenda-clockreport-
    -- mode`) starts each agenda buffer with the clock report visible
    -- (default off; `gR` toggles per-buffer).
    local clock_default = (require("organ.buf_config").read(nil, "agenda") or {}).clockreport_mode
      == true
    local show_clock_report = agenda_state.clock_report_mode
    if show_clock_report == nil then
      show_clock_report = clock_default
    end
    if show_clock_report then
      local first
      for _, br in ipairs(blocks_with_rows) do
        if br.block and br.block.from then
          first = br.block
          break
        end
      end
      if first then
        local query = require("organ.query")
        local from_iso = (query.parse_date and query.parse_date(first.from)) or first.from
        local to_iso = (query.parse_date and query.parse_date(first.to or first.from))
          or (first.to or first.from)
        local rows = {}
        local ok_q, entries = pcall(query.clock_entries, {
          from = from_iso,
          to = to_iso,
          group_by = "headline",
        })
        if ok_q and entries then
          rows = entries
        end
        if #out.lines > 0 then
          out.lines[#out.lines + 1] = ""
        end
        local hdr = string.format("Clock report (%s → %s):", from_iso, to_iso)
        out.lines[#out.lines + 1] = hdr
        out.extmarks[#out.extmarks + 1] = { #out.lines, "@organ.agenda.block_header", 0, #hdr }
        local report_start = #out.lines + 1
        for _, l in ipairs(require("organ.clock.report").render(rows, {})) do
          out.lines[#out.lines + 1] = l
        end
        for i = report_start, #out.lines do
          out.extmarks[#out.extmarks + 1] = { i, "@organ.agenda.title", 0, #(out.lines[i] or "") }
        end
      end
    end
  end

  -- Buffer footer with keymap hints. Default ON because we don't install
  -- a winbar/statusline by default (no-surprises rule), and without any
  -- chrome the keymaps would be invisible. Set `agenda.footer = false`
  -- to suppress (typically when you've opted into `agenda.statusline`
  -- and don't need both).
  if cfg_agenda.footer ~= false then
    if #out.lines > 0 then
      out.lines[#out.lines + 1] = ""
    end
    local footer_start = #out.lines + 1
    for _, l in ipairs(FOOTER_LINES) do
      out.lines[#out.lines + 1] = l
    end
    for i = footer_start, #out.lines do
      out.extmarks[#out.extmarks + 1] = { i, "Comment", 0, #(out.lines[i] or "") }
    end
  end

  vim.bo[bufnr].modifiable = true
  -- Incremental update: replace only the changed line range AND only
  -- re-apply extmarks in that range. Full-buffer replacement OR full
  -- extmark clear-and-reapply both caused visible flicker on every
  -- `t` toggle — only one headline actually changed, but the entire
  -- buffer was being repainted.
  local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n_old, n_new = #old_lines, #out.lines
  local extmark_range_start, extmark_range_end
  local content_changed = false
  if n_old == n_new then
    local prefix = 0
    while prefix < n_old and old_lines[prefix + 1] == out.lines[prefix + 1] do
      prefix = prefix + 1
    end
    if prefix == n_old then
      -- Buffer text identical — skip both line write AND extmark touch.
      content_changed = false
    else
      local suffix = 0
      while suffix < (n_old - prefix) and old_lines[n_old - suffix] == out.lines[n_new - suffix] do
        suffix = suffix + 1
      end
      obuf.set_lines(
        bufnr,
        prefix,
        n_old - suffix,
        vim.list_slice(out.lines, prefix + 1, n_new - suffix)
      )
      extmark_range_start = prefix
      extmark_range_end = n_new - suffix
      content_changed = true
    end
  else
    -- Line count changed: full replace + full extmark refresh.
    obuf.set_lines(bufnr, 0, -1, out.lines)
    content_changed = true -- full refresh path
  end
  vim.bo[bufnr].modifiable = false
  if content_changed then
    apply_extmarks(bufnr, out.extmarks, extmark_range_start, extmark_range_end)
  end

  state.last_refresh_ts = os.time()
  state.line_index = out.line_index
  state.block_starts = out.block_starts
  set_state(bufnr, state)

  -- Cursor follow: locate the previously-focused headline in the new
  -- line_index and move cursor there. Sorting comparators (priority,
  -- todo_state, etc.) frequently shuffle row positions on `t` toggles —
  -- without this the cursor would jump to whatever row landed at the old
  -- line number, which is jarring.
  if prev_id and prev_winid and vim.api.nvim_win_is_valid(prev_winid) then
    for lnum, row in pairs(out.line_index) do
      if row.id == prev_id then
        local total = vim.api.nvim_buf_line_count(bufnr)
        local target = math.min(lnum, total)
        pcall(vim.api.nvim_win_set_cursor, prev_winid, { target, 0 })
        return
      end
    end
    -- Headline disappeared (e.g. its TODO filter no longer matches
    -- after the cycle). Leave cursor where it was, clamped to buffer.
    local prev_lnum = vim.api.nvim_win_get_cursor(prev_winid)[1]
    local total = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, prev_winid, { math.min(prev_lnum, total), 0 })
  end
end

-- Register default highlight groups once (default = true so user/colorscheme
-- overrides win).
local hl_registered = false
local function register_user_faces()
  -- User-supplied per-keyword and per-tag highlights (Emacs `org-todo-
  -- keyword-faces` and `org-tag-faces`).  Re-applied on every render
  -- so config-time changes are picked up without a plugin reload.
  -- Each value can be either:
  --   * a string  → linked highlight group name
  --   * a table   → forwarded as the second arg to nvim_set_hl
  -- Examples:
  --   todo = { keyword_faces = { WAITING = "WarningMsg",
  --                              NEXT    = { fg = "#5fafff", bold = true } } }
  --   tags = { faces         = { urgent  = "ErrorMsg",
  --                              work    = "Type" } }
  local function apply_user_hls(prefix, tbl)
    if type(tbl) ~= "table" then
      return
    end
    for name, spec in pairs(tbl) do
      local group = prefix .. tostring(name)
      if type(spec) == "string" then
        vim.api.nvim_set_hl(0, group, { link = spec })
      elseif type(spec) == "table" then
        vim.api.nvim_set_hl(0, group, spec)
      end
    end
  end
  local org = require("organ")
  if org.config and org.config.todo and org.config.todo.keyword_faces then
    local lower = {}
    for k, v in pairs(org.config.todo.keyword_faces) do
      lower[k:lower()] = v
    end
    apply_user_hls("@organ.agenda.todo_", lower)
  end
  if org.config and org.config.tags and org.config.tags.faces then
    apply_user_hls("@organ.agenda.tag_", org.config.tags.faces)
  end
end

local function register_highlights()
  -- User faces always re-apply (cheap; lets config-time tweaks take
  -- effect on the next render without a plugin reload).
  register_user_faces()
  if hl_registered then
    return
  end
  hl_registered = true
  local hls = {
    ["@organ.agenda.header"] = "Title",
    ["@organ.agenda.date_today"] = "Constant",
    ["@organ.agenda.date_overdue"] = "ErrorMsg",
    ["@organ.agenda.todo_todo"] = "WarningMsg",
    ["@organ.agenda.todo_next"] = "Statement",
    ["@organ.agenda.todo_done"] = "Comment",
    ["@organ.agenda.priority_A"] = "ErrorMsg",
    ["@organ.agenda.priority_B"] = "WarningMsg",
    ["@organ.agenda.priority_C"] = "Comment",
    ["@organ.agenda.tag"] = "Type",
    -- Single-cell overflow marker emitted in place of the full tag
    -- block when the row would not fit in the window's content area.
    -- Linked to NonText so it's visually subdued (matches Emacs's
    -- continuation-marker convention).
    ["@organ.agenda.tag_overflow"] = "NonText",
    ["@organ.agenda.category"] = "Identifier",
    ["@organ.agenda.location"] = "Directory",
    ["@organ.agenda.block_separator"] = "NonText",
    ["@organ.agenda.time"] = "Number",
    ["@organ.agenda.effort"] = "Number",
    ["@organ.agenda.block_header"] = "Title",
    -- Title text (per-row title bytes). Distinct from @organ.agenda.header
    -- (which is the date / block heading line).
    ["@organ.agenda.view_header"] = "Title",
    ["@organ.agenda.title"] = "Function",
    -- Emacs `org-scheduled` / `org-upcoming-deadline` faces; these
    -- color the "Scheduled:" / "Deadline:" tag text in row prefixes.
    ["@organ.agenda.scheduled"] = "Function",
    ["@organ.agenda.deadline"] = "WarningMsg",
    -- "← now" marker line in today's group_by="day" bucket.
    ["@organ.agenda.now_marker"] = "Special",
    -- Body-preview lines injected by entry-text mode (org-agenda-
    -- entry-text-mode).
    ["@organ.agenda.entry_text"] = "Comment",
  }
  for group, link in pairs(hls) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

local function install_keymaps(bufnr)
  local organ = require("organ")
  local agenda_cfg = require("organ.buf_config").read(nil, "agenda") or {}
  -- Rule 2: keymaps = false disables all agenda bindings.
  if agenda_cfg.keymaps == false then
    return
  end
  local cfg = agenda_cfg.keymaps or {}

  local function map(default_lhs, rhs, desc)
    local lhs = cfg[desc] -- user may override via organ.config.agenda.keymaps[desc]
    if lhs == false then
      return
    end
    if lhs == nil then
      lhs = default_lhs
    end
    vim.api.nvim_buf_set_keymap(bufnr, "n", lhs, "", {
      noremap = true,
      silent = true,
      desc = desc,
      callback = rhs,
    })
  end

  local function current_row()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = buf_state(bufnr)
    return (state.line_index or {})[lnum]
  end

  -- Helper: load the source buffer + return the 1-based source line for a
  -- row. Returns nil + warns if the row has no editable source (synthetic
  -- diary_sexp rows, empty-state placeholders, etc. lack file_path /
  -- line_start). Without this guard, every t/T/s/D/I/R/<CR>/gs/gv keymap
  -- would crash with `attempt to perform arithmetic on field 'line_start'
  -- (a nil value)` on synthetic rows.
  local function source_for(r)
    if not r.file_path or not r.line_start then
      require("organ.notify").warn(
        "agenda: this row has no editable source (synthetic / placeholder)"
      )
      return nil, nil
    end
    local target = vim.fn.bufadd(r.file_path)
    vim.fn.bufload(target)
    return target, r.line_start + 1
  end

  map("<CR>", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path then
      require("organ.notify").warn("agenda: this row has no source file")
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(r.file_path))
    if r.line_start then
      vim.api.nvim_win_set_cursor(0, { r.line_start + 1, 0 })
    end
  end, "jump")

  -- Preview the source headline + body in a floating window without
  -- leaving the agenda buffer. Press `q` or `<Esc>` (anything that
  -- closes the float) to dismiss. K is unbound in vim's normal-mode
  -- defaults for nofile buffers; override is non-conflicting.
  map("K", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path or not r.line_start then
      return
    end
    local target = vim.fn.bufadd(r.file_path)
    vim.fn.bufload(target)
    -- Slice from headline to subtree end.
    local structure = require("organ.structure")
    local hl = structure._find_containing_headline(target, (r.line_start or 0) + 1)
    if not hl then
      return
    end
    local subtree_end = structure._subtree_end(target, hl)
    local lines = vim.api.nvim_buf_get_lines(target, hl.line - 1, subtree_end, false)
    -- Width: longest line + small padding, capped to ~edge of window.
    local max_w = 0
    for _, l in ipairs(lines) do
      max_w = math.max(max_w, vim.fn.strdisplaywidth(l))
    end
    local width = math.min(math.max(max_w + 4, 40), math.floor(vim.o.columns * 0.8))
    local height = math.min(#lines, math.floor(vim.o.lines * 0.6))
    -- vim.lsp.util.open_floating_preview handles q / Esc dismissal +
    -- closes on cursor move. Set filetype=org so syntax highlights.
    local _, _ = vim.lsp.util.open_floating_preview(lines, "org", {
      width = width,
      height = height,
      border = "rounded",
    })
  end, "preview")

  -- Open in horizontal/vertical split. `gs` / `gv` — single-finger
  -- two-key sequences in the vim "go" family (`g` prefix is the
  -- canonical "go to" namespace). Both have no-op vim defaults in a
  -- nomodifiable buffer (vim's `gs` sleeps, `gv` re-enters last
  -- visual selection — neither does anything useful here).
  --
  -- We deliberately don't bind bare `o` or `v`: those shadow vim's
  -- normal-mode `o` (open new line) and `v` (visual-character mode)
  -- which users have hard-wired muscle memory for.
  map("gs", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path then
      require("organ.notify").warn("agenda: this row has no source file")
      return
    end
    vim.cmd("split " .. vim.fn.fnameescape(r.file_path))
    if r.line_start then
      vim.api.nvim_win_set_cursor(0, { r.line_start + 1, 0 })
    end
  end, "open_split")

  map("gv", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path then
      require("organ.notify").warn("agenda: this row has no source file")
      return
    end
    vim.cmd("vsplit " .. vim.fn.fnameescape(r.file_path))
    if r.line_start then
      vim.api.nvim_win_set_cursor(0, { r.line_start + 1, 0 })
    end
  end, "open_vsplit")

  map("r", function()
    M.refresh(bufnr)
  end, "refresh")

  -- `E` toggles entry-text mode (Emacs `org-agenda-entry-text-mode`):
  -- inject up to `agenda.entry_text.max_lines` body lines from each
  -- item's source headline as indented preview rows under the row.
  map("E", function()
    local state = buf_state(bufnr)
    state.entry_text = not state.entry_text
    set_state(bufnr, state)
    M.refresh(bufnr)
  end, "toggle_entry_text")

  -- `l` toggles log mode (Emacs `org-agenda-log-mode`): inject CLOSED
  -- entries (and clock / state events when those land in the indexer)
  -- as additional rows on the day each event happened.  Set
  -- `agenda.log_mode.on_start = true` to default it on.
  map("l", function()
    local state = buf_state(bufnr)
    state.log_mode = not state.log_mode
    set_state(bufnr, state)
    M.refresh(bufnr)
  end, "toggle_log_mode")

  -- Undo last destructive bulk op (delete, currently). Pops the
  -- per-buffer history stack and re-inserts each captured subtree at
  -- its original file:line position. Vim's native `u` is a no-op in
  -- this nofile non-modifiable buffer, so overriding it gives users
  -- the seamless "vim-native undo feel" they expect — no
  -- :Org paste_subtree dance.
  map("u", function()
    local snap = M.undo_last_delete(bufnr)
    if not snap then
      require("organ.notify").info("agenda: nothing to undo")
      return
    end
    M.refresh(bufnr)
    require("organ.notify").info(("agenda: restored %d subtree(s)"):format(#snap))
  end, "undo_delete")

  -- Redo the last undone delete. Vim convention: <C-r>.
  map("<C-r>", function()
    local snap = M.redo_last_delete(bufnr)
    if not snap then
      require("organ.notify").info("agenda: nothing to redo")
      return
    end
    M.refresh(bufnr)
    require("organ.notify").info(("agenda: re-deleted %d subtree(s)"):format(#snap))
  end, "redo_delete")

  map("q", function()
    -- Snapshot any layout-restore command set up by M.open and run it
    -- AFTER the buffer is gone so the previous window arrangement
    -- comes back (Emacs `org-agenda-restore-windows-after-quit`).
    local restore = vim.b[bufnr].organ_agenda_restore_cmd
    vim.api.nvim_buf_delete(bufnr, { force = true })
    if restore and restore ~= "" then
      pcall(vim.cmd, restore)
    end
  end, "close")

  map("j", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = buf_state(bufnr)
    local total = vim.api.nvim_buf_line_count(bufnr)
    for i = lnum + 1, total do
      if (state.line_index or {})[i] then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, "next_item")

  map("k", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = buf_state(bufnr)
    for i = lnum - 1, 1, -1 do
      if (state.line_index or {})[i] then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, "prev_item")

  map("/", function()
    local input = vim.fn.input("filter title: ")
    local state = buf_state(bufnr)
    local view = state.view or { blocks = {} }
    for _, block in ipairs(view.blocks) do
      block.title_match = input ~= "" and input or nil
    end
    state.view = view
    set_state(bufnr, state)
    M.refresh(bufnr)
  end, "filter")

  map("<Tab>", function()
    vim.cmd("normal! za")
  end, "fold")

  map("]]", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = buf_state(bufnr)
    local starts = state.block_starts or {}
    local target
    for k in pairs(starts) do
      if k > lnum and (target == nil or k < target) then
        target = k
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
  end, "next_block")

  map("[[", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = buf_state(bufnr)
    local starts = state.block_starts or {}
    local target
    for k in pairs(starts) do
      if k < lnum and (target == nil or k > target) then
        target = k
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
  end, "prev_block")

  map("g?", function()
    local help = {
      "organ.agenda keymaps",
      "  Navigation",
      "    <CR>  jump to source         gs / gv  split / vsplit",
      "    j / k  next/prev item        ]] / [[  next/prev block",
      "    <Tab>  toggle block fold     /        title filter",
      "  Period",
      "    f / b  next/prev             .        today",
      "    gd / gw  day/week view       gj       jump to date",
      "  Per-row edit",
      "    t  cycle TODO                T        TODO menu",
      "    s  schedule                  D        deadline",
      "    +  raise priority            -        lower priority",
      "    =  clear priority            gT       set tags",
      "    R  refile                    I / O    clock in/out",
      "    e  effort filter",
      "  Bulk",
      "    <Space>  mark + advance      gM       mark all toggle",
      "    gB       apply action menu",
      "    u        undo last delete    <C-r>    redo last undone",
      "  Misc",
      "    A   archive row                gA  show/hide archived",
      "    gC  open clock report          gR  toggle in-agenda clocktable",
      "    <M-CR>  new entry            r   refresh",
      "    q   close                    g?  this help",
    }
    vim.api.nvim_echo({ { table.concat(help, "\n"), "None" } }, true, {})
  end, "help")

  map("t", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    local err = require("organ.todo").cycle(target, lnum)
    if err then
      require("organ.notify").error(err)
    end
  end, "todo_cycle")

  map("T", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    -- Use the SOURCE FILE's sequence (file-level `#+TODO:` directive
    -- wins over global config), matching Emacs's per-file behavior.
    local choices = { "(none)" }
    for _, k in ipairs(require("organ.todo").all_keywords()) do
      choices[#choices + 1] = k
    end
    -- If the row's source buffer is loaded, prefer its file-level
    -- directives over global; otherwise fall back to global keywords.
    if vim.api.nvim_buf_is_valid(target) then
      local seqs = require("organ.todo").effective_sequences(target)
      local seen, file_choices = {}, { "(none)" }
      for _, seq in ipairs(seqs) do
        for _, k in ipairs(seq) do
          if k ~= "|" and not seen[k] then
            seen[k] = true
            file_choices[#file_choices + 1] = k
          end
        end
      end
      if #file_choices > 1 then
        choices = file_choices
      end
    end
    vim.ui.select(choices, { prompt = "TODO state: " }, function(choice)
      if not choice then
        return
      end
      local state = choice == "(none)" and nil or choice
      local err = require("organ.todo").set(target, lnum, state)
      if err then
        require("organ.notify").error(err)
      end
    end)
  end, "todo_set")

  -- Priority: ^ raise, _ lower, $ clear (Emacs convention).
  -- Priority shortcuts — `+` raise, `-` lower, `=` clear. Mnemonic:
  -- + = more, - = less, = = none. Avoids vim's `^`/`$` (line start/end
  -- navigation, useful even in fixed-format buffers).
  map("+", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.inline_edit").raise_priority(target, lnum)
    M.refresh(bufnr)
  end, "priority_raise")

  map("-", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.inline_edit").lower_priority(target, lnum)
    M.refresh(bufnr)
  end, "priority_lower")

  map("=", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.inline_edit").set_priority(target, lnum, nil)
    M.refresh(bufnr)
  end, "priority_clear")

  -- Jump to a specific date (Emacs `j` in org-agenda; we use `gj` since
  -- `j` is already bound to next-item-line).
  map("gj", function()
    vim.ui.input({ prompt = "Jump to date (YYYY-MM-DD or 'today', '+1w'…): " }, function(input)
      if not input or input == "" then
        return
      end
      local query = require("organ.query")
      local parsed = nil
      if query.parse_date then
        local ok, p = pcall(query.parse_date, input)
        if ok and p then
          parsed = p
        end
      end
      -- Fall back to literal pass-through when parse_date isn't available
      -- or doesn't recognise the input — _set_window will validate.
      parsed = parsed or input
      M._set_window(bufnr, parsed, parsed)
      M.refresh(bufnr)
    end)
  end, "jump_to_date")

  -- Bulk selection + action menu (Emacs `m`/`u`/`*`/`B B`).
  -- Marks are stored on buf_state.bulk_marked as { [src_id] = true }
  -- and rendered as a sign in the agenda buffer's gutter. Action menu
  -- (`B`) iterates marked rows and applies one of: state change,
  -- schedule, deadline, refile, archive, delete-subtree.
  --
  -- Mark id: row.id when present; else file_path .. ":" .. line_start.
  local function row_mark_id(r)
    if not r then
      return nil
    end
    if r.id then
      return r.id
    end
    if r.file_path and r.line_start then
      return r.file_path .. ":" .. r.line_start
    end
    return nil
  end

  local SIGN_GROUP = "organ_agenda_bulk_" .. bufnr
  local SIGN_NAME = "OrganAgendaBulk"
  pcall(vim.fn.sign_define, SIGN_NAME, { text = "▎", texthl = "@organ.agenda.priority_A" })

  local function redraw_bulk_signs()
    pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })
    local state = buf_state(bufnr)
    local marked = state.bulk_marked or {}
    for lnum, r in pairs(state.line_index or {}) do
      local id = row_mark_id(r)
      if id and marked[id] then
        pcall(vim.fn.sign_place, 0, SIGN_GROUP, SIGN_NAME, bufnr, { lnum = lnum, priority = 10 })
      end
    end
  end

  local function set_marked(id, value)
    local state = buf_state(bufnr)
    state.bulk_marked = state.bulk_marked or {}
    state.bulk_marked[id] = value or nil
    set_state(bufnr, state)
    redraw_bulk_signs()
  end

  -- <Space> toggles bulk mark on the cursor row + advances to next
  -- item. Space is unmapped in vim-default normal mode (it's <Right>
  -- as motion), so this is the cleanest single-key for bulk select
  -- without colliding with `*` (search-word) or `m` (set register).
  map("<Space>", function()
    local r = current_row()
    local id = row_mark_id(r)
    if id then
      local state = buf_state(bufnr)
      state.bulk_marked = state.bulk_marked or {}
      local on = state.bulk_marked[id]
      state.bulk_marked[id] = (not on) and true or nil
      set_state(bufnr, state)
      redraw_bulk_signs()
    end
    -- Advance to the next item row.
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local total = vim.api.nvim_buf_line_count(bufnr)
    local state = buf_state(bufnr)
    for i = lnum + 1, total do
      if (state.line_index or {})[i] then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, "bulk_mark_toggle")

  -- gM toggles bulk mark for ALL visible rows. (gM is unbound in vim
  -- default; capital M alone moves to middle of window — useful — and
  -- `*` is search-word — also useful — so we use the g prefix.)
  map("gM", function()
    local state = buf_state(bufnr)
    state.bulk_marked = state.bulk_marked or {}
    local any = next(state.bulk_marked) ~= nil
    if any then
      state.bulk_marked = {}
    else
      for _, r in pairs(state.line_index or {}) do
        local id = row_mark_id(r)
        if id then
          state.bulk_marked[id] = true
        end
      end
    end
    set_state(bufnr, state)
    redraw_bulk_signs()
  end, "bulk_mark_all")

  -- gB applies the action menu to every marked row. (vim's `B` is
  -- back-WORD which we keep available.) Iterates marked rows, prompts
  -- for action, applies.
  -- Resolves each marked id back to its source via the buffer's
  -- line_index (we look up live so cursor moves don't matter).
  map("gB", function()
    local state = buf_state(bufnr)
    local marked = state.bulk_marked or {}
    local marked_rows = {}
    for _, r in pairs(state.line_index or {}) do
      local id = row_mark_id(r)
      if id and marked[id] then
        marked_rows[#marked_rows + 1] = r
      end
    end
    if #marked_rows == 0 then
      require("organ.notify").warn("agenda: no rows marked (press <Space> to mark)")
      return
    end
    local actions = {
      { "Set TODO state", "todo" },
      { "Schedule", "schedule" },
      { "Set deadline", "deadline" },
      { "Refile", "refile" },
      { "Archive subtree", "archive" },
      { "Delete subtree", "delete" },
    }
    local labels = {}
    for _, a in ipairs(actions) do
      labels[#labels + 1] = a[1]
    end
    vim.ui.select(
      labels,
      { prompt = ("Bulk (%d rows):"):format(#marked_rows) },
      function(choice, idx)
        if not choice then
          return
        end
        if not idx then
          for i, l in ipairs(labels) do
            if l == choice then
              idx = i
              break
            end
          end
        end
        if not idx then
          return
        end
        local kind = actions[idx][2]
        local apply
        if kind == "todo" then
          local cfg = require("organ.buf_config").read(nil, "todo") or {}
          local choices = { "(none)" }
          for _, k in ipairs(cfg.sequence or {}) do
            if k ~= "|" then
              choices[#choices + 1] = k
            end
          end
          vim.ui.select(choices, { prompt = "TODO state for all marked: " }, function(state_choice)
            if not state_choice then
              return
            end
            local new_state = state_choice == "(none)" and nil or state_choice
            for _, r in ipairs(marked_rows) do
              local target, lnum = source_for(r)
              if target then
                pcall(require("organ.todo").set, target, lnum, new_state)
              end
            end
            state.bulk_marked = {}
            set_state(bufnr, state)
            redraw_bulk_signs()
            M.refresh(bufnr)
          end)
          return
        elseif kind == "schedule" then
          apply = function(target, lnum)
            require("organ.schedule").set_schedule(target, lnum)
          end
        elseif kind == "deadline" then
          apply = function(target, lnum)
            require("organ.schedule").set_deadline(target, lnum)
          end
        elseif kind == "refile" then
          -- Bulk-refile is fiddly (one target, multiple sources) — fall
          -- back to triggering the per-row refile picker for each marked
          -- row. The user picks a destination once per row.
          apply = function(target, lnum)
            local saved = vim.api.nvim_get_current_buf()
            vim.api.nvim_set_current_buf(target)
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
            pcall(require("organ.refile").refile)
            pcall(vim.api.nvim_set_current_buf, saved)
          end
        elseif kind == "archive" then
          apply = function(target, lnum)
            require("organ.archive").archive_subtree(target, lnum)
          end
        elseif kind == "delete" then
          local confirm = vim.fn.confirm(
            ("Delete %d subtree(s)? Press `u` in this buffer to undo."):format(#marked_rows),
            "&Yes\n&No",
            2
          )
          if confirm ~= 1 then
            return
          end
          -- Resolve marked_rows to (target_buf, lnum) pairs and hand
          -- to M.bulk_delete_apply. The public function snapshots,
          -- cuts, and pushes to delete_history.
          local resolved = {}
          for _, r in ipairs(marked_rows) do
            local target, lnum = source_for(r)
            if target then
              resolved[#resolved + 1] = { _source_bufnr = target, _source_lnum = lnum }
            end
          end
          local snapshot = M.bulk_delete_apply(bufnr, resolved)
          state.bulk_marked = {}
          set_state(bufnr, state)
          redraw_bulk_signs()
          M.refresh(bufnr)
          require("organ.notify").info(("Deleted %d subtree(s). `u` to undo."):format(#snapshot))
          return
        end
        if apply then
          for _, r in ipairs(marked_rows) do
            local target, lnum = source_for(r)
            if target then
              pcall(apply, target, lnum)
            end
          end
          state.bulk_marked = {}
          set_state(bufnr, state)
          redraw_bulk_signs()
          M.refresh(bufnr)
        end
      end
    )
  end, "bulk_action")

  -- Set tags on row at cursor. Bound to `gT` (override vim's "previous
  -- tab" — agenda buffers usually live in a single tab, and the
  -- alternative `:` would shadow vim's command-mode trigger which
  -- users press constantly). For users who DO want :tabprev, vim's
  -- `:tabprevious` command is always available.
  map("gT", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    local cur = require("organ.tag_writer").read(target, lnum) or {}
    vim.ui.input(
      { prompt = "Tags (space- or colon-separated): ", default = table.concat(cur, " ") },
      function(input)
        if input == nil then
          return
        end
        local tags = {}
        for tok in input:gmatch("[^%s:]+") do
          tags[#tags + 1] = tok
        end
        require("organ.tag_writer").write(target, lnum, tags)
        M.refresh(bufnr)
      end
    )
  end, "set_tags")

  -- Toggle whether archived headlines are SHOWN in the agenda. Bound
  -- to `gA` so the user's vim `;` (repeat f/F/t/T) stays usable.
  -- Distinct from `A` below, which archives the row at cursor.
  map("gA", function()
    local state = buf_state(bufnr)
    state.show_archived = not state.show_archived
    set_state(bufnr, state)
    require("organ.notify").info(
      "agenda: archived rows " .. (state.show_archived and "shown" or "hidden")
    )
    M.refresh(bufnr)
  end, "toggle_archived_visibility")

  -- Archive the source headline of the row at cursor (Emacs `$` in
  -- agenda → `org-agenda-archive`). We use uppercase `A` because our
  -- `$` is bound to clear-priority and lowercase `a` is unbound and
  -- frequently typed by mistake.
  map("A", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    local err = require("organ.archive").archive_subtree(target, lnum)
    if err then
      require("organ.notify").error(tostring(err))
      return
    end
    require("organ.notify").info("archived")
    M.refresh(bufnr)
  end, "archive_row")

  -- Open clock report from agenda. `c` is unbound in vim default
  -- normal mode (the `c` family — `cw`, `cc` — are operator-pending,
  -- which still works because `c` alone waits for a motion. We
  -- override only the wait-for-motion case in this nofile buffer
  -- where text-changing motions are no-ops anyway.)
  map("gC", function()
    pcall(require("organ.clock").report)
  end, "clock_report")

  -- gR: toggle in-agenda clock-report mode (Emacs `R` in agenda buffer
  -- but R is taken by refile; use gR to mirror the "g-prefix for go-do"
  -- pattern). When on, the agenda renderer appends a clocktable showing
  -- clocked time for headlines visible in the current window. Toggle
  -- again to remove.
  map("gR", function()
    local state = buf_state(bufnr)
    state.clock_report_mode = not state.clock_report_mode
    set_state(bufnr, state)
    require("organ.notify").info(
      "agenda: clock-report mode " .. (state.clock_report_mode and "ON" or "OFF")
    )
    M.refresh(bufnr)
  end, "toggle_clock_report")

  -- M-CR: add a new TODO heading. Prompts for title, then for target file
  -- (defaults to the current row's file or org_dir's first file).
  map("<M-CR>", function()
    local default_path
    local r = current_row()
    if r and r.file_path then
      default_path = r.file_path
    end
    if not default_path then
      local org_dir = require("organ.buf_config").read(nil, "org_dir")
      if org_dir and org_dir ~= "" then
        local fd = vim.uv.fs_scandir(org_dir)
        if fd then
          while true do
            local n, t = vim.uv.fs_scandir_next(fd)
            if not n then
              break
            end
            if t == "file" and n:match("%.org$") then
              default_path = org_dir .. "/" .. n
              break
            end
          end
        end
      end
    end
    vim.ui.input({ prompt = "New TODO: " }, function(title)
      if not title or title == "" then
        return
      end
      vim.ui.input({ prompt = "File: ", default = default_path or "" }, function(file)
        if not file or file == "" then
          return
        end
        local ok_path, why = M.add_entry_path_ok(file)
        if not ok_path then
          require("organ.notify").error("agenda add-entry: " .. why)
          return
        end
        -- Append a new top-level TODO heading at end of file.
        local lines = vim.fn.readfile(file)
        if lines == nil then
          lines = {}
        end
        if #lines > 0 and lines[#lines] ~= "" then
          lines[#lines + 1] = ""
        end
        lines[#lines + 1] = "* TODO " .. title
        vim.fn.writefile(lines, file)
        require("organ.notify").info("appended to " .. file)
        -- Re-index + refresh agenda.
        require("organ.queue").enqueue_interactive(file)
        vim.defer_fn(function()
          M.refresh(bufnr)
        end, 200)
      end)
    end)
  end, "add_entry")

  -- Schedule / deadline: reuse the calendar picker on the source headline.
  map("s", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.schedule").set_schedule(target, lnum)
  end, "schedule")

  map("D", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.schedule").set_deadline(target, lnum)
  end, "deadline")

  -- Clocking from agenda.
  map("I", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.clock").start({ bufnr = target, line = lnum })
  end, "clock_in")

  map("O", function()
    require("organ.clock").stop({})
  end, "clock_out")

  -- Refile the source subtree: switch to source, position cursor, dispatch.
  map("R", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    vim.api.nvim_set_current_buf(target)
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
    require("organ.refile").refile()
  end, "refile")

  -- Date navigation: shift the visible window forward/back by its own length;
  -- "." resets to today (range length preserved).
  map("f", function()
    M._shift_period(bufnr, 1)
    M.refresh(bufnr)
  end, "next_period")
  map("b", function()
    M._shift_period(bufnr, -1)
    M.refresh(bufnr)
  end, "prev_period")
  map(".", function()
    M._reset_today(bufnr)
    M.refresh(bufnr)
  end, "today")

  -- View-mode switches: 1-day / 7-day window starting today.
  -- View-window commands. Prefix `g` keeps them in the same family as
  -- `gs`/`gv` (open split/vsplit). The previous `vd`/`vw` bindings
  -- caused a 1-second timeoutlen wait on every bare `v` because vim had
  -- to disambiguate `v` (visual mode) vs `vd`/`vw` (these). With `gd`/`gw`
  -- the `v` key fires visual mode immediately.
  map("gd", function()
    M._set_window(bufnr, "today", "today")
    M.refresh(bufnr)
  end, "view_day")
  map("gw", function()
    M._set_window(bufnr, "today", "+6d")
    M.refresh(bufnr)
  end, "view_week")

  -- Effort filter. `e` prompts for a spec ("<30", "1:00..2:00", ">=60");
  -- empty input clears.
  map("e", function()
    vim.ui.input({ prompt = "Effort filter (e.g. <30, 1:00..2:00, >=1h): " }, function(input)
      if input == nil then
        return
      end
      local s = buf_state(bufnr)
      s.effort_filter = input
      set_state(bufnr, s)
      M.refresh(bufnr)
    end)
  end, "effort_filter")
end

-- Convert an ISO date "YYYY-MM-DD" to a unix timestamp (UTC midnight).
local function iso_to_time(iso)
  local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 })
end

local function time_to_iso(t)
  local lt = os.date("*t", t)
  return string.format("%04d-%02d-%02d", lt.year, lt.month, lt.day)
end

local function shift_iso(iso, days)
  local t = iso_to_time(iso)
  if not t then
    return iso
  end
  return time_to_iso(t + days * 86400)
end

-- Shift every block's date window by n full periods (period = block span).
function M._shift_period(bufnr, n)
  local state = buf_state(bufnr)
  local view = state.view or { blocks = {} }
  local query = require("organ.query")
  for _, block in ipairs(view.blocks) do
    if block.from and block.to then
      local from_iso = query.parse_date(block.from)
      local to_iso = query.parse_date(block.to)
      if from_iso and to_iso then
        local from_t = iso_to_time(from_iso)
        local to_t = iso_to_time(to_iso)
        local span = math.floor((to_t - from_t) / 86400) + 1
        local delta = n * span
        block.from = shift_iso(from_iso, delta)
        block.to = shift_iso(to_iso, delta)
      end
    end
  end
  state.view = view
  set_state(bufnr, state)
end

-- Reset every block's window to today, preserving its prior span.
function M._reset_today(bufnr)
  local state = buf_state(bufnr)
  local view = state.view or { blocks = {} }
  local query = require("organ.query")
  local today_iso = query.parse_date("today")
  for _, block in ipairs(view.blocks) do
    if block.from and block.to then
      local from_iso = query.parse_date(block.from)
      local to_iso = query.parse_date(block.to)
      if from_iso and to_iso then
        local span = math.floor((iso_to_time(to_iso) - iso_to_time(from_iso)) / 86400)
        block.from = today_iso
        block.to = shift_iso(today_iso, span)
      end
    end
  end
  state.view = view
  set_state(bufnr, state)
end

-- Replace every block's window with the given (from, to) — relative or ISO.
function M._set_window(bufnr, from, to)
  local state = buf_state(bufnr)
  local view = state.view or { blocks = {} }
  for _, block in ipairs(view.blocks) do
    if block.from and block.to then
      block.from = from
      block.to = to
    end
  end
  state.view = view
  set_state(bufnr, state)
end

-- Sticky agenda registry: { [view_name] = bufnr }. Opening the same
-- view twice (e.g. user runs :Org agenda day twice) reuses the existing
-- buffer instead of creating a duplicate. Set agenda.sticky = false in
-- config to disable; default is on (matches Emacs `org-agenda-sticky`).
M._sticky = M._sticky or {}

-- Build a human-readable buffer name from view_name + resolved dates.
-- The "organ-agenda://" prefix keeps nvim from treating the name as a
-- relative file path; the body identifies the view at a glance:
--   "Day 2026-05-05"      view_name == "day"
--   "Week 2026-W19"       view_name == "week", clean ISO week
--   "Week 2026-W19-W20"   view_name == "week", spans two ISO weeks
--   "Todos"               view_name == "todos"
--   "Tag: <q>"            view_name like "tags:<q>"
--   "Search: <q>"         view_name like "search:<q>"
--   "Agenda: <name>"      any other named view
--   "Agenda"              no view_name
local function format_buf_name(view, view_name)
  local q = require("organ.query")
  local function as_iso(s)
    if not s then
      return nil
    end
    return (q.parse_date and q.parse_date(s)) or s
  end
  local first = view.blocks and view.blocks[1] or {}
  local body
  if view_name == "day" then
    body = "Day " .. (as_iso(first.from) or "?")
  elseif view_name == "week" then
    local from_iso = as_iso(first.from)
    local to_iso = as_iso(first.to or first.from)
    local from_ts = from_iso and iso_to_ts(from_iso)
    local to_ts = to_iso and iso_to_ts(to_iso)
    if from_ts and to_ts then
      local fy = os.date("%Y", from_ts)
      local fw = iso_week_of(from_ts)
      local tw = iso_week_of(to_ts)
      if tw == fw then
        body = string.format("Week %s-W%02d", fy, fw)
      else
        body = string.format("Week %s-W%02d-W%02d", fy, fw, tw)
      end
    else
      body = "Week " .. (from_iso or "?")
    end
  elseif view_name == "todos" then
    body = "Todos"
  elseif view_name and view_name:match("^tags:") then
    body = "Tag: " .. view_name:sub(6)
  elseif view_name and view_name:match("^search:") then
    body = "Search: " .. view_name:sub(8)
  elseif view_name and view_name ~= "" and view_name ~= "default" then
    body = "Agenda: " .. view_name
  else
    body = "Agenda"
  end
  return "organ-agenda://" .. body
end

-- Apply `base` as the buffer name; on collision with another buffer,
-- retry as "base (2)", "base (3)", ...  Same-name conflicts arise
-- when sticky=false and the user re-opens the same view, or when
-- two distinct views happen to render to the same human form.
local function set_unique_buf_name(bufnr, base)
  local function name_taken(name)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= bufnr and vim.api.nvim_buf_is_valid(b) then
        if vim.api.nvim_buf_get_name(b) == name then
          return true
        end
      end
    end
    return false
  end
  if not name_taken(base) then
    vim.api.nvim_buf_set_name(bufnr, base)
    return
  end
  for i = 2, 99 do
    local cand = string.format("%s (%d)", base, i)
    if not name_taken(cand) then
      vim.api.nvim_buf_set_name(bufnr, cand)
      return
    end
  end
  -- Bufnr-suffix fallback if we somehow hit 99 collisions.
  vim.api.nvim_buf_set_name(bufnr, string.format("%s [%d]", base, bufnr))
end

-- Exposed for tests; call sites stay local.
M._format_buf_name = format_buf_name

function M.open(view_opts, view_name)
  register_highlights()

  -- First-run safety net: if the DB has zero indexed files AND the
  -- user has a real org_dir, trigger a background scan and tell them.
  -- Otherwise the agenda silently shows nothing useful, which masquerades
  -- as a parser/filter bug — Emacs's agenda always re-reads
  -- `org-agenda-files` on open.  We don't wait for the scan; the user
  -- can `r`-refresh once the queue drains.  We probe the DB directly
  -- (`indexer.files_count`) instead of trusting `_last_status.last_file`,
  -- which is session-local state that resets on every nvim restart.
  do
    local organ = require("organ")
    local org_dir = organ.config and require("organ.buf_config").read(nil, "org_dir")
    local indexed = 0
    local rt_ok, rt = pcall(require, "organ.runtime")
    if rt_ok then
      local h_ok, h = pcall(rt.db)
      if h_ok and h then
        local idx_ok, idx = pcall(require, "organ.indexer")
        if idx_ok and idx.files_count then
          indexed = idx.files_count(h)
        end
      end
    end
    if
      indexed == 0
      and type(org_dir) == "string"
      and org_dir ~= ""
      and vim.fn.isdirectory(vim.fn.expand(org_dir)) == 1
    then
      require("organ.notify").info(
        "organ: index is empty — scanning "
          .. org_dir
          .. " in background (refresh agenda with `r` when done)"
      )
      pcall(organ._start_scan)
    end
  end

  local view, err = M.normalize_view(view_opts, view_name)
  if not view then
    require("organ.notify").error(err)
    return nil
  end

  local default_lf = (require("organ.buf_config").read(nil, "agenda") or {}).line_format
  if default_lf then
    for _, block in ipairs(view.blocks) do
      if block.line_format == nil then
        block.line_format = default_lf
      end
    end
  end

  -- Reuse an existing buffer for this view name (sticky agenda). The
  -- buffer keeps its scroll position, fold state, and bulk_marked set
  -- across re-opens. New view config overwrites the stored view so a
  -- changed period / title_match takes effect on next refresh.
  local sticky_on = ((require("organ.buf_config").read(nil, "agenda") or {}).sticky ~= false)
  local sticky_key = view_name or "default"
  if sticky_on and M._sticky[sticky_key] then
    local existing = M._sticky[sticky_key]
    if vim.api.nvim_buf_is_valid(existing) then
      local state = decode_state(vim.b[existing].organ_agenda) or {}
      state.view = view
      state.view_name = view_name or "default"
      local first = view.blocks[1] or {}
      if first.from then
        state.window = { from = first.from, to = first.to }
      end
      vim.b[existing].organ_agenda = encode_state(state)
      -- Refresh the buffer name in case the view's resolved date
      -- changed (e.g. "day" view kept across midnight).
      local desired = format_buf_name(view, view_name)
      if vim.api.nvim_buf_get_name(existing) ~= desired then
        set_unique_buf_name(existing, desired)
      end
      vim.api.nvim_set_current_buf(existing)
      M.refresh(existing)
      return existing
    else
      M._sticky[sticky_key] = nil
    end
  end

  local bufnr = vim.api.nvim_create_buf(true, true)
  set_unique_buf_name(bufnr, format_buf_name(view, view_name))
  vim.bo[bufnr].filetype = "organ-agenda"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false
  if sticky_on then
    M._sticky[sticky_key] = bufnr
  end

  -- Stash the view kind / window / name on the buffer so the statusline
  -- elements (`organ.statusline`) and lualine components can read them.
  local first = view.blocks[1] or {}
  local window
  if first.from then
    window = { from = first.from, to = first.to }
  end
  -- Honor on_start defaults so users who always want previews / log
  -- mode don't have to press the toggle after every open.
  local et_cfg = ((require("organ.buf_config").read(nil, "agenda") or {}).entry_text or {})
  local log_cfg_init = ((require("organ.buf_config").read(nil, "agenda") or {}).log_mode or {})
  set_state(bufnr, {
    view = view,
    view_name = view_name or "default",
    window = window,
    listeners = {},
    entry_text = et_cfg.on_start == true,
    log_mode = log_cfg_init.on_start == true,
  })

  local organ = require("organ")
  local cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  local debounce_ms = (view.refresh_debounce_ms or cfg.refresh_debounce_ms or 300)
  local timer
  local listener = function(payload)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if payload and payload.skipped then
      return
    end
    if timer then
      timer:stop()
      timer:close()
    end
    local t = vim.loop.new_timer()
    timer = t
    t:start(
      debounce_ms,
      0,
      vim.schedule_wrap(function()
        if t:is_closing() then
          return
        end
        t:stop()
        t:close()
        if timer == t then
          timer = nil
        end
        if vim.api.nvim_buf_is_valid(bufnr) then
          M.refresh(bufnr)
        end
      end)
    )
  end

  local events = require("organ.events")
  events.on("indexed", listener)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      events.off("indexed", listener)
      if timer then
        pcall(function()
          timer:stop()
          timer:close()
        end)
      end
      -- Drop the sticky registry entry pointing here so a subsequent
      -- :Org agenda creates a fresh buffer instead of trying to reuse
      -- this (now-wiped) bufnr.
      for k, v in pairs(M._sticky) do
        if v == bufnr then
          M._sticky[k] = nil
        end
      end
    end,
  })

  -- WinResized: rerender so the tag-overflow check (virt_text vs
  -- single-cell marker) re-evaluates against the new content width.
  -- Without this, a window narrowed AFTER initial render still has
  -- the original full-tag virt_text emitted at the right edge — and
  -- with line text now wider than (window - tag_width), the virt_text
  -- visually overlaps the END of the title.  Refresh is debounced
  -- through the same timer the indexed-listener uses so back-to-back
  -- resizes don't thrash.
  local resize_group =
    vim.api.nvim_create_augroup("organ_agenda_resize_" .. bufnr, { clear = true })
  local resize_timer
  vim.api.nvim_create_autocmd("WinResized", {
    group = resize_group,
    callback = function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      -- Only refresh when this buffer is actually visible somewhere.
      local visible = false
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == bufnr then
          visible = true
          break
        end
      end
      if not visible then
        return
      end
      if resize_timer then
        resize_timer:stop()
        resize_timer:close()
      end
      local t = vim.loop.new_timer()
      resize_timer = t
      t:start(
        50,
        0,
        vim.schedule_wrap(function()
          if t:is_closing() then
            return
          end
          t:stop()
          t:close()
          if resize_timer == t then
            resize_timer = nil
          end
          if vim.api.nvim_buf_is_valid(bufnr) then
            M.refresh(bufnr)
          end
        end)
      )
    end,
  })

  install_keymaps(bufnr)

  -- Window-open strategy (Emacs `org-agenda-window-setup`).  Default
  -- "reuse" replaces the current window's buffer (preserves layout).
  -- Other shapes:
  --   "only"          → close other windows, agenda fills the tab
  --   "split-below"   → horizontal split beneath the current window
  --   "vsplit-right"  → vertical split to the right
  --   "tab"           → new tab page
  -- When `restore_windows_after_quit` is on, the previous layout is
  -- snapshot-and-restored on `q` close.
  local cfg_open = cfg.window_setup or "reuse"
  local cfg_restore = cfg.restore_windows_after_quit == true
  local restore_view
  if cfg_restore then
    restore_view = vim.fn.winrestcmd()
  end

  if cfg_open == "only" then
    pcall(vim.cmd, "only")
    vim.api.nvim_set_current_buf(bufnr)
  elseif cfg_open == "split-below" then
    vim.cmd("belowright new")
    vim.api.nvim_set_current_buf(bufnr)
  elseif cfg_open == "vsplit-right" then
    vim.cmd("rightbelow vnew")
    vim.api.nvim_set_current_buf(bufnr)
  elseif cfg_open == "tab" then
    vim.cmd("tabnew")
    vim.api.nvim_set_current_buf(bufnr)
  else -- "reuse" / "current" / unknown
    vim.api.nvim_set_current_buf(bufnr)
  end

  if cfg_restore and restore_view then
    -- Defer the restore command to `q` close so it runs in the
    -- right window context.  Stash on the buffer var so it survives
    -- across refresh cycles.
    vim.b[bufnr].organ_agenda_restore_cmd = restore_view
  end

  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_set_option_value("foldmethod", "expr", { win = winid })
  vim.api.nvim_set_option_value(
    "foldexpr",
    "v:lua.require'organ.agenda'.foldexpr(v:lnum)",
    { win = winid }
  )
  vim.api.nvim_set_option_value("foldlevel", 99, { win = winid })
  -- Emacs's agenda buffer has `truncate-lines` on; mirror that so long
  -- title rows don't wrap and so `virt_text_pos = "right_align"` tags
  -- always anchor cleanly at the window's right edge.
  vim.api.nvim_set_option_value("wrap", false, { win = winid })

  -- Window-local winbar + statusline. Buffer-local only — never touches
  -- the user's global `vim.o.winbar` / `vim.o.statusline`. Each is opt-out
  -- (`agenda.winbar = false` / `agenda.statusline = false`) and accepts a
  -- string OR function override. See `:h organ-statusline` for the
  -- composable pieces if the user wants to compose their own.
  require("organ.statusline").apply(bufnr, {
    winbar = cfg.winbar,
    winbar_default = "agenda_winbar",
    statusline = cfg.statusline,
    statusline_default = "agenda_statusline",
  })

  M.refresh(bufnr)
  return bufnr
end

-- Exposed for tests: invokes the same filter pipeline (file-based
-- includes, todo-list ignores, COMMENT-tree skip, skip-if-done,
-- overdue-rollup, tag-match predicate, …) the agenda buffer uses.
M._run_query = run_query
-- Forward-published so `M.render` (declared earlier in the file) can
-- re-apply user-face overrides on every render without breaking the
-- top-down `local function` declaration order.
M._register_highlights = register_highlights

-- High-level entry points (the cmd.lua shims forward to these).

--- Open the day-view agenda (today only).
function M.day()
  local cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  local view = vim.tbl_extend("force", {}, cfg.default_view or {}, {
    from = "today",
    to = "today",
  })
  M.open(view, "day")
end

--- Open the week-view agenda anchored to `agenda.week_starts_on`:
---   "monday".."sunday"   pin the first day of the week (default
---                        "monday", mirroring Emacs's default)
---   "today"              no fixed anchor; window is today..+6d
function M.week()
  local cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  local sow = resolve_week_anchor(cfg.week_starts_on)
  local now_ts = os.time()
  local week_start_ts
  if sow == nil then
    week_start_ts = now_ts
  else
    local w = tonumber(os.date("%w", now_ts))
    local iso = (w == 0) and 7 or w
    local back = (iso - sow) % 7
    week_start_ts = now_ts - back * 86400
  end
  local week_end_ts = week_start_ts + 6 * 86400
  local view = vim.tbl_extend("force", {}, cfg.default_view or {}, {
    from = os.date("%Y-%m-%d", week_start_ts),
    to = os.date("%Y-%m-%d", week_end_ts),
  })
  M.open(view, "week")
end

--- Open the global TODO list (every active TODO across all org files).
function M.todos()
  M.open({
    blocks = {
      {
        label = "Global TODOs",
        kind = "todo",
        todo = { exclude = { "DONE", "CANCELLED", "CANCELED", "CLOSED" } },
      },
    },
  }, "todos")
end

--- Open a tag-match agenda view.  When `query` is nil/empty, prompts via
--- `vim.ui.input` (Emacs `M-x org-tags-view`).
function M.tags(query)
  local function go(q)
    if not q or q == "" then
      return
    end
    M.open({
      blocks = { { label = "Tag match: " .. q, kind = "tags", tag_match = q } },
    }, "tags:" .. q)
  end
  if query and query ~= "" then
    go(query)
    return
  end
  vim.ui.input({ prompt = "Tag query (e.g. work&urgent-@home): " }, go)
end

--- Open a title-search agenda view.  When `query` is nil/empty, prompts via
--- `vim.ui.input`.
function M.search(query)
  local function go(q)
    if not q or q == "" then
      return
    end
    M.open({
      blocks = { { label = "Search: " .. q, kind = "search", title_match = q } },
    }, "search:" .. q)
  end
  if query and query ~= "" then
    go(query)
    return
  end
  vim.ui.input({ prompt = "Search string: " }, go)
end

--- Open the stuck-projects view.
function M.stuck()
  M.open({ blocks = { { label = "Stuck projects", kind = "stuck" } } })
end

--- Open a user-defined named view from `config.agenda.views[name]`.  Surfaces
--- a notify error if the name is not registered.
function M.named_view(name)
  local views = (require("organ.buf_config").read(nil, "agenda") or {}).views or {}
  local view = views[name]
  if not view then
    require("organ.notify").error("organ: no agenda view named " .. tostring(name))
    return
  end
  M.open(view, name)
end

-- Build the dispatcher entry list (key, label, action).  Standard entries
-- + every named view + a "default" tail entry on `D` (or space if D is
-- already taken by a user view).
local function build_dispatch_entries()
  local entries = {
    { "a", "Week agenda", M.week },
    { "d", "Day agenda", M.day },
    { "t", "Global TODO list", M.todos },
    { "m", "Tag query…", M.tags },
    { "s", "Search by string…", M.search },
    { "#", "Stuck projects", M.stuck },
  }
  local views = (require("organ.buf_config").read(nil, "agenda") or {}).views or {}
  local used = {}
  for _, e in ipairs(entries) do
    used[e[1]] = true
  end
  local view_names = {}
  for k in pairs(views) do
    view_names[#view_names + 1] = k
  end
  table.sort(view_names)
  for _, k in ipairs(view_names) do
    local first = k:sub(1, 1)
    local key = (not used[first]) and first or nil
    if key then
      used[key] = true
    end
    entries[#entries + 1] = {
      key or " ",
      k,
      function()
        M.open(views[k], k)
      end,
    }
  end
  local def_key = used["D"] and " " or "D"
  used[def_key] = true
  entries[#entries + 1] = {
    def_key,
    "default",
    function()
      M.open((require("organ.buf_config").read(nil, "agenda") or {}).default_view, "default_view")
    end,
  }
  return entries
end
M._build_dispatch_entries = build_dispatch_entries

-- Show a single-keystroke menu in a centered floating window and
-- block on getcharstr until the user picks.  Returns the matched
-- entry's action (a function) or nil on cancel / unmapped key.
-- Works under any UI plugin (noice / snacks / native cmdline) since
-- it doesn't go through nvim_echo or vim.notify -- those routes
-- get intercepted and the menu fades.
local function show_popup_menu(entries, title)
  local lines = { "Press key for an agenda command:", "" }
  for _, e in ipairs(entries) do
    lines[#lines + 1] = string.format("  %s   %s", e[1], e[2])
  end
  local width = 0
  for _, l in ipairs(lines) do
    if #l > width then
      width = #l
    end
  end
  width = math.max(width + 2, #(title or "") + 4)
  local height = #lines

  local bufnr = vim.api.nvim_create_buf(false, true)
  obuf.set_lines(bufnr, 0, -1, lines)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false

  local row = math.max(0, math.floor((vim.o.lines - height) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local win = vim.api.nvim_open_win(bufnr, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    style = "minimal",
    title = title and (" " .. title .. " ") or nil,
    title_pos = title and "center" or nil,
    noautocmd = true,
  })

  -- Force a redraw so the popup is visible before getcharstr blocks.
  pcall(vim.cmd, "redraw")
  local ok, char = pcall(vim.fn.getcharstr)
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.cmd, "redraw")

  if not ok or not char or char == "" then
    return nil, nil
  end
  for _, e in ipairs(entries) do
    if e[1] == char then
      return e[3], char
    end
  end
  return nil, char
end

--- Open the agenda dispatcher menu (Emacs `C-c a`).  Style is controlled
--- by `config.agenda.dispatcher_style`:
---   "popup"  — single-keystroke menu in a floating window (default;
---              works under noice / snacks / native cmdline alike)
---   "echo"   — single-keystroke menu via nvim_echo + getchar
---              (terminal-classic; gets intercepted by some UI plugins)
---   "select" — `vim.ui.select` (telescope / dressing / snacks-pickers)
---   custom   — `config.agenda.dispatcher_handler({title, entries})`
function M.dispatch()
  local cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  local entries = build_dispatch_entries()

  local handler = cfg.dispatcher_handler
  if type(handler) == "function" then
    local data = {}
    for _, e in ipairs(entries) do
      data[#data + 1] = { key = e[1], label = e[2], action = e[3] }
    end
    handler({ title = "Agenda dispatcher", entries = data })
    return
  end

  if cfg.dispatcher_style == "select" then
    local labels = {}
    for _, e in ipairs(entries) do
      labels[#labels + 1] = string.format("%s   %s", e[1], e[2])
    end
    vim.ui.select(labels, { prompt = "Agenda dispatcher:" }, function(choice, idx)
      if not choice then
        return
      end
      if not idx then
        for i, l in ipairs(labels) do
          if l == choice then
            idx = i
            break
          end
        end
      end
      if not idx then
        return
      end
      local ok, err = pcall(entries[idx][3])
      if not ok then
        require("organ.notify").error("agenda: " .. tostring(err))
      end
    end)
    return
  end

  if cfg.dispatcher_style == "echo" then
    local lines = { "Press key for an agenda command:", "" }
    for _, e in ipairs(entries) do
      lines[#lines + 1] = string.format("  %s   %s", e[1], e[2])
    end
    vim.api.nvim_echo({ { table.concat(lines, "\n"), "Normal" } }, false, {})
    local ok, char = pcall(vim.fn.getcharstr)
    pcall(vim.cmd, "redraw")
    if not ok or not char or char == "" then
      return
    end
    for _, e in ipairs(entries) do
      if e[1] == char then
        local ok2, err = pcall(e[3])
        if not ok2 then
          require("organ.notify").error("agenda: " .. tostring(err))
        end
        return
      end
    end
    require("organ.notify").warn("organ: no agenda view bound to '" .. char .. "'")
    return
  end

  -- Default: floating-window popup.
  local action, char = show_popup_menu(entries, "Agenda dispatcher")
  if action then
    local ok, err = pcall(action)
    if not ok then
      require("organ.notify").error("agenda: " .. tostring(err))
    end
  elseif char and char ~= "" and char ~= "\27" and char ~= "\3" then
    -- Esc (\27) and Ctrl-C (\3) cancel silently; any other unmapped
    -- key reports so the user knows the menu didn't bind it.
    require("organ.notify").warn("organ: no agenda view bound to '" .. char .. "'")
  end
end

-- Exposed for tests; the only call site stays inside this module.
M._show_popup_menu = show_popup_menu

local function complete_agenda_views()
  local out = {}
  for k in pairs((require("organ.buf_config").read(nil, "agenda") or {}).views or {}) do
    out[#out + 1] = k
  end
  return out
end

-- :Org agenda custom <lua-expr> evaluates a Lua expression that returns
-- a view spec (matching M.normalize_view shape) and opens it.  Mirrors
-- Emacs `org-agenda-custom-commands` ad-hoc dispatch but inline.
local function open_custom_view(args)
  local expr = args or ""
  if expr == "" then
    require("organ.notify").warn(":Org agenda custom requires a Lua view-spec expression")
    return
  end
  local chunk, err = loadstring("return " .. expr)
  if not chunk then
    chunk, err = loadstring(expr)
  end
  if not chunk then
    require("organ.notify").error("invalid view-spec expression: " .. tostring(err))
    return
  end
  local ok, view = pcall(chunk)
  if not ok then
    require("organ.notify").error("view-spec evaluation failed: " .. tostring(view))
    return
  end
  if type(view) ~= "table" then
    require("organ.notify").error("view-spec must be a table; got " .. type(view))
    return
  end
  M.open(view, "custom")
end

-- :Org habits -- list every `:STYLE: habit` headline with status,
-- streak, and a consistency-graph row showing the last N days
-- (default 21).  Builds a popup buffer with the habits report.
local function open_habits_view(days_arg)
  local days = tonumber(days_arg) or 21
  local query = require("organ.query")
  local hab = require("organ.habit")
  local rep = require("organ.todo.repeater")

  local rows = query.habits({ days = days })
  if #rows == 0 then
    require("organ.notify").info("no habits found (no :STYLE: habit properties)")
    return
  end

  local today = _today_iso()
  local lines = { string.format("Habits -- %d days ending %s", days, today), "" }
  for _, r in ipairs(rows) do
    local repeater = nil
    if r.scheduled then
      repeater = rep.parse("<" .. r.scheduled:sub(2, -2) .. ">")
    end
    local info = {
      scheduled_date = r.scheduled_date and r.scheduled_date:sub(1, 10) or nil,
      period_days = hab.period_days(repeater),
      alarm_days = hab.alarm_days(repeater),
      completions = r.completions,
    }
    local glyph_row = hab.render_glyph_row(info, today, days)
    local status = hab.status(info, today)
    local streak = hab.streak(r.completions, info.period_days)
    lines[#lines + 1] = string.format(
      "  %s  %-12s  streak=%-3d  %s   %s",
      glyph_row,
      status,
      streak,
      r.title or "(untitled)",
      r.file_path
          and (vim.fn.fnamemodify(r.file_path, ":t") .. ":" .. tostring((r.line_start or 0) + 1))
        or ""
    )
  end

  local buf = vim.api.nvim_create_buf(false, true)
  obuf.set_lines(buf, 0, -1, lines)
  vim.api.nvim_set_option_value("filetype", "organ-habits", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(120, vim.o.columns - 4),
    height = math.min(#lines + 2, vim.o.lines - 4),
    row = 2,
    col = 2,
    border = "rounded",
    title = " Habits ",
  })
end

M.commands = {
  agenda = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      if args ~= "" then
        M.named_view(args)
      else
        M.dispatch()
      end
    end,
    nargs = "?",
    complete = complete_agenda_views,
    desc = "Open organ agenda (with optional named view)",
  },
  ["agenda day"] = {
    fn = function()
      M.day()
    end,
    desc = "Agenda for today (single-day window)",
  },
  ["agenda week"] = {
    fn = function()
      M.week()
    end,
    desc = "Agenda for the current week",
  },
  ["agenda todos"] = {
    fn = function()
      M.todos()
    end,
    desc = "Global TODO list across all org files",
  },
  ["agenda tags"] = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      M.tags(args ~= "" and args or nil)
    end,
    nargs = "?",
    desc = "Tag-query agenda view (Emacs org-match syntax)",
  },
  ["agenda search"] = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      M.search(args ~= "" and args or nil)
    end,
    nargs = "?",
    desc = "Title-substring search agenda view",
  },
  ["agenda custom"] = {
    fn = function(cmd)
      open_custom_view(cmd and cmd.args)
    end,
    nargs = "+",
    desc = "Open an ad-hoc view from a Lua expression (like Emacs org-agenda-custom-commands)",
  },
  stuck_projects = {
    fn = function()
      M.stuck()
    end,
    desc = "Open agenda buffer with stuck projects",
  },
  habits = {
    fn = function(cmd)
      open_habits_view(cmd and cmd.args)
    end,
    nargs = "?",
    desc = "Habits view (consistency graph + streaks; arg = days, default 21)",
  },
}

return M
