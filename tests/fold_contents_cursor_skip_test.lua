-- CONTENTS view installs a CursorMoved redirector so any motion
-- (j, k, arrows, gj, gk, search, gg, G, custom mappings, mouse, ...)
-- that lands on a concealed body line bounces to the nearest visible
-- line in the direction of travel.  Verifies the autocmd path
-- without relying on any specific keymap.
--
-- Run via: nvim --headless -l tests/fold_contents_cursor_skip_test.lua

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

-- Buffer:
--   1: * H1
--   2: body
--   3: more
--   4: ** H2
--   5: body
--   6: * H3
--   7: body
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* H1",
  "body of H1",
  "more body",
  "** H2",
  "body of H2",
  "* H3",
  "body of H3",
})
vim.bo[b].filetype = "org"

contents.enter(b)

local function set_cursor(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  -- Trigger CursorMoved manually since headless doesn't always fire it.
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = b })
end

-- Position cursor on H1, simulate `j`-like motion via a direct cursor
-- set to the next-row body, see autocmd bounces forward to H2.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = b })
check("starts on H1", vim.fn.line(".") == 1)

-- Move down one row (lands on row 2 = body).  Autocmd should redirect
-- forward to row 4 (H2), the next non-concealed line.
set_cursor(2)
check(
  "forward-direction redirect skips body to H2",
  vim.fn.line(".") == 4,
  "got " .. vim.fn.line(".")
)

-- Now move down again (lands on row 5 = body of H2).  Should redirect
-- forward to row 6 (H3).
set_cursor(5)
check("forward redirect again -> H3", vim.fn.line(".") == 6, "got " .. vim.fn.line("."))

-- Now move BACKWARDS into body (lands on row 5 again, but coming from
-- row 6 the direction is backward, so should go to row 4 = H2).
set_cursor(5)
check("backward redirect lands on H2", vim.fn.line(".") == 4, "got " .. vim.fn.line("."))

-- gg-style large jump: cursor jumps to row 7 (body of H3, last line).
-- Forward direction from H2 (row 4); next visible after 7 doesn't
-- exist, fall back to prev visible -> H3 (row 6).
set_cursor(7)
check(
  "jump past last visible falls back to prev visible (H3)",
  vim.fn.line(".") == 6,
  "got " .. vim.fn.line(".")
)

contents.leave(b)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_contents_cursor_skip_test: PASS")
os.exit(0)
