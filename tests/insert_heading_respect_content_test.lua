-- organ.meta_return.insert_heading_respect_content: `:Org
-- insert_heading_respect_content` and its TODO variant (Emacs C-RET /
-- C-S-RET).  The line each heading lands on, and its level, is what real
-- Emacs 30 / org 9.7.11 produces, checked with
--   emacs --batch -Q -l org --eval '(org-insert-heading-respect-content)'
-- before it was encoded here.
--
-- Run via: nvim --headless -l tests/insert_heading_respect_content_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local meta_return = require("organ.meta_return")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function inserted(label, lines, l, c, opts, want)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { l, c })
  meta_return.insert_heading_respect_content(
    vim.tbl_extend("force", { enter_insert = false }, opts or {})
  )
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(label, vim.deep_equal(got, want), table.concat(got, " | "))
end

local ONE = { "* One", "content of one", "** Child", "child body", "* Two" }

-- 1. From the heading line, the new heading lands AFTER the subtree's
-- content -- this is the whole point of the command.
inserted("from the heading, after the subtree", ONE, 1, 5, nil, {
  "* One",
  "content of one",
  "** Child",
  "child body",
  "* ",
  "* Two",
})

-- 2. From a body line, the same place -- the body line is never split.
inserted("from a body line, after the subtree", ONE, 2, 3, nil, {
  "* One",
  "content of one",
  "** Child",
  "child body",
  "* ",
  "* Two",
})

-- 3. From a child heading, the new heading takes the CHILD's level and
-- follows the child's own content.
inserted("from a child heading, at the child's level", ONE, 3, 5, nil, {
  "* One",
  "content of one",
  "** Child",
  "child body",
  "** ",
  "* Two",
})

-- 4. On a list item this inserts a HEADING, not another item -- the
-- difference from `:Org meta_return`.
inserted(
  "on a list item it still inserts a heading",
  { "* One", "- a", "- b", "* Two" },
  2,
  3,
  nil,
  {
    "* One",
    "- a",
    "- b",
    "* ",
    "* Two",
  }
)

-- 5. The TODO variant carries the first active keyword of the reference
-- entry's sequence.
inserted("the TODO variant adds the keyword", ONE, 1, 5, { todo = true }, {
  "* One",
  "content of one",
  "** Child",
  "child body",
  "* TODO ",
  "* Two",
})
inserted(
  "the TODO variant works from a list item too",
  { "* One", "- a", "- b", "* Two" },
  2,
  3,
  { todo = true },
  { "* One", "- a", "- b", "* TODO ", "* Two" }
)

-- 6. Edges: last subtree in the file, a preamble with no enclosing
-- heading, and an empty buffer.
inserted("the last subtree appends at end of file", { "* One", "body" }, 1, 3, nil, {
  "* One",
  "body",
  "* ",
})
inserted("from the preamble, above the first heading", { "preamble", "* One" }, 1, 3, nil, {
  "preamble",
  "* ",
  "* One",
})
inserted("an empty buffer starts the outline", { "" }, 1, 0, nil, { "* " })

-- 7. The cursor lands on the new heading, ready to type the title.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, ONE)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  meta_return.insert_heading_respect_content({ enter_insert = false })
  check("the cursor follows the new heading", vim.api.nvim_win_get_cursor(0)[1] == 5)
end

-- 8. A deep subtree is walked in bounded time.
do
  local lines = { "* One" }
  for i = 1, 5000 do
    lines[#lines + 1] = ("body %d"):format(i)
  end
  lines[#lines + 1] = "* Two"
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local started = vim.uv.hrtime()
  meta_return.insert_heading_respect_content({ enter_insert = false })
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check("a 5000-line subtree is walked", got[5002] == "* " and got[5003] == "* Two", got[5002])
  check("a 5000-line subtree is walked inside 5s", elapsed < 5000, ("%.0fms"):format(elapsed))
end

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\ninsert_heading_respect_content: all checks passed")
