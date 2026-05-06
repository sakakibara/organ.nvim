-- Edit-special: open src block in language buffer, commit back.
-- Run via: nvim --headless -l tests/edit_special_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local es = require("organ.edit_special")

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

-- ──────────────────────────────────────────────────────────────────
-- find_block
-- ──────────────────────────────────────────────────────────────────

local b = vim.api.nvim_create_buf(true, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "Some intro paragraph.",
  "",
  "#+begin_src python",
  "print('hi')",
  "x = 42",
  "#+end_src",
  "",
  "After.",
})

local block = es.find_block(b, 4)
eq(block.begin_line, 3, "begin line")
eq(block.end_line, 6, "end line")
eq(block.lang, "python", "lang")
eq(block.base_indent, "", "no indent")

-- Indented variant (base_indent = "  ").
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* Section",
  "  #+begin_src lua",
  "  return 1",
  "  #+end_src",
})
block = es.find_block(b, 3)
eq(block.lang, "lua", "indented lang")
eq(block.base_indent, "  ", "base_indent reflects column shift")

-- Outside any block.
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "Just text" })
eq(es.find_block(b, 1), nil, "no block → nil")

-- ──────────────────────────────────────────────────────────────────
-- open + commit + indentation round-trip
-- ──────────────────────────────────────────────────────────────────

local source = vim.api.nvim_create_buf(true, true)
vim.api.nvim_buf_set_lines(source, 0, -1, false, {
  "* Section",
  "  Some prose.",
  "",
  "  #+begin_src lua",
  "  return 1",
  "  return 2",
  "  #+end_src",
  "",
  "  After.",
})
vim.api.nvim_set_current_buf(source)

local edit = es.open(source, 5) -- inside the src block
assert(edit, "open returned nil")

-- Edit buffer should have stripped indent.
local edit_body = vim.api.nvim_buf_get_lines(edit, 0, -1, false)
deq(edit_body, { "return 1", "return 2" }, "edit buffer body strips base indent")

-- Modify the edit buffer.
vim.api.nvim_buf_set_lines(edit, 0, -1, false, { "return 99", "-- comment" })
es.commit(edit)

-- Source buffer should reflect the changes with indent re-added.
local src_body = vim.api.nvim_buf_get_lines(source, 0, -1, false)
deq(src_body, {
  "* Section",
  "  Some prose.",
  "",
  "  #+begin_src lua",
  "  return 99",
  "  -- comment",
  "  #+end_src",
  "",
  "  After.",
}, "commit re-applies indent and replaces body")

-- A second commit (e.g. user keeps editing then saves again).
vim.api.nvim_buf_set_lines(edit, 0, -1, false, { "return 1; return 2; return 3" })
es.commit(edit)
src_body = vim.api.nvim_buf_get_lines(source, 0, -1, false)
deq(src_body, {
  "* Section",
  "  Some prose.",
  "",
  "  #+begin_src lua",
  "  return 1; return 2; return 3",
  "  #+end_src",
  "",
  "  After.",
}, "second commit collapses body to single line")

-- Cleanup.
es.abort(edit)
vim.api.nvim_buf_delete(source, { force = true })
vim.api.nvim_buf_delete(b, { force = true })

io.write("edit_special ok\n")
os.exit(0)
