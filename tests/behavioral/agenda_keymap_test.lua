-- Behavioral test: <Leader>oa opens an agenda buffer.
--
-- Loads organ + a real org fixture, fires the global <Leader>oa
-- binding programmatically, and asserts the visible result.
-- Catches the full keypress→keymap→user-command→dispatcher→
-- agenda-render chain — not just rhs string validity.
--
-- Run via: nvim --headless -l tests/behavioral/agenda_keymap_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
-- The :Org dispatcher and ftplugin filetype registration both come
-- from plugin/organ.lua. Source it explicitly because headless nvim
-- doesn't auto-source plugin/ files when started with -l.
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

-- Fixture: copy parity tasks.org into a temp org_dir so the indexer
-- has real headlines to render.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
vim.fn.system({ "cp", root .. "/tests/fixtures/parity/tasks.org", org_dir .. "/tasks.org" })

vim.g.mapleader = " "

-- Inject a dispatcher handler so the menu picks "Week agenda" without
-- waiting on getchar(). Lets us assert the post-dispatcher buffer
-- state synchronously. This is the same hook real users would use to
-- swap the menu UI for fzf / telescope.
local picked_entry
local function pick_entry(spec)
  for _, e in ipairs(spec.entries) do
    if e.key == "a" then
      picked_entry = e.label
      e.action()
      return
    end
  end
end

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "WAIT", "PROJ", "|", "DONE", "CANCELLED" } },
  agenda = { dispatcher_handler = pick_entry },
})
require("organ").scan_blocking(org_dir, 5000)

-- Step 1: the keymap is installed at setup time.
local maps = vim.api.nvim_get_keymap("n")
local oa
for _, m in ipairs(maps) do
  if m.lhs == " oa" then
    oa = m
    break
  end
end
check("`<Leader>oa` is registered", oa ~= nil, "no keymap with lhs ' oa'")
if oa then
  check(
    "`<Leader>oa` rhs targets the :Org dispatcher",
    oa.rhs and oa.rhs:find("<Cmd>Org agenda<CR>", 1, true) ~= nil,
    ("rhs = %q"):format(tostring(oa.rhs))
  )
end

-- Step 2: firing the keymap actually opens an agenda buffer.
local pre_bufs = {}
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  pre_bufs[b] = true
end

-- Use feedkeys with `x` flag = execute synchronously. This is the
-- closest we can get to a real `<Leader>oa` keypress in headless.
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(" oa", true, false, true), "x", false)
-- Agenda render is partly asynchronous (events.indexed listener +
-- debounce). Yield a few ticks for the buffer to populate.
vim.wait(500, function()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not pre_bufs[b] and vim.bo[b].filetype == "organ-agenda" then
      return vim.api.nvim_buf_line_count(b) > 1
    end
  end
  return false
end)

local agenda_buf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if not pre_bufs[b] and vim.bo[b].filetype == "organ-agenda" then
    agenda_buf = b
    break
  end
end
check("`<Leader>oa` produced an `organ-agenda` buffer", agenda_buf ~= nil)

if agenda_buf then
  local lines = vim.api.nvim_buf_get_lines(agenda_buf, 0, -1, false)
  check("agenda buffer is non-empty", #lines > 1, ("only %d lines"):format(#lines))
  -- The default agenda view begins with a "Week-agenda (W##):" or
  -- "Week-agenda (W##-W##):" header (the latter when the 7-day window
  -- straddles an ISO week boundary).
  check(
    "first line is the agenda view header",
    lines[1] and lines[1]:match("^Week%-agenda %(W%d%d") ~= nil,
    ("got: %q"):format(tostring(lines[1]))
  )
  -- One of the fixture's headlines should appear somewhere in the buffer.
  local found_dentist = false
  for _, l in ipairs(lines) do
    if l:find("Call dentist", 1, true) then
      found_dentist = true
      break
    end
  end
  check("fixture headline appears in rendered output", found_dentist)
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_keymap_test: PASS")
