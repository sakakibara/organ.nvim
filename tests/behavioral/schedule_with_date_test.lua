-- Behavioral test: scheduling a TODO via the calendar picker.
--
-- Opens a real org file, places the cursor on a TODO headline, fires
-- :Org schedule (the user-command form of `<Leader>os`), accepts the
-- default (today) in the calendar with `<CR>`, and asserts a SCHEDULED
-- planning line was inserted below the headline.  Exercises:
--   :Org schedule -> organ.schedule.commands.schedule
--   organ.schedule.set_schedule (find headline, open calendar)
--   organ.calendar.pick (calendar UI lifecycle)
--   <CR> keymap on calendar buf -> _close_and_callback
--   organ.schedule._set_planning (planning line insert)
--
-- Run via: nvim --headless -l tests/behavioral/schedule_with_date_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/inbox.org"
vim.fn.writefile({
  "#+TITLE: Inbox",
  "",
  "* TODO Plan release",
  "* DONE Older",
}, fixture)

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

vim.cmd("filetype plugin on")
vim.cmd("edit " .. fixture)
local org_buf = vim.api.nvim_get_current_buf()

-- Wait for ftplugin to attach -- structure module needs the parser ready.
vim.wait(500, function()
  return vim.bo[org_buf].filetype == "org"
end)

-- Cursor on the TODO line (line 3).
vim.api.nvim_win_set_cursor(0, { 3, 0 })

-- Pre-state: no SCHEDULED line on or after the TODO.
local function find_sched_line()
  local lines = vim.api.nvim_buf_get_lines(org_buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:match("SCHEDULED:%s*<") then
      return i, l
    end
  end
  return nil, nil
end
do
  local i = find_sched_line()
  check("pre-state: no SCHEDULED line", i == nil)
end

-- Fire the schedule command via the :Org dispatcher.  set_schedule
-- opens the calendar float synchronously and registers a callback on
-- <CR>.
vim.cmd("Org schedule")

-- Find the calendar buffer.
local function find_cal_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].organ_calendar then
      return b
    end
  end
  return nil
end
local cal_buf = find_cal_buf()
check("calendar float opened", cal_buf ~= nil)

-- Accept the default selection (today) by sending <CR>.  The calendar
-- buffer is already focused; "x" mode flag drains the keymap callback
-- before we proceed.
local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
vim.api.nvim_feedkeys(cr, "x", false)

-- Calendar should be closed.
check("calendar float closed after <CR>", find_cal_buf() == nil)

-- SCHEDULED line should now exist on line 4 (right after the TODO),
-- containing today's date in active-timestamp form.
do
  local i, l = find_sched_line()
  check(
    "SCHEDULED line inserted",
    i ~= nil,
    "lines: " .. table.concat(vim.api.nvim_buf_get_lines(org_buf, 0, -1, false), "|")
  )
  if i and l then
    local today = os.date("%Y-%m-%d")
    check("SCHEDULED line contains today's date", l:find(today, 1, true) ~= nil, "got: " .. l)
    check("SCHEDULED line directly follows the TODO (line 4)", i == 4, "got line " .. tostring(i))
  end
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("schedule_with_date_test: PASS")
