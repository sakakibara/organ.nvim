-- Behavioral test: pick "Cycle TODO state" from the context action menu.
--
-- The action menu uses vim.ui.select; the test installs a stub that
-- auto-picks an action by title.  Verifies that picking "Cycle TODO
-- state" advances the underlying headline.
--
-- Exercises:
--   :Org actions -> organ.action_menu.open
--   actions_at_cursor (TS context detection on a headline)
--   vim.ui.select integration -> chosen.run()
--   organ.todo.cycle (the action body)
--
-- Run via: nvim --headless -l tests/behavioral/action_menu_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/inbox.org"
vim.fn.writefile({
  "#+TITLE: Inbox",
  "",
  "* TODO Pick me",
}, fixture)

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "WAIT", "|", "DONE" } },
})

vim.cmd("filetype plugin on")
vim.cmd("edit " .. fixture)
local buf = vim.api.nvim_get_current_buf()
vim.wait(500, function()
  return vim.bo[buf].filetype == "org"
end)
vim.api.nvim_win_set_cursor(0, { 3, 0 })

local function todo_state()
  local l = vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1] or ""
  return l:match("^%*+%s+(%S+)")
end
check("pre-state: line is TODO", todo_state() == "TODO", todo_state() or "(nil)")

-- Stub vim.ui.select to auto-pick "Cycle TODO state".  Captures the
-- offered actions for assertion, then fires the chosen one.
local saved_ui_select = vim.ui.select
local captured_titles = {}
local picked_title = nil
vim.ui.select = function(items, opts, on_choice)
  -- Only intercept the action-menu invocation; format_item gives the
  -- visible title.  Other vim.ui.select calls (e.g. nested "Set TODO
  -- from menu") fall through.
  local fmt = opts and opts.format_item
  if fmt then
    for _, it in ipairs(items) do
      captured_titles[#captured_titles + 1] = fmt(it)
    end
    for _, it in ipairs(items) do
      if fmt(it) == "Cycle TODO state" then
        picked_title = "Cycle TODO state"
        on_choice(it)
        return
      end
    end
  end
  -- Fallback: first item.
  on_choice(items[1])
end

vim.cmd("Org actions")

vim.ui.select = saved_ui_select

check(
  "action menu offered Cycle TODO state",
  vim.tbl_contains(captured_titles, "Cycle TODO state"),
  table.concat(captured_titles, "|")
)
check("stub picked Cycle TODO state", picked_title == "Cycle TODO state")
check("post: TODO advanced to NEXT", todo_state() == "NEXT", todo_state() or "(nil)")

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("action_menu_test: PASS")
