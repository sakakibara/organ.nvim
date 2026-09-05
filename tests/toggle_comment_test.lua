-- organ.structure.toggle_comment: `:Org toggle_comment` (Emacs
-- org-toggle-comment, C-c ;).  Every expectation is the headline real
-- Emacs 30 / org 9.7.11 writes for the same input, checked with
--   emacs --batch -Q -l org --eval '(org-toggle-comment)'
-- before it was encoded here.
--
-- Run via: nvim --headless -l tests/toggle_comment_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local structure = require("organ.structure")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function toggled(label, lines, line, want)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  local err = structure.toggle_comment({ bufnr = b, line = line })
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(label, err == nil and vim.deep_equal(got, want), err or table.concat(got, " | "))
end

-- 1. COMMENT goes after the TODO keyword and the priority cookie, and
-- the tags stay where they are.
toggled(
  "COMMENT lands after the priority cookie",
  { "* TODO [#A] Task :tag:", "body" },
  1,
  { "* TODO [#A] COMMENT Task :tag:", "body" }
)

-- 2. Toggling off takes the keyword wherever it sits after the TODO.
toggled(
  "COMMENT is removed from before the cookie too",
  { "* TODO COMMENT [#A] Task :tag:", "body" },
  1,
  { "* TODO [#A] Task :tag:", "body" }
)

-- 3. A plain headline.
toggled("a plain headline gains COMMENT", { "* Task" }, 1, { "* COMMENT Task" })

-- 4. From a body line, the enclosing headline is the one that changes.
toggled(
  "a body line toggles its own headline",
  { "* Task", "body" },
  2,
  { "* COMMENT Task", "body" }
)

-- 5. Empty titles: Emacs leaves the trailing space that keeps the line
-- a headline.
toggled("an empty title gains COMMENT", { "* " }, 1, { "* COMMENT" })
toggled("removing from an empty title keeps the space", { "* COMMENT" }, 1, { "* " })
toggled("removing after a TODO keeps the space", { "* TODO COMMENT" }, 1, { "* TODO " })
toggled("a bare TODO headline gains COMMENT", { "* TODO" }, 1, { "* TODO COMMENT" })

-- 6. Round trip.
do
  local before = { "* TODO [#B] Write the docs :work:", "body" }
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, before)
  structure.toggle_comment({ bufnr = b, line = 1 })
  structure.toggle_comment({ bufnr = b, line = 1 })
  check(
    "toggle twice restores the headline",
    vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), before),
    table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), " | ")
  )
end

-- 7. Off any headline, Emacs raises "Before first headline"; organ
-- reports and leaves the buffer alone.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "no headings here" })
  local err = structure.toggle_comment({ bufnr = b, line = 1 })
  check(
    "a buffer with no headline refuses",
    err == "not inside a headline"
      and vim.api.nvim_buf_get_lines(b, 0, -1, false)[1] == "no headings here",
    tostring(err)
  )
end

-- 8. A COMMENT keyword the command did not write is still recognised
-- for removal -- `COMMENTARY` is not, because org requires whitespace
-- or end of line after the keyword.
toggled(
  "COMMENTARY is not a COMMENT keyword",
  { "* COMMENTARY notes" },
  1,
  { "* COMMENT COMMENTARY notes" }
)

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\ntoggle_comment: all checks passed")
