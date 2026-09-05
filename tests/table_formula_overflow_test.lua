-- tests/table_formula_overflow_test.lua
-- Run via: nvim --headless -l tests/table_formula_overflow_test.lua
--
-- `#+TBLFM: $3=$1^$2` over two large integers used to run for twenty
-- seconds of uninterruptible exact arithmetic, freezing the editor.
-- Emacs caps exact integers at `integer-width` bits and signals an
-- arithmetic overflow instead; organ refuses the same way and leaves
-- the table alone.
--
-- The evaluation runs in its own nvim under `timeout -s KILL` so a
-- regression fails here with a message instead of wedging the suite:
-- a hang test that hangs is not a test.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local BUDGET_SECONDS = 10
local KILL_AFTER = "15"

local out_path = vim.fn.tempname()
local script = vim.fn.tempname() .. ".lua"

local f = assert(io.open(script, "w"))
f:write(([[
dofile(%q .. "/tests/_bootstrap.lua")
local b = vim.api.nvim_create_buf(false, true)
vim.bo[b].filetype = "org"
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "| 12345 | 67890 | keepme |",
  "#+TBLFM: $3=$1^$2",
})
vim.api.nvim_set_current_buf(b)
vim.api.nvim_win_set_cursor(0, { 1, 1 })
local applied = require("organ.table").eval_formulas(b)
local out = assert(io.open(%q, "w"))
out:write(tostring(applied) .. "\n")
out:write(table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n") .. "\n")
out:close()
]]):format(root, out_path))
f:close()

local started = vim.loop.hrtime()
vim.fn.system({ "timeout", "-s", "KILL", KILL_AFTER, vim.v.progpath, "--headless", "-l", script })
local killed = vim.v.shell_error ~= 0
local elapsed = (vim.loop.hrtime() - started) / 1e9

assert(not killed, ("$1^$2 did not finish within %ss"):format(KILL_AFTER))
assert(
  elapsed < BUDGET_SECONDS,
  ("$1^$2 took %.1fs, budget is %ds"):format(elapsed, BUDGET_SECONDS)
)

local result = assert(io.open(out_path)):read("*a")
local applied, table_line = result:match("^(%a+)\n(.-)\n")
assert(applied == "false", "the formula must be refused, got applied=" .. tostring(applied))
assert(
  table_line == "| 12345 | 67890 | keepme |",
  "the row must be byte-unchanged, got: " .. tostring(table_line)
)

vim.fn.delete(script)
vim.fn.delete(out_path)

io.write(("table formula overflow ok (%.2fs)\n"):format(elapsed))
