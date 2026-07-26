-- tests/structure_promote_test.lua
-- Run via: nvim --headless -l tests/structure_promote_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local structure = require("organ.structure")

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
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- promote_headline level-2 -> level-1.
do
  local b = mk_buf({ "* A", "** B", "*** C" })
  local err = structure.promote_headline({ bufnr = b, line = 2 })
  assert(err == nil, "no error")
  assert_eq(get_lines(b)[2], "* B", "B promoted to level 1")
  -- C is unchanged (only headline-level promote).
  assert_eq(get_lines(b)[3], "*** C")
end

-- promote_headline at level-1 errors.
do
  local b = mk_buf({ "* A" })
  local err = structure.promote_headline({ bufnr = b, line = 1 })
  assert(err and err:find("level%-1"), "got: " .. tostring(err))
  assert_eq(get_lines(b)[1], "* A", "buffer unchanged on error")
end

-- promote_subtree decrements current + descendants.
do
  local b = mk_buf({
    "* Root",
    "** A",
    "  body",
    "*** A1",
    "** B",
    "* Other",
  })
  -- Promote A's subtree from cursor on A's body.
  local err = structure.promote_subtree({ bufnr = b, line = 3 })
  assert(err == nil, "no error: " .. tostring(err))
  local out = get_lines(b)
  assert_eq(out[2], "* A", "A promoted to level 1")
  assert_eq(out[4], "** A1", "A1 promoted to level 2")
  -- B is sibling of A (same level), should be unchanged.
  assert_eq(out[5], "** B", "B sibling unchanged")
  -- Root unchanged (parent of subtree we operated on).
  assert_eq(out[1], "* Root")
end

-- promote_subtree at level-1 errors.
do
  local b = mk_buf({ "* A", "** B" })
  local err = structure.promote_subtree({ bufnr = b, line = 1 })
  assert(err and err:find("level%-1"), "got: " .. tostring(err))
  assert_eq(get_lines(b)[1], "* A", "buffer unchanged")
  assert_eq(get_lines(b)[2], "** B")
end

-- Cursor not on a headline returns error.
do
  local b = mk_buf({ "before", "* A" })
  local err = structure.promote_headline({ bufnr = b, line = 1 })
  assert(err and err:find("not on a headline"), "got: " .. tostring(err))
end

io.write("structure promote ok\n")
