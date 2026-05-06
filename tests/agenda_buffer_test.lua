-- Agenda buffer: open, refresh, filetype, event-driven re-render.
-- Run via: nvim --headless -l tests/agenda_buffer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db_path = tmp .. "/a.db"
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
for _, name in ipairs({ "02-planning.org", "04-dates.org" }) do
  vim.fn.system({ "cp", root .. "/tests/fixtures/" .. name, org_dir .. "/" .. name })
end

require("organ").setup({
  db_path = db_path,
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  agenda = { refresh_debounce_ms = 30 },
})
require("organ").scan_blocking(org_dir, 5000)

local agenda = require("organ.agenda")
local events = require("organ.events")

-- open with a wide window that includes the fixture dates.
local bufnr = agenda.open({
  from = "2026-04-01",
  to = "2026-06-01",
  types = { "scheduled", "deadline" },
  group_by = "day",
  include_overdue = true,
  now = "2026-04-23",
})
assert(type(bufnr) == "number" and bufnr > 0)

-- filetype set
assert(vim.bo[bufnr].filetype == "organ-agenda", "filetype=" .. tostring(vim.bo[bufnr].filetype))
assert(vim.bo[bufnr].buftype == "nofile")
assert(vim.bo[bufnr].modifiable == false)

-- lines rendered
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
assert(#lines > 0, "agenda buffer empty")
local joined = table.concat(lines, "\n")
-- Date header now mirrors Emacs: "Saturday    25 April 2026" (full
-- weekday + month name, no leading zero).
assert(
  joined:find("25 April 2026", 1, true) or joined:find("2026-04-25", 1, true),
  "expected 25 April 2026 header:\n" .. joined
)

-- Simulate an "indexed" event for a file in the org_dir → buffer re-renders.
local before = vim.api.nvim_buf_line_count(bufnr)
events.emit("indexed", { path = org_dir .. "/04-dates.org", n_headlines = 99 })
vim.wait(200, function()
  return false
end) -- let debounce timer fire
local after = vim.api.nvim_buf_line_count(bufnr)
assert(after > 0, "buffer empty after refresh")

-- Skipped event should NOT trigger a refresh. We detect by patching render:
local patched = 0
local orig_render = agenda.render
agenda.render = function(...)
  patched = patched + 1
  return orig_render(...)
end
events.emit("indexed", { path = org_dir .. "/04-dates.org", skipped = "mtime" })
vim.wait(100, function()
  return false
end)
assert(patched == 0, "skipped event should not trigger render")
agenda.render = orig_render

-- Explicit refresh
agenda.refresh(bufnr)
local after2 = vim.api.nvim_buf_line_count(bufnr)
assert(after2 > 0)

-- Close the buffer → listener unsubscribes.
vim.api.nvim_buf_delete(bufnr, { force = true })
----------------------------------------------------------------------
-- title_match filter preserves agenda's multi-type OR semantics
-- (i.e. rows with scheduled-but-no-deadline are still included).
do
  -- Reopen with a clean window covering the planning fixture.
  local bufnr2 = agenda.open({
    from = "2026-04-01",
    to = "2026-06-01",
    types = { "scheduled", "deadline" },
    group_by = "none",
    include_overdue = false,
    now = "2026-04-23",
  })

  -- Baseline: how many item lines do we get before filtering?
  local baseline_items = 0
  local state = vim.b[bufnr2].organ_agenda
  for lnum, r in pairs(state.line_index or {}) do
    if r then
      baseline_items = baseline_items + 1
    end
  end
  assert(baseline_items > 0, "baseline agenda should have items")

  -- Apply a title_match that matches some of the planning fixture's headlines
  -- (one of them contains the substring "Combined").
  state.view.blocks[1].title_match = "Combined"
  vim.b[bufnr2].organ_agenda = state
  agenda.refresh(bufnr2)

  local filtered_items = 0
  state = vim.b[bufnr2].organ_agenda
  for lnum, r in pairs(state.line_index or {}) do
    if r then
      filtered_items = filtered_items + 1
      assert(
        r.title:lower():find("combined", 1, true),
        "filtered row does not match title_match: " .. r.title
      )
    end
  end
  assert(filtered_items > 0, "title_match should match at least one row")
  assert(filtered_items <= baseline_items, "filtered should not exceed baseline")

  vim.api.nvim_buf_delete(bufnr2, { force = true })
end

vim.fn.delete(tmp, "rf")
io.write("agenda buffer ok\n")
os.exit(0)
