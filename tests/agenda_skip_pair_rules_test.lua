-- Two skip pair rules added on top of the existing skip_*_if_done:
--   * `skip_scheduled_if_deadline_shown` (Emacs `org-agenda-skip-
--     scheduled-if-deadline-is-shown`) — when a row has BOTH a
--     scheduled date AND a deadline (different days), suppress the
--     scheduled-day occurrence and only render on the deadline day.
--   * `skip_deadline_prewarning_if_scheduled` (Emacs `org-agenda-
--     skip-deadline-prewarning-if-scheduled`) — drop the deadline
--     early-warning row from today's bucket when the row is already
--     scheduled within the window (the scheduled-day occurrence
--     already surfaces the work).
--
-- Run via: nvim --headless -l tests/agenda_skip_pair_rules_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").config = require("organ").config or {}
require("organ").config.agenda = require("organ").config.agenda or {}
require("organ").config.agenda.tags_virt_align = false

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Common sample: one row with both sched + deadline (different days),
-- another with only-deadline 7 days from today (warning window).
local SAMPLE_DUAL = {
  {
    id = "h1",
    file_path = "/x.org",
    title = "Both-dated",
    todo_state = "TODO",
    line_start = 1,
    level = 1,
    tags = {},
    scheduled_date = "2026-05-04",
    deadline_date = "2026-05-08",
  },
}
local SAMPLE_DL_WARN = {
  {
    id = "h2",
    file_path = "/x.org",
    title = "Deadline-only",
    todo_state = "TODO",
    line_start = 2,
    level = 1,
    tags = {},
    deadline_date = "2026-05-11",
  },
  {
    id = "h3",
    file_path = "/x.org",
    title = "Sched-and-deadline",
    todo_state = "TODO",
    line_start = 3,
    level = 1,
    tags = {},
    scheduled_date = "2026-05-06",
    deadline_date = "2026-05-11",
  },
}

local function stub_query(rows)
  package.loaded["organ.query"] = {
    agenda = function()
      return rows
    end,
    headlines = function()
      return rows
    end,
    files = function()
      return {}
    end,
    links = function()
      return {}
    end,
    get_by_id = function()
      return nil
    end,
    parse_date = function(s)
      return s
    end,
  }
end

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "|", "DONE" } },
})

local agenda = require("organ.agenda")

local function count_in(out, needle)
  local n = 0
  for _, l in ipairs(out.lines) do
    if l:find(needle, 1, true) then
      n = n + 1
    end
  end
  return n
end

-- (a) skip_scheduled_if_deadline_shown
stub_query(SAMPLE_DUAL)

require("organ").config.agenda.skip_scheduled_if_deadline_shown = false
local out_dual_off = agenda.render({
  {
    block = {
      kind = "agenda",
      from = "2026-05-04",
      to = "2026-05-08",
      group_by = "day",
    },
    rows = SAMPLE_DUAL,
  },
}, { now = "2026-05-04" })
check(
  "skip_scheduled_if_deadline_shown=false: row appears on BOTH days",
  count_in(out_dual_off, "Both-dated") >= 2,
  "got " .. count_in(out_dual_off, "Both-dated") .. " occurrences"
)

require("organ").config.agenda.skip_scheduled_if_deadline_shown = true
local out_dual_on = agenda.render({
  {
    block = {
      kind = "agenda",
      from = "2026-05-04",
      to = "2026-05-08",
      group_by = "day",
    },
    rows = SAMPLE_DUAL,
  },
}, { now = "2026-05-04" })
check(
  "skip_scheduled_if_deadline_shown=true: only deadline-day occurrence remains",
  count_in(out_dual_on, "Both-dated") == 1,
  "got " .. count_in(out_dual_on, "Both-dated") .. " occurrences"
)
require("organ").config.agenda.skip_scheduled_if_deadline_shown = nil

-- (b) skip_deadline_prewarning_if_scheduled — defaults to true.  The
-- "Sched-and-deadline" row should NOT spawn an early-warning row on
-- today, because it's already on the agenda via its scheduled day.
-- The "Deadline-only" row SHOULD still get the warning row.
stub_query(SAMPLE_DL_WARN)

require("organ").config.agenda.skip_deadline_prewarning_if_scheduled = true
local out_pw_on = agenda.render({
  {
    block = {
      kind = "agenda",
      from = "2026-05-04",
      to = "2026-05-11",
      group_by = "day",
    },
    rows = SAMPLE_DL_WARN,
  },
}, { now = "2026-05-04" })
-- Today's bucket should contain "Deadline-only" with `In N d.:` label,
-- but NOT contain "Sched-and-deadline" with `In N d.:` (that one only
-- appears on its scheduled day + deadline day).
local function on_today(out, title, label)
  for _, l in ipairs(out.lines) do
    if l:find(title, 1, true) and l:find(label, 1, true) then
      return true
    end
  end
  return false
end
check(
  "skip_deadline_prewarning_if_scheduled=true: deadline-only row gets `In N d.:` warning",
  on_today(out_pw_on, "Deadline-only", "In")
)
check(
  "skip_deadline_prewarning_if_scheduled=true: scheduled+deadline row does NOT get warning",
  not on_today(out_pw_on, "Sched-and-deadline", "In")
)

require("organ").config.agenda.skip_deadline_prewarning_if_scheduled = false
local out_pw_off = agenda.render({
  {
    block = {
      kind = "agenda",
      from = "2026-05-04",
      to = "2026-05-11",
      group_by = "day",
    },
    rows = SAMPLE_DL_WARN,
  },
}, { now = "2026-05-04" })
check(
  "skip_deadline_prewarning_if_scheduled=false: scheduled+deadline row gets warning too",
  on_today(out_pw_off, "Sched-and-deadline", "In")
)
require("organ").config.agenda.skip_deadline_prewarning_if_scheduled = nil

require("organ").config.agenda.tags_virt_align = nil

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_skip_pair_rules_test: PASS")
