-- Verifies organ.latex_preview.fragment_at_cursor identifies fragments
-- and entity expansion.
-- Run via: nvim --headless -l tests/latex_preview_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local lp = require("organ.latex_preview")

local function setup_buf(lines, line, col)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { line, col })
  return buf
end

-- 1. `$x^2$` inline fragment.
do
  setup_buf({ "Some math: $x^2 + 1$ stuff." }, 1, 14)
  local f = lp.fragment_at_cursor(0)
  assert(f, "expected a fragment when cursor is inside $x^2 + 1$")
  assert(f.kind == "inline", "expected kind=inline got " .. tostring(f.kind))
  assert(f.text:find("x^2", 1, true), "fragment text should contain x^2")
end

-- 2. `\(...\)` inline.
do
  setup_buf({ [[Inline \(\alpha + \beta\) text]] }, 1, 12)
  local f = lp.fragment_at_cursor(0)
  assert(f, "expected paren-style inline fragment")
  assert(f.kind == "inline")
end

-- 3. `\[...\]` display.
do
  setup_buf({ [[Block: \[\sum_{i=1}^n i\] done]] }, 1, 14)
  local f = lp.fragment_at_cursor(0)
  assert(f, "expected display fragment")
  assert(f.kind == "display")
end

-- 4. `\begin{equation}...\end{equation}` environment, multi-line.
do
  setup_buf({
    "Before",
    "\\begin{equation}",
    "  E = mc^2",
    "\\end{equation}",
    "After",
  }, 3, 4)
  local f = lp.fragment_at_cursor(0)
  assert(f, "expected environment match")
  assert(f.kind == "environment", "kind should be environment, got " .. tostring(f.kind))
  assert(f.text:find("E = mc%^2"), "text should include the body")
end

-- 5. Cursor outside any fragment.
do
  setup_buf({ "No math here at all." }, 1, 5)
  assert(lp.fragment_at_cursor(0) == nil, "no fragment expected")
end

-- 6. Pretty rendering substitutes \alpha → α.
do
  setup_buf({ [[$\alpha + \beta$]] }, 1, 4)
  local f = lp.fragment_at_cursor(0)
  assert(f, "should find a fragment")
  -- Manually invoke the open() path and inspect the popup buffer.
  local win = lp.open(0)
  assert(win, "open() should return a window id")
  local buf = vim.api.nvim_win_get_buf(win)
  local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(body:find("α", 1, true), "α expansion missing in popup:\n" .. body)
  pcall(vim.api.nvim_win_close, win, true)
end

io.write("latex preview ok\n")
os.exit(0)
