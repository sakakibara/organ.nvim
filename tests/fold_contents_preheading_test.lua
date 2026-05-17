-- Pre-first-heading lines (`#+title:`, `#+author:`, blank lines, etc.)
-- live outside the org outline and must remain visible under CONTENTS
-- view -- mirrors Emacs's behavior where `<S-Tab>` doesn't hide
-- content above the first level-1 headline.
--
-- Run via: nvim --headless -l tests/fold_contents_preheading_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  scan_on_startup = false,
  watcher = { enabled = false },
  notify = false,
})

local contents = require("organ.fold.contents")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
local lines = {
  "#+title: Notes", -- 1 pre-heading
  "#+author: Sho", -- 2 pre-heading
  "", -- 3 pre-heading (blank)
  "* H1", -- 4 heading
  "body of H1", -- 5 body (concealed)
  "* H2", -- 6 heading
  "body of H2", -- 7 body (concealed)
}
vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
vim.bo[b].filetype = "org"

contents.enter(b)

local h = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = #lines - 1 }).all
-- Expected visible: 3 pre-heading + 2 headings = 5.  Body of H1 (1)
-- and body of H2 (1) are concealed.  If pre-heading were concealed
-- the count would drop to 2.
check("CONTENTS keeps pre-heading lines visible", h == 5, ("got %d, expected 5"):format(h))

contents.leave(b)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_contents_preheading_test: PASS")
os.exit(0)
