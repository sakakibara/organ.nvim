-- The documented per-row action keys (`A` archive, `s` schedule, `D`
-- deadline) call into archive/schedule, which take an options table.
-- Driven here by real keypresses in a real agenda buffer, because the
-- keymap callback is where the argument shape is decided.
-- Run via: nvim --headless -l tests/agenda_row_action_keys_test.lua

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

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local src = org_dir .. "/a.org"
vim.fn.writefile({
  "* TODO alpha",
  "SCHEDULED: <2026-04-10 Fri>",
  "body",
}, src)

require("organ").setup({
  db_path = tmp .. "/keys.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
require("organ").scan_blocking(org_dir, 5000)

local agenda = require("organ.agenda")
local bufnr = agenda.open({ from = "2026-04-01", to = "2026-05-01" })
vim.api.nvim_win_set_buf(0, bufnr)

local function goto_row()
  for l = 1, vim.api.nvim_buf_line_count(bufnr) do
    if (vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""):match("alpha") then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return true
    end
  end
  return false
end

check("agenda has a row for the scheduled headline", goto_row())

-- `normal` (not `normal!`) honours the buffer-local map and turns the
-- handler's runtime error into a catchable Vim error.
local function press(key)
  vim.v.errmsg = ""
  local ok, err = pcall(vim.cmd, "normal " .. key)
  return ok and vim.v.errmsg == "", tostring(err) .. " errmsg=" .. tostring(vim.v.errmsg)
end

for _, key in ipairs({ "s", "D" }) do
  goto_row()
  local ok, detail = press(key)
  check(("agenda `%s` opens the picker without erroring"):format(key), ok, detail)
  -- Dismiss the calendar float the key opened.
  pcall(vim.cmd, "normal \27")
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  vim.api.nvim_win_set_buf(0, bufnr)
end

goto_row()
local ok_a, detail_a = press("A")
check("agenda `A` archives the row without erroring", ok_a, detail_a)
check(
  "agenda `A` removed the subtree from the source file",
  not vim.tbl_contains(vim.fn.readfile(src), "* TODO alpha"),
  table.concat(vim.fn.readfile(src), "\n")
)
check(
  "agenda `A` wrote the archive file",
  vim.fn.filereadable(src .. "_archive") == 1,
  src .. "_archive"
)

vim.fn.delete(tmp, "rf")
if fails > 0 then
  error(fails .. " checks failed")
end
print("\nAll checks passed.")
