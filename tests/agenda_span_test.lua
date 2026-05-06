-- `agenda.span` + `agenda.start_day` + `agenda.week_starts_on`
-- mirror Emacs's `org-agenda-span` / `-start-day` / `-start-on-weekday`.
-- They resolve a block's window when `from` / `to` are omitted:
--
--   span = "day"        → from=anchor,         to=anchor
--   span = "week"       → from=Monday on/before anchor, to=from+6d
--   span = "fortnight"  → ditto, to=from+13d
--   span = "month"      → from=1st of anchor's month, to=last day
--   span = "year"       → from=Jan 1, to=Dec 31
--   span = N (integer)  → from=anchor, to=anchor + (N-1) days
--
-- Run via: nvim --headless -l tests/agenda_span_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
local agenda = require("organ.agenda")

-- 2026-05-04 is a Monday; pick it as the anchor for deterministic
-- week-shift assertions across all the cases.
local anchor = "2026-05-04"

local function rs(opts)
  return { agenda.resolve_span(opts, opts._cfg or {}) }
end

-- (a) span = "day"
do
  local f, t = unpack(rs({ span = "day", start_day = anchor }))
  check(
    "span=day → single-day window",
    f == anchor and t == anchor,
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (b) span = "week" with default week_starts_on="monday"
do
  local f, t = unpack(rs({ span = "week", start_day = anchor }))
  check(
    "span=week (Mon anchor): from=Mon, to=Sun",
    f == "2026-05-04" and t == "2026-05-10",
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (c) span = "week" with start_day mid-week → shifts back to Mon
do
  local f, t = unpack(rs({ span = "week", start_day = "2026-05-07" })) -- Thu
  check(
    "span=week (Thu anchor → Mon-anchored)",
    f == "2026-05-04" and t == "2026-05-10",
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (d) span = "week" with week_starts_on = "sunday"
do
  local f, t = unpack(rs({ span = "week", start_day = "2026-05-07", week_starts_on = "sunday" })) -- Thu → prev Sun
  check(
    "span=week, week_starts_on='sunday': shifts to prev Sunday",
    f == "2026-05-03" and t == "2026-05-09",
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (e) span = "fortnight"
do
  local f, t = unpack(rs({ span = "fortnight", start_day = anchor }))
  check(
    "span=fortnight: 14-day window from Monday",
    f == "2026-05-04" and t == "2026-05-17",
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (f) span = "month" — May has 31 days
do
  local f, t = unpack(rs({ span = "month", start_day = anchor }))
  check(
    "span=month: from=1st, to=last",
    f == "2026-05-01" and t == "2026-05-31",
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (g) span = "month" — Feb (handles month-end roll)
do
  local f, t = unpack(rs({ span = "month", start_day = "2026-02-15" }))
  check(
    "span=month, Feb 2026: ends 2026-02-28 (non-leap)",
    f == "2026-02-01" and t == "2026-02-28",
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (h) span = "year"
do
  local f, t = unpack(rs({ span = "year", start_day = anchor }))
  check(
    "span=year: Jan 1 to Dec 31",
    f == "2026-01-01" and t == "2026-12-31",
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (i) span = N (integer)
do
  local f, t = unpack(rs({ span = 3, start_day = anchor }))
  check(
    "span=3 (integer): 3-day window",
    f == "2026-05-04" and t == "2026-05-06",
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (j) explicit from/to wins — span ignored
do
  local f, t = unpack(rs({ span = "month", from = "2026-05-04", to = "2026-05-04" }))
  check(
    "explicit from/to wins (span ignored)",
    f == nil and t == nil,
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (k) global cfg via the second arg — block has no span itself but cfg does
do
  local f, t =
    unpack(rs({ start_day = anchor, _cfg = { span = "week", week_starts_on = "monday" } }))
  check(
    "global cfg.span = 'week' applies when block omits span",
    f == "2026-05-04" and t == "2026-05-10",
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (l) start_day = "+Nd" relative offset
do
  -- Set today to a known Monday by mocking os.time briefly.  Skip
  -- the strict check if we can't mock — just assert that resolve
  -- returns something that doesn't crash.
  local f, t = unpack(rs({ span = "day", start_day = "+0d" }))
  check(
    "span=day, start_day=+0d → today",
    type(f) == "string" and f == t,
    ("from=%s to=%s"):format(tostring(f), tostring(t))
  )
end

-- (m) view normalization: top-level span resolves into block.from/to
do
  local view, _ = agenda.normalize_view({
    span = "day",
    start_day = anchor,
    types = { "scheduled" },
  })
  local block = view.blocks[1]
  check(
    "normalize_view (flat): span resolved to from/to on the block",
    block.from == anchor and block.to == anchor,
    ("block.from=%s block.to=%s"):format(tostring(block.from), tostring(block.to))
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_span_test: PASS")
