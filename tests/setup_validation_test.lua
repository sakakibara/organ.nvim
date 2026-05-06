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

-- ---------------------------------------------------------------------------
-- 1. Bad agenda.views (a value that's not a table) → setup errors clearly.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 2. Bad agenda.views[name].blocks (not a list) → setup errors clearly.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 3. Valid view passes.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 4. todo.sequence missing `|` divider → warns but does NOT error.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 5. org_dir nonexistent → warns at startup.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 6. Capture template invalid shape: setup errors clearly (existing behavior).
-- ---------------------------------------------------------------------------
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

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("setup_validation_test: PASS")
