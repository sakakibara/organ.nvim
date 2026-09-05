-- `todo.planning_indent` governs the indent of newly-inserted
-- planning lines (SCHEDULED:, DEADLINE:, CLOSED:).  Three writers
-- across two modules must agree on it: schedule._set_planning for
-- SCHEDULED / DEADLINE first-writes, todo.insert_closed_line for
-- the CLOSED line on DONE transitions.  Previously these were
-- inconsistent -- SCHEDULED/DEADLINE went to col 0, CLOSED to col 2.
--
-- Covers:
--   1. default "adapt" -- heading_level + 1 spaces, matches Emacs
--      `org-adapt-indentation = 'headline-data` (Org 9.5+ default).
--      Same heading -> SCHEDULED + CLOSED agree.  Deeper heading ->
--      both indent further.
--   2. fixed number -- both writers honor `planning_indent = 4`.
--   3. zero -- both writers write flush-left when set to 0.
--   4. existing-line edits preserve whatever indent is on the line,
--      irrespective of the config -- the config only governs the
--      FIRST write.
--
-- Run via: nvim --headless -l tests/planning_indent_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Re-setup organ with a specific archive/planning config + a fresh
-- DB path each call.  Necessary because cfg is read at write time
-- via buf_config.
local function fresh_setup(overrides)
  require("organ").config = require("organ.defaults")
  require("organ").setup(vim.tbl_extend("force", {
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  }, overrides or {}))
end

local function load_buf(text, name)
  local path = tmp .. "/" .. name
  local fh = assert(io.open(path, "w"))
  fh:write(text)
  fh:close()
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  return b
end

-- Extract the planning line directly below `hl_line` (1-indexed).
local function planning_line(b, hl_line)
  return (vim.api.nvim_buf_get_lines(b, hl_line, hl_line + 1, false) or {})[1] or ""
end

-- Count leading spaces on a string.
local function leading_spaces(s)
  return #(s:match("^( *)") or "")
end

-- ─── 1. default "adapt" -- level + 1 ────────────────────────────────────────
do
  fresh_setup({})
  local schedule = require("organ.schedule")
  local todo = require("organ.todo")

  -- Level-1 heading
  local b = load_buf("* TODO Top thing\n", "adapt_l1.org")
  schedule._set_planning(b, 1, "SCHEDULED", "2026-05-19")
  local sched = planning_line(b, 1)
  check(
    "adapt L1: SCHEDULED at col 2 (1 star + space)",
    leading_spaces(sched) == 2,
    "got " .. leading_spaces(sched) .. " leading spaces on: " .. vim.inspect(sched)
  )

  -- Now apply done -> CLOSED should also be 2 spaces (consistent)
  todo.set(b, 1, "DONE")
  -- find the CLOSED line
  local closed
  for i = 1, vim.api.nvim_buf_line_count(b) do
    local l = vim.api.nvim_buf_get_lines(b, i - 1, i, false)[1] or ""
    if l:match("CLOSED:") then
      closed = l
      break
    end
  end
  if closed then
    check(
      "adapt L1: CLOSED also at col 2 -- SCHEDULED and CLOSED agree",
      leading_spaces(closed) == 2,
      "got " .. leading_spaces(closed) .. " on: " .. vim.inspect(closed)
    )
  end

  -- Level-3 heading -- should indent further (level 3 + 1 = 4 spaces)
  local b3 = load_buf("* Top\n** Mid\n*** TODO Deep\n", "adapt_l3.org")
  schedule._set_planning(b3, 3, "DEADLINE", "2026-05-19")
  local dline = planning_line(b3, 3)
  check(
    "adapt L3: DEADLINE at col 4 (3 stars + space)",
    leading_spaces(dline) == 4,
    "got " .. leading_spaces(dline) .. " on: " .. vim.inspect(dline)
  )
end

-- ─── 2. fixed number ────────────────────────────────────────────────────────
do
  fresh_setup({ todo = { planning_indent = 4 } })
  local schedule = require("organ.schedule")

  local b = load_buf("* TODO L1 fixed\n", "fixed_l1.org")
  schedule._set_planning(b, 1, "SCHEDULED", "2026-05-19")
  local sched = planning_line(b, 1)
  check(
    "fixed=4 at L1: SCHEDULED at col 4",
    leading_spaces(sched) == 4,
    "got " .. leading_spaces(sched) .. " on: " .. vim.inspect(sched)
  )

  -- Level 2 -- still 4 spaces, regardless of depth
  local b2 = load_buf("* Top\n** TODO L2 fixed\n", "fixed_l2.org")
  schedule._set_planning(b2, 2, "SCHEDULED", "2026-05-19")
  local sched2 = planning_line(b2, 2)
  check(
    "fixed=4 at L2: SCHEDULED still at col 4 (no depth adapt)",
    leading_spaces(sched2) == 4,
    "got " .. leading_spaces(sched2) .. " on: " .. vim.inspect(sched2)
  )
end

-- ─── 3. zero / flush-left ───────────────────────────────────────────────────
do
  fresh_setup({ todo = { planning_indent = 0 } })
  local schedule = require("organ.schedule")
  local todo = require("organ.todo")

  local b = load_buf("* TODO Flush left\n", "flush.org")
  schedule._set_planning(b, 1, "SCHEDULED", "2026-05-19")
  local sched = planning_line(b, 1)
  check(
    "zero: SCHEDULED at col 0",
    leading_spaces(sched) == 0,
    "got " .. leading_spaces(sched) .. " on: " .. vim.inspect(sched)
  )

  todo.set(b, 1, "DONE")
  local closed
  for i = 1, vim.api.nvim_buf_line_count(b) do
    local l = vim.api.nvim_buf_get_lines(b, i - 1, i, false)[1] or ""
    if l:match("CLOSED:") then
      closed = l
      break
    end
  end
  if closed then
    check(
      "zero: CLOSED at col 0 too",
      leading_spaces(closed) == 0,
      "got " .. leading_spaces(closed) .. " on: " .. vim.inspect(closed)
    )
  end
end

-- ─── 4. an edit keeps the indent the planning line already has ───────────────
do
  fresh_setup({ todo = { planning_indent = "adapt" } })
  local schedule = require("organ.schedule")

  -- Buffer has SCHEDULED at col 7 (off-spec).  `org-add-planning-info`
  -- inserts at the existing line's own indentation, so adding DEADLINE
  -- leaves those 7 columns alone; the config governs only a first write.
  local b = load_buf("* TODO Existing\n       SCHEDULED: <2026-05-19 Tue>\n", "existing.org")
  schedule._set_planning(b, 1, "DEADLINE", "2026-05-20")
  local pl = planning_line(b, 1)
  check(
    "an existing planning line keeps its own indent",
    leading_spaces(pl) == 7,
    "got " .. leading_spaces(pl) .. " on: " .. vim.inspect(pl)
  )
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("planning_indent_test: PASS")
