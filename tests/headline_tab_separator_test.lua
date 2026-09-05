-- A headline is a star run followed by a SPACE.  `*<TAB>text` is body
-- text, and every module has to agree on that or fold renders a line as
-- body while structure moves it as a heading.
--
-- Verified against `emacs --batch -Q -l org` (Org 9.7.11):
--   org-outline-regexp          -> "\\*+ "
--   `*<TAB>tab head`            -> org-element-at-point = paragraph
--   `* <TAB>TODO tabbed kw`     -> org-get-todo-state = nil,
--                                  org-get-heading = "<TAB>TODO tabbed kw"
--   `*   Spaced title`          -> org-get-heading = "Spaced title"
--
-- Run via: nvim --headless -l tests/headline_tab_separator_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local headline = require("organ.headline")
local element_cache = require("organ.element_cache")
local fold = require("organ.fold")
local structure = require("organ.structure")

-- 1. The shared splitter.
check("split rejects a tab separator", headline.split("*\ttab head") == nil)
check("split rejects `**<TAB>`", headline.split("**\tdeep") == nil)
do
  local lvl, rest = headline.split("*   Spaced title")
  check("split eats every separating space", lvl == 1 and rest == "Spaced title", tostring(rest))
end
do
  local lvl, rest = headline.split("* \tTODO tabbed kw")
  check(
    "split keeps a tab that follows the separating space",
    lvl == 1 and rest == "\tTODO tabbed kw",
    vim.inspect(rest)
  )
end
do
  local lvl, rest = headline.split("** ")
  check("split still accepts an empty title", lvl == 2 and rest == "", tostring(rest))
end

local BUF = { "* A", "body", "*\tnot heading", "more", "** B", "tail" }

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, BUF)

-- 2. The indexer agrees with the splitter.
do
  local seen = {}
  for _, h in ipairs(element_cache.headlines(bufnr)) do
    seen[#seen + 1] = h.line
  end
  check("element_cache skips the tab line", vim.deep_equal(seen, { 1, 5 }), vim.inspect(seen))
  local owner = element_cache.containing(bufnr, 3)
  check(
    "the tab line belongs to the heading above it",
    owner ~= nil and owner.line == 1,
    owner and tostring(owner.line) or "nil"
  )
end

-- 3. fold and the structural model agree on which lines start a section.
do
  local levels = fold._build_fold_levels(bufnr)
  local fold_starts = {}
  for i, lv in ipairs(levels) do
    if lv:sub(1, 1) == ">" then
      fold_starts[#fold_starts + 1] = i
    end
  end
  local model = {}
  for _, h in ipairs(element_cache.headlines(bufnr)) do
    model[#model + 1] = h.line
  end
  check(
    "fold starts match the headline model",
    vim.deep_equal(fold_starts, model),
    "fold=" .. vim.inspect(fold_starts) .. " model=" .. vim.inspect(model)
  )
end

-- 4. The user-visible harm: moving a subtree must carry the tab line with
--    the section fold draws it into, not strand it above the next heading.
do
  local mv = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(mv)
  vim.bo[mv].filetype = "org"
  vim.api.nvim_buf_set_lines(mv, 0, -1, false, {
    "* A",
    "*\tnot heading",
    "* B",
    "b body",
  })
  local err = structure.move_subtree_down({ bufnr = mv, line = 1 })
  local got = vim.api.nvim_buf_get_lines(mv, 0, -1, false)
  check(
    "move_subtree_down carries the tab line with its heading",
    err == nil and vim.deep_equal(got, { "* B", "b body", "* A", "*\tnot heading" }),
    tostring(err) .. " " .. vim.inspect(got)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("headline_tab_separator_test: PASS")
os.exit(0)
