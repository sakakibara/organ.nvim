-- todo.log_reschedule / log_redeadline / log_refile insert LOGBOOK entries
-- on planning-change events.
-- Run via: nvim --headless -l tests/logbook_planning_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = {
    log_done = false,
    log_drawer = "LOGBOOK",
    log_reschedule = "time",
    log_redeadline = "time",
    log_refile = "time",
  },
})

local schedule = require("organ.schedule")
local logbook = require("organ.logbook")
local refile = require("organ.refile")

-- 1. Reschedule: change an existing SCHEDULED → log entry.
local fixture = org_dir .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write([[* TODO Heading
SCHEDULED: <2026-05-02 Sat>
  body
]])
fh:close()
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)

schedule._set_planning(b, 1, "SCHEDULED", "2026-05-09")
local joined = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
assert(joined:find(":LOGBOOK:", 1, true), "expected LOGBOOK drawer; got:\n" .. joined)
-- Emacs quotes the old stamp as an inactive timestamp and appends ` \\`
-- only when a note follows.
local resched_line
for _, ln in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
  if ln:find("Rescheduled", 1, true) then
    resched_line = ln
  end
end
assert(resched_line, "expected Rescheduled entry; got:\n" .. joined)
assert(
  resched_line:match('^%s*%- Rescheduled from "%[2026%-05%-02 Sat%]" on %[[^%]]+%]$'),
  "expected Emacs-shaped Rescheduled entry; got: " .. resched_line
)

-- 2. First-time SCHEDULED set on a headline with no prior planning → NO log.
local fixture2 = org_dir .. "/y.org"
fh = assert(io.open(fixture2, "w"))
fh:write("* TODO Fresh\n  body\n")
fh:close()
local b2 = vim.fn.bufadd(fixture2)
vim.fn.bufload(b2)
schedule._set_planning(b2, 1, "SCHEDULED", "2026-05-09")
local j2 = table.concat(vim.api.nvim_buf_get_lines(b2, 0, -1, false), "\n")
assert(not j2:find(":LOGBOOK:", 1, true), "first-time schedule should not log; got:\n" .. j2)

-- 3. Redeadline: change an existing DEADLINE → log "New deadline".
local fixture3 = org_dir .. "/z.org"
fh = assert(io.open(fixture3, "w"))
fh:write([[* TODO Heading
DEADLINE: <2026-05-15 Fri>
  body
]])
fh:close()
local b3 = vim.fn.bufadd(fixture3)
vim.fn.bufload(b3)
schedule._set_planning(b3, 1, "DEADLINE", "2026-05-22")
local j3 = table.concat(vim.api.nvim_buf_get_lines(b3, 0, -1, false), "\n")
assert(
  j3:find('New deadline from "[2026-05-15 Fri]"', 1, true),
  "expected New deadline entry; got:\n" .. j3
)

-- 4. Refile: move a subtree to a different file → "Refiled" log entry on
-- the new headline.
local source = org_dir .. "/src.org"
local target = org_dir .. "/dst.org"
fh = assert(io.open(source, "w"))
fh:write([[* TODO Source
  body
]])
fh:close()
fh = assert(io.open(target, "w"))
fh:write("* Destination\n")
fh:close()
local sb = vim.fn.bufadd(source)
vim.fn.bufload(sb)
local tb = vim.fn.bufadd(target)
vim.fn.bufload(tb)
local err = refile.move(sb, 1, target, 1)
assert(err == nil, "refile.move failed: " .. tostring(err))

local jt = table.concat(vim.api.nvim_buf_get_lines(tb, 0, -1, false), "\n")
assert(jt:find(":LOGBOOK:", 1, true), "expected LOGBOOK drawer on refiled subtree; got:\n" .. jt)
assert(jt:find("- Refiled on", 1, true), "expected '- Refiled on' line; got:\n" .. jt)

-- 5. logbook.build_planning_entry shape.
do
  local entry = logbook.build_planning_entry("Rescheduled", "<2026-05-02>", nil)
  assert(#entry == 1, "no-note: 1 line")
  assert(
    entry[1]:match('^%- Rescheduled from "%[2026%-05%-02%]" on %[[^%]]+%]$'),
    "shape: " .. entry[1]
  )
  local bare = logbook.build_planning_entry("Refiled", nil, nil)
  assert(bare[1]:match("^%- Refiled on %[[^%]]+%]$"), "no-note bare shape: " .. bare[1])
  local note_entry = logbook.build_planning_entry("Refiled", nil, "needed cleanup")
  assert(#note_entry == 2, "with note: 2 lines")
  assert(note_entry[1]:match("^%- Refiled on %[[^%]]+%] \\\\$"), "note marker: " .. note_entry[1])
  assert(note_entry[2] == "  needed cleanup", "note line: " .. note_entry[2])
end

vim.fn.delete(tmp, "rf")
io.write("logbook planning ok\n")
os.exit(0)
