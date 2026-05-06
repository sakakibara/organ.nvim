-- :Org todo command + tab-completion + opt-in FileType org keymap.
-- Run via: nvim --headless -l tests/orgtodo_command_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write("* TODO Heading\n  body\n")
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { log_done = false, keymaps = { cycle = "<LocalLeader>t" } },
})

assert(vim.api.nvim_get_commands({}).Org, ":Org dispatcher not registered")
assert(require("organ").cmd("todo"), "subcommand `todo` not registered on :Org")

vim.cmd("edit " .. vim.fn.fnameescape(fixture))
vim.bo.filetype = "org"
vim.api.nvim_win_set_cursor(0, { 1, 0 })

-- :Org todo with no arg → cycle (TODO → NEXT)
vim.cmd("Org todo")
assert(
  vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "* NEXT Heading",
  "after cycle: " .. vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
)

-- :Org todo DONE → set DONE
vim.cmd("Org todo DONE")
assert(
  vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "* DONE Heading",
  "after set DONE: " .. vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
)

-- :Org todo none → clear
vim.cmd("Org todo none")
assert(
  vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "* Heading",
  "after clear: " .. vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
)

-- Opt-in source keymap installed.
-- Neovim expands <LocalLeader> when storing lhs, so we compare against both
-- the literal string (in case of future API changes) and the expanded form.
local maps = vim.api.nvim_buf_get_keymap(0, "n")
local has_localleader_t = false
local expanded = vim.api.nvim_replace_termcodes("<LocalLeader>t", true, true, true)
for _, m in ipairs(maps) do
  if m.lhs == "<LocalLeader>t" or m.lhs == "<LocalLeader>t" or m.lhs == expanded then
    has_localleader_t = true
    break
  end
end
assert(has_localleader_t, "expected <LocalLeader>t to be mapped in *.org buffer")

vim.fn.delete(tmp, "rf")
io.write("orgtodo command ok\n")
os.exit(0)
