-- `agenda.todo_keyword_format` mirrors Emacs `org-agenda-todo-keyword-
-- format`: the TODO state token in each agenda row is passed through
-- `string.format(fmt, state)` before rendering.  Default `"%s"` is a
-- no-op.  Examples: `"%-7s"` right-pads keywords so `TODO` / `NEXT` /
-- `WAITING` all align across rows; `"[%s]"` wraps keywords in brackets.
--
-- Run via: nvim --headless -l tests/agenda_todo_keyword_format_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").config = require("organ").config or {}
require("organ").config.agenda = require("organ").config.agenda or {}
require("organ").config.agenda.tags_virt_align = false -- snapshot inline text

local SAMPLE = {
  {
    id = "h1",
    file_path = "/x.org",
    title = "Short",
    todo_state = "TODO",
    line_start = 1,
    level = 1,
    tags = {},
  },
  {
    id = "h2",
    file_path = "/x.org",
    title = "Long",
    todo_state = "WAITING",
    line_start = 2,
    level = 1,
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
  get_by_id = function()
    return nil
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "WAITING", "|", "DONE" } },
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

local function row_for(out, needle)
  for _, l in ipairs(out.lines) do
    if l:find(needle, 1, true) then
      return l
    end
  end
  return nil
end

-- (a) Default `"%s"` — no-op, behavior unchanged.
require("organ").config.agenda.todo_keyword_format = nil
local out_def = agenda.render(
  { { block = { kind = "todo" }, rows = SAMPLE } },
  { now = "2026-05-04" }
)
local short_def = row_for(out_def, "Short")
local long_def = row_for(out_def, "Long")
check(
  "default %s: TODO appears as-is",
  short_def and short_def:find(" TODO ", 1, true),
  short_def or "(missing)"
)
check(
  "default %s: WAITING appears as-is",
  long_def and long_def:find(" WAITING ", 1, true),
  long_def or "(missing)"
)

-- (b) `"%-7s"` — right-pad, both keywords occupy the same column.
require("organ").config.agenda.todo_keyword_format = "%-7s"
local out_pad = agenda.render(
  { { block = { kind = "todo" }, rows = SAMPLE } },
  { now = "2026-05-04" }
)
local short_pad = row_for(out_pad, "Short")
local long_pad = row_for(out_pad, "Long")
local short_title_col = short_pad and short_pad:find("Short", 1, true)
local long_title_col = long_pad and long_pad:find("Long", 1, true)
check(
  "'%-7s': both rows' titles begin at the same column",
  short_title_col == long_title_col,
  ("short=%s, long=%s"):format(tostring(short_title_col), tostring(long_title_col))
)
check(
  "'%-7s': TODO is followed by trailing spaces (pads to 7)",
  short_pad and short_pad:find("TODO   ", 1, true) ~= nil,
  short_pad or "(missing)"
)

-- (c) `"[%s]"` — bracket wrapping.
require("organ").config.agenda.todo_keyword_format = "[%s]"
local out_brk = agenda.render(
  { { block = { kind = "todo" }, rows = SAMPLE } },
  { now = "2026-05-04" }
)
local short_brk = row_for(out_brk, "Short")
check(
  "'[%s]': TODO wrapped in brackets",
  short_brk and short_brk:find("[TODO]", 1, true) ~= nil,
  short_brk or "(missing)"
)

-- Restore.
require("organ").config.agenda.todo_keyword_format = nil
require("organ").config.agenda.tags_virt_align = nil

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_todo_keyword_format_test: PASS")
