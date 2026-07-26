-- Entry-text mode (Emacs `org-agenda-entry-text-mode`).  When on,
-- each agenda item row gets up to `agenda.entry_text.max_lines` body
-- lines from its source headline appended underneath as indented
-- preview rows.  The `E` keymap toggles per-buffer; the
-- `agenda.entry_text.on_start` config decides the initial state.
--
-- Run via: nvim --headless -l tests/agenda_entry_text_test.lua

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

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

-- One scheduled task with a multi-line body so entry-text has
-- content to preview.
local f = io.open(org_dir .. "/tasks.org", "w")
f:write([==[
* TODO Buy groceries
SCHEDULED: <2026-05-04 Mon>
First body line.
Second body line.
Third body line.
Fourth body line.
Fifth body line.
Sixth body line.
]==])
f:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  agenda = {
    -- Snapshot-style flags so the buffer is deterministic.
    tags_virt_align = false,
    footer = false,
    now_marker = false,
    now_override = "2026-05-04T12:00",
    entry_text = { max_lines = 3, on_start = false },
  },
})
require("organ").scan_blocking(org_dir, 5000)

local agenda = require("organ.agenda")

-- (a) Default (on_start=false): no body preview rows in the buffer.
local bufnr = agenda.open({
  from = "2026-05-04",
  to = "2026-05-04",
  types = { "scheduled" },
  group_by = "day",
}, "et_test")

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local function find_line(needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return i, l
    end
  end
  return nil
end

check("agenda rendered with the scheduled task", find_line("Buy groceries") ~= nil)
check(
  "default: no preview body in the buffer",
  find_line("First body line") == nil,
  "found body preview when entry_text.on_start was false"
)

-- (b) Toggle via `E` keymap: max_lines body rows appear under the item.
vim.api.nvim_set_current_buf(bufnr)
for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
  if m.lhs == "E" and m.callback then
    m.callback()
    break
  end
end

lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check("after E: First body line appears", find_line("First body line") ~= nil)
check("after E: Second body line appears", find_line("Second body line") ~= nil)
check("after E: Third body line appears", find_line("Third body line") ~= nil)
check("after E: Fourth body line NOT shown (max_lines = 3)", find_line("Fourth body line") == nil)

-- (c) Toggle off again: previews disappear.
for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
  if m.lhs == "E" and m.callback then
    m.callback()
    break
  end
end

lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check("after E (toggle off): body preview gone", find_line("First body line") == nil)

-- (d) on_start = true: a freshly-opened agenda buffer renders with
--     previews already shown.
vim.api.nvim_buf_delete(bufnr, { force = true })
require("organ").config.agenda.entry_text.on_start = true
local b2 = agenda.open({
  from = "2026-05-04",
  to = "2026-05-04",
  types = { "scheduled" },
  group_by = "day",
}, "et_test_on")
local lines2 = vim.api.nvim_buf_get_lines(b2, 0, -1, false)
local found_first = false
for _, l in ipairs(lines2) do
  if l:find("First body line", 1, true) then
    found_first = true
    break
  end
end
check("on_start = true: previews shown on first open", found_first)

vim.api.nvim_buf_delete(b2, { force = true })
vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_entry_text_test: PASS")
