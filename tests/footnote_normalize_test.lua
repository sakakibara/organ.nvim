-- footnote.normalize_inline: convert `[fn:LABEL:body]` and `[fn::body]`
-- to `[fn:LABEL]` references with definitions appended at buffer end.
-- Run via: nvim --headless -l tests/footnote_normalize_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local fn = require("organ.footnote")

-- 1. Named inline footnote.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "Some prose with [fn:detail:explanation here] inline.",
  })
  local n = fn.normalize_inline(b)
  assert(n == 1, "1 conversion; got " .. n)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  -- Inline replaced with bare reference.
  assert(lines[1] == "Some prose with [fn:detail] inline.", "ref line: " .. lines[1])
  -- Definition appended.
  local has_def = false
  for _, l in ipairs(lines) do
    if l == "[fn:detail] explanation here" then
      has_def = true
    end
  end
  assert(has_def, "definition not appended:\n" .. table.concat(lines, "\n"))
end

-- 2. Anonymous inline → assigned numeric label.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "Anon[fn::body text] here.",
  })
  fn.normalize_inline(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1]:find("%[fn:1%]"), "first ref should be [fn:1]: " .. lines[1])
  local has_def = false
  for _, l in ipairs(lines) do
    if l == "[fn:1] body text" then
      has_def = true
    end
  end
  assert(has_def, "definition for [fn:1] not appended")
end

-- 3. Anonymous numeric labels skip already-used ones.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "Already [fn:1] used and [fn::new one] inline.",
  })
  fn.normalize_inline(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  -- The anon should become [fn:2] since [fn:1] is taken.
  assert(lines[1]:find("%[fn:2%]"), "anon should pick [fn:2]: " .. lines[1])
end

io.write("footnote normalize ok\n")
os.exit(0)
