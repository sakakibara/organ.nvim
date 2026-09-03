-- Turns agenda records into display lines and extmark specs.
-- Owns the prefix mini-format-language, category resolution, and
-- render-config assembly.

local M = {}

local dates = require("organ.agenda.dates")

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
-- Per-render cache of file_path -> CATEGORY (via `#+CATEGORY:` directive
-- read from the file's leading comment block). reset_caches() drops it at
-- the start of each render, so rows that share a file read it once per
-- pass while a live directive edit shows on the next refresh.
local _category_cache = {}

local function reset_caches()
  _category_cache = {}
end

-- Read the first ~30 lines of `path` and return the `#+CATEGORY:` value
-- if present (case-insensitive directive name).
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
--   * a string -- applied to every block regardless of kind. Same mini-
--     format-language as Emacs (see format_prefix below for tokens).
--   * a table keyed by view kind: { agenda = "...", todo = "...",
--     stuck = "...", default = "..." } -- picked per block. Mirrors
--     Emacs's per-view-type defaults.
--   * a function `function(record, ctx) -> string` -- full control.
--
-- Defaults mirror Emacs's `org-agenda-prefix-format`:
--   agenda (daily/weekly): "  %-12:c %?-12t %?s "
--     -> category-with-colon padded to 12, time dot-padded to 12 (or
--       12 spaces when un-timed), Scheduled:/Deadline: tag (blank when
--       neither). Matches Emacs's daily-agenda visual style.
--   todo (global TODO list): "  %-12:c "
--     -> category-with-colon only; time/sched/dl noise is dropped because
--       the global TODO list isn't date-window-scoped.
local DEFAULT_PREFIX_FORMAT = {
  -- Matches Emacs's `org-agenda-prefix-format` default:
  --   `  %-12:c%?-12t %?-11s `
  -- Layout is three fixed-width fields:
  --   - cat:   12 chars (Tasks: -> "Tasks:      ")
  --   - time:  12 chars (timed: ` 9:00 ┄┄┄┄┄ `; untimed: 12 spaces)
  --   - sched: 12 chars (with-label: "Scheduled:  "; without: 12 sp)
  -- NO separator between cat and time -- the right-aligned hour
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
    todo_width = cfg.todo_width, -- nil -> auto-fit per block
    -- Tag right-align column. Default `-1` = "right edge minus 1
    -- char" (window-relative, matches Emacs's `org-agenda-tags-column`
    -- default of -2 closely -- Emacs uses -2 to leave 2-char gap;
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
    --   false        -> no separator (just a blank line)
    --   true / nil   -> default `═` repeated to the content width
    --   string "X"   -> that single char repeated to the content width
    --   string "..." -> multi-char strings render as the literal string
    --                  (no rep), trimmed/padded to the content width
    block_separator = cfg.block_separator,
  }
end

-- Pick the right format string for a given block, given a per-kind
-- prefix_format table. Heuristic for kind-detection when the user didn't
-- set `block.kind` explicitly: `from` set -> daily-agenda; else -> todo.
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
--   %t           scheduled time, e.g. `9:00` (no leading zero -- Emacs default)
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

-- Compute the per-row scheduling label. `today` is an ISO yyyy-mm-dd
-- string (the renderer's reference point, may be back-dated for tests).
local function sched_label_for(r, today)
  if not today then
    today = dates.today_iso()
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
  --   * scheduled date == today (the bucket date) -> "Scheduled:"
  --   * deadline  date == today                   -> "Deadline:"
  --   * else fall through to whichever is sooner / present
  -- Mirrors Emacs's per-bucket precedence (Tuesday's "Submit expense"
  -- row reads "Scheduled:" because Tuesday is its scheduled day, not
  -- "In 2 d.:" because the deadline is later in the week).
  local has_sched = r.scheduled_date and r.scheduled_date ~= ""
  local has_dead = r.deadline_date and r.deadline_date ~= ""
  local sched_d = has_sched and dates.days_diff(today, r.scheduled_date) or nil
  local dead_d = has_dead and dates.days_diff(today, r.deadline_date) or nil

  -- Priority order for the sched-label (matches Emacs's
  -- org-agenda-format priority -- overdue-scheduled wins over
  -- deadline-warning when both apply, because the overdue scheduled
  -- is the primary view of the row):
  --   1. scheduled today          -> "Scheduled:"
  --   2. deadline today           -> "Deadline:"
  --   3. scheduled overdue        -> "Sched. Nx:" (carryover label)
  --   4. deadline within 14 days  -> "In   N d.:"  (early warning)
  --   5. scheduled within 14 days -> "In   N d.:"
  --   6. fallback                 -> "Scheduled:" / "Deadline:" / ""
  if sched_d == 0 then
    return "Scheduled:"
  end
  if dead_d == 0 then
    return "Deadline:"
  end
  if has_sched and sched_d and sched_d < 0 then
    -- Overdue: Emacs shows "Sched.Nx" with N = raw days late, for
    -- habit-style rows and ordinary scheduled rows alike -- verified
    -- against real Emacs 30.1 (a `.+1w` habit 3 days overdue reads
    -- "Sched. 3x:", not a repeat-cycle count).
    return string.format("Sched.%2dx:", -sched_d)
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
  local tstr = dates.time_only(r.scheduled_date) or ""
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
    -- walk` -- empty time + empty sched columns disappear entirely.
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
        -- Map: { category_name = "icon ", ... }.  No-op when unset.
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
-- line numbers, and fold column don't count as text cells -- padding
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

-- Resolve the per-row prefix spec from block/render opts.  A table spec
-- (per-view-type map) without an enclosing block picks the "default"
-- entry as the safest fallback.
local function resolve_row_prefix_spec(block_opts, opts)
  local prefix_spec = block_opts.prefix_format or opts.prefix_format
  if type(prefix_spec) == "table" then
    prefix_spec = prefix_spec.default or prefix_spec.todo or "  %-12:c "
  end
  return prefix_spec
end

-- Render the prefix block (category + time + sched/dl tag), mirroring
-- Emacs's `org-agenda-prefix-format`.  A function spec is called with
-- the row + context; a string spec runs through format_prefix.
local function build_prefix(prefix_spec, r, opts)
  if type(prefix_spec) == "function" then
    local ok, s = pcall(prefix_spec, r, { category = category_for(r), today = opts.today })
    return ok and s or ""
  end
  return format_prefix(prefix_spec, r, opts)
end

-- Locate semantic substrings inside the prefix and highlight them.
-- Category, time, and the Scheduled:/Deadline: tag all live in the
-- prefix string so we colorize by string-search.
local function mark_prefix_substrings(marks, prefix_str, r)
  local cat = category_for(r)
  local cat_start = prefix_str:find(cat, 1, true)
  if cat_start then
    marks[#marks + 1] = { "@organ.agenda.category", cat_start - 1, cat_start - 1 + #cat }
  end
  local tstr = dates.time_only(r.scheduled_date)
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
  -- "In   N d.:" and "Sched. Nx:" -- match by pattern (note the space
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

-- TODO state (left-padded to `todo_width`; no padding if nothing in this
-- block has a state).  When `agenda.todo_keyword_format` is set (Emacs
-- `org-agenda-todo-keyword-format`, default `"%s"`), the keyword passes
-- through `string.format` first so users can right-pad / left-pad / wrap
-- it.  Examples: `"%-7s"` right-pads to 7 chars so all rows align across
-- `TODO` / `NEXT` / `WAITING`; `"[%s]"` wraps in brackets.
local function append_todo(parts, marks, col, r, todo_width)
  if todo_width <= 0 then
    return col
  end
  local todo_raw = r.todo_state or ""
  local kw_fmt = (require("organ.buf_config").read(nil, "agenda") or {}).todo_keyword_format or "%s"
  local todo_disp = todo_raw
  if r.todo_state and kw_fmt ~= "%s" then
    local ok, formatted = pcall(string.format, kw_fmt, todo_raw)
    if ok then
      todo_disp = formatted
    end
  end
  local todo_padded = todo_disp
  local disp_width = vim.fn.strdisplaywidth(todo_disp)
  if disp_width < todo_width then
    todo_padded = todo_disp .. string.rep(" ", todo_width - disp_width)
  end
  table.insert(parts, todo_padded)
  if r.todo_state then
    local hl = "@organ.agenda.todo_" .. r.todo_state:lower()
    marks[#marks + 1] = { hl, col, col + #todo_disp }
  end
  col = col + #todo_padded
  table.insert(parts, " ")
  col = col + 1
  return col
end

-- Priority cookie `[#A]` -- matches the org-mode source format. Blank
-- when unset (no `[ ]` placeholder; mirrors Emacs).
local function append_priority(parts, marks, col, r)
  if not r.priority then
    return col
  end
  local prio_text = "[#" .. r.priority .. "]"
  table.insert(parts, prio_text .. " ")
  marks[#marks + 1] = { "@organ.agenda.priority_" .. r.priority, col, col + #prio_text }
  return col + #prio_text + 1
end

-- Title. Apply @organ.agenda.title so titles read distinctly from body
-- text (Emacs uses org-agenda-structure-secondary-face / the per-todo-
-- state face that bleeds into title bytes; we keep them separate so
-- users can theme each independently).
local function append_title(parts, marks, col, r)
  local title = r.title or ""
  if title == "" then
    return col
  end
  table.insert(parts, title)
  marks[#marks + 1] = { "@organ.agenda.title", col, col + #title }
  return col + #title
end

-- Build the tag display string from a row's tags, mirroring Emacs's
-- tag-marker convention:
--   * pure-direct, no inherited   -> `:tag1:tag2:`
--   * pure-inherited, no direct    -> `:tag1:tag2::`  (trailing `::`)
--   * mixed                        -> `:inh1::dir1:dir2:`
local function build_tag_str(r, n_direct)
  if n_direct >= #r.tags then
    return ":" .. table.concat(r.tags, ":") .. ":"
  elseif n_direct == 0 then
    return ":" .. table.concat(r.tags, ":") .. "::"
  end
  local direct, inherited = {}, {}
  for i, t in ipairs(r.tags) do
    if i <= n_direct then
      direct[#direct + 1] = t
    else
      inherited[#inherited + 1] = t
    end
  end
  return ":" .. table.concat(inherited, ":") .. "::" .. table.concat(direct, ":") .. ":"
end

-- Build per-tag virt_text chunks so `tags.faces[tag]` can color
-- individual tags (Emacs `org-tag-faces`).  Fall back to the generic
-- `@organ.agenda.tag` highlight for tags without a registered face.
-- When `faces` is empty, return a single chunk so we don't pay the
-- split cost.
local function build_tag_chunks(r, n_direct, tag_str, faces)
  if next(faces) == nil then
    return { { tag_str, "@organ.agenda.tag" } }
  end
  local chunks = {}
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
    -- a third colon in a row -- strip the first colon by passing
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

-- Tags as a `virt_text_pos = "right_align"` extmark rather than written
-- into the line.  Neovim's render layer positions virt-text against the
-- window's right edge on every redraw, so window resizes / splits /
-- Zen-mode toggles re-align the tag column for free with no buffer churn
-- or flicker (same mechanism as winbar / statuscolumn).  Nothing in the
-- line string itself changes; tags float independently.  Strictly better
-- than Emacs's "re-align on refresh only" behavior.
--
-- Overflow guard: when the line text + a 2-char gap + tag block would
-- not fit in the window's content area, the tag virt_text would visually
-- overlap the END of the title.  Title visibility wins -- drop the tag
-- and emit a single-cell marker (`tags_overflow_marker`, default `›`) so
-- the user still knows tags exist on this row and can widen the window
-- to see them.  Marks tuple's 5th element is an `extra_opts` table merged
-- into the nvim_buf_set_extmark call by `apply_extmarks`.  col is left
-- unchanged -- virt_text doesn't occupy line cells.
local function append_tags_virt(marks, col, r, n_direct, tag_str, faces, agcfg)
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
        virt_text = build_tag_chunks(r, n_direct, tag_str, faces),
        virt_text_pos = "right_align",
        hl_mode = "combine",
      },
    }
  end
  return col
end

-- Legacy inline-padding path: bake tag chars + spaces into the buffer
-- line.  Use this when consumers need plain-text output (export, copy/
-- paste, headless snapshot tests).
--
-- Overflow guard (same policy as virt_align mode): when the title +
-- 2-char gap + tag block exceeds the visible content width, write a
-- single-cell `tags_overflow_marker` (default `›`) instead of the full
-- tag run.  Title stays readable, user knows tags exist.  Set
-- `tags_overflow_marker = false` to keep the legacy behavior of always
-- emitting full tags (which then get clipped at the window edge).
local function append_tags_inline(parts, marks, col, r, n_direct, tag_str, faces, agcfg, opts)
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
      -- emit one extmark per chunk at the corresponding byte offset
      -- inside the inlined tag_str.
      local off = col + #pad
      for _, chunk in ipairs(build_tag_chunks(r, n_direct, tag_str, faces)) do
        local txt, hl = chunk[1], chunk[2]
        marks[#marks + 1] = { hl, off, off + #txt }
        off = off + #txt
      end
    end
    col = col + #pad + #tag_str
  end
  return col
end

-- Tags -- right-aligned at `tags_column` (Emacs convention).  When
-- inherited tags are present (n_direct_tags < #tags), Emacs emits
-- `:inherited1:inherited2::direct1:direct2:` -- the doubled colon
-- between sections marks the inheritance boundary.  Pure-direct and
-- pure-inherited rows just get `:tag1:tag2:`.
local function append_tags(parts, marks, col, r, opts)
  if not (r.tags and #r.tags > 0) then
    return col
  end
  local n_direct = r.n_direct_tags or #r.tags
  local tag_str = build_tag_str(r, n_direct)
  local agcfg = require("organ.buf_config").read(nil, "agenda") or {}
  local virt_align = (agcfg.tags_virt_align ~= false)
  local tags_cfg = (require("organ.buf_config").read(nil, "tags") or {})
  local faces = tags_cfg.faces or {}
  if virt_align then
    return append_tags_virt(marks, col, r, n_direct, tag_str, faces, agcfg)
  end
  return append_tags_inline(parts, marks, col, r, n_direct, tag_str, faces, agcfg, opts)
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
  local prefix_spec = resolve_row_prefix_spec(block_opts, opts)
  local parts, marks = {}, {}

  -- Prefix block (category + time + sched/dl tag) -- mirrors Emacs's
  -- `org-agenda-prefix-format`.
  local prefix_str = build_prefix(prefix_spec, r, opts)
  table.insert(parts, prefix_str)
  mark_prefix_substrings(marks, prefix_str, r)
  local col = #prefix_str

  col = append_todo(parts, marks, col, r, todo_width)
  col = append_priority(parts, marks, col, r)
  col = append_title(parts, marks, col, r)
  -- Effort estimate / clock budget.
  col = append_effort(parts, marks, col, r)
  col = append_tags(parts, marks, col, r, opts)

  -- Habit consistency graph (`..............` after the tag).  Off by
  -- default: Emacs's `org-habit` ships disabled in most distributions
  -- and the typical agenda view doesn't show graphs, so for parity
  -- we don't either.  Users who explicitly want them set
  -- `agenda.show_habit_graphs = true`.
  local show_graphs = (require("organ.buf_config").read(nil, "agenda") or {}).show_habit_graphs
    == true
  if show_graphs then
    append_habit_glyphs(parts, marks, col, r)
  end

  return table.concat(parts), marks
end

M.format_line = format_line
M.category_for = category_for
M.render_opts = render_opts
M.resolve_prefix_format = resolve_prefix_format
M.content_width = content_width
M.reset_caches = reset_caches

return M
