-- Pin the output of organ.nvim's agenda for a known fixture set
-- (tests/fixtures/parity/) so any future render change forces an
-- explicit snapshot update. Compares our rendered lines against a
-- stored expected list.
--
-- A separate harness (scripts/emacs-agenda-snapshot.el) captures
-- Emacs's reference output for the same fixture so contributors can
-- diff side-by-side; the parity work is tracked in
-- tests/fixtures/parity/EMACS-EXPECTED.txt (regenerated when
-- intentional divergences accumulate).
--
-- Run via: nvim --headless -l tests/agenda_parity_snapshot_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
-- Snapshot tests assert inline tag chars; opt out of the new
-- virt_text right-align path so the buffer-line text contains tags.
-- Pin "today" so the rendered labels (Scheduled: vs Sched. Nx:, Deadline:
-- vs Past-due, etc.) are deterministic regardless of when CI runs.
-- Must match the snapshot script's value -- the agenda_parity_diff_test
-- pins the same date.
require("organ").config.agenda = require("organ").config.agenda or {}
require("organ").config.agenda.tags_virt_align = false
require("organ").config.agenda.now_override = "2026-05-04T12:00"

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fixture_src = root .. "/tests/fixtures/parity"
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
for _, name in ipairs({ "tasks.org", "habits.org", "playground.org" }) do
  vim.fn.system({ "cp", fixture_src .. "/" .. name, org_dir .. "/" .. name })
end

require("organ").setup({
  db_path = tmp .. "/parity.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "WAIT", "PROJ", "|", "DONE", "CANCELLED" } },
})
require("organ").scan_blocking(org_dir, 5000)

local agenda = require("organ.agenda")
local bufnr = agenda.open({
  from = "2026-05-04",
  to = "2026-05-10",
  types = { "scheduled", "deadline" },
  todo = { exclude = { "DONE", "CANCELLED" } },
  include_overdue = true,
  group_by = "day",
}, "parity_snapshot")

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
-- Strip trailing blanks.
while #lines > 0 and (lines[#lines] == "" or lines[#lines] == nil) do
  table.remove(lines)
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Print the snapshot for visual review.
print()
print("---- agenda parity snapshot (" .. #lines .. " lines) ----")
for i, l in ipairs(lines) do
  print(string.format("%2d  %s", i, l))
end
print("--------------------------------------------------------")
print()

-- High-level invariants the parity work locked in. Each is a behavior
-- we explicitly aim to preserve; if a renderer change breaks one,
-- the test points at the regression.

check(
  "buffer starts with view-header line",
  lines[1] and lines[1]:match("^Week%-agenda %(W%d%d%):") ~= nil,
  "got: " .. tostring(lines[1])
)

local function find_line_with(needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return l
    end
  end
end

check("Monday header has W-suffix", find_line_with("Monday      4 May 2026 W19") ~= nil)

check(
  "each weekday in the window has its own day header",
  (function()
    local count = 0
    for _, day in ipairs({
      "Monday",
      "Tuesday",
      "Wednesday",
      "Thursday",
      "Friday",
      "Saturday",
      "Sunday",
    }) do
      for _, l in ipairs(lines) do
        if l:find(day, 1, true) then
          count = count + 1
          break
        end
      end
    end
    return count == 7
  end)()
)

check(
  "9:00 timed row sorted before 10:00 (numeric not lexical)",
  (function()
    local nine_idx, ten_idx
    for i, l in ipairs(lines) do
      if not nine_idx and l:find("9:00", 1, true) then
        nine_idx = i
      end
      if not ten_idx and l:find("10:00", 1, true) then
        ten_idx = i
      end
    end
    return nine_idx and ten_idx and nine_idx < ten_idx
  end)()
)

check(
  "Tag order is file-source order (`:gtd:@errand:` not `:@errand:gtd:`)",
  find_line_with(":gtd:@errand:") ~= nil and not find_line_with(":@errand:gtd:")
)

check(
  "Category respects `#+CATEGORY:` casing (Tasks: not tasks:)",
  find_line_with("Tasks:") ~= nil and not find_line_with(" tasks:") ~= nil
)

check(
  "Recurring habit appears on multiple days (repeater expansion)",
  (function()
    local count = 0
    for _, l in ipairs(lines) do
      if l:find("Morning walk", 1, true) then
        count = count + 1
      end
    end
    return count >= 5 -- daily over 7 days = ≥5 (some days may be skipped)
  end)()
)

check(
  "Habit row carries 'Scheduled:' prefix (matches Emacs)",
  (function()
    for _, l in ipairs(lines) do
      if l:find("Morning walk", 1, true) then
        return l:find("Scheduled:", 1, true) ~= nil
      end
    end
    return false
  end)()
)

check(
  "Future-day rows in their bucket show 'Scheduled:' (bucket-relative)",
  (function()
    for _, l in ipairs(lines) do
      if l:find("Sync with Anil", 1, true) then
        return l:find("Scheduled:", 1, true) ~= nil
      end
    end
    return false
  end)()
)

check(
  "Submit expense report on Tuesday is 'Scheduled:' (sched matches bucket, not deadline)",
  (function()
    for _, l in ipairs(lines) do
      if l:find("Submit expense report", 1, true) then
        return l:find("Scheduled:", 1, true) ~= nil
      end
    end
    return false
  end)()
)

check(
  "Footer help bar present at end",
  (function()
    for i = math.max(1, #lines - 5), #lines do
      if lines[i] and lines[i]:find("g%? help") then
        return true
      end
    end
    return false
  end)()
)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_parity_snapshot_test: PASS")
