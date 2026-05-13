-- M-RET context-aware insert.
-- Run via: nvim --headless -l tests/meta_return_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local mr = require("organ.meta_return")

local function with_buffer(lines, line, col, fn)
  local b = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { line, col })
  fn()
  local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local cur = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_buf_delete(b, { force = true })
  return out, cur
end

local function eq(a, b, label)
  if a ~= b then
    error(label .. ":\n  expected: " .. vim.inspect(b) .. "\n  actual:   " .. vim.inspect(a))
  end
end

local function deq(a, b, label)
  if vim.deep_equal(a, b) ~= true then
    error(label .. ":\n  expected: " .. vim.inspect(b) .. "\n  actual:   " .. vim.inspect(a))
  end
end

-- 1. Headline: insert sibling at same level after the section.
local out = with_buffer(
  {
    "* First",
    "Some body.",
    "* Second",
  },
  1,
  0,
  function()
    mr.dispatch({ enter_insert = false })
  end
)
deq(out, {
  "* First",
  "Some body.",
  "* ",
  "* Second",
}, "headline → new sibling at same level after section body")

-- 2. List item with `-` bullet: insert new `-` below.
out = with_buffer(
  {
    "- one",
    "- two",
  },
  1,
  4,
  function()
    mr.dispatch({ enter_insert = false })
  end
)
deq(out, {
  "- one",
  "- ",
  "- two",
}, "list item `- ` → new `- ` below")

-- 3. Numeric list: new item + renumbers the rest.
out = with_buffer(
  {
    "1. one",
    "2. two",
    "3. three",
  },
  1,
  0,
  function()
    mr.dispatch({ enter_insert = false })
  end
)
deq(out, {
  "1. one",
  "2. ",
  "3. two",
  "4. three",
}, "numeric list inserts and renumbers tail")

-- 4. Indented `*` bullet.
out = with_buffer(
  {
    "* H",
    "  * subitem",
  },
  2,
  4,
  function()
    mr.dispatch({ enter_insert = false })
  end
)
deq(out, {
  "* H",
  "  * subitem",
  "  * ",
}, "indented `*` bullet → another `*` at same indent")

-- 5. Table row: new row with same column count.
out = with_buffer(
  {
    "| a | b | c |",
    "| 1 | 2 | 3 |",
  },
  1,
  0,
  function()
    mr.dispatch({ enter_insert = false })
  end
)
deq(out, {
  "| a | b | c |",
  "|  |  |  |",
  "| 1 | 2 | 3 |",
}, "table row → new row with same cell count")

-- 6. Plain paragraph: open blank line below.
out = with_buffer(
  {
    "Just text",
  },
  1,
  0,
  function()
    mr.dispatch({ enter_insert = false })
  end
)
deq(out, { "Just text", "" }, "paragraph → blank line below")

-- 7. Body line inside a subtree → new heading at the enclosing level
-- appended after the subtree's content (mirrors Emacs
-- `org-insert-heading-respect-content`).
out = with_buffer(
  {
    "* First",
    "body line",
    "more body",
    "* Second",
  },
  2,
  3,
  function()
    mr.dispatch({ enter_insert = false })
  end
)
deq(out, {
  "* First",
  "body line",
  "more body",
  "* ",
  "* Second",
}, "body line inside subtree → new headline at enclosing level after subtree")

-- 8. Body line inside a level-2 subtree → new level-2 heading after the
-- innermost subtree's content (NOT promoted to level 1).
out = with_buffer(
  {
    "* L1",
    "** L2",
    "body of L2",
    "* L1 sibling",
  },
  3,
  0,
  function()
    mr.dispatch({ enter_insert = false })
  end
)
deq(out, {
  "* L1",
  "** L2",
  "body of L2",
  "** ",
  "* L1 sibling",
}, "body line under level-2 heading → new level-2 heading, not level 1")

-- 9. Body line under L1 with multiple L2 children → new L1 heading
-- appended AFTER the full subtree (past all the L2 children).  The
-- walk must step over deeper-level child headings without stopping.
out = with_buffer(
  {
    "* L1",
    "body of L1",
    "** Sub 1",
    "body of Sub 1",
    "** Sub 2",
    "body of Sub 2",
    "** Sub 3",
    "body of Sub 3",
    "* L1 sibling",
  },
  2,
  3,
  function()
    mr.dispatch({ enter_insert = false })
  end
)
deq(out, {
  "* L1",
  "body of L1",
  "** Sub 1",
  "body of Sub 1",
  "** Sub 2",
  "body of Sub 2",
  "** Sub 3",
  "body of Sub 3",
  "* ",
  "* L1 sibling",
}, "body of L1 with L2 children → new L1 after subtree, not before children")

-- 10. Same shape, but L1 is the LAST top-level heading in the buffer
-- (no L1 sibling).  The new L1 should land at end-of-buffer.
out = with_buffer(
  {
    "* L1",
    "body of L1",
    "** Sub 1",
    "body of Sub 1",
    "** Sub 2",
    "body of Sub 2",
  },
  2,
  3,
  function()
    mr.dispatch({ enter_insert = false })
  end
)
deq(out, {
  "* L1",
  "body of L1",
  "** Sub 1",
  "body of Sub 1",
  "** Sub 2",
  "body of Sub 2",
  "* ",
}, "body of last L1 with children → new L1 appended at end of buffer")

io.write("meta_return ok\n")
os.exit(0)
