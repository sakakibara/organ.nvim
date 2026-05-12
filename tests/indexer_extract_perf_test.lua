-- Performance regression test for organ.indexer.extract on large
-- org files.  Before commit 4eb76dc fix, two per-heading helpers
-- (collect_habit_completions, collect_state_changes) each walked the
-- entire source string via gmatch on every call, making M.extract
-- O(N_headings * file_size) -- a 5000-line file with ~770 headings
-- took 800ms+ per call and caused user-visible freezes during the
-- VimEnter scan.
--
-- This test fixes a wall-clock budget so a regression that
-- reintroduces quadratic behavior fails CI on a synthetic fixture,
-- not in production on a user's real org files.
--
-- Run via: nvim --headless -l tests/indexer_extract_perf_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

local indexer = require("organ.indexer")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Build a synthetic org file with N headings, each carrying a small
-- LOGBOOK drawer (the path the slow helpers walk).  Total line count
-- is roughly N * 7 so N=700 produces a ~5000-line file -- the size
-- at which the pre-fix code took ~800ms.
local function build_fixture(n_headings)
  local lines = {}
  local function add(s)
    lines[#lines + 1] = s
  end
  add("#+TITLE: Perf fixture")
  add("")
  for i = 1, n_headings do
    add(("* TODO Heading %d"):format(i))
    add("  :LOGBOOK:")
    add(('  - State "DONE" from "TODO" [2024-01-%02d Mon 10:00]'):format((i % 28) + 1))
    add('  - State "TODO" from "" [2024-01-01 Mon 09:00]')
    add("  :END:")
    add(("Body text for heading %d."):format(i))
    add("")
  end
  return table.concat(lines, "\n") .. "\n"
end

-- ---- correctness sanity check (run before timing) -------------------
do
  local src = build_fixture(5)
  local headlines = indexer.extract(src, "perf-fixture.org", parser_path)
  check(
    "extract returns 5 headings on a 5-heading fixture",
    #headlines == 5,
    "got " .. tostring(#headlines)
  )
  check(
    "heading 1 has 1 habit completion (the DONE state change)",
    headlines[1] and #headlines[1].habit_completions == 1,
    headlines[1] and ("got " .. #headlines[1].habit_completions) or "headlines[1] missing"
  )
  check(
    "heading 1 has 2 state changes (DONE + TODO)",
    headlines[1] and #headlines[1].state_changes == 2,
    headlines[1] and ("got " .. #headlines[1].state_changes) or "headlines[1] missing"
  )
end

-- ---- perf budget on a 5000-line fixture -----------------------------
-- Pre-fix baseline: ~800ms.  Post-fix on the same machine: ~100ms.
-- The 400ms ceiling here is 2x the post-fix headroom -- enough to
-- absorb CI noise / slower machines, tight enough to catch a real
-- O(N^2) regression (which would reintroduce 800ms+).
do
  local src = build_fixture(700)
  local t0 = vim.uv.hrtime()
  local headlines = indexer.extract(src, "perf-fixture.org", parser_path)
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  print(
    ("       elapsed: %.1f ms for %d headings (~%d lines)"):format(elapsed_ms, #headlines, 700 * 7)
  )
  check(
    "extract under 400ms on a 700-heading, ~5000-line fixture",
    elapsed_ms < 400,
    ("took %.1f ms -- O(N^2) regression?"):format(elapsed_ms)
  )
  check("all 700 headings returned", #headlines == 700, "got " .. tostring(#headlines))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("indexer_extract_perf_test: PASS")
os.exit(0)
