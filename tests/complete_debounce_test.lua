-- The TextChangedI completion trigger must be debounced: rapid keystrokes
-- collapse to a single maybe_open after a trailing delay, instead of
-- running completion work on every keystroke.
-- Run via: nvim --headless -l tests/complete_debounce_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  complete = { debounce_ms = 60 },
})

local complete = require("organ.complete")
local b = vim.api.nvim_create_buf(false, true)

local calls = 0
complete.maybe_open = function(_)
  calls = calls + 1
end

complete.schedule_open(b)
complete.schedule_open(b)
complete.schedule_open(b)

-- Trailing debounce: nothing should have fired yet.
assert(calls == 0, "debounced trigger fired synchronously on the keystroke: " .. calls)

assert(
  vim.wait(500, function()
    return calls >= 1
  end, 10),
  "debounced maybe_open never fired"
)
assert(calls == 1, "rapid keystrokes should collapse to one maybe_open, got " .. calls)

io.write("complete debounce ok\n")
os.exit(0)
