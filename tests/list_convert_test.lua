-- list_convert: list_to_subtree + toggle_item.
-- Run via: nvim --headless -l tests/list_convert_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local lc = require("organ.list_convert")

-- 1. list_to_subtree under a level-1 headline → produces level-2 headlines.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Container",
    "- one",
    "- two",
    "  - nested",
    "- three",
  })
  local n = lc.list_to_subtree({ bufnr = b, line = 2 })
  assert(n == 4, "expected 4 lines converted; got " .. tostring(n))
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "* Container", "container intact")
  assert(lines[2] == "** one", "row 2: " .. lines[2])
  assert(lines[3] == "** two", "row 3: " .. lines[3])
  assert(lines[4] == "*** nested", "nested becomes deeper: " .. lines[4])
  assert(lines[5] == "** three", "row 5: " .. lines[5])
end

-- 2. list_to_subtree at top of file → level-1 headlines.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "- alpha",
    "- beta",
  })
  lc.list_to_subtree({ bufnr = b, line = 1 })
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "* alpha", "1: " .. lines[1])
  assert(lines[2] == "* beta", "2: " .. lines[2])
end

-- 3. toggle_item: list item → headline.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Parent",
    "- thing",
  })
  local kind = lc.toggle_item({ bufnr = b, line = 2 })
  assert(kind == "to_headline", "kind: " .. tostring(kind))
  local line = vim.api.nvim_buf_get_lines(b, 1, 2, false)[1]
  assert(line == "** thing", "expected ** thing; got " .. line)
end

-- 4. toggle_item: headline → list item (indent reflects level).
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "** sub item",
  })
  local kind = lc.toggle_item({ bufnr = b, line = 1 })
  assert(kind == "to_item", "kind: " .. tostring(kind))
  local line = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(line == "  - sub item", "expected '  - sub item'; got '" .. line .. "'")
end

io.write("list convert ok\n")
os.exit(0)
