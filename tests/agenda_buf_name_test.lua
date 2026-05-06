-- Pure-function test for the agenda buffer-name formatter.  Bypasses
-- agenda.open() entirely so we don't pull in DB / indexer / render
-- code paths -- the helper only needs view + view_name.
--
-- Run via: nvim --headless -l tests/agenda_buf_name_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local agenda = require("organ.agenda")
local format = agenda._format_buf_name

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Today's date; resolve via the same path the helper does so this
-- test doesn't depend on system clock formatting.
local today_iso = os.date("%Y-%m-%d")
local today_year = os.date("%Y")
local today_ts = os.time()
local today_w = tonumber(os.date("%V", today_ts)) or 1
local plus6_ts = today_ts + 6 * 86400
local plus6_w = tonumber(os.date("%V", plus6_ts)) or 1

-- (a) Day view: literal date in name.
do
  local view = { blocks = { { label = "Day", from = "today", to = "today" } } }
  local got = format(view, "day")
  local want = "organ-agenda://Day " .. today_iso
  check("day view -> 'Day YYYY-MM-DD'", got == want, "got=" .. got .. " want=" .. want)
end

-- (b) Week view: ISO week number; "today..+6d" may span two weeks.
do
  local view = { blocks = { { label = "Week", from = "today", to = "+6d" } } }
  local got = format(view, "week")
  local want
  if plus6_w == today_w then
    want = string.format("organ-agenda://Week %s-W%02d", today_year, today_w)
  else
    want = string.format("organ-agenda://Week %s-W%02d-W%02d", today_year, today_w, plus6_w)
  end
  check("week view -> 'Week YYYY-Www[-Wxx]'", got == want, "got=" .. got .. " want=" .. want)
end

-- (c) Todos: fixed string.
do
  local view = { blocks = { { label = "Global TODOs", kind = "todo" } } }
  local got = format(view, "todos")
  check("todos view -> 'Todos'", got == "organ-agenda://Todos", "got=" .. got)
end

-- (d) Tag view: query embedded in name, including special chars.
do
  local view = { blocks = { { label = "Tag", kind = "tags", tag_match = "work&urgent" } } }
  local got = format(view, "tags:work&urgent")
  local want = "organ-agenda://Tag: work&urgent"
  check("tags:<q> -> 'Tag: <q>'", got == want, "got=" .. got)
end

-- (e) Search view: query embedded.
do
  local view = { blocks = { { label = "Search", kind = "search", title_match = "foo bar" } } }
  local got = format(view, "search:foo bar")
  local want = "organ-agenda://Search: foo bar"
  check("search:<q> -> 'Search: <q>'", got == want, "got=" .. got)
end

-- (f) Custom named view: prefix + raw name.
do
  local view = { blocks = { { label = "Custom", kind = "todo" } } }
  local got = format(view, "my-custom-view")
  local want = "organ-agenda://Agenda: my-custom-view"
  check("custom name -> 'Agenda: <name>'", got == want, "got=" .. got)
end

-- (g) No view_name: bare 'Agenda'.
do
  local view = { blocks = { { label = "Stuck", kind = "stuck" } } }
  local got = format(view, nil)
  check("nil view_name -> 'Agenda'", got == "organ-agenda://Agenda", "got=" .. got)
end

-- (h) "default" view_name (the sticky-key default) maps to bare 'Agenda'.
do
  local view = { blocks = { { label = "Stuck", kind = "stuck" } } }
  local got = format(view, "default")
  check("'default' view_name -> 'Agenda'", got == "organ-agenda://Agenda", "got=" .. got)
end

-- (i) Day view with no resolvable date should still produce a string,
-- not crash.  Unlikely in practice but guards the helper's nil paths.
do
  local view = { blocks = {} }
  local got = format(view, "day")
  check("day view with no blocks -> string", type(got) == "string", "got=" .. tostring(got))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_buf_name_test: PASS")
