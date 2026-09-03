-- Every place that raises `conceallevel` for an org window must set the
-- WINDOW-LOCAL value only.  Writing the global value leaks it into the
-- next buffer shown in that window (the ftplugin's BufWinLeave reset
-- `setlocal conceallevel<` copies the global back in) and into every
-- new window.
--
-- Run via: nvim --headless -l tests/modern_conceallevel_scope_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "* A1", "| a | b |", "|---+---|", "| 1 | 2 |" }, dir .. "/a.org")
vim.fn.writefile({ "* A1", "| a | b |", "|---+---|", "| 1 | 2 |" }, dir .. "/t.org")
vim.fn.writefile({ "plain text", "more" }, dir .. "/c.txt")

local function open_org(path)
  vim.cmd("edit " .. path)
  if vim.bo.filetype ~= "org" then
    vim.bo.filetype = "org"
  end
  vim.wait(100)
  return vim.api.nvim_get_current_buf()
end

local base = {
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
}

-- Render engine (bullets).
require("organ").setup(vim.tbl_extend("force", base, { modern = { bullets = true } }))
check("global conceallevel starts at 0", vim.go.conceallevel == 0, "got " .. vim.go.conceallevel)
open_org(dir .. "/a.org")
check(
  "engine: org window conceallevel is 2",
  vim.wo.conceallevel == 2,
  "got " .. vim.wo.conceallevel
)
check(
  "engine: global conceallevel untouched",
  vim.go.conceallevel == 0,
  "got " .. vim.go.conceallevel
)
vim.cmd("edit " .. dir .. "/c.txt")
vim.wait(50)
check(
  "engine: next buffer in the window gets conceallevel 0",
  vim.wo.conceallevel == 0,
  "got " .. vim.wo.conceallevel
)

-- Table conceal (its own attach path).
require("organ").setup({ modern = { bullets = false, table = true } })
open_org(dir .. "/t.org")
check(
  "table: org window conceallevel is 2",
  vim.wo.conceallevel == 2,
  "got " .. vim.wo.conceallevel
)
check(
  "table: global conceallevel untouched",
  vim.go.conceallevel == 0,
  "got " .. vim.go.conceallevel
)
vim.cmd("edit " .. dir .. "/c.txt")
vim.wait(50)
check(
  "table: next buffer in the window gets conceallevel 0",
  vim.wo.conceallevel == 0,
  "got " .. vim.wo.conceallevel
)

-- `:Org conceal toggle`.
require("organ").setup({ modern = { table = false } })
local b = open_org(dir .. "/a.org")
vim.api.nvim_set_option_value("conceallevel", 0, { win = 0, scope = "local" })
local conceal = require("organ.conceal")
local on = conceal.toggle(b)
check(
  "conceal.toggle: turns on",
  on == true and vim.wo.conceallevel == 2,
  "got " .. vim.wo.conceallevel
)
check(
  "conceal.toggle on: global conceallevel untouched",
  vim.go.conceallevel == 0,
  "got " .. vim.go.conceallevel
)
local off = conceal.toggle(b)
check(
  "conceal.toggle: turns off",
  off == false and vim.wo.conceallevel == 0,
  "got " .. vim.wo.conceallevel
)
check(
  "conceal.toggle off: global conceallevel untouched",
  vim.go.conceallevel == 0,
  "got " .. vim.go.conceallevel
)

vim.fn.delete(dir, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_conceallevel_scope_test: PASS")
os.exit(0)
