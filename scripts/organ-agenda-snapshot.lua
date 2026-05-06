-- Render organ.nvim's agenda for a given org-dir + date and print the
-- buffer text. Used by the parity test to diff against Emacs's
-- org-agenda output captured via scripts/emacs-agenda-snapshot.el.
--
-- Usage:
--   nvim --headless -l scripts/organ-agenda-snapshot.lua <org-dir> <today-iso> <span>
--
-- where span is "day" or "week".

local org_dir = vim.v.argv[#vim.v.argv - 2] or arg[1]
local today_iso = vim.v.argv[#vim.v.argv - 1] or arg[2]
local span = vim.v.argv[#vim.v.argv] or arg[3]

-- Robust arg fallback (vim.v.argv has --headless / -l prefixed).
local args = arg or {}
org_dir = args[1] or org_dir
today_iso = args[2] or today_iso
span = args[3] or span

if not org_dir or not today_iso or not span then
  io.stderr:write("usage: organ-agenda-snapshot.lua <org-dir> <today-iso> <day|week>\n")
  os.exit(2)
end

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/tests/deps/tablature.nvim")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "WAIT", "PROJ", "|", "DONE", "CANCELLED" } },
  agenda = {
    -- Snapshots compare buffer text byte-for-byte; force tags into
    -- the buffer text so they show up in the diff, instead of the
    -- default virt_text right-align which the reader can't see.
    tags_virt_align = false,
    -- Keymap-hint footer is interactive UX, not part of the agenda
    -- proper.  Hide it so the snapshot just contains the rendered
    -- agenda lines (matches Emacs's plain buffer).
    footer = false,
    -- "← now" marker reads system clock, breaking snapshot
    -- determinism on a busy host.  Disable for the parity dump;
    -- interactive use keeps the default-on.
    now_marker = false,
    -- Pin "today" so the time grid + deadline countdown are
    -- reproducible across machines / dates.  The day after the
    -- visible window's start places today inside the rendered week
    -- (so the time grid is visible in the snapshot).
    now_override = today_iso .. "T12:00",
  },
})
require("organ").scan_blocking(org_dir, 5000)

-- Resolve the to-date.
local to_iso
if span == "day" then
  to_iso = today_iso
else
  local y, m, d = today_iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) + 6, hour = 12 })
  to_iso = os.date("%Y-%m-%d", t)
end

-- Drive the FULL agenda.open path so the overdue + repeater + sticky
-- + view-header logic in collect_block_rows / render_block all apply
-- exactly as they do in interactive use.
local agenda = require("organ.agenda")
local bufnr = agenda.open({
  from = today_iso,
  to = to_iso,
  types = { "scheduled", "deadline" },
  todo = { exclude = { "DONE", "CANCELLED" } },
  include_overdue = true,
  group_by = "day",
}, "snapshot")
-- Use io.write to keep the snapshot on stdout: in headless nvim,
-- `print` goes through vim.notify which lands on stderr.  Pipe
-- redirection at the call site assumes stdout, so go direct.
for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  io.write(l, "\n")
end
