-- complete.apply_selection splices the chosen item into the buffer.
-- Run via: nvim --headless -l tests/complete_apply_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local complete = require("organ.complete")

vim.opt.virtualedit = "onemore"

local function setup_buf(line, cursor_col_0based)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { line })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, cursor_col_0based })
  return b
end

-- Happy path: detect trigger, apply selection.
do
  local b = setup_buf("see [[id:", 9)
  local trigger = complete.trigger_at_cursor(b)
  assert(trigger, "trigger should be detected")
  assert(trigger.prefix_col == 4, "prefix_col should be 4; got " .. trigger.prefix_col)

  local item = {
    kind = "id",
    display = "Alpha   x.org:1",
    insert_text = "abc-id",
    description = "Alpha",
  }
  complete.apply_selection(b, trigger, item)

  local lines = vim.api.nvim_buf_get_lines(b, 0, 1, false)
  assert(lines[1] == "see [[id:abc-id][Alpha]]", "expected splice; got '" .. lines[1] .. "'")
  local cursor = vim.api.nvim_win_get_cursor(0)
  assert(cursor[2] == #lines[1], "cursor should be at end-of-link; got col " .. cursor[2])
end

-- Trigger moved between detect and apply → notify-warn, no buffer change.
do
  local b = setup_buf("see [[id:", 9)
  local trigger = complete.trigger_at_cursor(b)
  -- Mutate the buffer to move the trigger.
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "different content" })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })

  local notified = nil
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    notified = msg
  end

  local item = { insert_text = "abc-id", description = "Alpha" }
  complete.apply_selection(b, trigger, item)

  vim.notify = original_notify
  assert(
    notified and notified:find("aborting", 1, true),
    "expected abort notify; got " .. tostring(notified)
  )
  local after = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(after == "different content", "buffer should be unchanged; got '" .. after .. "'")
end

-- Buffer wiped → silent no-op.
do
  local b = setup_buf("see [[id:", 9)
  local trigger = complete.trigger_at_cursor(b)
  vim.api.nvim_buf_delete(b, { force = true })
  local item = { insert_text = "x", description = "X" }
  local ok = pcall(complete.apply_selection, b, trigger, item)
  assert(ok, "apply on invalid buffer should not raise")
end

io.write("complete apply ok\n")
os.exit(0)
