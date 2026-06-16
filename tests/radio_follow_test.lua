-- link.follow falls back to radio: jump from an occurrence to its def.
-- Run via: nvim --headless -l tests/radio_follow_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "Define <<<my phrase>>> here.",
  "Jump from my phrase now.",
})
vim.bo[b].filetype = "org"
vim.api.nvim_set_current_buf(b)
vim.api.nvim_win_set_cursor(0, { 2, 11 })
require("organ.link").follow({ bufnr = b })
local cur = vim.api.nvim_win_get_cursor(0)
check(cur[1] == 1, "follow: cursor jumped to the definition line")

print("ALL PASS: radio_follow")
