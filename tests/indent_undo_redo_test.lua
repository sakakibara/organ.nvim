-- Regression: undo / redo must leave org-indent-mode pad widths
-- correctly matched to the post-undo / post-redo heading structure.
--
-- Earlier the indent walker pulled section ranges from a treesitter
-- tree that wasn't up-to-date when our on_lines callback ran in a
-- "fast" context (the LanguageTree's edit bookkeeping hadn't been
-- updated yet, so parser:parse() returned a tree consistent with the
-- PRE-undo line numbers).  Subsequent set_extmark calls landed pads
-- against the wrong rows, leaving some headlines / body rows with no
-- pad until a later refresh.
--
-- The fix walks buffer lines directly to find `^*+ ` headings, which
-- always reads the current buffer state regardless of fast-context
-- timing.  This test pins the invariant by exercising the exact
-- sequence (dd a heading, then undo) that broke it.
--
-- Run via: nvim --headless -l tests/indent_undo_redo_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  indent = { enabled = true, shift_per_level = 2 },
  modern = { bullets = false },
  stars = { hide = false },
})

local indent = require("organ.indent")

-- A real on-disk file path is required for `:undo` / `:redo` to do
-- anything; scratch buffers don't accumulate an undo tree from API
-- writes the same way.
local tmp = vim.fn.tempname() .. ".org"
vim.fn.writefile({
  "* H1", -- row 0
  "Body H1", -- row 1
  "** H2", -- row 2
  "Body H2", -- row 3
}, tmp)
vim.cmd("edit " .. tmp)
local b = vim.api.nvim_get_current_buf()
vim.bo[b].filetype = "org"
indent.attach(b)
vim.wait(20)

local function pads()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, indent._ns, 0, -1, { details = true })) do
    out[m[2]] = #m[4].virt_text[1][1]
  end
  return out
end

local function assert_pad(label, row, expected)
  local p = pads()[row]
  local got = p or 0
  if got ~= expected then
    error(("%s: row %d expected pad=%d, got pad=%d"):format(label, row, expected, got))
  end
end

-- Initial layout: H1(L1) / body(L1) / H2(L2) / body(L2).
assert_pad("initial", 0, 0) -- L1 heading: no pad
assert_pad("initial", 1, 2) -- L1 body: pad=2
assert_pad("initial", 2, 2) -- L2 heading: pad=2
assert_pad("initial", 3, 5) -- L2 body: pad=5

-- `dd` row 3 (the `** H2` heading line).  Body H2 (formerly row 3)
-- becomes row 2, now under H1's section (level 1, body pad = 2).
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.cmd("normal! dd")
vim.wait(20)
assert_pad("after dd", 0, 0) -- L1 heading: no pad
assert_pad("after dd", 1, 2) -- L1 body: pad=2
assert_pad("after dd", 2, 2) -- former L2 body, now under H1: pad=2

-- `undo` brings H2 back.  Row 3 must regain pad=5 (L2 body).  Without
-- the fix the indent walker saw a stale tree and never re-padded row 3.
vim.cmd("undo")
vim.wait(20)
assert_pad("after undo", 0, 0)
assert_pad("after undo", 1, 2)
assert_pad("after undo", 2, 2) -- L2 heading
assert_pad("after undo", 3, 5) -- L2 body -- the row that previously regressed

-- `redo` removes H2 again.
vim.cmd("redo")
vim.wait(20)
assert_pad("after redo", 0, 0)
assert_pad("after redo", 1, 2)
assert_pad("after redo", 2, 2)
-- After redo the buffer is back to 3 rows; row 3 must have no mark.
do
  local row3 = pads()[3]
  if row3 ~= nil then
    error("after redo: row 3 should have no pad mark (buffer is 3 rows), got pad=" .. row3)
  end
end

-- Repeat undo to make sure the bug doesn't re-emerge on a second
-- undo / redo cycle.
vim.cmd("undo")
vim.wait(20)
assert_pad("after second undo", 3, 5)

io.write("indent undo redo ok\n")
os.exit(0)
