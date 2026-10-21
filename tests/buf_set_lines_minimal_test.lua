-- obuf.set_lines changes only what differs: unchanged lines and the
-- unchanged parts of an edited line keep their extmarks (fold and reveal
-- marks), and the buffer always ends up with exactly the new lines.
-- Run via: nvim --headless -l tests/buf_set_lines_minimal_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local obuf = require("organ.buf")
local NS = vim.api.nvim_create_namespace("set_lines_minimal_test")

local failures = 0
local function check(label, ok, detail)
  if not ok then
    failures = failures + 1
    io.write("FAIL " .. label .. (detail and (": " .. tostring(detail)) or "") .. "\n")
  end
end

local function buffer(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function mark(b, row)
  return vim.api.nvim_buf_set_extmark(b, NS, row, 0, { invalidate = true, undo_restore = true })
end

local function where(b, id)
  local m = vim.api.nvim_buf_get_extmark_by_id(b, NS, id, { details = true })
  if not m[1] or m[3].invalid then
    return nil
  end
  return m[1], m[2]
end

-- An in-place headline edit keeps the heading's mark.
local b = buffer({ "* TODO A", "body", "* B" })
local ma, mb = mark(b, 0), mark(b, 2)
obuf.set_lines(b, 0, 1, { "* DONE A" })
check("TODO change keeps the heading's mark", where(b, ma) == 0)
check("unrelated mark untouched", where(b, mb) == 2)

-- A rename and a COMMENT toggle are in-place edits too.
obuf.set_lines(b, 0, 1, { "* DONE COMMENT Renamed" })
check("rename keeps the mark", where(b, ma) == 0)

-- A multi-line write that changes two consecutive headlines' tags keeps
-- both marks; unchanged lines in the range keep theirs.
b = buffer({ "* A :x:", "** B :y:", "body", "* C" })
local m1, m2, m3, m4 = mark(b, 0), mark(b, 1), mark(b, 2), mark(b, 3)
obuf.set_lines(b, 0, 4, { "* A      :x:", "** B     :y:", "body", "* C" })
check("retag keeps the first heading's mark", where(b, m1) == 0)
check("retag keeps the second heading's mark", where(b, m2) == 1)
check("unchanged line in the range keeps its mark", where(b, m3) == 2)
check("unchanged last line keeps its mark", where(b, m4) == 3)

-- Swapping and retagging two headings carries neither's mark to the other.
b = buffer({ "* A :x:", "* B :y:" })
m1, m2 = mark(b, 0), mark(b, 1)
obuf.set_lines(b, 0, 2, { "* B   :y:", "* A   :x:" })
local r1, r2 = where(b, m1), where(b, m2)
check("swap does not hand A's mark to B", r1 ~= 0, r1)
check("swap does not hand B's mark to A", r2 ~= 1, r2)

-- Inserting lines above leaves later lines' marks on their lines.
b = buffer({ "* A", "* B", "* C" })
m3 = mark(b, 2)
obuf.set_lines(b, 0, 3, { "* A", "* New", "body", "* B", "* C" })
check("insert above keeps a later heading's mark on it", where(b, m3) == 4)

-- The cursor stays on the same character when text is inserted before it.
b = buffer({ "* heading title" })
vim.api.nvim_set_current_buf(b)
vim.api.nvim_win_set_cursor(0, { 1, 10 })
obuf.set_lines(b, 0, 1, { "* TODO heading title" })
check("cursor stays on its character", vim.api.nvim_win_get_cursor(0)[2] == 15)

-- One call is one undo step.
b = buffer({ "a", "b", "c", "d" })
vim.api.nvim_set_current_buf(b)
vim.bo[b].undolevels = 100
vim.cmd("let &undolevels = &undolevels")
obuf.set_lines(b, 0, 4, { "A", "b", "C", "d", "e" })
vim.cmd("silent undo")
check(
  "one undo restores the whole write",
  vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "a", "b", "c", "d" })
)

-- Equal content stays a no-op.
b = buffer({ "x", "y" })
vim.bo[b].modified = false
obuf.set_lines(b, 0, 2, { "x", "y" })
check("equal content leaves the buffer unmodified", not vim.bo[b].modified)

-- start > end raises as nvim_buf_set_lines does.
b = buffer({ "a", "b", "c", "d", "e" })
local ok_raise = pcall(obuf.set_lines, b, 7, 1, { "x" })
check("start past end raises", not ok_raise)
check("and leaves the buffer as it was", #vim.api.nvim_buf_get_lines(b, 0, -1, false) == 5)

-- Only the buffer's TODO keywords are stripped when pairing headings: two
-- different titles starting with capitals never share a mark.
b = buffer({ "* NASA x", "* ESA y" })
m1, m2 = mark(b, 0), mark(b, 1)
obuf.set_lines(b, 0, 2, { "* ESA x", "* NASA y" })
check("capitalised titles are not taken for TODO keywords", where(b, m1) ~= 0 or where(b, m2) ~= 1)

-- The result is always exactly the new lines (bounded random sweep).
math.randomseed(7)
local alphabet = { "* A", "* B", "** C", "body", "", "x y", "* A :t:", "- item" }
local function random_lines(n)
  local t = {}
  for i = 1, n do
    t[i] = alphabet[math.random(#alphabet)]
  end
  return t
end
for i = 1, 400 do
  local before = random_lines(math.random(0, 7))
  local after = random_lines(math.random(0, 7))
  local s = math.random(0, #before)
  local e = math.random(s, #before)
  b = buffer(#before > 0 and before or { "" })
  local base = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local expected = {}
  vim.list_extend(expected, base, 1, s)
  vim.list_extend(expected, after)
  vim.list_extend(expected, base, e + 1, #base)
  obuf.set_lines(b, s, e, after)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  if #expected == 0 then
    expected = { "" }
  end
  if not vim.deep_equal(got, expected) then
    check(
      "random write " .. i,
      false,
      vim.inspect({ before = base, s = s, e = e, after = after, got = got })
    )
    break
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

if failures > 0 then
  os.exit(1)
end
io.write("buf set_lines minimal ok\n")
