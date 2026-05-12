-- Performance regression test for the decoration provider migration.
-- Asserts wall-clock budgets for per-edit and per-frame dispatch.
--
-- Run via: nvim --headless -l tests/decoration_perf_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  conceal = { enabled = true },
  modern = { stars = { enabled = true } },
})

require("organ.conceal")
require("organ.stars")
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

-- Initial-population cost.
do
  local t0 = vim.uv.hrtime()
  decoration.attach(bufnr)
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  print(("       initial attach: %.1f ms"):format(elapsed_ms))
  check(
    "initial attach + population under 500ms",
    elapsed_ms < 500,
    ("took %.1f ms"):format(elapsed_ms)
  )
end

-- Per-edit cost (debounced -- timer fires asynchronously; we measure
-- only the synchronous portion of the on_lines dispatch).
do
  local t0 = vim.uv.hrtime()
  vim.api.nvim_buf_set_text(bufnr, 100, 0, 100, 0, { "a" })
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  print(("       single-edit synchronous dispatch: %.1f ms"):format(elapsed_ms))
  check(
    "single edit synchronous dispatch under 20ms",
    elapsed_ms < 20,
    ("took %.1f ms"):format(elapsed_ms)
  )
end

-- Per-frame (simulated) cost.
do
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  local t0 = vim.uv.hrtime()
  for row = 100, 200 do
    decoration._dispatch_on_line(0, winid, bufnr, row)
  end
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  print(("       100-row simulated frame: %.1f ms"):format(elapsed_ms))
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
