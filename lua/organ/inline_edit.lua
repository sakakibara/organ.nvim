local M = {}

local obuf = require("organ.buf")
-- Match a timestamp: <YYYY-MM-DD( DOW)?( HH:MM(-HH:MM)?)?( REPEATER)?> or [...]
-- Returns { open = "<"|"[", close = ">"|"]", year, month, day, weekday?, hour?, minute?, end_hour?, end_min?, repeater? } or nil.
local TS_PATTERN = "([<%[])(%d%d%d%d)%-(%d%d)%-(%d%d)([^>%]]*)([>%]])"

local function parse_ts(text)
  local open, y, m, d, rest, close = text:match(TS_PATTERN)
  if not open then
    return nil
  end
  local out = {
    open = open,
    close = close,
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    rest = rest, -- " Sun 09:30 +1w" or similar
  }
  -- Parse rest: optional weekday, optional time, optional repeater.
  local r = rest
  local wd = r:match("^%s+(%a%a%a)%f[%A]")
  if wd then
    out.weekday = wd
    r = r:gsub("^%s+%a%a%a", "", 1)
  end
  local h, mn = r:match("^%s+(%d%d):(%d%d)")
  if h then
    out.hour = tonumber(h)
    out.minute = tonumber(mn)
    r = r:gsub("^%s+%d%d:%d%d", "", 1)
    local eh, em = r:match("^%-(%d%d):(%d%d)")
    if eh then
      out.end_hour = tonumber(eh)
      out.end_min = tonumber(em)
      r = r:gsub("^%-%d%d:%d%d", "", 1)
    end
  end
  if r:match("%S") then
    out.repeater = r:match("^%s*(.-)%s*$")
  end
  return out
end

-- Find the timestamp containing (line, col) (col is 0-based).
-- Returns { start_col, end_col, ts (parsed), text (raw substring) } or nil.
local function find_ts_at(line_text, col)
  local pos = 1
  while true do
    local s = line_text:find("[<%[]%d%d%d%d%-", pos)
    if not s then
      return nil
    end
    -- Find matching close bracket
    local open = line_text:sub(s, s)
    local close = open == "<" and ">" or "]"
    local e = line_text:find(close, s + 1, true)
    if not e then
      return nil
    end
    -- col is 0-based; s/e are 1-based inclusive.
    if col + 1 >= s and col + 1 <= e then
      local text = line_text:sub(s, e)
      local ts = parse_ts(text)
      if ts then
        return { start_col = s - 1, end_col = e, ts = ts, text = text }
      end
    end
    pos = e + 1
  end
end

-- Identify which sub-token contains col within the timestamp.
-- Returns one of "year", "month", "day", "hour", "minute", "end_hour",
-- "end_minute", or "day" as default.
local function sub_unit_at(line_text, range, col)
  local s = range.start_col + 1 -- 1-based start of '<'
  -- Layout: <YYYY-MM-DD ...
  -- Year: cols s+1 .. s+4 (1-based positions inside the bracket)
  -- - at s+5
  -- Month: s+6 .. s+7
  -- - at s+8
  -- Day: s+9 .. s+10
  local rel = col + 1 - s -- 0-based offset from open bracket
  if rel >= 1 and rel <= 4 then
    return "year"
  end
  if rel >= 6 and rel <= 7 then
    return "month"
  end
  if rel >= 9 and rel <= 10 then
    return "day"
  end
  -- Past the date portion: re-scan the actual text for hour/minute positions.
  local text = line_text:sub(s, range.end_col)
  -- Find weekday
  local wd_s, wd_e = text:find("%s%a%a%a%f[%A]", 11)
  if wd_s and rel >= wd_s - 1 and rel < wd_e then
    return "day"
  end
  -- Find time HH:MM
  local h_s = text:find("%s%d%d:", 11)
  if h_s then
    local hour_start = h_s -- skip leading space
    if rel >= hour_start and rel <= hour_start + 1 then
      return "hour"
    end
    if rel >= hour_start + 3 and rel <= hour_start + 4 then
      return "minute"
    end
    if text:match("^%-%d%d:%d%d", h_s + 6) then
      if rel >= hour_start + 6 and rel <= hour_start + 7 then
        return "end_hour"
      end
      if rel >= hour_start + 9 and rel <= hour_start + 10 then
        return "end_minute"
      end
    end
  end
  return "day" -- default for bracket / repeater / unknown positions
end

-- Days-in-month with leap-year handling.
local function days_in_month(y, m)
  if m == 2 then
    local leap = (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
    return leap and 29 or 28
  end
  if m == 4 or m == 6 or m == 9 or m == 11 then
    return 30
  end
  return 31
end

local function shift_days(ts, days)
  local t = os.time({ year = ts.year, month = ts.month, day = ts.day, hour = 12 })
  local nt = os.date("*t", t + days * 86400)
  ts.year, ts.month, ts.day = nt.year, nt.month, nt.day
end

-- The end of a time range wraps within the day (Emacs
-- `org-modify-ts-extra`).
local function shift_end(ts, minutes)
  local total = (ts.end_hour * 60 + (ts.end_min or 0) + minutes) % 1440
  ts.end_hour, ts.end_min = math.floor(total / 60), total % 60
end

local function shift_unit(ts, unit, dir)
  local d = dir == "inc" and 1 or -1
  if unit == "day" then
    shift_days(ts, d)
  elseif unit == "month" then
    ts.month = ts.month + d
    if ts.month > 12 then
      ts.month = 1
      ts.year = ts.year + 1
    end
    if ts.month < 1 then
      ts.month = 12
      ts.year = ts.year - 1
    end
    local maxd = days_in_month(ts.year, ts.month)
    if ts.day > maxd then
      ts.day = maxd
    end
  elseif unit == "year" then
    ts.year = ts.year + d
    local maxd = days_in_month(ts.year, ts.month)
    if ts.day > maxd then
      ts.day = maxd
    end
  elseif unit == "hour" or unit == "minute" then
    local minutes = d * (unit == "hour" and 60 or 1)
    local total = (ts.hour or 0) * 60 + (ts.minute or 0) + minutes
    local days = math.floor(total / 1440)
    total = total - days * 1440
    ts.hour, ts.minute = math.floor(total / 60), total % 60
    if days ~= 0 then
      shift_days(ts, days)
    end
    if ts.end_hour then
      shift_end(ts, minutes)
    end
  elseif unit == "end_hour" then
    shift_end(ts, d * 60)
  elseif unit == "end_minute" then
    shift_end(ts, d)
  end
  local t = os.time({ year = ts.year, month = ts.month, day = ts.day, hour = 12 })
  ts.weekday = os.date("%a", t)
end

local function format_ts(ts)
  local s = string.format("%s%04d-%02d-%02d", ts.open, ts.year, ts.month, ts.day)
  if ts.weekday then
    s = s .. " " .. ts.weekday
  end
  if ts.hour then
    s = s .. string.format(" %02d:%02d", ts.hour, ts.minute or 0)
    if ts.end_hour then
      s = s .. string.format("-%02d:%02d", ts.end_hour, ts.end_min or 0)
    end
  end
  if ts.repeater then
    s = s .. " " .. ts.repeater
  end
  s = s .. ts.close
  return s
end

local function _adjust_date(bufnr, lnum, range, direction)
  local unit = sub_unit_at(
    vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or "",
    range,
    vim.fn.col(".") - 1
  )
  shift_unit(range.ts, unit, direction)
  local new_text = format_ts(range.ts)
  obuf.set_text(bufnr, lnum - 1, range.start_col, lnum - 1, range.end_col, { new_text })
end

-- Find a priority cookie [#X] on a headline line, or detect cursor in title region.
-- Returns:
--   { has_cookie = true, start_col, end_col, letter = "A" }  if cursor on cookie
--   { has_cookie = false, insert_col = N }                    if cursor in headline title region
--   nil                                                       otherwise
local function find_priority_at(line_text, col)
  local stars = line_text:match("^(%*+) ")
  if not stars then
    return nil
  end
  local headline_start = #stars + 1 -- col of first non-star, 0-based
  if col < headline_start then
    return nil
  end

  -- Find existing cookie.
  local s, e = line_text:find("%[#[A-Z]%]")
  if s then
    -- Allow cursor anywhere from '[' through the space after ']' (inclusive).
    local match_end = e
    if line_text:sub(e + 1, e + 1) == " " then
      match_end = e + 1
    end
    if col + 1 >= s and col + 1 <= match_end then
      local letter = line_text:sub(s + 2, s + 2)
      return { has_cookie = true, start_col = s - 1, end_col = e, letter = letter }
    end
  end

  -- Cursor in title region (past any TODO keyword). If cursor is on the TODO
  -- keyword itself, return nil so the TODO branch can handle it.
  -- Find insertion point: after stars + space + (optional) TODO keyword + space.
  local todo_seq = (require("organ.buf_config").read(nil, "todo") or {}).sequence or {}
  local prefix_len = headline_start -- 0-based col of first body char (after "* ")
  local body = line_text:sub(headline_start + 1) -- text after "* " (1-based sub)
  local first = body:match("^(%S+)")
  for _, k in ipairs(todo_seq) do
    if k == first then
      -- Cursor is on the TODO keyword itself: let TODO branch handle it.
      local kw_start = headline_start -- 0-based col where keyword starts
      local kw_end = headline_start + #first -- exclusive
      if col >= kw_start and col < kw_end then
        return nil
      end
      prefix_len = headline_start + #first + 1 -- past stars, space, todo, space
      break
    end
  end
  return { has_cookie = false, insert_col = prefix_len }
end

-- Public: set the priority cookie on a headline line directly.
-- `letter` is "A"/"B"/"C" or nil to clear the cookie. Inserts a new
-- cookie if absent, replaces if present, removes (with trailing space)
-- when letter is nil and a cookie exists. No-op if `lnum` isn't a
-- headline.
function M.set_priority(bufnr, lnum, letter)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  if not line:match("^%*+ ") then
    return
  end
  local s, e = line:find("%[#[A-Z]%]")
  if s then
    if letter then
      obuf.set_text(bufnr, lnum - 1, s - 1, lnum - 1, e, { "[#" .. letter .. "]" })
    else
      local end_col = e
      if line:sub(e + 1, e + 1) == " " then
        end_col = e + 1
      end
      obuf.set_text(bufnr, lnum - 1, s - 1, lnum - 1, end_col, { "" })
    end
    return
  end
  if not letter then
    return
  end
  local stars = line:match("^(%*+)") or ""
  local insert_col = #stars + 1 -- byte after "* "
  local body = line:sub(insert_col + 1)
  local first = body:match("^(%S+)")
  local todo_seq = (require("organ.buf_config").read(nil, "todo") or {}).sequence or {}
  for _, k in ipairs(todo_seq) do
    if k == first then
      insert_col = insert_col + #first + 1
      break
    end
  end
  obuf.set_text(bufnr, lnum - 1, insert_col, lnum - 1, insert_col, { "[#" .. letter .. "] " })
end

-- Cycle: raise = A → A, B → A, C → B, none → A. Lower = A → B, B → C, C → none, none → C.
-- Resolve the configured priority range. Defaults to A..C / B (Emacs
-- defaults). Override via config.priority.{highest, lowest, default}.
-- Honors any single uppercase letter (or digit, as Emacs allows).
local function priority_range()
  local cfg = (require("organ.buf_config").read(nil, "priority") or {})
  return cfg.highest or "A", cfg.lowest or "C", cfg.default or "B"
end

-- Step the priority letter by `delta` (1 → next-higher = closer to
-- highest; -1 → next-lower = closer to lowest, then nil). Returns
-- the new letter or nil to clear.
local function step_priority(cur, delta)
  local hi, lo, def = priority_range()
  if not cur then
    -- No priority cookie.  By default, raise → highest, lower →
    -- lowest (mirrors Emacs's `org-priority-up` / `org-priority-down`
    -- terminal behavior).  When `priority.start_cycle_with_default
    -- = true` (Emacs `org-priority-start-cycle-with-default`), the
    -- first cycle adds the DEFAULT priority instead — useful when
    -- "raise" should mean "add a priority cookie" before pinning to
    -- highest.
    local cfg = (require("organ.buf_config").read(nil, "priority") or {})
    if cfg.start_cycle_with_default then
      return def
    end
    if delta > 0 then
      return hi
    end
    return lo
  end
  local cur_b = string.byte(cur)
  local hi_b, lo_b = string.byte(hi), string.byte(lo)
  -- "Higher priority" = letter closer to `highest` (which has the
  -- LOWER ASCII value when range is alphabetical A..C; matches Emacs).
  -- Compute direction: if hi_b < lo_b, raising decreases byte; vice versa.
  local raise_step = (hi_b < lo_b) and -1 or 1
  local next_b = cur_b + (delta > 0 and raise_step or -raise_step)
  -- Clamp / clear.
  if delta > 0 and ((hi_b < lo_b and next_b < hi_b) or (hi_b > lo_b and next_b > hi_b)) then
    return hi -- already at highest, stay
  end
  if delta < 0 and ((hi_b < lo_b and next_b > lo_b) or (hi_b > lo_b and next_b < lo_b)) then
    return nil -- past lowest → clear
  end
  return string.char(next_b)
end

function M.raise_priority(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local cur = line:match("%[#([A-Z])%]")
  local nxt = step_priority(cur, 1)
  if nxt == cur then
    return
  end -- already at highest, no change
  return M.set_priority(bufnr, lnum, nxt)
end

function M.lower_priority(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local cur = line:match("%[#([A-Z])%]")
  local nxt = step_priority(cur, -1)
  return M.set_priority(bufnr, lnum, nxt)
end

M._step_priority = step_priority
M._priority_range = priority_range

-- inc walks toward the lowest priority and then clears the cookie;
-- dec walks toward the highest and clears from there.
local function _cycle_priority(bufnr, lnum, range, direction)
  local hi, lo = priority_range()
  if range.has_cookie then
    local next_letter
    if direction == "inc" then
      next_letter = step_priority(range.letter, -1)
    elseif range.letter ~= hi then
      next_letter = step_priority(range.letter, 1)
    end
    M.set_priority(bufnr, lnum, next_letter)
  else
    local letter = direction == "inc" and hi or lo
    obuf.set_text(
      bufnr,
      lnum - 1,
      range.insert_col,
      lnum - 1,
      range.insert_col,
      { "[#" .. letter .. "] " }
    )
  end
end

function M.dispatch(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.fn.line(".")
  local col = vim.fn.col(".") - 1
  local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""

  -- 1. Date
  local date_range = find_ts_at(line_text, col)
  if date_range then
    return _adjust_date(bufnr, lnum, date_range, direction)
  end

  -- 2. Priority — only when the cursor is ON an existing `[#X]`
  -- cookie.  Title-region cursor (no cookie) falls through to TODO
  -- cycling so `<C-a>` on a heading without a priority advances the
  -- TODO state rather than silently inserting a `[#A]` ahead of the
  -- title.  Use `:Org set_property` (or a keymap that wraps
  -- inline_edit.set_priority) to insert a cookie deliberately.
  local prio_range = find_priority_at(line_text, col)
  if prio_range and prio_range.has_cookie then
    return _cycle_priority(bufnr, lnum, prio_range, direction)
  end

  -- 3. TODO cycling on a headline.  Cursor anywhere on the headline
  -- line counts (matches Emacs `S-Right` / `S-Left`); the narrow
  -- `detect_todo_at` check would only trigger on the TODO keyword
  -- itself, leaving title-region clicks with no action.
  if line_text:match("^%*+ ") then
    local todo = require("organ.todo")
    if direction == "inc" then
      return todo.cycle(bufnr, lnum)
    end
    return todo.cycle_back(bufnr, lnum)
  end

  -- 4. Fallback (in priority order):
  --   a. user-supplied callback (`fallback_increment` / `fallback_decrement`)
  --   b. dial.nvim's augend dispatcher if installed (so semantic
  --      types like booleans / weekdays / aliases work)
  --   c. Vim's native <C-a> / <C-x>
  local cfg = (require("organ.buf_config").read(nil, "inline_edit") or {})
  local fb = direction == "inc" and cfg.fallback_increment or cfg.fallback_decrement
  if type(fb) == "function" then
    return fb()
  end
  local has_dial, dial_map = pcall(require, "dial.map")
  if has_dial and cfg.use_dial ~= false then
    -- dial.map.inc_normal() / dec_normal() returns the key sequence
    -- to feed; it is not safe to splice into `:normal!`.  Feed it via
    -- nvim_feedkeys with the "n" remap-no flag so dial's <Cmd>...<CR>
    -- form runs.
    local keys = direction == "inc" and dial_map.inc_normal() or dial_map.dec_normal()
    if keys and keys ~= "" then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
    end
    return
  end
  local key = direction == "inc" and "<C-a>" or "<C-x>"
  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(key, true, false, true))
end

M.commands = {
  increment = {
    fn = function()
      M.dispatch("inc")
    end,
    desc = "Increment the number / TODO state / priority / date at cursor",
  },
  decrement = {
    fn = function()
      M.dispatch("dec")
    end,
    desc = "Decrement the number / TODO state / priority / date at cursor",
  },
}

return M
