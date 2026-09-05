-- The debounced completion open reads the cursor, which only describes
-- the captured buffer while that buffer is still the current window's.
-- Firing after the user moved to another window must open nothing and
-- must not splice into (or move the cursor of) that unrelated window.
-- Run via: nvim --headless -l tests/complete_window_target_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  complete = { enabled = true, debounce_ms = 20 },
})

local complete = require("organ.complete")
local find = require("organ.find")

vim.opt.virtualedit = "onemore"

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local opened = {}
find.pick = function(opts)
  opened[#opened + 1] = opts
end

vim.cmd("silent! only")
local org_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(org_buf, 0, -1, false, { "* A", "line two", "see [[id:", "line four" })
vim.api.nvim_set_current_buf(org_buf)
vim.bo[org_buf].filetype = "org"
local org_win = vim.api.nvim_get_current_win()

vim.cmd("vsplit")
local plain_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(plain_buf)
vim.api.nvim_buf_set_lines(plain_buf, 0, -1, false, { "p1", "p2", "p3 plain text", "p4" })
local plain_win = vim.api.nvim_get_current_win()

-- Trigger typed in the org window, then the user leaves before the
-- debounce expires.
vim.api.nvim_set_current_win(org_win)
vim.api.nvim_win_set_cursor(org_win, { 3, 9 })
complete.schedule_open(org_buf)
vim.api.nvim_set_current_win(plain_win)
vim.api.nvim_win_set_cursor(plain_win, { 3, 9 })
vim.wait(200, function()
  return #opened > 0
end)

check("no picker opens from a window the buffer does not own", #opened == 0, "got " .. #opened)

-- The same guard must stop a selection accepted from the wrong window
-- from editing the buffer or moving that window's cursor.
local trigger = { kind = "id", prefix = "[[id:", prefix_col = 4, query = "" }
local plain_before = vim.api.nvim_buf_get_lines(plain_buf, 0, -1, false)
local notify = vim.notify
vim.notify = function() end
complete.apply_selection(
  org_buf,
  trigger,
  { kind = "id", display = "Alpha", insert_text = "abc-id", description = "Alpha" }
)
vim.notify = notify

check(
  "org buffer untouched by a selection applied from another window",
  vim.deep_equal(
    vim.api.nvim_buf_get_lines(org_buf, 0, -1, false),
    { "* A", "line two", "see [[id:", "line four" }
  ),
  vim.inspect(vim.api.nvim_buf_get_lines(org_buf, 0, -1, false))
)
check(
  "unrelated window's buffer untouched",
  vim.deep_equal(vim.api.nvim_buf_get_lines(plain_buf, 0, -1, false), plain_before)
)
check(
  "unrelated window's cursor not moved",
  vim.deep_equal(vim.api.nvim_win_get_cursor(plain_win), { 3, 9 }),
  vim.inspect(vim.api.nvim_win_get_cursor(plain_win))
)

-- Back in the owning window the trigger is still detected, so the guard
-- costs nothing on the normal path.
vim.api.nvim_set_current_win(org_win)
check("trigger still detected in the owning window", complete.trigger_at_cursor(org_buf) ~= nil)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
io.write("complete_window_target ok\n")
os.exit(0)
