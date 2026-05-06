-- Tests for capture.popup — built-in prefix popup with mocked getcharstr.
-- Run via: nvim --headless -l tests/capture_popup_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local target_path = tmp .. "/inbox.org"
vim.fn.writefile({ "" }, target_path)

local templates = {
  { name = "Task", key = "t", target = { kind = "file", path = target_path }, body = "* %?" },
  { name = "Note", key = "n", target = { kind = "file", path = target_path }, body = "* %?" },
  {
    name = "Task quick",
    key = "tq",
    target = { kind = "file", path = target_path },
    body = "* %?",
  },
  {
    name = "Task slow",
    key = "ts",
    target = { kind = "file", path = target_path },
    body = "* %?",
  },
}

require("organ").setup({
  db_path = tmp .. "/c.db",
  org_dir = tmp,
  notify = true,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  capture = { templates = templates },
})

local popup = require("organ.capture.popup")

-- Make sure which-key isn't accidentally loaded (force fallback path).
package.loaded["which-key"] = nil

-- Provide a controllable input queue.
local input_queue = {}
local original_getchar = vim.fn.getcharstr
vim.fn.getcharstr = function()
  local c = table.remove(input_queue, 1)
  return c or ""
end

-- 1. Single leaf char "n" fires immediately (Note has unique key).
do
  input_queue = { "n" }
  local fired
  popup.open({}, function(t)
    fired = t
  end)
  assert(fired and fired.name == "Note", "expected Note; got " .. tostring(fired and fired.name))
end

-- 2. Prefix "t" → another popup → leaf "q" fires "Task quick".
do
  -- Three templates start with "t": Task ("t"), Task quick ("tq"), Task slow ("ts").
  -- "t" is BOTH a leaf (Task) and a prefix (tq, ts). Convention: ambiguity
  -- breaks toward prefix; user must press a follow-up char.
  input_queue = { "t", "q" }
  local fired
  popup.open({}, function(t)
    fired = t
  end)
  assert(
    fired and fired.name == "Task quick",
    "expected Task quick; got " .. tostring(fired and fired.name)
  )
end

-- 3. Esc cancels (no fire).
do
  input_queue = { "\27" } -- 0x1b
  local fired = false
  popup.open({}, function()
    fired = true
  end)
  assert(not fired, "Esc should cancel")
end

-- 4. Unknown char → notify-WARN, no fire.
do
  input_queue = { "z" }
  local fired = false
  local notified
  local orig = vim.notify
  vim.notify = function(msg, lvl)
    notified = { msg = msg, lvl = lvl }
  end
  popup.open({}, function()
    fired = true
  end)
  vim.notify = orig
  assert(not fired)
  assert(
    notified and notified.msg:find("no template"),
    "expected notify; got " .. tostring(notified and notified.msg)
  )
end

vim.fn.getcharstr = original_getchar
vim.fn.delete(tmp, "rf")
io.write("capture popup ok\n")
os.exit(0)
