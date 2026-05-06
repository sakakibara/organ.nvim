-- Unit tests for agenda.normalize_view — pure function returning (view, err).
-- Run via: nvim --headless -l tests/agenda_block_normalize_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local agenda = require("organ.agenda")

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

----------------------------------------------------------------------
-- Flat shape wraps as one labelless block.
do
  local v = {
    from = "today",
    to = "+7d",
    types = { "scheduled", "deadline" },
    group_by = "day",
    include_overdue = true,
    refresh_debounce_ms = 250,
  }
  local out, err = agenda.normalize_view(v, "default_view")
  assert(err == nil, "no error expected, got: " .. tostring(err))
  assert_eq(#out.blocks, 1, "one block")
  assert_eq(out.blocks[1].label, nil, "labelless block")
  assert_eq(out.blocks[1].from, "today")
  assert_eq(out.blocks[1].to, "+7d")
  assert_eq(out.blocks[1].group_by, "day")
  assert_eq(out.blocks[1].include_overdue, true)
  -- refresh_debounce_ms lifts to view level, not block level
  assert_eq(out.refresh_debounce_ms, 250)
  assert_eq(out.blocks[1].refresh_debounce_ms, nil)
end

----------------------------------------------------------------------
-- Block-list shape passes through.
do
  local v = {
    blocks = {
      { label = "Today", from = "today", to = "today" },
      { label = "Stuck", todo = "PROJECT", group_by = "none" },
    },
    refresh_debounce_ms = 100,
  }
  local out, err = agenda.normalize_view(v, "daily")
  assert(err == nil, "no error expected, got: " .. tostring(err))
  assert_eq(#out.blocks, 2)
  assert_eq(out.blocks[1].label, "Today")
  assert_eq(out.blocks[2].label, "Stuck")
  assert_eq(out.refresh_debounce_ms, 100)
end

----------------------------------------------------------------------
-- Mixed shape (top-level filter fields + blocks) errors.
do
  local v = { from = "today", blocks = { { label = "X" } } }
  local out, err = agenda.normalize_view(v, "bad")
  assert_eq(out, nil, "no view")
  assert(err and err:find("cannot mix"), "error mentions mix, got: " .. tostring(err))
  assert(err:find("'bad'"), "error names the view")
end

----------------------------------------------------------------------
-- Empty blocks list errors.
do
  local v = { blocks = {} }
  local out, err = agenda.normalize_view(v, "empty")
  assert_eq(out, nil)
  assert(err and err:find("blocks list is empty"), "error mentions empty, got: " .. tostring(err))
end

----------------------------------------------------------------------
-- Missing label errors with index.
do
  local v = { blocks = { { label = "OK" }, { from = "today" } } }
  local out, err = agenda.normalize_view(v, "missing")
  assert_eq(out, nil)
  assert(err and err:find("index 2"), "error names index 2, got: " .. tostring(err))
  assert(err:find("'label'"), "error names label, got: " .. tostring(err))
end

----------------------------------------------------------------------
-- Non-table input returns clean error (no exception).
do
  local out, err = agenda.normalize_view(nil, "nope")
  assert_eq(out, nil)
  assert(
    err and err:find("expected a table"),
    "error mentions expected-a-table, got: " .. tostring(err)
  )
  assert(err:find("'nope'"), "error names the view")
end

----------------------------------------------------------------------
-- Non-table 'blocks' field gets a distinct error from empty-list.
do
  local out, err = agenda.normalize_view({ blocks = "today" }, "stringblocks")
  assert_eq(out, nil)
  assert(
    err and err:find("'blocks' must be a table"),
    "error names the type problem, got: " .. tostring(err)
  )
  assert(err:find("got string"), "error names the actual type, got: " .. tostring(err))
end

----------------------------------------------------------------------
-- Block-list path does not alias the caller's tables (mutating the
-- normalized output must not leak back into the input).
do
  local v = { blocks = { { label = "X", line_format = nil } } }
  local out, err = agenda.normalize_view(v, "alias")
  assert(err == nil)
  out.blocks[1].line_format = function()
    return "mutated"
  end
  assert_eq(v.blocks[1].line_format, nil, "input table not mutated through normalized output")
end

io.write("agenda normalize_view ok\n")
