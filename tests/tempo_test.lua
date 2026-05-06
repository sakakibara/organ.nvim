-- tempo: trigger detection + expansion of `<KEY`.
-- Run via: nvim --headless -l tests/tempo_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local tempo = require("organ.tempo")

-- 1. resolve returns a function for built-in keys.
do
  local fn = tempo.resolve("s")
  assert(type(fn) == "function", "<s should resolve")
  local lines = fn("python")
  assert(lines[1] == "#+begin_src python", "<s python: " .. lines[1])
  assert(lines[3] == "#+end_src", "end")
end

-- 2. detect_trigger is the pure helper; trigger_at_cursor is its
-- buffer-bound wrapper. Use the pure form for deterministic assertions —
-- nvim_win_set_cursor clamps past-EOL columns in non-insert modes, so
-- mocking a 'cursor at end of `<s`' from a headless test requires
-- bypassing that clamp.
assert(tempo.detect_trigger("<s", 2) == "s", "should detect <s")
assert(tempo.detect_trigger("<s extra", 2) == nil, "trigger requires empty rest")
assert(tempo.detect_trigger("  <q", 4) == "q", "leading whitespace ok")
assert(tempo.detect_trigger("foo<s", 5) == nil, "trigger anchored at line start")

-- 3. expand replaces the line and lands cursor inside the body.
-- nvim_win_set_cursor clamps past-EOL columns in normal mode, so we set
-- the buffer to "<q " (trailing space) and put the cursor on the space —
-- detect_trigger's empty-rest check tolerates trailing whitespace.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "<q " })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  assert(tempo.expand(b) == true, "expansion should fire")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "#+begin_quote", "open: " .. lines[1])
  assert(lines[2] == "", "body line empty")
  assert(lines[3] == "#+end_quote", "close: " .. lines[3])
  local row = vim.api.nvim_win_get_cursor(0)[1]
  assert(row == 2, "cursor on body line; got row " .. row)
end

-- 4. User-supplied expansion via config overrides defaults.
do
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    tempo = { expansions = { x = { "FOO", "", "BAR" } } },
  })
  local fn = tempo.resolve("x")
  assert(fn, "user key should resolve")
  local out = fn()
  assert(out[1] == "FOO" and out[3] == "BAR", "user expansion: " .. table.concat(out, "/"))
end

io.write("tempo ok\n")
os.exit(0)
