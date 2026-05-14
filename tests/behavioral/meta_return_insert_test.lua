-- Behavioral test: M-RET fired from insert mode, with a user-installed
-- "strip trailing whitespace on InsertLeave" autocmd active.
--
-- Earlier the insert-mode keymap did stopinsert -> dispatch ->
-- startinsert!.  stopinsert is queued, so InsertLeave fired AFTER
-- dispatch had moved the cursor onto the freshly-inserted `* ` line --
-- a common "strip trailing whitespace" autocmd then ate the trailing
-- space, leaving `*` and breaking the heading.  This regression test
-- pins the fix: M-RET while a strip autocmd is active, followed by
-- typing a title, must produce a well-formed heading.
--
-- Run via: nvim --headless -l tests/behavioral/meta_return_insert_test.lua

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
local fixture = org_dir .. "/notes.org"
vim.fn.writefile({ "* foo" }, fixture)

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

vim.cmd("filetype plugin on")
vim.cmd("edit " .. fixture)
local bufnr = vim.api.nvim_get_current_buf()
-- Wait for ftplugin to attach the M-CR insert-mode keymap.
vim.wait(500, function()
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "i")) do
    if m.lhs == "<M-CR>" then
      return true
    end
  end
  return false
end)

-- Install the kind of autocmd that revealed the bug: strip trailing
-- whitespace on InsertLeave.  Common in user configs.
vim.api.nvim_create_autocmd("InsertLeave", {
  buffer = bufnr,
  callback = function()
    local line = vim.api.nvim_get_current_line()
    local stripped = line:gsub("%s+$", "")
    if stripped ~= line then
      vim.api.nvim_set_current_line(stripped)
    end
  end,
})

-- Cursor at end of "* foo" (col 5), enter insert mode, fire M-CR then
-- type "bar".  Expected: line 1 stays "* foo", line 2 becomes "* bar"
-- (the trailing space from `* ` is consumed by the typed title).
vim.api.nvim_win_set_cursor(0, { 1, 5 })
vim.cmd("startinsert")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<M-CR>bar", true, false, true), "x", false)
vim.wait(200)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check(
  "insert-mode M-RET with strip autocmd: original heading preserved",
  lines[1] == "* foo",
  vim.inspect(lines)
)
check(
  "insert-mode M-RET with strip autocmd: new heading typed cleanly",
  lines[2] == "* bar",
  vim.inspect(lines)
)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("meta_return_insert_test: PASS")
