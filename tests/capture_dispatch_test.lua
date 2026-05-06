-- Tests for Phase 2: single-key dispatcher for :Org capture.
-- Verifies: popup is used when templates have keys; direct key dispatch works.
-- Run via: nvim --headless -l tests/capture_dispatch_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local target_path = tmp .. "/inbox.org"
vim.fn.writefile({ "* Existing" }, target_path)

local templates = {
  {
    name = "Task",
    key = "t",
    target = { kind = "file", path = target_path },
    body = "* TODO task",
  },
  {
    name = "Note",
    key = "n",
    target = { kind = "file", path = target_path },
    body = "* note",
  },
  { name = "Keyless", target = { kind = "file", path = target_path }, body = "* keyless" },
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

local cmd_mod = {
  OrgCapture = require("organ.capture").commands.capture.fn,
}

-- Stub build_capture_ctx to avoid headless vim.fn.expand("<cword>") issues.
local function with_stubbed_ctx(fn)
  -- Temporarily stub vim.fn.expand to return "" for "<cword>".
  local orig_expand = vim.fn.expand
  vim.fn.expand = function(expr, ...)
    if type(expr) == "string" and expr:find("<cword>") then
      return ""
    end
    return orig_expand(expr, ...)
  end
  local ok, err = pcall(fn)
  vim.fn.expand = orig_expand
  if not ok then
    error(err, 2)
  end
end

-- 1. :Org capture t  →  opens Task template directly (no picker).
do
  local started_name
  local orig_start = require("organ.capture").start
  require("organ.capture").start = function(t, _ctx)
    started_name = t.name
  end

  with_stubbed_ctx(function()
    cmd_mod.OrgCapture({ args = "t" })
  end)

  require("organ.capture").start = orig_start
  assert(started_name == "Task", "expected Task; got " .. tostring(started_name))
end

-- 2. :Org capture n  →  opens Note template directly.
do
  local started_name
  local orig_start = require("organ.capture").start
  require("organ.capture").start = function(t, _ctx)
    started_name = t.name
  end

  with_stubbed_ctx(function()
    cmd_mod.OrgCapture({ args = "n" })
  end)

  require("organ.capture").start = orig_start
  assert(started_name == "Note", "expected Note; got " .. tostring(started_name))
end

-- 3. :Org capture <bad-key>  →  notify-WARN, no start.
do
  local started = false
  local notified
  local orig_start = require("organ.capture").start
  local orig_notify = vim.notify
  require("organ.capture").start = function()
    started = true
  end
  vim.notify = function(msg, lvl)
    notified = { msg = msg, lvl = lvl }
  end

  -- bad key doesn't need ctx (returns early before build_capture_ctx).
  cmd_mod.OrgCapture({ args = "z" })

  require("organ.capture").start = orig_start
  vim.notify = orig_notify
  assert(not started, "should not start on bad key")
  assert(
    notified and notified.msg:find("no capture template"),
    "expected warn; got " .. tostring(notified and notified.msg)
  )
end

-- 4. :Org capture (no args) with templates that have keys → popup is used, NOT vim.ui.select.
do
  local select_called = false
  local popup_called = false

  local orig_select = vim.ui.select
  local orig_popup_open = require("organ.capture.popup").open

  vim.ui.select = function()
    select_called = true
  end
  require("organ.capture.popup").open = function(_ctx, _cb)
    popup_called = true
  end

  with_stubbed_ctx(function()
    cmd_mod.OrgCapture({ args = "" })
  end)

  vim.ui.select = orig_select
  require("organ.capture.popup").open = orig_popup_open

  assert(popup_called, ":Org capture with no args + keyed templates should use popup")
  assert(not select_called, "vim.ui.select should NOT be called when templates have keys")
end

-- 5. :Org capture (no args) with keyless templates only → falls back to vim.ui.select.
do
  -- Temporarily reconfigure with only keyless templates.
  local organ = require("organ")
  local saved = organ.config.capture.templates
  organ.config.capture.templates = {
    { name = "Only", target = { kind = "file", path = target_path }, body = "* x" },
  }

  local select_called = false
  local popup_called = false
  local orig_select = vim.ui.select
  local orig_popup_open = require("organ.capture.popup").open
  vim.ui.select = function()
    select_called = true
  end
  require("organ.capture.popup").open = function()
    popup_called = true
  end

  with_stubbed_ctx(function()
    cmd_mod.OrgCapture({ args = "" })
  end)

  vim.ui.select = orig_select
  require("organ.capture.popup").open = orig_popup_open
  organ.config.capture.templates = saved

  assert(select_called, "keyless-only templates should fall back to vim.ui.select")
  assert(not popup_called, "popup should NOT be used for keyless templates")
end

vim.fn.delete(tmp, "rf")
io.write("capture dispatch ok\n")
os.exit(0)
