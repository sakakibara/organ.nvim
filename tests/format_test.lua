-- Org formatter (paragraph rewrap) preserves structure: headlines
-- never wrap, drawers/blocks/planning lines pass through verbatim,
-- list items rewrap continuation under the bullet's indent column.
--
-- Run via: nvim --headless -l tests/format_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local fmt = require("organ.format")

-- ---------------------------------------------------------------------------
-- (a) Headlines never wrap, even when longer than textwidth.
-- ---------------------------------------------------------------------------
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 40
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* TODO This is a very long headline that exceeds forty characters easily",
    "Body text here.",
  })
  fmt.format_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "headline > textwidth: NOT wrapped",
    lines[1] == "* TODO This is a very long headline that exceeds forty characters easily",
    vim.inspect(lines)
  )
end

-- ---------------------------------------------------------------------------
-- (b) Plain prose paragraph rewraps to textwidth.
-- ---------------------------------------------------------------------------
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 30
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Heading",
    "this is a single long line that should rewrap to thirty chars per line",
  })
  fmt.format_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  -- Heading stays.  Subsequent lines: each ≤ 30 chars.
  check("prose: heading preserved", lines[1] == "* Heading")
  for i = 2, #lines do
    check(
      ("prose line %d ≤ 30 chars"):format(i),
      #lines[i] <= 30,
      ("got %d: %q"):format(#lines[i], lines[i])
    )
  end
end

-- ---------------------------------------------------------------------------
-- (c) Drawer contents pass through verbatim.
-- ---------------------------------------------------------------------------
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 20
  local input = {
    "* H",
    ":PROPERTIES:",
    ":ID: this-is-a-very-long-id-that-should-not-wrap",
    ":END:",
    "Body.",
  }
  vim.api.nvim_buf_set_lines(b, 0, -1, false, input)
  fmt.format_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "drawer content: ID line untouched",
    lines[3] == ":ID: this-is-a-very-long-id-that-should-not-wrap",
    vim.inspect(lines)
  )
end

-- ---------------------------------------------------------------------------
-- (d) Source block contents pass through verbatim (would be invalid
-- code if wrapped).
-- ---------------------------------------------------------------------------
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 20
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "#+begin_src python",
    "def long_function_name_here(arg1, arg2): return arg1 + arg2",
    "#+end_src",
  })
  fmt.format_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "src block: long code line preserved",
    lines[2] == "def long_function_name_here(arg1, arg2): return arg1 + arg2",
    vim.inspect(lines)
  )
end

-- ---------------------------------------------------------------------------
-- (e) List item rewraps continuation under bullet indent.
-- ---------------------------------------------------------------------------
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 30
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* H",
    "- this is a long list item that should wrap under the bullet column",
  })
  fmt.format_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  -- First line of list item starts with `- `; subsequent lines
  -- start with two spaces (bullet width).
  check("list item: starts with `- `", lines[2]:sub(1, 2) == "- ", vim.inspect(lines))
  if lines[3] then
    check(
      "list continuation: starts with two-space indent",
      lines[3]:sub(1, 2) == "  ",
      vim.inspect(lines)
    )
  end
end

-- ---------------------------------------------------------------------------
-- (f) format_range exercises the same code path as formatexpr but
-- without the v:lnum/v:count ceremony (those are read-only outside
-- a real `gq` invocation).
-- ---------------------------------------------------------------------------
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 25
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* H",
    "long line one that should wrap to twenty five chars across multiple",
  })
  fmt.format_range(b, 2, 2)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check("format_range: rewrapped line 2", #lines >= 2 and #lines[2] <= 25, vim.inspect(lines))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_test: PASS")
