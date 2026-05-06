-- inline_edit fallback chain when the cursor isn't on an org element:
--   1. user-supplied callback (`fallback_increment`)
--   2. dial.nvim (auto-detected via pcall(require, "dial.map"))
--   3. native <C-a> / <C-x>
--
-- Run via: nvim --headless -l tests/inline_edit_dial_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = vim.fn.tempname(),
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
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

local inline_edit = require("organ.inline_edit")

-- Set up a buffer with a plain integer (no org element at cursor).
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(b)
vim.bo[b].filetype = "org"
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "5" })

-- ---------------------------------------------------------------------------
-- (a) No dial, no user callback → native <C-a> increments to 6.
-- ---------------------------------------------------------------------------
require("organ").config.inline_edit.fallback_increment = nil
require("organ").config.inline_edit.fallback_decrement = nil
package.loaded["dial.map"] = nil

vim.api.nvim_win_set_cursor(0, { 1, 0 })
inline_edit.dispatch("inc")
check("native fallback: 5 → 6", vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "6")

-- ---------------------------------------------------------------------------
-- (b) dial.nvim mocked: dispatch routes through dial.map.inc_normal().
-- ---------------------------------------------------------------------------
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "5" })
local dial_calls = { inc = 0, dec = 0 }
package.loaded["dial.map"] = {
  inc_normal = function()
    dial_calls.inc = dial_calls.inc + 1
    return "" -- empty rhs so vim.cmd("normal! ") is a no-op
  end,
  dec_normal = function()
    dial_calls.dec = dial_calls.dec + 1
    return ""
  end,
}

vim.api.nvim_win_set_cursor(0, { 1, 0 })
inline_edit.dispatch("inc")
check("dial.nvim auto-detected: inc_normal() called", dial_calls.inc == 1)
inline_edit.dispatch("dec")
check("dial.nvim auto-detected: dec_normal() called", dial_calls.dec == 1)

-- ---------------------------------------------------------------------------
-- (c) `use_dial = false` opts out even when dial is installed.
-- ---------------------------------------------------------------------------
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "5" })
require("organ").config.inline_edit.use_dial = false
local dial_baseline = dial_calls.inc
inline_edit.dispatch("inc")
check("use_dial = false: dial NOT called", dial_calls.inc == dial_baseline)
check(
  "use_dial = false: native <C-a> ran (5 → 6)",
  vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "6"
)

-- ---------------------------------------------------------------------------
-- (d) User callback wins over dial when both are configured.
-- ---------------------------------------------------------------------------
require("organ").config.inline_edit.use_dial = true
local user_calls = 0
require("organ").config.inline_edit.fallback_increment = function()
  user_calls = user_calls + 1
end
inline_edit.dispatch("inc")
check("user callback wins over dial", user_calls == 1 and dial_calls.inc == dial_baseline)

-- Cleanup.
package.loaded["dial.map"] = nil
require("organ").config.inline_edit.fallback_increment = nil
require("organ").config.inline_edit.fallback_decrement = nil
require("organ").config.inline_edit.use_dial = true
vim.api.nvim_buf_delete(b, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("inline_edit_dial_test: PASS")
