-- agenda.skip_scheduled_if_done / skip_deadline_if_done — finer-grained
-- DONE filter than blanket todo.exclude. Mirrors Emacs `org-agenda-
-- skip-scheduled-if-done` and `_skip_deadline_if_done`.
-- Run via: nvim --headless -l tests/agenda_skip_done_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local SAMPLE = {
  -- Active scheduled: should always show.
  {
    id = "h1",
    file_path = "/x.org",
    title = "Active scheduled",
    line_start = 1,
    level = 1,
    todo_state = "TODO",
    scheduled_date = "2026-05-04",
    tags = {},
  },
  -- DONE scheduled (no deadline).
  {
    id = "h2",
    file_path = "/x.org",
    title = "Done scheduled",
    line_start = 2,
    level = 1,
    todo_state = "DONE",
    scheduled_date = "2026-05-04",
    tags = {},
  },
  -- DONE deadline (no scheduled).
  {
    id = "h3",
    file_path = "/x.org",
    title = "Done deadline",
    line_start = 3,
    level = 1,
    todo_state = "DONE",
    deadline_date = "2026-05-04",
    tags = {},
  },
  -- DONE with both — should NOT be skipped (rule only triggers
  -- when only the matching kind is present).
  {
    id = "h4",
    file_path = "/x.org",
    title = "Done both",
    line_start = 4,
    level = 1,
    todo_state = "DONE",
    scheduled_date = "2026-05-04",
    deadline_date = "2026-05-04",
    tags = {},
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
  todo = { sequence = { "TODO", "|", "DONE" } },
})

local agenda = require("organ.agenda")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function render()
  local b = agenda.open({
    from = "2026-05-04",
    to = "2026-05-04",
    types = { "scheduled", "deadline" },
    -- Note: NO todo.exclude — we want DONE rows reaching collect_block_rows
    -- so the new skip_*_if_done filter has something to filter.
    group_by = "day",
  }, "skip_test_" .. tostring(math.random(1, 1e9)))
  return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
end

-- Defaults: nothing skipped
require("organ").config.agenda.skip_scheduled_if_done = false
require("organ").config.agenda.skip_deadline_if_done = false
local body = render()
check("default: 'Active scheduled' present", body:find("Active scheduled", 1, true) ~= nil)
check("default: 'Done scheduled' present", body:find("Done scheduled", 1, true) ~= nil)
check("default: 'Done deadline' present", body:find("Done deadline", 1, true) ~= nil)
check("default: 'Done both' present", body:find("Done both", 1, true) ~= nil)

-- skip_scheduled_if_done = true
require("organ").config.agenda.skip_scheduled_if_done = true
require("organ").config.agenda.skip_deadline_if_done = false
body = render()
check("skip-sched: 'Active scheduled' present", body:find("Active scheduled", 1, true) ~= nil)
check("skip-sched: 'Done scheduled' SKIPPED", body:find("Done scheduled", 1, true) == nil)
check(
  "skip-sched: 'Done deadline' present (deadline-only)",
  body:find("Done deadline", 1, true) ~= nil
)
check(
  "skip-sched: 'Done both' present (rule only fires for sched-only)",
  body:find("Done both", 1, true) ~= nil
)

-- skip_deadline_if_done = true
require("organ").config.agenda.skip_scheduled_if_done = false
require("organ").config.agenda.skip_deadline_if_done = true
body = render()
check("skip-dead: 'Done deadline' SKIPPED", body:find("Done deadline", 1, true) == nil)
check("skip-dead: 'Done scheduled' present", body:find("Done scheduled", 1, true) ~= nil)

require("organ").config.agenda.skip_scheduled_if_done = false
require("organ").config.agenda.skip_deadline_if_done = false

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_skip_done_test: PASS")
