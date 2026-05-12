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
-- real-world "typing in a long buffer" scenario.  No edit may exceed
-- 50ms; total throughput must stay under 1500ms.
do
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  local total_t0 = vim.uv.hrtime()
  local worst_edit_ms = 0
  for i = 1, 100 do
    local t0 = vim.uv.hrtime()
    vim.api.nvim_buf_set_text(bufnr, 100, 0, 100, 0, { "x" })
    -- Simulate a redraw: drive on_win + on_line for 60 visible rows.
    decoration._dispatch_on_win(0, winid, bufnr, 100, 160)
    for row = 100, 160 do
      decoration._dispatch_on_line(0, winid, bufnr, row)
    end
    local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
    if elapsed_ms > worst_edit_ms then
      worst_edit_ms = elapsed_ms
    end
  end
  local total_ms = (vim.uv.hrtime() - total_t0) / 1e6
  print(
    ("       100 edits + redraws: %.1f ms total, worst %.1f ms"):format(total_ms, worst_edit_ms)
  )
  -- Steady-state throughput on a stress fixture (7002 lines, 700 blocks).
  -- Real-world latency is captured by the "worst single edit + redraw"
  -- check below: that's what the user actually perceives.  The aggregate
  -- here is a coarser regression alarm bell that flags 2x slowdowns in
  -- per-frame on_win cost.
  check(
    "100 edits + redraws under 1500ms total",
    total_ms < 1500,
    ("took %.1f ms"):format(total_ms)
  )
  check(
    "no single edit + redraw over 50ms",
    worst_edit_ms < 50,
    ("worst %.1f ms"):format(worst_edit_ms)
  )
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
