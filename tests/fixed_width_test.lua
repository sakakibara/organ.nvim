-- organ.fixed_width: `:Org toggle_fixed_width` (Emacs
-- org-toggle-fixed-width, C-c :).  Every expectation is the buffer real
-- Emacs 30 / org 9.7.11 produces for the same input, checked with
--   emacs --batch -Q -l org --eval '(org-toggle-fixed-width)'
-- at the same point / region before it was encoded here.
--
-- Run via: nvim --headless -l tests/fixed_width_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local fixed_width = require("organ.fixed_width")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function toggled(label, lines, l1, l2, want)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  local err = fixed_width.toggle(b, l1, l2)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(label, err == nil and vim.deep_equal(got, want), err or table.concat(got, " | "))
end

local function refused(label, lines, l1, l2)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  local err = fixed_width.toggle(b, l1, l2)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    label,
    err == "cannot insert a fixed-width line here" and vim.deep_equal(got, lines),
    tostring(err)
  )
end

-- 1. One line: a paragraph gains the prefix, a fixed-width line loses it.
toggled("a paragraph line gains `: `", { "* H", "some text", "more" }, 2, 2, {
  "* H",
  ": some text",
  "more",
})
toggled("a fixed-width line loses `: `", { "* H", ": some text" }, 2, 2, { "* H", "some text" })
-- A bare `:` runs to end of line, so Emacs removes the indentation too.
toggled("a bare `:` line empties", { "* H", ":" }, 2, 2, { "* H", "" })
toggled("the marker goes after the indent", { "* H", "   indented" }, 2, 2, {
  "* H",
  "   : indented",
})
toggled("a headline gains the prefix at column 0", { "* H", "body" }, 1, 1, { ": * H", "body" })
-- A blank line after an element becomes `: ` (with the trailing space).
toggled("a trailing blank line becomes `: `", { "* H", "para", "" }, 3, 3, {
  "* H",
  "para",
  ": ",
})
-- Comments and keywords are ordinary elements for this command.
toggled("a comment line gains the prefix", { "# a comment" }, 1, 1, { ": # a comment" })
toggled("a keyword line gains the prefix", { "#+title: x" }, 1, 1, { ": #+title: x" })

-- 2. One line: places org refuses.
refused("inside a src block", { "* H", "#+begin_src sh", "echo hi", "#+end_src" }, 3, 3)
refused("on a table row", { "* H", "| a | b |" }, 2, 2)
refused("on a list item", { "* H", "- item" }, 2, 2)
refused("inside a drawer", { "* H", ":PROPERTIES:", ":ID: x", ":END:" }, 3, 3)

-- 3. A region with anything but fixed-width lines converts everything,
-- at the region's minimum indentation.
toggled("a mixed region converts", { "* H", "aaa", "bbb", "ccc" }, 2, 3, {
  "* H",
  ": aaa",
  ": bbb",
  "ccc",
})
toggled("the marker lands at the region's minimum indent", { "* H", "  aaa", "    bbb" }, 2, 3, {
  "* H",
  "  : aaa",
  "  :   bbb",
})
toggled("an interior blank line converts too", { "* H", "aaa", "", "bbb" }, 2, 4, {
  "* H",
  ": aaa",
  ": ",
  ": bbb",
})
-- Blank lines that directly follow a converted headline get a bare `:`.
toggled("a blank after a headline gets a bare `:`", { "* H", "", "aaa" }, 1, 3, {
  ": * H",
  ":",
  ": aaa",
})
-- An already fixed-width line inside a converting region is left alone.
toggled("an already-marked line is not double-marked", { "* H", ": aaa", "bbb" }, 2, 3, {
  "* H",
  ": aaa",
  ": bbb",
})

-- 4. A region of nothing but fixed-width (and blank) lines is stripped.
toggled("an all-fixed-width region strips", { "* H", ": aaa", ": bbb", "ccc" }, 2, 3, {
  "* H",
  "aaa",
  "bbb",
  "ccc",
})
toggled("blank lines between fixed-width lines do not block the strip", {
  "* H",
  ": aaa",
  "",
  ": bbb",
}, 2, 4, { "* H", "aaa", "", "bbb" })

-- 5. Trailing blank lines are ignored unless the region holds nothing
-- else, in which case they all convert.
toggled("trailing blanks are ignored", { "* H", "aaa", "", "" }, 2, 4, {
  "* H",
  ": aaa",
  "",
  "",
})
toggled("an all-blank region converts every line", { "* H", "", "" }, 2, 3, {
  "* H",
  ": ",
  ": ",
})

-- 6. Round trip: toggling twice returns the original text.
do
  local before = { "* H", "  alpha", "  bravo" }
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, before)
  fixed_width.toggle(b, 2, 3)
  fixed_width.toggle(b, 2, 3)
  check(
    "toggle twice restores the text",
    vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), before),
    table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), " | ")
  )
end

-- 7. A large region converts in bounded time.
do
  local lines = { "* H" }
  for i = 1, 5000 do
    lines[#lines + 1] = ("line %d"):format(i)
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  local started = vim.uv.hrtime()
  local err = fixed_width.toggle(b, 2, 5001)
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check("5000 lines convert", err == nil and got[2] == ": line 1" and got[5001] == ": line 5000")
  check("5000 lines convert inside 5s", elapsed < 5000, ("%.0fms"):format(elapsed))
end

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\nfixed_width: all checks passed")
