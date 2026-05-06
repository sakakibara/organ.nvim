-- Habit support — Emacs `org-habit`-compatible plus extensions.
--
-- Compatibility:
--   * `:STYLE: habit` property recognized.
--   * `.+P/Q` two-period repeater syntax parsed (P = repeat period, Q =
--     alarm period); see `lua/organ/todo/repeater.lua`.
--   * Completion history derived from LOGBOOK STATE→DONE entries.
--
-- Extensions over `org-habit`:
--   * Streak length, longest streak, completion rate.
--   * Status enum richer than glyph color: "done-today" / "due-today" /
--     "approaching" / "overdue" / "alarming" / "ahead".
--   * Heatmap data structure for calendar-grid renderers.
--
-- Public API (called from agenda renderer + queries):
--   M.is_habit(properties)               -> bool
--   M.parse_completions(logbook_text)    -> { "yyyy-mm-dd", ... } sorted
--   M.period_days(repeater_info)         -> number
--   M.status(info, today)                -> string
--   M.streak(completions, period_days)   -> number
--   M.glyph_row(info, today, days)       -> { {char, hl, date}, ... }

local M = {}

-- ─────────────────────────────────────────────────────────────────────
-- Property recognition
-- ─────────────────────────────────────────────────────────────────────

-- Properties may arrive case-folded ("STYLE") or as-typed; check both.
function M.is_habit(properties)
  if not properties then
    return false
  end
  local style = properties.STYLE or properties.Style or properties.style
  return style ~= nil and style:lower() == "habit"
end

-- ─────────────────────────────────────────────────────────────────────
-- Completion history
-- ─────────────────────────────────────────────────────────────────────

-- Extract State→DONE-(or any "done" keyword) date stamps from the text of
-- a LOGBOOK drawer.  Lines look like:
--   - State "DONE"      from "TODO"      [2026-04-25 Sat 14:30]
-- Returns an ascending-sorted list of YYYY-MM-DD strings.
local DONE_KEYWORDS = { DONE = true, CANCELLED = true }

function M.parse_completions(logbook_text, done_keywords)
  done_keywords = done_keywords or DONE_KEYWORDS
  if not logbook_text or logbook_text == "" then
    return {}
  end
  local seen, out = {}, {}
  for kw, date in
    logbook_text:gmatch('%-%s*State%s+"([%u_]+)"%s+from%s+"[%u_]+"%s*%[(%d%d%d%d%-%d%d%-%d%d)')
  do
    if done_keywords[kw] and not seen[date] then
      seen[date] = true
      out[#out + 1] = date
    end
  end
  table.sort(out)
  return out
end

-- ─────────────────────────────────────────────────────────────────────
-- Period math
-- ─────────────────────────────────────────────────────────────────────

local UNIT_DAYS = { d = 1, w = 7, m = 30, y = 365 }

-- Convert a repeater's value+unit to an integer number of days.
-- Months and years use approximations (30 / 365); habits care about
-- "is this day part of the streak", and exact month/year math doesn't
-- meaningfully change visualization.
function M.period_days(repeater_info)
  if not repeater_info then
    return 1
  end
  local n = repeater_info.value or 1
  local u = repeater_info.unit or "d"
  return n * (UNIT_DAYS[u] or 1)
end

function M.alarm_days(repeater_info)
  if not repeater_info or not repeater_info.deadline_value then
    return nil
  end
  local n = repeater_info.deadline_value
  local u = repeater_info.deadline_unit or "d"
  return n * (UNIT_DAYS[u] or 1)
end

-- ─────────────────────────────────────────────────────────────────────
-- Status / streak
-- ─────────────────────────────────────────────────────────────────────

local function to_time(date_str)
  local y, m, d = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = 12,
    min = 0,
    sec = 0,
  })
end

local function days_between(a, b)
  return math.floor((to_time(b) - to_time(a)) / 86400 + 0.5)
end

-- Current streak: count of consecutive completions ending at the latest,
-- where two are "consecutive" if their distance is <= `period_days`.  A
-- larger gap breaks the streak.  (For visualization the alarm window
-- still gives users grace — that's `glyph_row`'s job, not `streak`'s.)
function M.streak(completions, period_days)
  period_days = period_days or 1
  if #completions == 0 then
    return 0
  end
  local n = 1
  for i = #completions, 2, -1 do
    local d = days_between(completions[i - 1], completions[i])
    if d <= period_days then
      n = n + 1
    else
      break
    end
  end
  return n
end

-- Longest historical streak.
function M.longest_streak(completions, period_days)
  period_days = period_days or 1
  if #completions == 0 then
    return 0
  end
  local best, cur = 1, 1
  for i = 2, #completions do
    local d = days_between(completions[i - 1], completions[i])
    if d <= period_days then
      cur = cur + 1
      if cur > best then
        best = cur
      end
    else
      cur = 1
    end
  end
  return best
end

-- Status based on the next-due date and completion history.
--
-- info = {
--   scheduled_date  : "yyyy-mm-dd" or nil
--   period_days     : number
--   alarm_days      : number or nil
--   completions     : sorted list of "yyyy-mm-dd"
-- }
--
-- Returns one of:
--   "done-today"  Already completed today.
--   "ahead"       Next due is in the future; on track.
--   "due-today"   Next due is today.
--   "approaching" Past due but within alarm window (only when alarm_days set).
--   "overdue"     Past due (no alarm window) OR alarm window exceeded.
function M.status(info, today)
  today = today or os.date("%Y-%m-%d")
  local completions = info.completions or {}
  local last = completions[#completions]
  if last == today then
    return "done-today"
  end

  local sched = info.scheduled_date
  if not sched then
    -- No schedule — fall back to last_completion + period_days.
    if last then
      sched = M.add_days(last, info.period_days or 1)
    else
      return "due-today"
    end
  end

  local diff = days_between(sched, today) -- positive = past due
  if diff < 0 then
    return "ahead"
  end
  if diff == 0 then
    return "due-today"
  end
  if info.alarm_days and diff <= info.alarm_days then
    return "approaching"
  end
  if info.alarm_days and diff > info.alarm_days then
    return "overdue"
  end
  return "overdue" -- no alarm window, any past-due is overdue
end

function M.add_days(date_str, n)
  local t = to_time(date_str)
  if not t then
    return date_str
  end
  local nt = t + n * 86400
  return os.date("%Y-%m-%d", nt)
end

-- ─────────────────────────────────────────────────────────────────────
-- Glyph row (org-habit-style consistency graph)
-- ─────────────────────────────────────────────────────────────────────

-- Glyph characters and highlight groups.  Override per user config.
M.glyphs = {
  done_on_time = { char = "*", hl = "OrgHabitDone" },
  done_ahead = { char = "*", hl = "OrgHabitAhead" },
  done_late = { char = "!", hl = "OrgHabitLate" },
  miss_in_window = { char = ".", hl = "OrgHabitClear" },
  miss_overdue = { char = "X", hl = "OrgHabitOverdue" },
}

-- Compute a glyph row for the past `days` days ending today.  Each entry
-- in the returned list is { char, hl, date } describing one column of the
-- consistency graph.  Order: oldest → newest (today is rightmost).
function M.glyph_row(info, today, days)
  today = today or os.date("%Y-%m-%d")
  days = days or 14
  local completions_set = {}
  for _, c in ipairs(info.completions or {}) do
    completions_set[c] = true
  end
  local sched = info.scheduled_date
  local period = info.period_days or 1
  local alarm = info.alarm_days

  local out = {}
  for offset = days - 1, 0, -1 do
    local d = M.add_days(today, -offset)
    local entry
    if completions_set[d] then
      -- Was a completion expected on this day?  If `sched` is set, anything
      -- on or before the schedule's "current period" target is on-time.
      local diff = sched and days_between(sched, d) or 0
      if diff < 0 then
        entry = M.glyphs.done_ahead
      elseif diff == 0 then
        entry = M.glyphs.done_on_time
      else
        entry = M.glyphs.done_late
      end
    else
      -- No completion that day.  If beyond alarm window from any
      -- prior completion (or schedule), mark overdue; otherwise clear.
      local last_done = nil
      for _, c in ipairs(info.completions or {}) do
        if days_between(c, d) >= 0 then
          last_done = c
        end
      end
      local since
      if last_done then
        since = days_between(last_done, d)
      elseif sched then
        since = days_between(sched, d)
      else
        since = 0
      end
      if since > (alarm or period) then
        entry = M.glyphs.miss_overdue
      else
        entry = M.glyphs.miss_in_window
      end
    end
    out[#out + 1] = { char = entry.char, hl = entry.hl, date = d }
  end
  return out
end

-- ─────────────────────────────────────────────────────────────────────
-- Convenience: render a glyph row to a single-line string (no HL).
-- ─────────────────────────────────────────────────────────────────────

function M.render_glyph_row(info, today, days)
  local row = M.glyph_row(info, today, days)
  local chars = {}
  for _, e in ipairs(row) do
    chars[#chars + 1] = e.char
  end
  return table.concat(chars)
end

return M
