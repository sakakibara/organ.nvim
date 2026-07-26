-- Stub-picker test for the snacks find backend.  Plants a recording
-- fake for `_G.Snacks.picker.pick` and verifies the adapter:
--   * translates organ's item shape (file_path / line_start) into
--     snacks's expected shape (file / pos / text) without losing
--     organ's original fields
--   * registers the keymap table under `win.input.keys` with the
--     action names the user configured
--   * exposes the configured default action as `confirm` (snacks
--     routes <CR> through that name)
--   * closes the picker before invoking the action (so :edit lands
--     in the user's window, not the picker's)
-- Doesn't need snacks installed -- the fake stands in.
-- Run via: nvim --headless -l tests/find_backend_snacks_test.lua

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

-- Recording fake.  pick() captures every arg + lets the test drive
-- action callbacks afterwards (simulating user keypresses).
local recorded
local fake_pick = function(args)
  recorded = args
end
_G.Snacks = { picker = { pick = fake_pick } }
package.loaded["snacks.picker"] = _G.Snacks.picker

-- Reload the adapter so the captured Snacks reference is fresh.
package.loaded["organ.find.backends.snacks"] = nil
local backend = require("organ.find.backends.snacks")

-- 1. Item-shape translation: file_path -> file, line_start -> pos.
local items = {
  {
    title = "Buy groceries",
    file_path = "/x/inbox.org",
    line_start = 5,
    display = "Buy groceries",
  },
  {
    title = "Already-shaped",
    file = "/x/notes.org", -- has file: should not get clobbered
    pos = { 10, 0 },
    text = "Already-shaped already has text",
  },
}
local jumped_to
backend.pick(items, {
  title = "Find",
  default_action = "jump",
  actions = {
    jump = function(item)
      jumped_to = item
    end,
    split = function() end,
  },
  keymaps = { jump = "<CR>", split = "<C-s>" },
})

check("snacks fake captured", recorded ~= nil)
check(
  "items[1].file backfilled from file_path",
  items[1].file == "/x/inbox.org",
  tostring(items[1].file)
)
check(
  "items[1].pos backfilled from line_start (1-based)",
  items[1].pos and items[1].pos[1] == 6,
  vim.inspect(items[1].pos)
)
check(
  "items[1].text falls back to title when no match/display match",
  items[1].text == "Buy groceries"
)
check("items[2].file preserved when already set", items[2].file == "/x/notes.org")
check("items[2].pos preserved when already set", items[2].pos[1] == 10)

-- 2. Title forwarded.
check("title forwarded to snacks", recorded.title == "Find")

-- 3. Keymaps registered under win.input.keys with action names.
local keys = recorded.win and recorded.win.input and recorded.win.input.keys
check("win.input.keys present", type(keys) == "table")
check(
  "<CR> NOT in keys table (owned by `confirm` callback)",
  keys and keys["<CR>"] == nil,
  "<CR> bound via keys[]: " .. vim.inspect(keys and keys["<CR>"])
)
check("<C-s> mapped to 'split' action name", keys and keys["<C-s>"] and keys["<C-s>"][1] == "split")
check("top-level `confirm` callback is set (owns <CR>)", type(recorded.confirm) == "function")

-- Refile context: default_action = "refile_here" with multiple
-- actions claiming <CR> in the keymap table.  None should reach
-- the keys table; `confirm` is the only <CR> path.
recorded = nil
backend.pick(items, {
  title = "Refile to",
  default_action = "refile_here",
  actions = {
    jump = function() end,
    refile_here = function() end,
    split = function() end,
  },
  keymaps = { jump = "<CR>", refile_here = "<CR>", split = "<C-s>" },
})
local refile_keys = recorded.win and recorded.win.input and recorded.win.input.keys
check("refile: <CR> still NOT in keys table", refile_keys and refile_keys["<CR>"] == nil)
check(
  "refile: <C-s> bound to split (not <CR>-conflicted)",
  refile_keys and refile_keys["<C-s>"] and refile_keys["<C-s>"][1] == "split"
)

-- 4. actions.confirm aliases the default action.  snacks routes <CR>
--    through `confirm` on some versions; without this alias, pressing
--    Enter would silently fall back to snacks's built-in jump (which
--    doesn't know our item shape).
check("actions.confirm registered", type(recorded.actions.confirm) == "function")

-- 5. Action invocation: simulate <CR>; the adapter must close the
--    picker BEFORE running the action so :edit / etc. lands in the
--    user's window, not the picker window.  We reset and re-invoke
--    backend.pick with a NEW jump fn that observes the close state
--    at the moment it runs.
local close_called = false
local close_observed_in_action = nil
local jumped_in_action
backend.pick(items, {
  title = "Find",
  default_action = "jump",
  actions = {
    jump = function(item)
      close_observed_in_action = close_called
      jumped_in_action = item
    end,
  },
  keymaps = { jump = "<CR>" },
})
local fake_picker = {
  current = function()
    return items[1]
  end,
  close = function()
    close_called = true
  end,
}
recorded.actions.jump(fake_picker, items[1])
check("picker closed during action invocation path", close_called)
check("close happened BEFORE the user's action fn ran", close_observed_in_action == true)
check("default action received the picked item", jumped_in_action == items[1])

-- 6. Top-level `confirm` mirrors actions.confirm: close picker, then
--    invoke the default action.  snacks routes <CR> through this
--    callback in some versions.
close_called = false
close_observed_in_action = nil
local confirm_jumped_to
backend.pick(items, {
  title = "Find",
  default_action = "jump",
  actions = {
    jump = function(item)
      close_observed_in_action = close_called
      confirm_jumped_to = item
    end,
  },
  keymaps = { jump = "<CR>" },
})
local fake_picker2 = {
  current = function()
    return items[2]
  end,
  close = function()
    close_called = true
  end,
}
recorded.confirm(fake_picker2, items[2])
check("top-level confirm closes picker", close_called)
check("top-level confirm fires action AFTER close", close_observed_in_action == true)
check("top-level confirm passes the picked item to action", confirm_jumped_to == items[2])

-- 7. Format function: passes through display_segments when present,
--    falls back to single { display } pair otherwise.
local seg_item = { display = "fallback", display_segments = { { "[T]", "Type" }, { "title" } } }
local plain_item = { display = "just text" }
check(
  "format with segments returns segments as-is",
  recorded.format(seg_item) == seg_item.display_segments
)
local plain_fmt = recorded.format(plain_item)
check(
  "format without segments wraps display in { { display } }",
  type(plain_fmt) == "table" and plain_fmt[1] and plain_fmt[1][1] == "just text"
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("find_backend_snacks_test: PASS")
