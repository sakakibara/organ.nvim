-- Memory probe — opens N org buffers, runs typical workflows, reports
-- per-buffer memory growth. Fails if growth exceeds a sane bound.
-- Run: nvim --headless -l tests/memory_probe_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.cmd("runtime plugin/organ.lua")

require("organ").setup({})

local function lua_mem_kb()
  collectgarbage("collect")
  collectgarbage("collect")
  return collectgarbage("count") -- in KB
end

local function module_state_sizes()
  local fold = require("organ.fold")
  local complete = require("organ.complete")
  local indent = require("organ.indent")
  local function tablen(t)
    local n = 0
    for _ in pairs(t or {}) do
      n = n + 1
    end
    return n
  end
  return {
    fold_state = tablen(fold._state),
    complete_open = tablen(complete._open_for),
    indent_attached = tablen(indent._attached),
    indent_timers = tablen(indent._timers),
  }
end

-- Baseline.
local baseline_kb = lua_mem_kb()
local baseline_state = module_state_sizes()

-- Workflow: create N org buffers, populate them, simulate basic operations,
-- wipe them. Run multiple cycles to amplify leaks.
local N = 50
local CYCLES = 4
for cycle = 1, CYCLES do
  for i = 1, N do
    local b = vim.api.nvim_create_buf(true, false)
    local path = "/tmp/probe_" .. cycle .. "_" .. i .. ".org"
    vim.api.nvim_buf_set_name(b, path)
    vim.bo[b].filetype = "org"
    vim.api.nvim_buf_set_lines(b, 0, -1, false, {
      "* TODO Headline " .. i,
      "  SCHEDULED: <2026-04-28 Tue>",
      "  body line",
      "  another body line",
      "** Subhead",
      "   nested",
    })
    -- Simulate a fold cycle (populates fold._state).
    pcall(function()
      require("organ.fold").cycle(b, 1)
    end)
    -- Simulate completion lookup (populates complete._open_for).
    require("organ.complete")._open_for[b] = "1:0"
    -- Wipe.
    vim.api.nvim_buf_delete(b, { force = true })
  end
end

local final_kb = lua_mem_kb()
local final_state = module_state_sizes()

local function fmt_state(s)
  return string.format(
    "fold=%d complete=%d indent_a=%d indent_t=%d",
    s.fold_state,
    s.complete_open,
    s.indent_attached,
    s.indent_timers
  )
end

io.write(string.format("baseline: %.1f KB  state: %s\n", baseline_kb, fmt_state(baseline_state)))
io.write(string.format("final:    %.1f KB  state: %s\n", final_kb, fmt_state(final_state)))
io.write(
  string.format(
    "delta:    %+.1f KB after %d cycles × %d buffers (%d total)\n",
    final_kb - baseline_kb,
    CYCLES,
    N,
    CYCLES * N
  )
)

-- Module state must be bounded. After all wipes, no per-buffer entries remain.
assert(final_state.fold_state == 0, "fold._state leaked: " .. final_state.fold_state)
assert(final_state.complete_open == 0, "complete._open_for leaked: " .. final_state.complete_open)
assert(final_state.indent_attached == 0, "indent._attached leaked: " .. final_state.indent_attached)
assert(final_state.indent_timers == 0, "indent._timers leaked: " .. final_state.indent_timers)

-- The structural state assertions above are the regression net. A raw
-- heap-delta bound was tried and dropped: it varied 25× across nvim
-- versions on identical workloads (local 40 KB vs CI nightly 1 MB), so
-- it kept catching one-time JIT / parser / prepared-statement costs
-- instead of real leaks.

io.write("memory probe ok\n")
os.exit(0)
