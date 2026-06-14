-- View-spec normalization for the agenda: resolves `span`/`start_day`/
-- `week_starts_on` into absolute date windows, canonicalizes view tables
-- into the { blocks = ... } shape, and vets add-entry target paths.

local M = {}

local dates = require("organ.agenda.dates")

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

-- Exported for the week view, which anchors its window the same way.
M.resolve_week_anchor = resolve_week_anchor

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
      return dates.today_iso()
    end
    local sign, n = s:match("^([%+%-])(%d+)d$")
    if sign and n then
      local off = tonumber(n) * 86400 * (sign == "-" and -1 or 1)
      return os.date("%Y-%m-%d", dates.now_ts() + off)
    end
    if s:match("^%d%d%d%d%-%d%d%-%d%d") then
      return s:sub(1, 10)
    end
    return dates.today_iso()
  end
  local anchor = resolve_anchor(start_day)
  local anchor_ts = dates.iso_to_ts(anchor)
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
    -- Resolve span -> from/to for each block that asked for it.
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

return M
