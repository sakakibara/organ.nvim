-- Checkbox module unit tests.
-- Run via: nvim --headless -l tests/checkbox_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local cb = require("organ.checkbox")

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
-- parse_item_line
-- ──────────────────────────────────────────────────────────────────

local p
p = cb.parse_item_line("- [ ] task")
eq(p.state, " ", "blank checkbox state")
eq(p.indent, 0, "indent 0")

p = cb.parse_item_line("  - [X] done")
eq(p.state, "X", "X state")
eq(p.indent, 2, "indent 2")

p = cb.parse_item_line("  - [-] partial")
eq(p.state, "-", "- state (partial)")

p = cb.parse_item_line("- [x] lowercase")
eq(p.state, "X", "lowercase normalises to X")

p = cb.parse_item_line("- bullet without checkbox")
eq(p.state, nil, "no checkbox state")
eq(p.indent, 0, "still parses indent")

p = cb.parse_item_line("not a list item")
eq(p, nil, "non-item returns nil")

p = cb.parse_item_line("- [ ] [2/5] subtasks")
eq(p.state, " ", "still parses checkbox")
eq(p.cookie, "[2/5]", "extracts statistics cookie")

p = cb.parse_item_line("- [ ] [50%] half")
eq(p.cookie, "[50%]", "percent cookie")

p = cb.parse_item_line("1. [ ] numbered")
eq(p.state, " ", "numbered bullet checkbox")

p = cb.parse_item_line("  + [X] plus bullet")
eq(p.state, "X", "+ bullet checkbox")

p = cb.parse_item_line("  * [ ] asterisk at indent")
eq(p.state, " ", "* bullet at non-zero indent")

-- ──────────────────────────────────────────────────────────────────
-- toggle (cycle ` ` → X → - → ` `)
-- ──────────────────────────────────────────────────────────────────

local function with_buffer(lines, fn)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  fn(b)
  local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.api.nvim_buf_delete(b, { force = true })
  return out
end

local out = with_buffer({ "- [ ] task" }, function(b)
  cb.toggle({ bufnr = b, line = 1 })
end)
deq(out, { "- [X] task" }, "blank → X")

out = with_buffer({ "- [X] task" }, function(b)
  cb.toggle({ bufnr = b, line = 1 })
end)
deq(out, { "- [-] task" }, "X → -")

out = with_buffer({ "- [-] task" }, function(b)
  cb.toggle({ bufnr = b, line = 1 })
end)
deq(out, { "- [ ] task" }, "- → blank")

-- Insert a checkbox if absent.
out = with_buffer({ "- task" }, function(b)
  cb.toggle({ bufnr = b, line = 1 })
end)
deq(out, { "- [ ] task" }, "absent → insert blank")

-- ──────────────────────────────────────────────────────────────────
-- update_parent_cookie
-- ──────────────────────────────────────────────────────────────────

out = with_buffer({
  "- [/] parent",
  "  - [ ] a",
  "  - [ ] b",
  "  - [ ] c",
}, function(b)
  cb.toggle({ bufnr = b, line = 2 })
end)
deq(out[1], "- [1/3] parent", "parent cookie reflects 1 done out of 3")

out = with_buffer({
  "- [/] parent",
  "  - [X] a",
  "  - [X] b",
}, function(b)
  cb.toggle({ bufnr = b, line = 2 })
end)
deq(out[1], "- [1/2] parent", "toggling X → - reduces done count")

out = with_buffer({
  "- [%] parent",
  "  - [X] a",
  "  - [ ] b",
  "  - [ ] c",
  "  - [ ] d",
}, function(b)
  cb.toggle({ bufnr = b, line = 3 })
end)
deq(out[1], "- [50%] parent", "percent form computed (2 done / 4 = 50%)")

-- Parent state flips to X when all children done — only fires if parent
-- HAS a checkbox itself.  Cookie-only parents update the cookie only.
out = with_buffer({
  "- [/] parent",
  "  - [X] a",
  "  - [ ] b",
}, function(b)
  cb.toggle({ bufnr = b, line = 3 })
end)
eq(out[1], "- [2/2] parent", "cookie updates; no parent state to flip")

-- Parent that DOES have its own checkbox flips correctly.
out = with_buffer({
  "- [ ] [/] parent",
  "  - [X] a",
  "  - [ ] b",
}, function(b)
  cb.toggle({ bufnr = b, line = 3 })
end)
eq(out[1], "- [X] [2/2] parent", "parent's own checkbox flips to X when all children done")

io.write("checkbox ok\n")
os.exit(0)
