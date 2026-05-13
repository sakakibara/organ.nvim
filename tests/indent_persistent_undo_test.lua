-- Regression: undoing past the buffer's loaded state (traversing
-- persistent undo entries written by an earlier nvim session) must
-- leave pad widths matching the restored heading structure.
--
-- Persistent-undo traversal mutates the buffer through a path that
-- `nvim_buf_attach`'s on_lines didn't reliably fire for in some
-- sessions: changedtick advanced, the buffer text was reverted to
-- the prior-session state, but pads stayed at the pre-undo widths.
-- That left headlines and body rows visibly indented to the wrong
-- column.
--
-- The fix is to drive refresh from a decoration provider's on_buf
-- callback as well as from on_lines.  on_buf fires once per redraw
-- cycle for every mutation path nvim records in changedtick -- the
-- one universal "the buffer changed" signal -- so this test forces
-- a redraw after the undo to exercise that trigger and asserts that
-- the post-undo pads match the post-undo structure.
--
-- Run via: nvim --headless -l tests/indent_persistent_undo_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

-- Two-state persistent-undo fixture: write state A (level-2 heading),
-- save, rewrite to state B (level-1 heading), save.  The .undofile
-- on disk records the A->B transition.
local undo_dir = vim.fn.tempname()
vim.fn.mkdir(undo_dir, "p")
vim.opt.undodir = undo_dir
vim.opt.undofile = true

local org_path = vim.fn.tempname() .. ".org"
do
  vim.cmd("edit " .. org_path)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "** H", "Body" })
  vim.cmd("write")
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "* H" })
  vim.cmd("write")
  vim.cmd("bwipeout!") -- close so the next :edit re-reads from disk + undofile
end

-- Re-open in a "fresh" session.  Loaded state is state B (`* H`).
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

vim.cmd("edit " .. org_path)
local b = vim.api.nvim_get_current_buf()
indent.attach(b)
vim.wait(20)

local function pad_at(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, indent._ns, 0, -1, { details = true })) do
    if m[2] == row then
      return #m[4].virt_text[1][1]
    end
  end
  return 0
end

local function assert_pad(label, row, expected)
  local got = pad_at(row)
  if got ~= expected then
    error(("%s: row %d expected pad=%d, got pad=%d"):format(label, row, expected, got))
  end
end

local function assert_one_mark_per_row(label)
  local seen = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, indent._ns, 0, -1, {})) do
    if seen[m[2]] then
      error(("%s: row %d has more than one mark"):format(label, m[2]))
    end
    seen[m[2]] = true
  end
end

-- State B (level-1 heading): row 0 = `* H` (no pad), row 1 = body (pad=2).
assert_pad("after reopen", 0, 0)
assert_pad("after reopen", 1, 2)
assert_one_mark_per_row("after reopen")

-- Undo past loaded state -> back to state A (level-2 heading).  Force
-- a redraw to drive the decoration provider's on_buf callback (the
-- only trigger that fires for every path nvim mutates the buffer
-- through -- including this persistent-undo traversal).
vim.cmd("silent! undo")
vim.cmd("redraw")
vim.wait(20)

-- State A: row 0 = `** H` (pad=2), row 1 = body (pad=5).
local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
assert(lines[1] == "** H", "post-undo line 1 must be '** H', got: " .. tostring(lines[1]))
assert(lines[2] == "Body", "post-undo line 2 must be 'Body', got: " .. tostring(lines[2]))
assert_pad("after persistent undo", 0, 2)
assert_pad("after persistent undo", 1, 5)
assert_one_mark_per_row("after persistent undo")

-- Redo back to state B.  Pads must match the level-1 structure again.
vim.cmd("silent! redo")
vim.cmd("redraw")
vim.wait(20)
assert_pad("after redo", 0, 0)
assert_pad("after redo", 1, 2)
assert_one_mark_per_row("after redo")

io.write("indent persistent undo ok\n")
os.exit(0)
