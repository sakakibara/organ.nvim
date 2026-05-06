-- Behavioral test for the vim_ui_select find backend (the always-
-- available fallback used when no picker plugin is loaded).  Stubs
-- vim.ui.select so we can verify the adapter's call shape without
-- a real UI.
-- Run via: nvim --headless -l tests/find_backend_vim_ui_select_test.lua

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

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local backend = require("organ.find.backends.vim_ui_select")

-- ---------------------------------------------------------------------------
-- 1. Empty items → vim.ui.select NOT called (early return).
-- ---------------------------------------------------------------------------
local select_called = false
local saved = vim.ui.select
vim.ui.select = function()
  select_called = true
end

backend.pick({}, { default_action = "jump" })
check("empty items: vim.ui.select skipped", not select_called)

backend.pick(nil, { default_action = "jump" })
check("nil items: vim.ui.select skipped", not select_called)

-- ---------------------------------------------------------------------------
-- 2. Items + format_item: each item formatted via display > match >
--    title > text > file fallback chain.
-- ---------------------------------------------------------------------------
local captured = nil
vim.ui.select = function(items, opts, on_choice)
  captured = { items = items, opts = opts, on_choice = on_choice }
end

local items = {
  { display = "First", title = "ignored when display present" },
  { match = "Second" },
  { title = "Third" },
  { text = "Fourth" },
  { file = "fifth.org" },
  { id = "no display fields" }, -- falls back to tostring
}

backend.pick(items, { prompt = "Pick:", default_action = "jump", actions = {} })

check("vim.ui.select called", captured ~= nil)
check("items passed through", captured.items == items)
check("prompt forwarded", captured.opts.prompt == "Pick:")
check("format: display wins", captured.opts.format_item(items[1]) == "First")
check("format: match falls back", captured.opts.format_item(items[2]) == "Second")
check("format: title falls back", captured.opts.format_item(items[3]) == "Third")
check("format: text falls back", captured.opts.format_item(items[4]) == "Fourth")
check("format: file falls back", captured.opts.format_item(items[5]) == "fifth.org")
check(
  "format: tostring fallback for empty item",
  type(captured.opts.format_item(items[6])) == "string"
)

-- ---------------------------------------------------------------------------
-- 3. on_choice: invokes the configured default_action with the
--    picked item.
-- ---------------------------------------------------------------------------
local jumped_to = nil
local picked_item = { title = "picked" }
backend.pick({ picked_item }, {
  default_action = "jump",
  actions = {
    jump = function(item)
      jumped_to = item
    end,
    split = function()
      jumped_to = "WRONG ACTION"
    end,
  },
})
captured.on_choice(picked_item)
check("default_action 'jump' invoked", jumped_to == picked_item)

-- ---------------------------------------------------------------------------
-- 4. on_choice with nil (user cancelled): action NOT invoked.
-- ---------------------------------------------------------------------------
local action_fired = false
backend.pick({ picked_item }, {
  default_action = "jump",
  actions = {
    jump = function()
      action_fired = true
    end,
  },
})
captured.on_choice(nil)
check("cancelled pick: action not invoked", not action_fired)

-- ---------------------------------------------------------------------------
-- 5. Unknown default_action: pick still completes without error.
-- ---------------------------------------------------------------------------
backend.pick({ picked_item }, {
  default_action = "no_such_action",
  actions = { jump = function() end },
})
local ok = pcall(captured.on_choice, picked_item)
check("missing action: no error thrown", ok)

vim.ui.select = saved

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("find_backend_vim_ui_select_test: PASS")
