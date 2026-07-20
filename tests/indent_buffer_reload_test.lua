-- Regression: a buffer reload must not silently kill the per-buffer
-- decoration attachments.
--
-- nvim drops every `nvim_buf_attach` listener that doesn't define an
-- `on_reload` callback when the buffer's contents are reloaded, firing
-- the listener's `on_detach` instead.  organ's indent / decoration /
-- entities modules all clear their per-buffer attach state from
-- `on_detach`, so after a reload they believed the buffer was detached
-- while `indent.enabled` was still true.  Every refresh path then
-- short-circuited: the extmarks placed before the reload were never
-- cleared and never recomputed, so they drifted with subsequent edits
-- and stacked up multiple-deep on a row.
--
-- Two reload paths reach this, both common with org files that an
-- external process (or organ itself) rewrites:
--   * autoread / `:checktime` picking up an on-disk change
--   * undoing back across the undo entry that reload recorded
--
-- Run via: nvim --headless -l tests/indent_buffer_reload_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

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
local decoration = require("organ.decoration")

local org_path = vim.fn.tempname() .. ".org"
vim.fn.writefile({ "* H", "Body" }, org_path)

vim.cmd("edit " .. org_path)
local b = vim.api.nvim_get_current_buf()
indent.attach(b)
decoration.attach(b)
vim.cmd("redraw")
vim.wait(20)

local function pad_at(row)
  local pads = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, indent._ns, 0, -1, { details = true })) do
    if m[2] == row then
      pads[#pads + 1] = #m[4].virt_text[1][1]
    end
  end
  if #pads > 1 then
    error(
      ("row %d carries %d indent marks (%s), expected at most one"):format(
        row,
        #pads,
        table.concat(pads, ",")
      )
    )
  end
  return pads[1] or 0
end

local function assert_pad(label, row, expected)
  local got = pad_at(row)
  if got ~= expected then
    error(("%s: row %d expected pad=%d, got pad=%d"):format(label, row, expected, got))
  end
end

-- Level-1 heading: row 0 = `* H` (no pad), row 1 = body (pad=2).
assert_pad("after attach", 0, 0)
assert_pad("after attach", 1, 2)

-- An external writer rewrites the file to a level-3 heading; nvim picks
-- the change up and reloads the buffer.
vim.fn.writefile({ "*** H", "Body", "More" }, org_path)
vim.cmd("checktime")
vim.cmd("redraw")
vim.wait(20)

assert(indent._attached[b], "indent must stay attached across a buffer reload")
assert(decoration._attached()[b], "decoration must stay attached across a buffer reload")

-- Level-3 heading: row 0 pad = (3-1)*2 = 4, body rows = 4 + 3 + 1 = 8.
assert_pad("after reload", 0, 4)
assert_pad("after reload", 1, 8)
assert_pad("after reload", 2, 8)

-- Undo back across the reload entry -- the other path into the same
-- reload machinery.  Buffer returns to the pre-reload level-1 state.
vim.cmd("silent! undo")
vim.cmd("redraw")
vim.wait(20)

local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
assert(lines[1] == "* H", "post-undo line 1 must be '* H', got: " .. tostring(lines[1]))

assert(indent._attached[b], "indent must stay attached across an undo-driven reload")
assert_pad("after undo across reload", 0, 0)
assert_pad("after undo across reload", 1, 2)

-- Redo forward again.
vim.cmd("silent! redo")
vim.cmd("redraw")
vim.wait(20)

assert_pad("after redo across reload", 0, 4)
assert_pad("after redo across reload", 1, 8)
assert_pad("after redo across reload", 2, 8)

io.write("indent buffer reload ok\n")
os.exit(0)
