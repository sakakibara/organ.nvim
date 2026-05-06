-- :Org agenda custom evaluates an inline Lua view spec.
-- Run via: nvim --headless -l tests/agenda_custom_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fixture = tmp .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write([[
* TODO Buy milk
* WAITING Boss approval
* DONE Old task
]])
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = tmp,
  notify = true,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
require("organ").scan_blocking(tmp, 5000)

-- 1. Inline view spec opens the agenda with the custom filter.
vim.cmd('Org agenda custom { types = { "any" }, todo = { include = { "WAITING" } } }')
local b = vim.api.nvim_get_current_buf()
assert(vim.bo[b].filetype == "organ-agenda", "expected organ-agenda buffer")
local body = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
assert(body:find("Boss approval", 1, true), "WAITING entry should appear; got:\n" .. body)
assert(not body:find("Buy milk", 1, true), "TODO entry should NOT appear under WAITING-only filter")
vim.api.nvim_buf_delete(b, { force = true })

-- 2. Block agenda spec inline.
vim.cmd(
  "Org agenda custom { blocks = { "
    .. '{ label = "Now",   types = { "any" }, todo = { include = { "WAITING" } } }, '
    .. '{ label = "Later", types = { "any" }, todo = { include = { "TODO" } } } '
    .. "} }"
)
b = vim.api.nvim_get_current_buf()
body = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
assert(body:find("══ Now", 1, true), "Now block label present")
assert(body:find("══ Later", 1, true), "Later block label present")
vim.api.nvim_buf_delete(b, { force = true })

-- 3. Bad expr surfaces a clear error (notify-captured).
local notified
vim.notify = function(msg, lvl)
  notified = msg
end
vim.cmd("Org agenda custom this is not lua")
assert(
  notified and notified:find("invalid view-spec expression", 1, true),
  "expected invalid-expr notification; got " .. tostring(notified)
)

io.write("agenda custom ok\n")
os.exit(0)
