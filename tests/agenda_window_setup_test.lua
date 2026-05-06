-- `agenda.window_setup` mirrors Emacs `org-agenda-window-setup`,
-- controlling how `:Org agenda` places its buffer relative to the
-- existing window layout: "reuse" (default), "only", "split-below",
-- "vsplit-right", "tab".
--
-- `agenda.restore_windows_after_quit` mirrors Emacs `-restore-
-- windows-after-quit`: snapshot the layout on open, replay it on `q`
-- close.
--
-- Run via: nvim --headless -l tests/agenda_window_setup_test.lua

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

-- Stub the query path so .open() is fast and deterministic.
package.loaded["organ.query"] = {
  agenda = function()
    return {}
  end,
  headlines = function()
    return {}
  end,
  files = function()
    return {}
  end,
  links = function()
    return {}
  end,
  get_by_id = function()
    return nil
  end,
  parse_date = function(s)
    return s
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  debounce_ms = 0,
})

local agenda = require("organ.agenda")

-- ---------------------------------------------------------------------------
-- (a) "reuse" — default.  Window count unchanged; current window
-- adopts the agenda buffer.
-- ---------------------------------------------------------------------------
local before = #vim.api.nvim_list_wins()
require("organ").config.agenda.window_setup = "reuse"
require("organ").config.agenda.sticky = false -- always fresh buffer
local b1 = agenda.open({ from = "today", to = "today", group_by = "none", types = { "scheduled" } })
local after = #vim.api.nvim_list_wins()
check(
  "reuse: window count unchanged",
  after == before,
  ("before=%d after=%d"):format(before, after)
)
check("reuse: agenda buffer is current", vim.api.nvim_get_current_buf() == b1)
vim.api.nvim_buf_delete(b1, { force = true })

-- ---------------------------------------------------------------------------
-- (b) "split-below" — adds a horizontal split.
-- ---------------------------------------------------------------------------
local before_b = #vim.api.nvim_list_wins()
require("organ").config.agenda.window_setup = "split-below"
local b2 = agenda.open({ from = "today", to = "today", group_by = "none", types = { "scheduled" } })
local after_b = #vim.api.nvim_list_wins()
check(
  "split-below: window count +1",
  after_b == before_b + 1,
  ("before=%d after=%d"):format(before_b, after_b)
)
vim.api.nvim_buf_delete(b2, { force = true })

-- ---------------------------------------------------------------------------
-- (c) "vsplit-right" — adds a vertical split.
-- ---------------------------------------------------------------------------
local before_v = #vim.api.nvim_list_wins()
require("organ").config.agenda.window_setup = "vsplit-right"
local b3 = agenda.open({ from = "today", to = "today", group_by = "none", types = { "scheduled" } })
local after_v = #vim.api.nvim_list_wins()
check(
  "vsplit-right: window count +1",
  after_v == before_v + 1,
  ("before=%d after=%d"):format(before_v, after_v)
)
vim.api.nvim_buf_delete(b3, { force = true })

-- ---------------------------------------------------------------------------
-- (d) "tab" — opens in a new tab.
-- ---------------------------------------------------------------------------
local tabs_before = #vim.api.nvim_list_tabpages()
require("organ").config.agenda.window_setup = "tab"
local b4 = agenda.open({ from = "today", to = "today", group_by = "none", types = { "scheduled" } })
local tabs_after = #vim.api.nvim_list_tabpages()
check(
  "tab: tab count +1",
  tabs_after == tabs_before + 1,
  ("before=%d after=%d"):format(tabs_before, tabs_after)
)
vim.cmd("tabclose")
vim.api.nvim_buf_delete(b4, { force = true })

-- ---------------------------------------------------------------------------
-- (e) restore_windows_after_quit — open with split, close with `q`,
-- expect the previous single-window layout to come back.
-- ---------------------------------------------------------------------------
require("organ").config.agenda.window_setup = "split-below"
require("organ").config.agenda.restore_windows_after_quit = true
local before_r = #vim.api.nvim_list_wins()
local b5 = agenda.open({ from = "today", to = "today", group_by = "none", types = { "scheduled" } })
local during_r = #vim.api.nvim_list_wins()
check("restore: opened split adds one window", during_r == before_r + 1)
-- Simulate the `q` keymap directly.
local restore_cmd = vim.b[b5].organ_agenda_restore_cmd
check(
  "restore: organ_agenda_restore_cmd buf var was set",
  type(restore_cmd) == "string" and restore_cmd ~= "",
  "got: " .. tostring(restore_cmd)
)
vim.api.nvim_buf_delete(b5, { force = true })
if restore_cmd then
  pcall(vim.cmd, restore_cmd)
end
local after_r = #vim.api.nvim_list_wins()
check(
  "restore: window count returns to baseline after q",
  after_r == before_r,
  ("before=%d after=%d"):format(before_r, after_r)
)

require("organ").config.agenda.window_setup = nil
require("organ").config.agenda.restore_windows_after_quit = nil
require("organ").config.agenda.sticky = nil

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_window_setup_test: PASS")
