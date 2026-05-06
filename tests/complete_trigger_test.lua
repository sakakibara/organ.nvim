-- Pure unit on complete.trigger_at_cursor.
-- Run via: nvim --headless -l tests/complete_trigger_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local complete = require("organ.complete")

-- Allow cursor one past EOL so col == #line (typical insert-mode position
-- right after typing) is valid in these test setups.
vim.opt.virtualedit = "onemore"

local function setup_buf(line, cursor_col_0based)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { line })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, cursor_col_0based })
  return b
end

local function eq_trigger(t, kind, prefix, prefix_col, query)
  assert(t, "trigger expected, got nil")
  assert(t.kind == kind, "kind: got " .. tostring(t.kind))
  assert(t.prefix == prefix, "prefix: got " .. tostring(t.prefix))
  assert(t.prefix_col == prefix_col, "prefix_col: got " .. tostring(t.prefix_col))
  assert(t.query == query, "query: got " .. tostring(t.query))
end

local b1 = setup_buf("[[id:abc", 8)
eq_trigger(complete.trigger_at_cursor(b1), "id", "[[id:", 0, "abc")

local b2 = setup_buf("[[*Some Title", 13)
eq_trigger(complete.trigger_at_cursor(b2), "headline", "[[*", 0, "Some Title")

local b3 = setup_buf("[[file:./not", 12)
eq_trigger(complete.trigger_at_cursor(b3), "file", "[[file:", 0, "./not")

local b4 = setup_buf("[[attachment:img", 16)
eq_trigger(complete.trigger_at_cursor(b4), "attachment", "[[attachment:", 0, "img")

local b5 = setup_buf("text [[id:abc", 13)
eq_trigger(complete.trigger_at_cursor(b5), "id", "[[id:", 5, "abc")

local b6 = setup_buf("[[id:abc]] x", 12)
assert(complete.trigger_at_cursor(b6) == nil, "closed link should be nil")

local b7 = setup_buf("[[id:abc]", 9)
local t7 = complete.trigger_at_cursor(b7)
assert(t7 and t7.kind == "id", "single ] is not a close; should match")

local b8 = setup_buf("just some text", 14)
assert(complete.trigger_at_cursor(b8) == nil, "no trigger should be nil")

local b9 = setup_buf("see [[id:foo and [[id:bar", 25)
local t9 = complete.trigger_at_cursor(b9)
assert(
  t9 and t9.kind == "id" and t9.query == "bar",
  "rightmost trigger expected; got " .. tostring(t9 and t9.query)
)

io.write("complete trigger ok\n")
os.exit(0)
