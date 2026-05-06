-- :Org agenda dispatcher (Emacs-style chooser): no-args opens a select
-- menu with built-in entries (Week / Day / TODOs / Tags / Search /
-- Stuck) followed by user-configured named views and a default fallback.
-- Passing a name as arg bypasses the dispatcher.
--
-- Run via: nvim --headless -l tests/agenda_dispatcher_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  db_path = tmp .. "/a.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  agenda = {
    -- This file specifically tests the vim.ui.select dispatcher path;
    -- pin the style so the new "popup" default doesn't redirect us.
    dispatcher_style = "select",
    views = {
      daily = { from = "today", to = "today", types = { "scheduled" } },
      weekly = { from = "today", to = "+7d", types = { "scheduled", "deadline" } },
    },
  },
})

local cmd_mod = {
  OrgAgenda = require("organ.agenda").commands.agenda.fn,
}

-- 1. :Org agenda with no args → vim.ui.select called with builtin + user entries.
do
  local select_called = false
  local select_items
  local orig_select = vim.ui.select
  vim.ui.select = function(items, _opts, _cb)
    select_called = true
    select_items = items
  end

  cmd_mod.OrgAgenda({ args = "" })

  vim.ui.select = orig_select
  assert(select_called, "expected vim.ui.select to be called")
  assert(
    select_items and #select_items >= 6,
    "expected ≥ 6 choices (a/d/t/m/s/# builtins + 2 views + default); got "
      .. tostring(select_items and #select_items)
  )
  -- Built-in 'a' (Week agenda) always first.
  assert(
    select_items[1]:find("Week agenda", 1, true),
    "first choice should be 'a   Week agenda'; got " .. tostring(select_items[1])
  )
  -- Builtin 's' for search must be present.
  local has_search = false
  for _, l in ipairs(select_items) do
    if l:find("Search by string", 1, true) then
      has_search = true
    end
  end
  assert(has_search, "expected 'Search by string' choice")
  -- User views appear (indented).
  local has_daily = false
  for _, l in ipairs(select_items) do
    if l:match("daily$") then
      has_daily = true
    end
  end
  assert(has_daily, "user view 'daily' should appear in choices")
end

-- 2. Selecting "daily" from the dispatcher opens the daily view.
do
  local opened_view, opened_name
  local orig_open = require("organ.agenda").open
  require("organ.agenda").open = function(v, n)
    opened_view = v
    opened_name = n
  end

  local orig_select = vim.ui.select
  vim.ui.select = function(items, _opts, cb)
    -- Find the entry whose label ends with "daily".
    for i, l in ipairs(items) do
      if l:match("daily$") then
        cb(l, i)
        return
      end
    end
  end

  cmd_mod.OrgAgenda({ args = "" })

  vim.ui.select = orig_select
  require("organ.agenda").open = orig_open

  assert(opened_name == "daily", "expected 'daily'; got " .. tostring(opened_name))
  assert(
    opened_view and opened_view.types and opened_view.types[1] == "scheduled",
    "expected daily view config; got " .. vim.inspect(opened_view)
  )
end

-- 3. Selecting the "default" entry opens default_view.
do
  local opened_name
  local orig_open = require("organ.agenda").open
  require("organ.agenda").open = function(_v, n)
    opened_name = n
  end

  local orig_select = vim.ui.select
  vim.ui.select = function(items, _opts, cb)
    for i, l in ipairs(items) do
      if l:match("default$") then
        cb(l, i)
        return
      end
    end
  end

  cmd_mod.OrgAgenda({ args = "" })

  vim.ui.select = orig_select
  require("organ.agenda").open = orig_open

  assert(opened_name == "default_view", "expected 'default_view'; got " .. tostring(opened_name))
end

-- 4. Cancelling (nil choice) → agenda.open NOT called.
do
  local opened = false
  local orig_open = require("organ.agenda").open
  require("organ.agenda").open = function()
    opened = true
  end

  local orig_select = vim.ui.select
  vim.ui.select = function(_items, _opts, cb)
    cb(nil)
  end

  cmd_mod.OrgAgenda({ args = "" })

  vim.ui.select = orig_select
  require("organ.agenda").open = orig_open

  assert(not opened, "agenda.open should NOT be called on dispatcher cancel")
end

-- 5. :Org agenda daily (with arg) → direct open, no dispatcher.
do
  local select_called = false
  local opened_name
  local orig_select = vim.ui.select
  local orig_open = require("organ.agenda").open
  vim.ui.select = function()
    select_called = true
  end
  require("organ.agenda").open = function(_v, n)
    opened_name = n
  end

  cmd_mod.OrgAgenda({ args = "daily" })

  vim.ui.select = orig_select
  require("organ.agenda").open = orig_open

  assert(not select_called, ":Org agenda <name> should NOT open dispatcher")
  assert(opened_name == "daily", "expected 'daily'; got " .. tostring(opened_name))
end

vim.fn.delete(tmp, "rf")
io.write("agenda dispatcher ok\n")
os.exit(0)
