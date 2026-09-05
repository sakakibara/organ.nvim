-- Validate that organ.setup() catches common config-shape mistakes early
-- with clear error / warning messages, instead of crashing later in some
-- opaque place.
--
-- Run via: nvim --headless -l tests/setup_validation_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Reset organ.config between cases.
local function fresh_setup(opts)
  package.loaded["organ"] = nil
  return require("organ").setup(opts or {})
end

-- 1. Bad agenda.views (a value that's not a table) → setup errors clearly.
do
  local ok, err = pcall(fresh_setup, {
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    agenda = { views = { broken = "not a table" } },
  })
  check(
    "agenda.views[broken]: setup raises a clear error",
    not ok and tostring(err):find("must be a table"),
    "got " .. tostring(err)
  )
end

-- 2. Bad agenda.views[name].blocks (not a list) → setup errors clearly.
do
  local ok, err = pcall(fresh_setup, {
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    agenda = { views = { x = { blocks = "not a list" } } },
  })
  check(
    "agenda.views[x].blocks: setup raises a clear error",
    not ok and tostring(err):find("must be a list"),
    "got " .. tostring(err)
  )
end

-- 3. Valid view passes.
do
  local ok, err = pcall(fresh_setup, {
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    agenda = { views = { ok = { blocks = { { source = "headlines" } } } } },
  })
  check("valid agenda view: setup succeeds", ok, "err: " .. tostring(err))
end

-- 3b. Assigning `agenda.views` REPLACES the default set (Rule 1).
do
  fresh_setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    agenda = { views = { mine = { types = { "any" }, group_by = "none" } } },
  })
  local keys = vim.tbl_keys(require("organ").config.agenda.views)
  table.sort(keys)
  check(
    "agenda.views: user assignment replaces the defaults",
    vim.deep_equal(keys, { "mine" }),
    "got " .. vim.inspect(keys)
  )
  -- A later setup() without `views` keeps the user's set.
  require("organ").setup({ notify = false })
  keys = vim.tbl_keys(require("organ").config.agenda.views)
  check(
    "agenda.views: setup() without views keeps the user's set",
    vim.deep_equal(keys, { "mine" }),
    "got " .. vim.inspect(keys)
  )
end

-- 4. todo.sequence missing `|` divider → warns but does NOT error.
do
  local notes = {}
  local saved = vim.notify
  vim.notify = function(msg, _level, _opts)
    notes[#notes + 1] = msg
  end

  local ok, err = pcall(fresh_setup, {
    db_path = vim.fn.tempname() .. ".db",
    notify = true,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    todo = { sequence = { "TODO", "DONE" } }, -- missing "|"
  })
  vim.wait(50) -- let scheduled warn fire
  vim.notify = saved
  check("todo.sequence missing `|`: setup still succeeds", ok, "err: " .. tostring(err))
  local saw_warn = false
  for _, m in ipairs(notes) do
    if m:find("`|` divider", 1, true) then
      saw_warn = true
    end
  end
  check("todo.sequence missing `|`: warning emitted", saw_warn, "notes: " .. vim.inspect(notes))
end

-- 5. org_dir nonexistent → warns at startup.
do
  local notes = {}
  local saved = vim.notify
  vim.notify = function(msg, _level, _opts)
    notes[#notes + 1] = msg
  end

  fresh_setup({
    db_path = vim.fn.tempname() .. ".db",
    org_dir = "/nonexistent/path/that/should/not/exist",
    notify = true,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  })
  vim.wait(50)
  vim.notify = saved
  local saw_warn = false
  for _, m in ipairs(notes) do
    if m:find("org_dir does not exist", 1, true) then
      saw_warn = true
    end
  end
  check("org_dir missing: warning emitted", saw_warn, "notes: " .. vim.inspect(notes))
end

-- 6. Capture template invalid shape: setup errors clearly (existing behavior).
do
  local ok, err = pcall(fresh_setup, {
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    capture = {
      templates = {
        { key = nil, name = "Bad", body = "* %?" }, -- key is required
      },
    },
  })
  check(
    "invalid capture template: setup raises a clear error",
    not ok and tostring(err):find("templates invalid"),
    "got " .. tostring(err)
  )
end

-- The bad-template check above leaves its template in the merged config.
require("organ").config.capture.templates = {}

-- Unknown keys are reported instead of silently swallowed.  `org_directory`
-- is nvim-orgmode's spelling of organ's `org_dir`; accepting it quietly sends
-- the indexer and the watcher at `~/org` instead of the user's directory.
do
  local warned = {}
  local notify = require("organ.notify")
  local orig_warn = notify.warn
  notify.warn = function(m)
    warned[#warned + 1] = m
  end
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    org_directory = vim.fn.tempname(),
    typo_key_xyz = 1,
    agenda = { unknown_agenda_key = true },
  })
  vim.wait(500, function()
    return #warned > 0
  end)
  notify.warn = orig_warn
  local msg = table.concat(warned, "\n")
  check("unknown top-level key is reported", msg:find("typo_key_xyz", 1, true) ~= nil, msg)
  check(
    "unknown NESTED key is reported",
    msg:find("agenda.unknown_agenda_key", 1, true) ~= nil,
    msg
  )
  check("near-miss names the real key", msg:find("did you mean `org_dir`", 1, true) ~= nil, msg)
end

-- A config made only of real keys warns about nothing, including the
-- user-named subtrees (`agenda.views`, `find.keymaps`) whose key set is not
-- organ's to police.
do
  local warned = {}
  local notify = require("organ.notify")
  local orig_warn = notify.warn
  notify.warn = function(m)
    warned[#warned + 1] = m
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    org_dir = dir,
    org_dirs = nil,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    agenda_files = { dir },
    watcher = { enabled = false },
    todo = { sequences = { { "TODO", "|", "DONE" } }, repeat_to_state = "TODO" },
    attach = { dir = "data" },
    modern = { preset = "all" },
    agenda = { views = { mine = { blocks = {} } }, now_override = "2026-05-04T12:00" },
    find = { keymaps = { jump = "<CR>", whatever_backend_key = "<C-x>" } },
    clock = { idle_threshold_minutes = 15 },
  })
  vim.wait(300, function()
    return #warned > 0
  end)
  notify.warn = orig_warn
  local msg = table.concat(warned, "\n")
  check("a valid config warns about nothing", not msg:find("unknown option", 1, true), msg)
end

-- A key whose default is nil has no entry in `organ.defaults`, so the
-- unknown-key check can only know about it from the optional list.  Keep the
-- two in step or setting a documented option starts warning about itself.
do
  local optional = require("organ")._optional_keys
  local missing = {}
  for line in io.lines(vim.fn.getcwd() .. "/lua/organ/defaults.lua") do
    local key = line:match("^%s+([%a_][%w_]*) = nil%f[%W]")
    if key and not optional[key] then
      missing[#missing + 1] = key
    end
  end
  check(
    "every nil-valued default is in the optional-key list",
    #missing == 0,
    "not listed: " .. table.concat(missing, ", ")
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("setup_validation_test: PASS")
