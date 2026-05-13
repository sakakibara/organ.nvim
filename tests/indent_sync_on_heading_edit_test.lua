-- Regression: a promote / demote operation must leave indent extmarks
-- with their NEW pad widths visible immediately -- BEFORE returning to
-- nvim's event loop.  When indent's on_lines callback only schedules a
-- deferred refresh, nvim paints one frame with stale pad widths (the
-- buffer text is at the new level but the pads still match the old),
-- which the user perceives as a flush-left flicker on subtree
-- promote / demote (`<M-h>` / `<M-l>`).
--
-- Run via: nvim --headless -l tests/indent_sync_on_heading_edit_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  indent = { shift_per_level = 2 },
  modern = { bullets = false },
  stars = { hide = false },
})

local indent = require("organ.indent")
local structure = require("organ.structure")

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* H1", -- row 0
  "Body H1", -- row 1
  "** H2", -- row 2
  "Body H2", -- row 3
})
vim.bo[b].filetype = "org"
vim.api.nvim_set_current_buf(b)
indent.attach(b)

-- Snapshot the extmark widths after a structure op WITHOUT vim.wait()
-- and WITHOUT calling indent.refresh.  Captures the state nvim would
-- have at its next redraw, which is what the user sees.
local function widths_after_op(op)
  op()
  local marks = vim.api.nvim_buf_get_extmarks(b, indent._ns, 0, -1, { details = true })
  local by_row = {}
  for _, m in ipairs(marks) do
    -- m[2] = row (0-based); m[4].virt_text[1][1] = pad string.
    by_row[m[2]] = #m[4].virt_text[1][1]
  end
  return by_row
end

-- Sanity: starting widths reflect the level-1 / level-2 layout.
do
  local w = widths_after_op(function() end)
  assert(w[0] == nil or w[0] == 0, "pre: row 0 (L1 heading) pad must be 0, got " .. tostring(w[0]))
  assert(w[1] == 2, "pre: row 1 (L1 body) pad must be 2, got " .. tostring(w[1]))
  assert(w[2] == 2, "pre: row 2 (L2 heading) pad must be 2, got " .. tostring(w[2]))
  assert(w[3] == 5, "pre: row 3 (L2 body) pad must be 5, got " .. tostring(w[3]))
end

-- demote_subtree on H1: H1 L1 -> L2, H2 L2 -> L3.
-- Expected new widths: row 0 = 2, row 1 = 5, row 2 = 4, row 3 = 8.
do
  local w = widths_after_op(function()
    structure.demote_subtree({ bufnr = b, line = 1 })
  end)
  assert(w[0] == 2, "post-demote: row 0 (L2 heading) pad must be 2, got " .. tostring(w[0]))
  assert(w[1] == 5, "post-demote: row 1 (L2 body) pad must be 5, got " .. tostring(w[1]))
  assert(w[2] == 4, "post-demote: row 2 (L3 heading) pad must be 4, got " .. tostring(w[2]))
  assert(w[3] == 8, "post-demote: row 3 (L3 body) pad must be 8, got " .. tostring(w[3]))
end

-- promote_subtree on H1 back to L1: pads return to initial widths.
do
  local w = widths_after_op(function()
    structure.promote_subtree({ bufnr = b, line = 1 })
  end)
  assert(w[0] == nil or w[0] == 0, "post-promote: row 0 (L1) pad must be 0, got " .. tostring(w[0]))
  assert(w[1] == 2, "post-promote: row 1 pad must be 2, got " .. tostring(w[1]))
  assert(w[2] == 2, "post-promote: row 2 pad must be 2, got " .. tostring(w[2]))
  assert(w[3] == 5, "post-promote: row 3 pad must be 5, got " .. tostring(w[3]))
end

io.write("indent sync on heading edit ok\n")
os.exit(0)
