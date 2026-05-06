-- Sticky agenda buffers: opening the same view twice reuses the
-- existing buffer; opening a different view creates a fresh one.
-- Run via: nvim --headless -l tests/agenda_sticky_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

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
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local agenda = require("organ.agenda")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- 1. Two opens of the same view → same buffer.
local b1 = agenda.open({ from = "today", to = "today", types = { "scheduled" } }, "today_view")
local b2 = agenda.open({ from = "today", to = "today", types = { "scheduled" } }, "today_view")
check(
  "same view name reuses buffer",
  b1 == b2,
  "got bufnrs " .. tostring(b1) .. " and " .. tostring(b2)
)

-- 2. Different view name → different buffer.
local b3 = agenda.open({ from = "today", to = "+6d", types = { "scheduled" } }, "week_view")
check(
  "different view name creates a new buffer",
  b3 ~= b1,
  "got bufnrs " .. tostring(b1) .. " and " .. tostring(b3)
)

-- 3. Wiping the buffer drops it from the sticky registry; reopen makes a new one.
vim.api.nvim_buf_delete(b1, { force = true })
local b4 = agenda.open({ from = "today", to = "today", types = { "scheduled" } }, "today_view")
check("wiped sticky entry is replaced (new bufnr issued)", b4 ~= b1)

-- 4. Sticky registry contains the live bufnrs and not the wiped one.
local seen_b4 = false
for _, v in pairs(agenda._sticky) do
  if v == b1 then
    check("sticky registry no longer points to wiped bufnr", false)
  end
  if v == b4 then
    seen_b4 = true
  end
end
check("sticky registry contains the new bufnr", seen_b4)

-- 5. agenda.sticky = false disables: every open creates a fresh buffer.
require("organ").config.agenda.sticky = false
agenda._sticky = {}
local b5 =
  agenda.open({ from = "today", to = "today", types = { "scheduled" } }, "today_view_disabled")
local b6 =
  agenda.open({ from = "today", to = "today", types = { "scheduled" } }, "today_view_disabled")
check(
  "sticky=false yields fresh buffer per open",
  b5 ~= b6,
  "got bufnrs " .. tostring(b5) .. " and " .. tostring(b6)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_sticky_test: PASS")
