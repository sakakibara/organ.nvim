-- tests/capture_default_templates_test.lua
-- Tests for:
--   1. Default capture templates (t/n/j) present when no override.
--   2. Rule 1: user override fully replaces defaults (no merge).
--   3. Auto-create: finalise against a non-existent file creates file+parent dirs.
-- Run via: nvim --headless -l tests/capture_default_templates_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")

-- ─── 1. Default templates present when no capture.templates override ────────
do
  require("organ").setup({
    db_path = tmp .. "/d1.db",
    org_dir = tmp,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  })

  local templates = require("organ").config.capture.templates
  assert(type(templates) == "table", "templates should be a table")
  assert(#templates == 3, "expected 3 default templates; got " .. #templates)

  -- Find by key.
  local keys = {}
  for _, t in ipairs(templates) do
    keys[t.key] = t.name
  end
  assert(keys["t"] == "Task", "expected t=Task; got " .. tostring(keys["t"]))
  assert(keys["n"] == "Note", "expected n=Note; got " .. tostring(keys["n"]))
  assert(keys["j"] == "Journal", "expected j=Journal; got " .. tostring(keys["j"]))
end

-- ─── 2. User override fully replaces defaults (Rule 1) ───────────────────────
do
  require("organ").setup({
    db_path = tmp .. "/d2.db",
    org_dir = tmp,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    capture = {
      templates = {
        {
          name = "MyTemplate",
          key = "m",
          target = { kind = "file", path = tmp .. "/my.org" },
          body = "* %?",
        },
      },
    },
  })

  local templates = require("organ").config.capture.templates
  assert(type(templates) == "table", "templates should be a table")
  assert(#templates == 1, "expected 1 template (user replaced defaults); got " .. #templates)
  assert(
    templates[1].name == "MyTemplate",
    "expected MyTemplate; got " .. tostring(templates[1].name)
  )
  assert(templates[1].key == "m", "expected key=m; got " .. tostring(templates[1].key))
end

-- ─── 3. Auto-create: finalise creates file and parent directories ─────────────
do
  -- Ensure the target file and its parent do NOT exist.
  local nested_dir = tmp .. "/new_subdir/deep"
  local target_file = nested_dir .. "/auto_created.org"
  vim.fn.delete(nested_dir, "rf")
  assert(not vim.loop.fs_stat(target_file), "target file should not exist before test")
  assert(not vim.loop.fs_stat(nested_dir), "nested dir should not exist before test")

  require("organ").setup({
    db_path = tmp .. "/d3.db",
    org_dir = tmp,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    capture = {
      templates = {
        {
          name = "AutoCreate",
          key = "a",
          target = { kind = "file", path = target_file },
          body = "* AutoCreated",
        },
      },
    },
  })

  local capture = require("organ.capture")
  local template = require("organ").config.capture.templates[1]

  local ctx = {
    source_bufnr = 0,
    source_win = vim.api.nvim_get_current_win(),
    source_cursor = { 1, 0 },
    source_file = "",
    prompts = { text = {}, dates = {} },
    now = os.time(),
  }

  capture.start(template, ctx)
  local bufnr = vim.api.nvim_get_current_buf()
  capture.finalise(bufnr)

  assert(vim.loop.fs_stat(nested_dir), "parent dir should have been auto-created")
  assert(vim.loop.fs_stat(target_file), "target file should have been auto-created")

  local lines = vim.fn.readfile(target_file)
  assert(#lines >= 1, "expected at least 1 line in auto-created file")
  local found = false
  for _, l in ipairs(lines) do
    if l == "* AutoCreated" then
      found = true
    end
  end
  assert(found, "expected '* AutoCreated' in file; got: " .. vim.inspect(lines))
end

vim.fn.delete(tmp, "rf")
io.write("capture default templates ok\n")
os.exit(0)
