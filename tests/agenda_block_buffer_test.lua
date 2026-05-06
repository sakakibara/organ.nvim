-- tests/agenda_block_buffer_test.lua
-- Run via: nvim --headless -l tests/agenda_block_buffer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({}) -- minimal config

local agenda = require("organ.agenda")
local query = require("organ.query")

-- Stub query.agenda so we can count calls and feed deterministic rows.
local calls = 0
local orig = query.agenda
query.agenda = function(opts)
  calls = calls + 1
  return {
    {
      id = "row" .. calls,
      title = "T" .. calls,
      todo_state = "TODO",
      priority = "A",
      scheduled_date = "2026-04-26",
      tags = {},
      file_path = "/x.org",
      line_start = calls,
      level = 1,
    },
  }
end

local bufnr = agenda.open({
  blocks = {
    { label = "First", from = "today", to = "today", group_by = "none" },
    { label = "Second", from = "+1d", to = "+7d", group_by = "none" },
  },
})

query.agenda = orig

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- 2 blocks × 2 queries each (in-window + overdue carryover for
-- `show_overdue_scheduled = true` default).
assert_eq(calls, 4, "two queries per block")

-- Normalized view stored.
local stored = vim.b[bufnr].organ_agenda.view
assert(stored and stored.blocks and #stored.blocks == 2, "normalized view has 2 blocks")

-- block_starts populated.  Read via agenda.buf_state so the encode/decode
-- round-trip through vim.b is exercised and integer keys are restored.
local starts = agenda.buf_state(bufnr).block_starts
assert(starts, "block_starts present")
local count = 0
for _ in pairs(starts) do
  count = count + 1
end
assert_eq(count, 2, "two block_starts entries")

-- block_starts uses integer keys (spec contract: { [lnum] = block_index })
-- Confirm the keys are integers, not stringified, after vim.b round-trip.
for k in pairs(starts) do
  assert(type(k) == "number", "block_starts key must be integer, got " .. type(k))
end
-- And exercise the > comparison that Task 5's ]] keymap will use.
local lnum = 1
for k in pairs(starts) do
  assert(k > lnum or k < lnum or k == lnum, "comparable to integer (no string error)")
end

-- Both block-header lines visible in the buffer.
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local found_first, found_second = false, false
for _, l in ipairs(lines) do
  if l:find("══ First") then
    found_first = true
  end
  if l:find("══ Second") then
    found_second = true
  end
end
assert(found_first and found_second, "both block headers rendered")

-- foldmethod is expr on the window showing this buffer.
local winid = vim.api.nvim_get_current_win()
assert_eq(vim.api.nvim_get_option_value("foldmethod", { win = winid }), "expr")
assert(
  vim.api.nvim_get_option_value("foldexpr", { win = winid }):find("organ.agenda"),
  "foldexpr references organ.agenda"
)

vim.api.nvim_buf_delete(bufnr, { force = true })
io.write("agenda block buffer ok\n")
