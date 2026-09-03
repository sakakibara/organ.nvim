-- Emacs parity: date-repeater semantics on TODO -> DONE transitions.
--
-- Three repeater kinds (Emacs `org-auto-repeat-maybe'):
--   `+1w`   simple repeat: bump original date by interval ONCE
--   `++1w`  catch-up: bump until past `org-today'
--   `.+1w`  from completion: bump from today, ignoring original
--
-- When a TODO with a repeater is marked DONE:
--   * SCHEDULED / DEADLINE timestamp is bumped per the kind above
--   * State is reset to the FIRST active keyword (NOT left as DONE)
--   * `:LAST_REPEAT:` property is stamped
--   * No CLOSED line is inserted (the task didn't actually complete)
--
-- Both sides pin "today" to 2026-05-04 (Mon) so the case results are
-- byte-stable across runs.
--
-- Run via: nvim --headless -l tests/parity_org_repeater_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parity = dofile(root .. "/tests/_emacs_parity.lua")
parity.skip_if_no_emacs()

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = {
    log_done = false,
    log_state_changes = false,
    log_reschedule = false,
    log_redeadline = false,
    log_refile = false,
  },
})

-- Pin our "today" + LAST_REPEAT inactive-timestamp to match
-- emacs-op.el's pinned `organ-op--pinned-iso` (2026-05-04 noon).
require("organ.todo")._now_for_test = function()
  return "2026-05-04"
end
require("organ.todo")._now_ts_for_test = function()
  return "[2026-05-04 Mon 12:00]"
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function our_done(input)
  local stripped, cursor = parity.parse_cursor(input)
  local b = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(stripped, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, cursor)
  require("organ.todo").set(b, cursor[1], "DONE")
  local out_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.api.nvim_buf_delete(b, { force = true })
  return table.concat(out_lines, "\n") .. "\n"
end

local function fixture(scheduled)
  return ("#+TODO: TODO | DONE\n* TODO <CURSOR>Task\nSCHEDULED: <%s>\n"):format(scheduled)
end

local cases = {
  {
    label = "+1d simple repeater: bumps original by one interval",
    input = fixture("2026-05-01 Fri +1d"),
  },
  {
    label = "++1d catch-up: bumps until strictly after pinned today",
    input = fixture("2026-05-01 Fri ++1d"),
  },
  {
    label = ".+1d from-completion: bumps relative to pinned today",
    input = fixture("2026-05-01 Fri .+1d"),
  },
  {
    label = "+1w simple repeater on DEADLINE",
    input = ("#+TODO: TODO | DONE\n* TODO <CURSOR>Task\nDEADLINE: <%s>\n"):format(
      "2026-05-01 Fri +1w"
    ),
  },
  {
    label = "+1w repeater on the headline itself",
    input = "#+TODO: TODO | DONE\n* TODO <CURSOR>Meeting <2026-05-01 Fri +1w>\n  body\n",
  },
  {
    label = "+0d zero repeater: entry completes, timestamp untouched",
    input = fixture("2026-05-01 Fri +0d"),
  },
}

for _, c in ipairs(cases) do
  local emacs_out = parity.run("org-todo-done", c.input)
  local our_out = our_done(c.input)
  check(c.label, emacs_out == our_out, string.format("emacs=%q\n     ours= %q", emacs_out, our_out))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("parity_org_repeater_test: PASS")
