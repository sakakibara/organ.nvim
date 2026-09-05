-- Edit-special writes back through extmark anchors, so edits made to the
-- source buffer while the edit split is open cannot misdirect the commit.
-- Run via: nvim --headless -l tests/edit_special_anchor_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local es = require("organ.edit_special")

local function deq(a, b, label)
  if vim.deep_equal(a, b) ~= true then
    error(label .. ":\n  expected: " .. vim.inspect(b) .. "\n  actual:   " .. vim.inspect(a))
  end
end

local function eq(a, b, label)
  if a ~= b then
    error(label .. ":\n  expected: " .. vim.inspect(b) .. "\n  actual:   " .. vim.inspect(a))
  end
end

local BASE = {
  "* Notes",
  "important paragraph one",
  "important paragraph two",
  "#+begin_src lua",
  "print(1)",
  "#+end_src",
}

local function fresh_source()
  local b = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, BASE)
  vim.api.nvim_set_current_buf(b)
  return b
end

-- Lines inserted ABOVE the block push it down; the commit must follow.
local source = fresh_source()
local edit = es.open(source, 5)
assert(edit, "open returned nil")
vim.api.nvim_buf_set_lines(source, 0, 0, false, { "* NEW TOP HEADLINE" })
vim.api.nvim_buf_set_lines(edit, 0, -1, false, { "print(42)" })
eq(es.commit(edit), true, "commit after an insert above the block succeeds")
deq(vim.api.nvim_buf_get_lines(source, 0, -1, false), {
  "* NEW TOP HEADLINE",
  "* Notes",
  "important paragraph one",
  "important paragraph two",
  "#+begin_src lua",
  "print(42)",
  "#+end_src",
}, "body lands inside the block, prose intact")
es.abort(edit)
vim.api.nvim_buf_delete(source, { force = true })

-- Lines deleted above the block pull it up; same requirement.
source = fresh_source()
edit = es.open(source, 5)
vim.api.nvim_buf_set_lines(source, 1, 3, false, {})
vim.api.nvim_buf_set_lines(edit, 0, -1, false, { "print(7)", "print(8)" })
eq(es.commit(edit), true, "commit after a delete above the block succeeds")
deq(vim.api.nvim_buf_get_lines(source, 0, -1, false), {
  "* Notes",
  "#+begin_src lua",
  "print(7)",
  "print(8)",
  "#+end_src",
}, "body lands inside the block after the block moved up")
es.abort(edit)
vim.api.nvim_buf_delete(source, { force = true })

-- The block itself is gone: refuse rather than write over whatever now
-- occupies those lines.
source = fresh_source()
edit = es.open(source, 5)
vim.api.nvim_buf_set_lines(source, 3, 6, false, { "replacement paragraph" })
vim.api.nvim_buf_set_lines(edit, 0, -1, false, { "print(99)" })
eq(es.commit(edit), false, "commit refuses when the block no longer exists")
deq(vim.api.nvim_buf_get_lines(source, 0, -1, false), {
  "* Notes",
  "important paragraph one",
  "important paragraph two",
  "replacement paragraph",
}, "source untouched by the refused commit")
es.abort(edit)

-- Anchors are dropped with the edit buffer.
eq(#vim.api.nvim_buf_get_extmarks(source, es._ns, 0, -1, {}), 0, "anchors cleared on abort")
vim.api.nvim_buf_delete(source, { force = true })

io.write("edit_special_anchor ok\n")
os.exit(0)
