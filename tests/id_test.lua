-- tests/id_test.lua
-- Unit tests for lua/organ/id.lua (OrgIdGetCreate).
-- Run via: nvim --headless -l tests/id_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local id_mod = require("organ.id")

local function mk_buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function get_lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. "\n  expected: " .. tostring(b) .. "\n  got:      " .. tostring(a), 2)
  end
end

local function is_uuid_v7(s)
  return s
    and s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-7%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
      ~= nil
end

----------------------------------------------------------------------
-- 1. Headline without :ID: → new UUID written to :PROPERTIES: drawer; returns UUID.
do
  local b = mk_buf({ "* Task", "  body" })
  local result = id_mod.get_or_create(b, 1)
  assert(result, "get_or_create should return an ID string")
  assert(is_uuid_v7(result), "returned value should be UUID v7: " .. tostring(result))
  local lines = get_lines(b)
  -- :PROPERTIES: drawer should have been created.
  assert_eq(lines[2], "  :PROPERTIES:")
  assert_eq(lines[3], "  :ID:       " .. result)
  assert_eq(lines[4], "  :END:")
  assert_eq(lines[5], "  body")
end

----------------------------------------------------------------------
-- 2. Headline with existing :ID: → returns existing; no buffer change.
do
  local existing_id = "01234567-89ab-7cde-8abc-0123456789ab"
  local b = mk_buf({
    "* Task",
    ":PROPERTIES:",
    ":ID: " .. existing_id,
    ":END:",
    "  body",
  })
  local original_lines = get_lines(b)
  local result = id_mod.get_or_create(b, 1)
  assert_eq(result, existing_id, "should return existing ID unchanged")
  local after = get_lines(b)
  assert_eq(#after, #original_lines, "buffer length should not change")
  for i = 1, #after do
    assert_eq(after[i], original_lines[i], "line " .. i .. " should be unchanged")
  end
end

----------------------------------------------------------------------
-- 3. Cursor in body resolves to containing headline.
do
  local b = mk_buf({ "* Task", "  first body", "  second body" })
  -- Call from body line 3.
  local result = id_mod.get_or_create(b, 3)
  assert(result, "should resolve headline from body line and return ID")
  assert(is_uuid_v7(result), "result should be UUID v7: " .. tostring(result))
  local lines = get_lines(b)
  -- Drawer inserted at line 2.
  assert_eq(lines[2], "  :PROPERTIES:")
  assert_eq(lines[3], "  :ID:       " .. result)
  assert_eq(lines[4], "  :END:")
end

io.write("id ok\n")
os.exit(0)
