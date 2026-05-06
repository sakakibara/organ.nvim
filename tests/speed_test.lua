-- Verifies organ.speed dispatches at headline column 0 and falls
-- through otherwise.
-- Run via: nvim --headless -l tests/speed_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local speed = require("organ.speed")

-- 1. is_active() at column 0 of a headline.
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Heading",
  "Body line.",
  "** Sub heading",
})
vim.api.nvim_set_current_buf(bufnr)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(speed.is_active(), "speed.is_active should be true at col 0 of a headline")

vim.api.nvim_win_set_cursor(0, { 1, 2 })
assert(not speed.is_active(), "speed should NOT be active when cursor is past col 0")

vim.api.nvim_win_set_cursor(0, { 2, 0 })
assert(not speed.is_active(), "speed should NOT be active on a non-headline line")

vim.api.nvim_win_set_cursor(0, { 3, 0 })
assert(speed.is_active(), "speed.is_active should be true on a level-2 headline")

-- 2. dispatch() runs the named command.
local called = false
speed.dispatch(function()
  called = true
end)
assert(called, "dispatch with function should invoke it")

-- 3. Unknown command emits a warning, not a crash.
local last_msg, last_level
local saved_notify = vim.notify
vim.notify = function(m, l)
  last_msg, last_level = m, l
end
speed.dispatch("nonexistent_command")
vim.notify = saved_notify
assert(last_msg and last_msg:find("unknown"), "unknown command should warn")
assert(last_level == vim.log.levels.WARN, "warn level expected")

-- 4. attach() respects enabled = false.
local organ = require("organ")
organ.config = organ.config or {}
organ.config.speed = { enabled = false, commands = { n = "next_visible" } }
speed.attach(bufnr)
local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
local has_n = false
for _, m in ipairs(maps) do
  if m.lhs == "n" and (m.desc or ""):find("Speed:") then
    has_n = true
  end
end
-- (enabled=false on config means caller should NOT call attach, but if
-- they do, the implementation now early-returns. Verify no map.)
assert(not has_n, "no speed map should be installed when enabled=false")

-- 5. With enabled, the map exists and dispatches.
organ.config.speed = { enabled = true, commands = { n = "next_visible" } }
speed.attach(bufnr)
maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
has_n = false
for _, m in ipairs(maps) do
  if m.lhs == "n" and (m.desc or ""):find("Speed:") then
    has_n = true
  end
end
assert(has_n, "speed map for 'n' should be installed")

io.write("speed ok\n")
os.exit(0)
