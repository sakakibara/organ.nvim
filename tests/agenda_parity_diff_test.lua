-- Byte-for-byte snapshot diff: organ.nvim's live agenda render against
-- the committed tests/fixtures/parity/ORGAN-EXPECTED.txt.
--
-- The fixture is regenerated via `make parity-organ` (or
-- `make parity-update` to refresh both organ + emacs side-by-side).
-- Any render change that affects the parity output must come with a
-- corresponding fixture update -- this test fails otherwise, with a
-- diff showing what changed.
--
-- The matching Emacs reference (EMACS-EXPECTED.txt) lives next to
-- this fixture; the diff between the two is documented divergence
-- (see `make parity` for the side-by-side view).  This test only
-- gates against drift on the organ side; it does NOT enforce
-- byte-equal Emacs parity (which we have NOT achieved yet).
--
-- Run via: nvim --headless -l tests/agenda_parity_diff_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

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
  agenda = {
    -- Match the snapshot script's settings exactly so the live render
    -- compares apples-to-apples against the committed fixture.
    tags_virt_align = false,
    footer = false,
    now_marker = false,
    -- Pin "today" so the time grid + deadline countdown are
    -- deterministic regardless of the wall clock.  Must match the
    -- snapshot script's value (`today_iso` it was invoked with).
    now_override = "2026-05-04T12:00",
  },
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
}, "parity_diff")

local got = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
-- Strip a single trailing empty line if present (matches the snapshot
-- script's `\n` per line + final newline behavior).
if #got > 0 and got[#got] == "" then
  table.remove(got)
end

local fixture_path = fixture_src .. "/ORGAN-EXPECTED.txt"
local f = io.open(fixture_path, "r")
if not f then
  print("FAIL  ORGAN-EXPECTED.txt not found at " .. fixture_path)
  print("      Run `make parity-organ` to generate it.")
  os.exit(1)
end
local want = {}
for line in f:lines() do
  want[#want + 1] = line
end
f:close()

local fails = 0
if #got ~= #want then
  fails = fails + 1
  print(string.format("FAIL  line count: got %d, want %d", #got, #want))
end

local first_diff
local max = math.max(#got, #want)
local diff_lines = 0
for i = 1, max do
  if got[i] ~= want[i] then
    diff_lines = diff_lines + 1
    if not first_diff then
      first_diff = i
    end
  end
end

if diff_lines > 0 then
  fails = fails + 1
  print(
    string.format(
      "FAIL  %d line(s) differ; first divergence at line %d",
      diff_lines,
      first_diff or 0
    )
  )
  print()
  print("=== expected (ORGAN-EXPECTED.txt) ===")
  for i = math.max(1, first_diff - 2), math.min(#want, first_diff + 4) do
    print(string.format("  %3d %s %s", i, want[i] and "|" or "*", want[i] or ""))
  end
  print()
  print("=== got (live render) ===")
  for i = math.max(1, first_diff - 2), math.min(#got, first_diff + 4) do
    print(string.format("  %3d %s %s", i, got[i] and "|" or "*", got[i] or ""))
  end
  print()
  print("To accept the new render as the baseline, run:")
  print("  make parity-organ   (regenerate ORGAN-EXPECTED.txt)")
  print("  git diff " .. fixture_path)
  print("  git add " .. fixture_path)
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  os.exit(1)
end
print(string.format("PASS  %d lines match ORGAN-EXPECTED.txt byte-for-byte", #got))
print("agenda_parity_diff_test: PASS")
