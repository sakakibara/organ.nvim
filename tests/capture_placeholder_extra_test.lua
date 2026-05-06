-- capture placeholder: %f / %F / %n / %x / %c.
-- Run via: nvim --headless -l tests/capture_placeholder_extra_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local ph = require("organ.capture.placeholder")

local ctx = {
  source_file = "/abs/path/to/notes.org",
  visual_text = "",
  now = os.time({ year = 2026, month = 5, day = 2, hour = 12 }),
  prompts = { text = {}, tags = nil, dates = {} },
}

-- 1. %f → basename only.
do
  local out = ph.expand("file: %f", ctx)
  assert(out:find("file: notes.org", 1, true), "expand %f: " .. out)
end

-- 2. %F → absolute path.
do
  local out = ph.expand("path: %F", ctx)
  assert(out == "path: /abs/path/to/notes.org", "expand %F: " .. out)
end

-- 3. %n → login name (non-empty).
do
  local out = ph.expand("by %n", ctx)
  assert(out ~= "by ", "expand %n produced empty: " .. out)
end

-- 4. %x → clipboard. Headless nvim usually has no clipboard provider
--    (`+` register is empty); skip the round-trip when that's the case.
do
  vim.fn.setreg("+", "clipboard-content")
  if vim.fn.getreg("+") == "clipboard-content" then
    local out = ph.expand("clip=%x", ctx)
    assert(out == "clip=clipboard-content", "expand %x: " .. out)
  end
end

-- 5. %c → register 0.
do
  vim.fn.setreg("0", "last-yank")
  local out = ph.expand("yank=%c", ctx)
  assert(out == "yank=last-yank", "expand %c: " .. out)
end

io.write("capture placeholder extras ok\n")
os.exit(0)
