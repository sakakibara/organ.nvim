-- Behavioral test: cycling TODO state from a keymap.
--
-- Opens a real org file, places the cursor on a TODO headline,
-- fires `<M-t>` (the configured cycle binding), and asserts the
-- headline state advanced.  Then fires it again to verify the full
-- sequence cycles back around.  Exercises:
--   plugin/organ.lua (filetype mapping)
--   ftplugin/org.lua (parser start, keymap install)
--   keymaps.lua (rhs string → vim.cmd dispatch)
--   :Org dispatcher (subcommand resolution)
--   organ.todo.commands.todo (the action)
--   organ.todo.cycle (the underlying state transition)
--   buffer mutation visible in nvim_buf_get_lines
--
-- Run via: nvim --headless -l tests/behavioral/todo_cycle_test.lua

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
local fixture = org_dir .. "/inbox.org"
vim.fn.writefile({
  "#+TITLE: Inbox",
  "",
  "* TODO First task",
  "* NEXT Second task",
  "* DONE Closed task",
}, fixture)

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "WAIT", "PROJ", "|", "DONE", "CANCELLED" } },
})

-- Headless nvim leaves filetype detection off by default — `:edit foo.org`
-- won't fire ftplugin/org.lua without this.  Turn it on so buffer-local
-- keymaps install.
vim.cmd("filetype plugin on")
vim.cmd("edit " .. fixture)
local bufnr = vim.api.nvim_get_current_buf()
-- Wait for ftplugin to attach the keymap.
vim.wait(500, function()
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == "<M-t>" then
      return true
    end
  end
  return false
end)

local function todo_state_at(line)
  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  return text:match("^%*+%s+(%S+)")
end

check("fixture line 3 starts as TODO", todo_state_at(3) == "TODO", todo_state_at(3))

-- Move cursor to the TODO headline and fire <M-t>.
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<M-t>", true, false, true), "x", false)
check("after one <M-t>: TODO advanced to NEXT", todo_state_at(3) == "NEXT", todo_state_at(3))

vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<M-t>", true, false, true), "x", false)
check("after two <M-t>: NEXT advanced to WAIT", todo_state_at(3) == "WAIT", todo_state_at(3))

-- Cycling through the rest of the sequence: WAIT → PROJ → DONE → CANCELLED → (none) → TODO.
for i = 1, 5 do
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<M-t>", true, false, true), "x", false)
end
check(
  "after seven total <M-t>: cycle returned to TODO",
  todo_state_at(3) == "TODO",
  todo_state_at(3)
)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("todo_cycle_test: PASS")
