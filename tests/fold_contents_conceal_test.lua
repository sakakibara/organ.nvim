-- Default `fold.body_fold = false`: CONTENTS view hides body via the
-- `conceal_lines` extmark layer in `organ.fold.contents`, not via
-- foldlevel.  Verify enter/leave/refresh place and clear the marks
-- and bump conceallevel correctly.
--
-- Run via: nvim --headless -l tests/fold_contents_conceal_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  scan_on_startup = false,
  watcher = { enabled = false },
  notify = false,
})

local contents = require("organ.fold.contents")

if not contents.is_supported() then
  print("(skipped: nvim does not support `conceal_lines` extmark)")
  print("fold_contents_conceal_test: SKIP")
  os.exit(0)
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local NS = vim.api.nvim_get_namespaces().organ_fold_contents

local function extmark_count(buf)
  if not NS then
    return 0
  end
  return #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})
end

-- Buffer with three sections, each with body lines.
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* H1", -- 1
  "body of H1", -- 2
  "more body", -- 3
  "** H2", -- 4
  "body of H2", -- 5
  "* H3", -- 6
  "body of H3", -- 7
})
vim.bo[b].filetype = "org"
local HEADING_COUNT = 3
local TOTAL_LINES = 7

vim.wo.conceallevel = 0
vim.wo.concealcursor = ""
contents.enter(b)
check("active after enter", contents.is_active(b))
check("conceallevel bumped >= 2", vim.wo.conceallevel >= 2)
check(
  "concealcursor includes 'n' (cursor doesn't reveal body)",
  vim.wo.concealcursor:find("n") ~= nil
)
-- Each contiguous body range becomes one extmark; we have three (lines
-- 2-3, 5, 7).
local NS2 = vim.api.nvim_get_namespaces().organ_fold_contents
check("extmarks present", NS2 and extmark_count(b) > 0)

-- nvim_win_text_height is the easiest "screen height" probe — concealed
-- lines drop out of the rendered height.  ALL headings must remain
-- rendered, ONLY body lines hidden -- if the conceal range overshoots
-- by even one row, a heading vanishes and the count drops below
-- HEADING_COUNT.
local h_active = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = TOTAL_LINES - 1 }).all
check(
  "rendered height equals heading count (every heading visible, no more)",
  h_active == HEADING_COUNT,
  ("got rendered=%d, expected %d (TOTAL_LINES=%d)"):format(h_active, HEADING_COUNT, TOTAL_LINES)
)

-- Cursor on a body line MUST keep it concealed (Emacs CONTENTS).
vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- "body of H1"
vim.cmd("redraw")
local h_with_cursor_on_body =
  vim.api.nvim_win_text_height(0, { start_row = 0, end_row = TOTAL_LINES - 1 }).all
check(
  "cursor on body line stays concealed (height unchanged)",
  h_with_cursor_on_body == h_active,
  "got " .. tostring(h_with_cursor_on_body) .. " vs initial " .. tostring(h_active)
)

contents.leave(b)
check("inactive after leave", not contents.is_active(b))
check("conceallevel restored to 0", vim.wo.conceallevel == 0)
check("concealcursor restored to ''", vim.wo.concealcursor == "")
check("extmarks cleared", extmark_count(b) == 0)

local h_after = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = TOTAL_LINES - 1 }).all
check("full height restored after leave", h_after == TOTAL_LINES)

-- enter -> refresh after edit -> leave.
contents.enter(b)
vim.api.nvim_buf_set_lines(b, 7, 7, false, { "appended body" })
contents.refresh(b)
check("refresh keeps active", contents.is_active(b))
contents.leave(b)
check("leave clears", extmark_count(b) == 0)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_contents_conceal_test: PASS")
os.exit(0)
