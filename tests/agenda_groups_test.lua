-- agenda.groups: row partition within day-buckets (org-super-agenda
-- equivalent). Predicates AND within a group; first-match across
-- groups; auto "Other" catch-all unless suppressed.
--
-- Run via: nvim --headless -l tests/agenda_groups_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local SAMPLE = {
  {
    id = "h1",
    file_path = "/work.org",
    title = "Standup",
    line_start = 1,
    level = 1,
    todo_state = "TODO",
    priority = "B",
    scheduled_date = "2026-05-04T09:00",
    tags = { "work" },
  },
  {
    id = "h2",
    file_path = "/work.org",
    title = "Ship release",
    line_start = 2,
    level = 1,
    todo_state = "NEXT",
    priority = "A",
    scheduled_date = "2026-05-04",
    tags = { "work" },
  },
  {
    id = "h3",
    file_path = "/home.org",
    title = "Buy groceries",
    line_start = 3,
    level = 1,
    todo_state = "TODO",
    priority = "C",
    scheduled_date = "2026-05-04",
    tags = { "errand" },
  },
  {
    id = "h4",
    file_path = "/home.org",
    title = "Call dentist",
    line_start = 4,
    level = 1,
    todo_state = "TODO",
    scheduled_date = "2026-05-04",
    tags = { "phone" },
  },
}

package.loaded["organ.query"] = {
  agenda = function()
    return SAMPLE
  end,
  headlines = function()
    return SAMPLE
  end,
  files = function()
    return {}
  end,
  links = function()
    return {}
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
  agenda = { time_grid = false, now_marker = false, view_header = false },
})

local groups = require("organ.agenda.groups")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- 1. No groups → single anonymous bucket with all rows.
local p_none = groups.partition(SAMPLE, nil)
check(
  "no groups: single bucket, all rows",
  #p_none == 1 and #p_none[1].rows == 4 and p_none[1].title == nil
)

-- 2. Tag predicate (single string).
local p_tag = groups.partition(SAMPLE, {
  { title = "Work", tag = "work" },
})
check(
  "tag=work: 2 rows under Work",
  p_tag[1].title == "Work" and #p_tag[1].rows == 2,
  "got " .. #p_tag[1].rows .. " rows"
)
check(
  "tag=work: 'Other' catch-all has the rest",
  p_tag[2] and p_tag[2].title == "Other" and #p_tag[2].rows == 2
)

-- 3. Multiple groups; first-match wins.
local p_multi = groups.partition(SAMPLE, {
  { title = "High", priority = "A" },
  { title = "Errands", tag = "errand" },
  { title = "Work", tag = "work" },
})
check(
  "priority=A first → Ship release in High",
  p_multi[1].title == "High"
    and #p_multi[1].rows == 1
    and p_multi[1].rows[1].title == "Ship release"
)
check(
  "Errands gets the errand-tagged row only",
  p_multi[2].title == "Errands"
    and #p_multi[2].rows == 1
    and p_multi[2].rows[1].title == "Buy groceries"
)
check(
  "Work gets remaining work row (Standup), not Ship release (already taken)",
  p_multi[3].title == "Work" and #p_multi[3].rows == 1 and p_multi[3].rows[1].title == "Standup"
)
check("Other catches the phone-tagged row", p_multi[4].title == "Other" and #p_multi[4].rows == 1)

-- 4. AND within a group: tag=work AND has_time=true.
local p_and = groups.partition(SAMPLE, {
  { title = "Timed work", tag = "work", has_time = true },
})
check(
  "tag=work AND has_time: only Standup",
  #p_and[1].rows == 1 and p_and[1].rows[1].title == "Standup"
)

-- 5. todo predicate (list).
local p_todo = groups.partition(SAMPLE, {
  { title = "Active", todo = { "NEXT" } },
})
check(
  "todo=NEXT: only Ship release",
  #p_todo[1].rows == 1 and p_todo[1].rows[1].title == "Ship release"
)

-- 6. Custom pred function.
local p_pred = groups.partition(SAMPLE, {
  {
    title = "Home only",
    pred = function(r)
      return r.file_path == "/home.org"
    end,
  },
})
check("custom pred: 2 home.org rows", #p_pred[1].rows == 2)

-- 7. discard drops matching rows entirely (no group emitted).
local p_discard = groups.partition(SAMPLE, {
  { title = "drop phone", tag = "phone", discard = true },
})
-- After discard: catch-all gets the remaining 3 rows, no "drop phone" group.
check(
  "discard: matching group not in output",
  #p_discard == 1 and p_discard[1].title == "Other" and #p_discard[1].rows == 3
)

-- 8. Explicit catch-all (group with no predicates) suppresses auto-Other.
local p_explicit = groups.partition(SAMPLE, {
  { title = "Work", tag = "work" },
  { title = "Everything" }, -- no predicates → catch-all
})
check("explicit catch-all: no auto 'Other' appended", #p_explicit == 2)
check(
  "explicit catch-all: gets unmatched rows",
  p_explicit[2].title == "Everything" and #p_explicit[2].rows == 2
)

-- 9. catch_all_title = "" suppresses Other entirely.
local p_suppress = groups.partition(SAMPLE, {
  { title = "Work", tag = "work" },
}, { catch_all_title = "" })
check("catch_all_title='' suppresses Other", #p_suppress == 1 and p_suppress[1].title == "Work")

-- 10. category predicate.
local p_cat = groups.partition(SAMPLE, {
  { title = "From work.org", category = "work" },
}, {
  category_for = function(r)
    return r.file_path:match("/(%w+)%.org$")
  end,
})
check("category=work: 2 rows from work.org", #p_cat[1].rows == 2)

-- 11. has_deadline / has_scheduled.
local with_deadline = {
  {
    id = "d1",
    title = "DueX",
    scheduled_date = "2026-05-04",
    deadline_date = "2026-05-04",
    tags = {},
  },
  { id = "s1", title = "JustSched", scheduled_date = "2026-05-04", tags = {} },
}
local p_dl = groups.partition(with_deadline, {
  { title = "Has DL", has_deadline = true },
})
check(
  "has_deadline=true matches only the deadlined row",
  #p_dl[1].rows == 1 and p_dl[1].rows[1].title == "DueX"
)

-- 12. End-to-end: render() honours config.agenda.groups.
require("organ").config.agenda.groups = {
  { title = "Priority A", priority = "A" },
  { title = "Errands", tag = "errand" },
}
local agenda = require("organ.agenda")
local out = agenda.render({
  {
    block = {
      kind = "agenda",
      from = "2026-05-04",
      to = "2026-05-04",
      group_by = "day",
    },
    rows = SAMPLE,
  },
}, { now = "2026-05-04" })
local joined = table.concat(out.lines, "\n")
check(
  "render emits 'Priority A' group header",
  joined:find("Priority A %(1%)") ~= nil,
  "lines:\n" .. joined
)
check("render emits 'Errands' group header", joined:find("Errands %(1%)") ~= nil)
check("render emits 'Other' catch-all (Standup + Call dentist)", joined:find("Other %(2%)") ~= nil)

-- Group A line is BEFORE Errands line in render output (declared order).
local pa = joined:find("Priority A")
local er = joined:find("Errands")
check("declared group order preserved in render", pa and er and pa < er)

-- 13. Per-block override beats config.
require("organ").config.agenda.groups = nil
local out2 = agenda.render({
  {
    block = {
      kind = "agenda",
      from = "2026-05-04",
      to = "2026-05-04",
      group_by = "day",
      groups = { { title = "ALL_WORK", tag = "work" } },
    },
    rows = SAMPLE,
  },
}, { now = "2026-05-04" })
check(
  "per-block groups: 'ALL_WORK' header rendered",
  table.concat(out2.lines, "\n"):find("ALL_WORK %(2%)") ~= nil
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_groups_test: PASS")
