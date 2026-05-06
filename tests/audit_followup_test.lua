-- Regression coverage for the LOW/MED-priority audit items wired in
-- the parity-closing batch.  Each section asserts the WIRED behavior
-- (config → code path); items that ship as documented stubs only are
-- skipped here and tested separately when they're implemented.
--
-- Run via: nvim --headless -l tests/audit_followup_test.lua

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

-- ---------------------------------------------------------------------------
-- (1) agenda.time_leading_zero — affects the time_only formatter that
-- feeds the `%t` token in row prefixes.  Sample row uses 9:00 AM.
-- ---------------------------------------------------------------------------
require("organ").config = require("organ").config or {}
require("organ").config.agenda = require("organ").config.agenda or {}
require("organ").config.agenda.tags_virt_align = false -- snapshot inline text

local SAMPLE = {
  {
    id = "h1",
    file_path = "/x.org",
    title = "Standup",
    todo_state = "TODO",
    priority = "A",
    line_start = 1,
    level = 1,
    scheduled_date = "2026-05-04T09:00",
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
  parse_date = function(s)
    return s
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "|", "DONE" } },
})

local agenda = require("organ.agenda")

local function find(out, needle)
  for _, l in ipairs(out.lines) do
    if l:find(needle, 1, true) then
      return l
    end
  end
end

-- (1a) default: no leading zero ` 9:00`.
require("organ").config.agenda.time_leading_zero = false
local out_def = agenda.render({
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
local row_def = find(out_def, "Standup")
check(
  "time_leading_zero=false: ` 9:00` (compact, no leading zero)",
  row_def and row_def:find(" 9:00", 1, true) ~= nil,
  row_def or "(missing)"
)

-- (1b) on: `09:00`.
require("organ").config.agenda.time_leading_zero = true
local out_zero = agenda.render({
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
local row_zero = find(out_zero, "Standup")
check(
  "time_leading_zero=true: `09:00` (uniform 5-cell)",
  row_zero and row_zero:find("09:00", 1, true) ~= nil,
  row_zero or "(missing)"
)
require("organ").config.agenda.time_leading_zero = nil

-- ---------------------------------------------------------------------------
-- (2) agenda.category_icons — prepends an icon to the rendered
-- category column when matched.
-- ---------------------------------------------------------------------------
require("organ").config.agenda.category_icons = { x = "■ " }
local out_icon = agenda.render({
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
local row_icon = find(out_icon, "Standup")
check(
  "category_icons: prefix rendered before category",
  row_icon and row_icon:find("■ x", 1, true) ~= nil,
  row_icon or "(missing)"
)
require("organ").config.agenda.category_icons = nil

-- ---------------------------------------------------------------------------
-- (3) priority.start_cycle_with_default — first raise on cookie-less
-- headline jumps to `default` instead of `highest`.
-- ---------------------------------------------------------------------------
local inline_edit = require("organ.inline_edit")
require("organ").config.priority = require("organ").config.priority or {}
require("organ").config.priority.highest = "A"
require("organ").config.priority.lowest = "C"
require("organ").config.priority.default = "B"

require("organ").config.priority.start_cycle_with_default = false
local b1 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b1, 0, -1, false, { "* TODO No priority" })
inline_edit.raise_priority(b1, 1)
local line1 = vim.api.nvim_buf_get_lines(b1, 0, 1, false)[1]
check(
  "start_cycle_with_default=false: first raise → highest [#A]",
  line1:find("[#A]", 1, true) ~= nil,
  line1
)

require("organ").config.priority.start_cycle_with_default = true
local b2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "* TODO No priority" })
inline_edit.raise_priority(b2, 1)
local line2 = vim.api.nvim_buf_get_lines(b2, 0, 1, false)[1]
check(
  "start_cycle_with_default=true: first raise → default [#B]",
  line2:find("[#B]", 1, true) ~= nil,
  line2
)
require("organ").config.priority.start_cycle_with_default = nil

-- ---------------------------------------------------------------------------
-- (4) links.id_method — "ts" generator emits a timestamp-formatted ID.
-- ---------------------------------------------------------------------------
require("organ").config.links = require("organ").config.links or {}
require("organ").config.links.id_method = "ts"
local b3 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b3, 0, -1, false, { "* TODO Heading" })
local id_ts = require("organ.id").get_or_create(b3, 1)
check(
  "id_method='ts': matches YYYYMMDDTHHMMSS-NNN shape",
  type(id_ts) == "string" and id_ts:match("^%d%d%d%d%d%d%d%d[Tt]%d%d%d%d%d%d%-%d%d%d$") ~= nil,
  "got: " .. tostring(id_ts)
)

require("organ").config.links.id_method = function()
  return "custom-fixed-id"
end
local b4 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b4, 0, -1, false, { "* TODO Heading" })
local id_custom = require("organ.id").get_or_create(b4, 1)
check(
  "id_method=function: custom generator wins",
  id_custom == "custom-fixed-id",
  "got: " .. tostring(id_custom)
)
require("organ").config.links.id_method = nil

-- ---------------------------------------------------------------------------
-- (5) archive.save_context_info — restrict which ARCHIVE_* properties
-- get injected into the archived subtree's property drawer.
-- ---------------------------------------------------------------------------
require("organ").config.agenda.tags_virt_align = nil
require("organ").config.archive = require("organ").config.archive or {}
require("organ").config.archive.save_context_info = { "time", "olpath" }

-- We test the metadata WRITER directly (not the whole archive flow) by
-- inspecting the `archive.archive_subtree` output through a tmpfile.
local tmpsrc = os.tmpname() .. ".org"
local f = assert(io.open(tmpsrc, "w"))
f:write([[
* TODO Parent project
** TODO Child task
   :PROPERTIES:
   :ID: child-id-1
   :END:
]])
f:close()

require("organ").config.org_dir = vim.fn.fnamemodify(tmpsrc, ":h")
require("organ").config.archive.file_pattern = "%s_archive"

vim.cmd("edit " .. vim.fn.fnameescape(tmpsrc))
local bufnr = vim.api.nvim_get_current_buf()
local arc_err, arc_path = require("organ.archive").archive_subtree({ bufnr = bufnr, line = 2 }) -- "** TODO Child task"
check(
  "archive: archive_subtree succeeded",
  arc_err == nil and type(arc_path) == "string" and arc_path ~= "",
  "err: " .. tostring(arc_err)
)
if arc_path then
  local arc_lines = vim.fn.readfile(arc_path)
  local got_time, got_olpath, got_file, got_category, got_todo = false, false, false, false, false
  for _, l in ipairs(arc_lines) do
    if l:find(":ARCHIVE_TIME:") then
      got_time = true
    end
    if l:find(":ARCHIVE_OLPATH:") then
      got_olpath = true
    end
    if l:find(":ARCHIVE_FILE:") then
      got_file = true
    end
    if l:find(":ARCHIVE_CATEGORY:") then
      got_category = true
    end
    if l:find(":ARCHIVE_TODO:") then
      got_todo = true
    end
  end
  check("save_context_info={time,olpath}: ARCHIVE_TIME present", got_time)
  check("save_context_info={time,olpath}: ARCHIVE_OLPATH present", got_olpath)
  check("save_context_info={time,olpath}: ARCHIVE_FILE absent", not got_file)
  check("save_context_info={time,olpath}: ARCHIVE_CATEGORY absent", not got_category)
  check("save_context_info={time,olpath}: ARCHIVE_TODO absent", not got_todo)
  os.remove(arc_path)
end
os.remove(tmpsrc)
require("organ").config.archive.save_context_info = nil

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("audit_followup_test: PASS")
