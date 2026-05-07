-- CONTENTS view's `za` toggle: revealing/re-concealing a heading's
-- body via `M.toggle_heading`.  Body is hidden via `conceal_lines`
-- extmarks (not folds), so toggling means removing/adding the
-- extmark for that heading's body range.  Reveal is subtree-deep:
-- sub-headings inside a revealed subtree also become visible.
--
-- Run via: nvim --headless -l tests/fold_contents_toggle_test.lua

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
  print("fold_contents_toggle_test: SKIP")
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

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* H1", -- 1
  "body of H1", -- 2
  "more H1", -- 3
  "** H2 sub", -- 4
  "body of H2", -- 5
  "* H3", -- 6
  "body of H3", -- 7
})
vim.bo[b].filetype = "org"
local TOTAL = 7
local HEADINGS = 3 -- H1, H2 sub, H3

contents.enter(b)

local function rendered_height()
  return vim.api.nvim_win_text_height(0, { start_row = 0, end_row = TOTAL - 1 }).all
end

check(
  "initial: rendered = heading count (only headings visible)",
  rendered_height() == HEADINGS,
  "got " .. rendered_height()
)

-- Toggle H1 (line 1) -> reveal H1's whole subtree (body + H2 sub + H2 body)
contents.toggle_heading(b, 1)
-- Expected visible rows: H1 + body H1 + more H1 + H2 sub + body H2 + H3 = 6
check(
  "after toggle H1: H1 subtree fully revealed",
  rendered_height() == 6,
  "got " .. rendered_height()
)

-- Toggle H1 again -> back to default
contents.toggle_heading(b, 1)
check(
  "toggle H1 again: back to heading-count",
  rendered_height() == HEADINGS,
  "got " .. rendered_height()
)

-- Toggle just H2 sub (line 4) -> reveal only its body
contents.toggle_heading(b, 4)
-- Expected: H1 + H2 sub + body H2 + H3 = 4
check(
  "after toggle H2 only: H2 body revealed, H1 + H3 still concealed",
  rendered_height() == 4,
  "got " .. rendered_height()
)

-- Reset state for the end-to-end check below.
contents.toggle_heading(b, 4) -- undo the H2 toggle from earlier
check(
  "back to clean state (only headings visible)",
  rendered_height() == HEADINGS,
  "got " .. rendered_height()
)

-- End-to-end via fold_action: simulate `za` keymap dispatch.  This
-- exercises the same path the user's keystroke takes -- buffer-local
-- mapping → fold_action → toggle_heading -- so a regression in the
-- mapping or the state[bufnr] lookup (the bufnr=0 desync that froze
-- za in TUI) is caught here too.
vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- cursor on H1
contents.fold_action("za")
check(
  'fold_action("za") on H1 reveals subtree',
  rendered_height() == 6,
  "got " .. rendered_height()
)
contents.fold_action("za")
check(
  'fold_action("za") again: re-conceals',
  rendered_height() == HEADINGS,
  "got " .. rendered_height()
)

-- zo (force-open) is unconditional: even on an already-revealed
-- heading it stays revealed; on a default-concealed heading it
-- reveals.  Idempotent.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
contents.fold_action("zo") -- H1 already concealed -> reveal
check('fold_action("zo") reveals H1 subtree', rendered_height() == 6, "got " .. rendered_height())
contents.fold_action("zo") -- already revealed, idempotent
check(
  'fold_action("zo") on already-open heading: no change',
  rendered_height() == 6,
  "got " .. rendered_height()
)

-- zc (force-close) is unconditional: re-conceals regardless of
-- prior state.
contents.fold_action("zc")
check(
  'fold_action("zc") re-conceals H1',
  rendered_height() == HEADINGS,
  "got " .. rendered_height()
)
contents.fold_action("zc") -- already concealed, idempotent
check(
  'fold_action("zc") on already-closed heading: no change',
  rendered_height() == HEADINGS,
  "got " .. rendered_height()
)

contents.leave(b)
local marks_after =
  vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_get_namespaces().organ_fold_contents, 0, -1, {})
check("leave clears all marks", #marks_after == 0, "got " .. #marks_after)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_contents_toggle_test: PASS")
os.exit(0)
