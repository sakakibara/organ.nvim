-- Behavioral test: pick a headline from :Org find and jump to it.
--
-- Uses the `_test_stub` find backend so the picker doesn't open a real
-- UI; the test inspects captured items and fires the default `jump`
-- action, then verifies the cursor landed on the chosen headline's line.
--
-- Exercises:
--   :Org find -> organ.find.commands.find
--   organ.find.pick (items build, source = "headlines")
--   standard_actions().jump (open file + cursor)
--
-- Run via: nvim --headless -l tests/behavioral/find_pick_test.lua

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

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

local notes_file = org_dir .. "/notes.org"
vim.fn.writefile({
  "#+TITLE: Notes",
  "",
  "* Apple",
  "* Banana",
  "* Cherry",
}, notes_file)

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
})
require("organ").scan_blocking(org_dir, 5000)

vim.cmd("filetype plugin on")
-- Start in a non-org buffer so the jump action's `edit` is meaningful.
vim.cmd("enew")

local stub = require("organ.find.backend")._test_stub
stub.last = nil
vim.cmd("Org find")

check("picker stub captured invocation", stub.last ~= nil)
check(
  "default action is jump",
  stub.last and stub.last.opts.default_action == "jump",
  stub.last and stub.last.opts.default_action or "(nil)"
)

-- Items should include the three fixture headlines.
local titles = {}
for _, it in ipairs(stub.last.items or {}) do
  titles[it.title] = it
end
check("items include Apple", titles.Apple ~= nil)
check("items include Banana", titles.Banana ~= nil)
check("items include Cherry", titles.Cherry ~= nil)

-- Fire jump on the Banana item.  Should open notes.org and place the
-- cursor on Banana's headline line.
local banana = titles.Banana
if banana then
  stub.last.opts.actions.jump(banana)
end

local cur_buf = vim.api.nvim_get_current_buf()
local cur_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cur_buf), ":p")
check("post: jump landed in notes.org", cur_path == vim.fn.fnamemodify(notes_file, ":p"), cur_path)

local cur_row = vim.api.nvim_win_get_cursor(0)[1]
local line = vim.api.nvim_buf_get_lines(cur_buf, cur_row - 1, cur_row, false)[1]
check(
  "post: cursor on a headline starting with `* Banana`",
  line and line:match("^%* Banana") ~= nil,
  "got: " .. tostring(line)
)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("find_pick_test: PASS")
