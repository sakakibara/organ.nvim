-- Default agenda dispatcher style ("popup"): single-keystroke menu in
-- a floating window, blocks on getcharstr until a key is pressed.
-- Works under any UI plugin (noice / snacks / native cmdline) since
-- it doesn't go through nvim_echo or vim.notify -- those routes get
-- intercepted and the menu fades.
--
-- Run via: nvim --headless -l tests/agenda_dispatcher_popup_test.lua

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
  -- Confirm the popup IS the default (config doesn't set it).
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local agenda = require("organ.agenda")

check(
  "default dispatcher_style is 'popup'",
  (require("organ").config.agenda or {}).dispatcher_style == "popup"
)

-- _show_popup_menu is the helper that opens the float and blocks on
-- getcharstr.  Stub getcharstr to return a fixed key, then assert
-- the helper returns the matching entry's action.
do
  local entries = {
    {
      "a",
      "Week agenda",
      function()
        return "WEEK"
      end,
    },
    {
      "d",
      "Day agenda",
      function()
        return "DAY"
      end,
    },
    {
      "#",
      "Stuck projects",
      function()
        return "STUCK"
      end,
    },
  }

  local saved = vim.fn.getcharstr
  vim.fn.getcharstr = function()
    return "d"
  end
  local action, key = agenda._show_popup_menu(entries, "Test")
  vim.fn.getcharstr = saved

  check("popup returns the matching action for 'd'", type(action) == "function")
  check("popup reports the pressed key", key == "d")
  if type(action) == "function" then
    check("matching action is the day-view action", action() == "DAY")
  end
end

-- Cancel via Esc returns nil action.
do
  local saved = vim.fn.getcharstr
  vim.fn.getcharstr = function()
    return "\27"
  end
  local action, key = agenda._show_popup_menu({ { "a", "Week", function() end } }, "Test")
  vim.fn.getcharstr = saved
  check("popup returns nil action on <Esc>", action == nil)
  check("popup still reports the cancel key", key == "\27")
end

-- Unmapped key: action nil, key reflects what was pressed.
do
  local saved = vim.fn.getcharstr
  vim.fn.getcharstr = function()
    return "z"
  end
  local action, key = agenda._show_popup_menu({ { "a", "Week", function() end } }, "Test")
  vim.fn.getcharstr = saved
  check("popup returns nil action on unmapped key", action == nil)
  check("popup reports the unmapped key", key == "z")
end

-- Popup creates and tears down the floating buffer/window cleanly --
-- after a pick, no extra buffer should leak.
do
  local pre = #vim.api.nvim_list_bufs()
  local saved = vim.fn.getcharstr
  vim.fn.getcharstr = function()
    return "a"
  end
  agenda._show_popup_menu({ { "a", "Week", function() end } }, "Cleanup")
  vim.fn.getcharstr = saved
  local post = #vim.api.nvim_list_bufs()
  check(
    "no extra buffers after popup teardown",
    post == pre,
    string.format("pre=%d post=%d", pre, post)
  )
end

-- End-to-end: M.dispatch() honors the popup default and runs the
-- chosen entry's action.  Stub getcharstr to pick the day view; spy
-- on agenda.day to confirm it fired.
do
  local fired = false
  local saved_day = agenda.day
  agenda.day = function()
    fired = true
  end
  local saved_get = vim.fn.getcharstr
  vim.fn.getcharstr = function()
    return "d"
  end

  agenda.dispatch()

  vim.fn.getcharstr = saved_get
  agenda.day = saved_day
  check("dispatch() with popup style fires the picked entry's action", fired)
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_dispatcher_popup_test: PASS")
