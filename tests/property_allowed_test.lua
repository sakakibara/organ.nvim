-- property.allowed_values: per-headline, ancestor-inherited, file-level.
-- Run via: nvim --headless -l tests/property_allowed_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local prop = require("organ.property")

-- 1. Per-headline allowed values via :EFFORT_ALL: in own drawer.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Task",
    "  :PROPERTIES:",
    "  :EFFORT_ALL: 0:15 0:30 1:00 2:00",
    "  :END:",
  })
  local v = prop.allowed_values(b, 1, "EFFORT")
  assert(v and #v == 4, "expected 4 values; got " .. tostring(v and #v))
  assert(v[1] == "0:15", "first value: " .. v[1])
end

-- 2. Inherited from an ancestor headline.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Project",
    "  :PROPERTIES:",
    "  :EFFORT_ALL: small medium large",
    "  :END:",
    "** Subtask",
  })
  local v = prop.allowed_values(b, 5, "EFFORT")
  assert(v and v[2] == "medium", "inherited from ancestor; got " .. tostring(v and v[2]))
end

-- 3. File-level #+PROPERTY: EFFORT_ALL ...
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "#+PROPERTY: EFFORT_ALL 0:30 1:00 2:00",
    "* Task",
  })
  local v = prop.allowed_values(b, 2, "EFFORT")
  assert(v and v[3] == "2:00", "file-level fallback; got " .. tostring(v and v[3]))
end

-- 4. Unconstrained → returns nil.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* Task" })
  local v = prop.allowed_values(b, 1, "EFFORT")
  assert(v == nil, "no allowed values configured → nil")
end

io.write("property allowed ok\n")
os.exit(0)
