-- complete.drawer: cursor_partial detection + completion_items.
-- Run via: nvim --headless -l tests/complete_drawer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local d = require("organ.complete.drawer")

-- Set up a buffer with a headline + an existing custom drawer.
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* Heading",
  "  :CUSTOM:",
  "  :END:",
  "  :LO", -- partial drawer being typed
})
vim.api.nvim_set_current_buf(b)
vim.opt.virtualedit = "all" -- allow cursor past EOL for headless setup

-- Cursor on line 4, after `:LO` (col 5 = past last char).
vim.api.nvim_win_set_cursor(0, { 4, 5 })
local partial = d.cursor_partial(b)
assert(partial == "LO", "expected 'LO'; got '" .. tostring(partial) .. "'")

local items = d.completion_items(partial)
local labels = {}
for _, it in ipairs(items) do
  labels[#labels + 1] = it.label
end
local set = {}
for _, l in ipairs(labels) do
  set[l] = true
end
assert(
  set[":LOGBOOK:"],
  "LOGBOOK should be suggested for partial 'LO'; got: " .. table.concat(labels, ", ")
)
assert(
  not set[":PROPERTIES:"],
  "PROPERTIES should NOT match partial 'LO'; got: " .. table.concat(labels, ", ")
)

-- With empty partial, all built-ins + buffer drawers come through.
vim.api.nvim_buf_set_lines(b, 3, 4, false, { "  :" })
vim.api.nvim_win_set_cursor(0, { 4, 3 }) -- past the `:`
local items2 = d.completion_items(d.cursor_partial(b))
local labels2 = {}
for _, it in ipairs(items2) do
  labels2[#labels2 + 1] = it.label
end
local set2 = {}
for _, l in ipairs(labels2) do
  set2[l] = true
end
assert(
  set2[":PROPERTIES:"] and set2[":LOGBOOK:"] and set2[":CLOCK:"],
  "all built-ins; got " .. table.concat(labels2, ", ")
)
assert(set2[":CUSTOM:"], "buffer-discovered :CUSTOM: should be present")

-- Outside a headline section → no completion.
local b2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "  :LO" })
vim.api.nvim_set_current_buf(b2)
vim.api.nvim_win_set_cursor(0, { 1, 5 })
assert(d.cursor_partial(b2) == "", "outside any headline section should suppress completion")

io.write("complete drawer ok\n")
os.exit(0)
