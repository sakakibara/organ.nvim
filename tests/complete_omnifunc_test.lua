-- Omnifunc fallback for users without blink.cmp / nvim-cmp.
--
-- Two-phase contract per `:h complete-functions`:
--   * findstart=1 → byte column where the COMPLETED text begins
--     (just past the trigger prefix), or -3 if no trigger
--   * findstart=0 → list of completion items in nvim's expected shape
--
-- Run via: nvim --headless -l tests/complete_omnifunc_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

-- Seed an org file with two ID-bearing headlines so items_for("id")
-- has something to return.
local seed = org_dir .. "/seed.org"
local f = assert(io.open(seed, "w"))
f:write([[
* Alpha
  :PROPERTIES:
  :ID:       alpha-id
  :END:
* Beta
  :PROPERTIES:
  :ID:       beta-id
  :END:
]])
f:close()

require("organ").setup({
  db_path = tmp .. "/omni.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
require("organ").scan_blocking(org_dir, 5000)

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local complete = require("organ.complete")
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.bo[b].filetype = "org"

-- ---------------------------------------------------------------------------
-- (a) No trigger at cursor → findstart returns -3 (silent cancel).
-- ---------------------------------------------------------------------------
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "plain text" })
vim.api.nvim_win_set_cursor(0, { 1, 5 })
local col = complete.omnifunc(1, "")
check("no trigger: findstart returns -3", col == -3, "got " .. tostring(col))

-- ---------------------------------------------------------------------------
-- (b) `[[id:` trigger → findstart returns the column AFTER the prefix.
--     Then phase 2 returns the two seeded IDs.
-- ---------------------------------------------------------------------------
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "see [[id: " })
vim.api.nvim_win_set_cursor(0, { 1, #"see [[id:" })
col = complete.omnifunc(1, "")
check(
  "[[id: trigger: findstart points past the prefix",
  col == #"see [[id:",
  "got " .. tostring(col)
)

local items = complete.omnifunc(0, "")
check(
  "[[id: trigger: phase 2 returns ID candidates",
  #items >= 2,
  "got " .. tostring(#items) .. " items"
)
local words = {}
for _, it in ipairs(items) do
  words[it.word] = it
end
check("[[id: results contain alpha-id", words["alpha-id"] ~= nil)
check("[[id: results contain beta-id", words["beta-id"] ~= nil)
check(
  "[[id: items carry an [organ:id] menu hint",
  words["alpha-id"].menu == "[organ:id]",
  vim.inspect(words["alpha-id"])
)

-- ---------------------------------------------------------------------------
-- (c) ftplugin attach sets buffer-local omnifunc when complete.enabled.
-- ---------------------------------------------------------------------------
require("organ.ftplugin.core").attach(b)
local of = vim.api.nvim_get_option_value("omnifunc", { buf = b })
check(
  "ftplugin sets bufnr.omnifunc to organ.complete.omnifunc",
  of:find("organ.complete", 1, true) ~= nil,
  of
)

-- ---------------------------------------------------------------------------
-- (d) ftplugin does NOT clobber an existing omnifunc.
-- ---------------------------------------------------------------------------
local b2 = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b2)
vim.bo[b2].filetype = "org"
vim.api.nvim_set_option_value("omnifunc", "syntaxcomplete#Complete", { buf = b2 })
require("organ.ftplugin.core").attach(b2)
local kept = vim.api.nvim_get_option_value("omnifunc", { buf = b2 })
check(
  "ftplugin preserves a pre-existing omnifunc (LSP / user)",
  kept == "syntaxcomplete#Complete",
  kept
)

vim.api.nvim_buf_delete(b, { force = true })
vim.api.nvim_buf_delete(b2, { force = true })
vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("complete_omnifunc_test: PASS")
