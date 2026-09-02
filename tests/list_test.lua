-- list.parse_item / block_at / repair / sort.
-- Run via: nvim --headless -l tests/list_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local list = require("organ.list")

-- 1. parse_item.
do
  local p = list.parse_item("- hello")
  assert(p.bullet == "-" and p.content == "hello", "unordered")
  p = list.parse_item("  + nested")
  assert(p.indent == "  " and p.bullet == "+", "indent + alt bullet")
  p = list.parse_item("3. third")
  assert(p.bullet == "3." and p.counter == 3, "ordered")
  p = list.parse_item("not a list")
  assert(p == nil, "non-item")
end

-- 2. block_at: find contiguous list span.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "intro line",
    "- one",
    "- two",
    "- three",
    "after",
  })
  local s, e = list.block_at(b, 3) -- cursor on `- two`
  assert(s == 2 and e == 4, ("block: " .. s .. ".." .. e))
end

-- 3. repair: re-sequence numbered.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "1. a",
    "5. b",
    "9. c",
  })
  local n = list.repair(b, 1)
  assert(n == 2, "expected 2 changes; got " .. n)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "1. a", "first stays: " .. lines[1])
  assert(lines[2] == "2. b", "second renum: " .. lines[2])
  assert(lines[3] == "3. c", "third renum: " .. lines[3])
end

-- 4. repair honors `[@N]` start marker.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "1. [@5] start at 5",
    "1. b",
    "1. c",
  })
  list.repair(b, 1)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "5. [@5] start at 5", "first becomes 5: " .. lines[1])
  assert(lines[2] == "6. b", "second 6: " .. lines[2])
  assert(lines[3] == "7. c", "third 7: " .. lines[3])
end

-- 5. sort alphabetic.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "- charlie",
    "- alpha",
    "- bravo",
  })
  list.sort(b, 1, "alpha")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "- alpha", "1st: " .. lines[1])
  assert(lines[2] == "- bravo", "2nd: " .. lines[2])
  assert(lines[3] == "- charlie", "3rd: " .. lines[3])
end

-- 5b. sort by display length, ties alphabetical.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "- longest one",
    "- bb",
    "- 日本",
    "- aa",
  })
  list.sort(b, 1, "length")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(
    vim.deep_equal(lines, { "- aa", "- bb", "- 日本", "- longest one" }),
    "length sort: " .. vim.inspect(lines)
  )
end

-- 6. sort keeps sub-items with their parent.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "- charlie",
    "  - sub of charlie",
    "- alpha",
    "  - sub of alpha",
  })
  list.sort(b, 1, "alpha")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "- alpha", "alpha first: " .. lines[1])
  assert(lines[2] == "  - sub of alpha", "alpha's sub follows: " .. lines[2])
  assert(lines[3] == "- charlie", "charlie next: " .. lines[3])
  assert(lines[4] == "  - sub of charlie", "charlie's sub follows: " .. lines[4])
end

io.write("list ok\n")
os.exit(0)
