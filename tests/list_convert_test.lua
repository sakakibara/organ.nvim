-- list_convert: list_to_subtree + toggle_item.
-- Run via: nvim --headless -l tests/list_convert_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local lc = require("organ.list_convert")

-- 1. list_to_subtree under a level-1 headline → produces level-2 headlines.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Container",
    "- one",
    "- two",
    "  - nested",
    "- three",
  })
  local n = lc.list_to_subtree({ bufnr = b, line = 2 })
  assert(n == 4, "expected 4 lines converted; got " .. tostring(n))
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "* Container", "container intact")
  assert(lines[2] == "** one", "row 2: " .. lines[2])
  assert(lines[3] == "** two", "row 3: " .. lines[3])
  assert(lines[4] == "*** nested", "nested becomes deeper: " .. lines[4])
  assert(lines[5] == "** three", "row 5: " .. lines[5])
end

-- 2. list_to_subtree at top of file → level-1 headlines.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "- alpha",
    "- beta",
  })
  lc.list_to_subtree({ bufnr = b, line = 1 })
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "* alpha", "1: " .. lines[1])
  assert(lines[2] == "* beta", "2: " .. lines[2])
end

-- 3. toggle_item: list item → headline.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Parent",
    "- thing",
  })
  local kind = lc.toggle_item({ bufnr = b, line = 2 })
  assert(kind == "to_text", "kind: " .. tostring(kind))
  local line = vim.api.nvim_buf_get_lines(b, 1, 2, false)[1]
  assert(line == "thing", "expected thing; got " .. line)
end

-- 3b. toggle_item on an item keeps the indent and any checkbox text
--     (Emacs `org-toggle-item`: only the bullet goes).
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "  - [ ] thing" })
  lc.toggle_item({ bufnr = b, line = 1 })
  local line = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(line == "  [ ] thing", "expected '  [ ] thing'; got '" .. line .. "'")
end

-- 4. toggle_item: headline -> flush-left list item; the TODO keyword
--    becomes a checkbox and tags go (Emacs: `** TODO foo` -> `- [ ] foo`).
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "** sub item" })
  local kind = lc.toggle_item({ bufnr = b, line = 1 })
  assert(kind == "to_item", "kind: " .. tostring(kind))
  local line = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(line == "- sub item", "expected '- sub item'; got '" .. line .. "'")

  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "** TODO foo" })
  lc.toggle_item({ bufnr = b, line = 1 })
  line = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(line == "- [ ] foo", "TODO -> [ ]; got '" .. line .. "'")

  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* DONE [#A] foo :t:" })
  lc.toggle_item({ bufnr = b, line = 1 })
  line = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(line == "- [X] [#A] foo", "DONE -> [X], tags dropped; got '" .. line .. "'")
end

-- 4b. Heading metadata (planning, property drawer, blank lines after
--     them) is deleted; the body and later headings stay.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* H",
    "** DONE foo",
    "SCHEDULED: <2025-01-01 Wed>",
    ":PROPERTIES:",
    ":A: b",
    ":END:",
    "",
    "body",
    "*** sub",
  })
  lc.toggle_item({ bufnr = b, line = 2 })
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(
    vim.deep_equal(lines, { "* H", "- [X] foo", "body", "*** sub" }),
    "metadata removed: " .. vim.inspect(lines)
  )
end

-- 5. toggle_item: plain text -> item at the same indent; blank lines
--    are left alone.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "  foo", "" })
  local kind = lc.toggle_item({ bufnr = b, line = 1 })
  assert(kind == "to_item", "kind: " .. tostring(kind))
  local line = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(line == "  - foo", "expected '  - foo'; got '" .. line .. "'")
  local none = lc.toggle_item({ bufnr = b, line = 2 })
  assert(none == nil, "blank line untouched")
  assert(vim.api.nvim_buf_get_lines(b, 1, 2, false)[1] == "", "blank line stays blank")
end

-- 6. list_to_subtree maps checkboxes to TODO/DONE (Emacs
--    `org-list-to-subtree`: `:cbon "DONE " :cboff "TODO " :cbtrans "TODO "`).
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* H",
    "- [X] foo",
    "- [ ] bar",
    "  - [-] baz",
  })
  lc.list_to_subtree({ bufnr = b, line = 2 })
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(
    vim.deep_equal(lines, { "* H", "** DONE foo", "** TODO bar", "*** TODO baz" }),
    "checkboxes -> keywords: " .. vim.inspect(lines)
  )
end

-- 7. toggle_heading (Emacs `org-toggle-heading`, C-c *): item or plain
--    line -> headline one level below the nearest headline, checkbox ->
--    keyword; headline -> plain text.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* H",
    "- [X] foo",
    "plain line",
    "** Child",
  })
  assert(lc.toggle_heading({ bufnr = b, line = 2 }) == "to_headline")
  assert(lc.toggle_heading({ bufnr = b, line = 3 }) == "to_headline")
  assert(lc.toggle_heading({ bufnr = b, line = 4 }) == "to_text")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(
    vim.deep_equal(lines, { "* H", "** DONE foo", "*** plain line", "Child" }),
    "toggle_heading: " .. vim.inspect(lines)
  )
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "" })
  local none = lc.toggle_heading({ bufnr = b, line = 1 })
  assert(none == nil, "blank line untouched")
end

io.write("list convert ok\n")
os.exit(0)
