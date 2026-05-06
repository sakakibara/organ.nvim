-- Tests for capture.pick (snacks via _test_stub) + :Org capture command.
-- :Org capture command tested via Task 7's wire-in. This task verifies
-- only the picker module's behaviour with mocked backends.
-- Run via: nvim --headless -l tests/capture_picker_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local target_path = tmp .. "/inbox.org"
vim.fn.writefile({ "* Existing" }, target_path)

local templates = {
  {
    name = "Inbox",
    key = "i",
    description = "Quick inbox",
    target = { kind = "file", path = target_path },
    body = "* TODO %?",
  },
  {
    name = "Journal",
    key = "j",
    description = "Daily log",
    target = { kind = "file", path = target_path },
    body = "* %?",
  },
  {
    name = "Keyless",
    description = "No key bound",
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
  find = { backend = "_test_stub" },
  capture = { templates = templates },
})

local picker = require("organ.capture.picker")

-- 1. picker.pick(templates, on_select) calls vim.ui.select with rendered items.
do
  local seen_items, chosen
  local original = vim.ui.select
  vim.ui.select = function(items, _o, cb)
    seen_items = items
    cb(items[2]) -- select the second template (Journal)
  end
  picker.pick(templates, function(t)
    chosen = t
  end)
  vim.ui.select = original

  assert(#seen_items == 3, "expected 3 items; got " .. #seen_items)
  assert(
    chosen and chosen.name == "Journal",
    "expected Journal selected; got " .. tostring(chosen and chosen.name)
  )
end

-- 2. Cancel (cb with nil) → on_select not called.
do
  local original = vim.ui.select
  vim.ui.select = function(_items, _o, cb)
    cb(nil)
  end
  local called = false
  picker.pick(templates, function()
    called = true
  end)
  vim.ui.select = original
  assert(not called, "on_select should not fire on cancel")
end

-- 3. Empty templates list → notify-WARN, no picker.
do
  local notified
  local original_notify = vim.notify
  vim.notify = function(msg, lvl)
    notified = { msg = msg, lvl = lvl }
  end
  local select_called = false
  local original_select = vim.ui.select
  vim.ui.select = function()
    select_called = true
  end

  picker.pick({}, function() end)

  vim.notify = original_notify
  vim.ui.select = original_select
  assert(
    notified and notified.msg:find("no capture templates"),
    "expected notify; got " .. tostring(notified and notified.msg)
  )
  assert(not select_called, "vim.ui.select should not fire on empty list")
end

vim.fn.delete(tmp, "rf")
io.write("capture picker ok\n")
os.exit(0)
