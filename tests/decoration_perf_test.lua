-- Performance regression test for all decoration providers.
-- Asserts wall-clock budgets for per-frame on_win + on_line dispatch
-- and per-edit synchronous notification cost.  Bounded by `timeout`
-- via the harness; this script also exits with a non-zero code on
-- failure rather than hanging.
--
-- Run via: nvim --headless -l tests/decoration_perf_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
local indexer = require("organ.indexer")
vim.treesitter.language.add("org", { path = parser_path })
vim.treesitter.language.add("org_inline", { path = indexer._inline_parser_path(parser_path) })

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  conceal = { enabled = true },
  modern = { stars = { enabled = true }, blocks = { enabled = true }, pills = { enabled = true } },
  indent = { enabled = true },
  description_list = { enabled = true },
})

-- Load every decoration provider that registers itself at require-time.
require("organ.conceal")
require("organ.stars")
require("organ.description_list")
require("organ.indent")
require("organ.modern.bullets")
require("organ.modern.pills")
require("organ.modern.blocks")
require("organ.fold.contents")

local decoration = require("organ.decoration")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local lines = vim.fn.readfile(root .. "/tests/fixtures/decoration_10k.org")
print(("       fixture: %d lines"):format(#lines))

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

-- Initial attach cost (one-time on BufRead).  With on_win design the
-- attach itself is cheap because no cache rebuild runs synchronously;
-- the first render frame does the work for the visible range only.
do
  local t0 = vim.uv.hrtime()
  decoration.attach(bufnr)
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  print(("       initial attach: %.1f ms"):format(elapsed_ms))
  check("initial attach under 50ms", elapsed_ms < 50, ("took %.1f ms"):format(elapsed_ms))
end

-- Single edit synchronous cost: with no on_lines handlers in any
-- on_win-based provider, this should be essentially zero (just the
-- nvim_buf_attach plumbing).
do
  local t0 = vim.uv.hrtime()
  vim.api.nvim_buf_set_text(bufnr, 100, 0, 100, 0, { "a" })
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  print(("       single-edit synchronous dispatch: %.1f ms"):format(elapsed_ms))
  check(
    "single edit synchronous dispatch under 5ms",
    elapsed_ms < 5,
    ("took %.1f ms"):format(elapsed_ms)
  )
end

-- 100 sequential edits with simulated redraw between each: this is the
-- real-world "typing in a long buffer" scenario.  p95 must stay under
-- 150ms; total throughput must stay under 15000ms on nvim 0.11+.
--
-- p95 (not worst-of-100) is what the user actually perceives: a single
-- GC pause or scheduler stall on shared CI hardware is invisible to a
-- typist, but a sustained 2x slowdown is not.  Worst-of-100 was tripping
-- on one-off runner blips while aggregate stayed flat; p95 is robust to
-- that without losing regression-detection power.
--
-- The budgets are set against `parser:parse(true)` once per redraw on a
-- ~7k-line fixture.  Org's `org_inline` injection is emitted on every
-- paragraph / headline / list item / table row, so the per-edit cost is
-- dominated by injection re-parse, not by our own dispatch.  Bounded
-- range parse would be faster but corrupts injection bookkeeping and
-- crashes downstream callers; the single shared full parse trades that
-- correctness in for a larger per-edit budget.
--
-- On nvim 0.10.x the budgets are skipped: upstream tree-sitter
-- incremental parse is materially slower on top of that, which is an
-- nvim-version characteristic, not a regression in our code.  The
-- numbers are still printed so a real regression on 0.10.x would show
-- up in CI logs.
local has_011 = vim.fn.has("nvim-0.11") == 1
do
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  local total_t0 = vim.uv.hrtime()
  local edit_ms = {}
  for i = 1, 100 do
    local t0 = vim.uv.hrtime()
    vim.api.nvim_buf_set_text(bufnr, 100, 0, 100, 0, { "x" })
    -- Simulate a redraw: drive on_win + on_line for 60 visible rows.
    decoration._dispatch_on_win(0, winid, bufnr, 100, 160)
    for row = 100, 160 do
      decoration._dispatch_on_line(0, winid, bufnr, row)
    end
    edit_ms[i] = (vim.uv.hrtime() - t0) / 1e6
  end
  local total_ms = (vim.uv.hrtime() - total_t0) / 1e6
  table.sort(edit_ms)
  local p95_ms = edit_ms[95]
  local worst_edit_ms = edit_ms[100]
  print(
    ("       100 edits + redraws: %.1f ms total, p95 %.1f ms, worst %.1f ms"):format(
      total_ms,
      p95_ms,
      worst_edit_ms
    )
  )
  if has_011 then
    check(
      "100 edits + redraws under 15000ms total",
      total_ms < 15000,
      ("took %.1f ms"):format(total_ms)
    )
    check("p95 edit + redraw under 150ms", p95_ms < 150, ("p95 %.1f ms"):format(p95_ms))
  else
    print("       (skipping 100-edits budget checks on nvim 0.10.x: upstream ts-parse perf)")
  end
end

-- 100-row simulated frame in isolation.
do
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  local t0 = vim.uv.hrtime()
  decoration._dispatch_on_win(0, winid, bufnr, 200, 300)
  for row = 200, 300 do
    decoration._dispatch_on_line(0, winid, bufnr, row)
  end
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  print(("       100-row simulated frame (all providers): %.1f ms"):format(elapsed_ms))
  check("100-row simulated frame under 30ms", elapsed_ms < 30, ("took %.1f ms"):format(elapsed_ms))
end

vim.api.nvim_buf_delete(bufnr, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_perf_test: PASS")
os.exit(0)
