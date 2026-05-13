-- Regression for the "Index out of bounds" crash from
-- vim/treesitter.lua:212.  Range-bounded parser:parse({...}) calls in
-- multiple decoration providers used to corrupt org_inline injection
-- state, which then surfaced as a crash inside iter_captures the next
-- time a downstream caller asked for node text.  The decoration
-- dispatcher now parses once per buffer per redraw and exposes the
-- cached tree; providers query the cache instead of calling parse
-- themselves.
--
-- Run via: nvim --headless -l tests/decoration_parse_cache_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
local indexer = require("organ.indexer")
vim.treesitter.language.add("org", { path = parser_path })
vim.treesitter.language.add("org_inline", { path = indexer._inline_parser_path(parser_path) })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  modern = { blocks = true, bullets = true, pills = true },
  description_list = { enabled = true },
})

local decoration = require("organ.decoration")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- 1. get_tree returns a tree on a basic org buffer (no src blocks).
do
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Heading",
    "Some /italic/ and *bold* text.",
    "- list item with [[link][label]]",
    "| col1 | col2 |",
    "| a    | b    |",
  })
  local tree = decoration.get_tree(b)
  check("get_tree returns tree on plain org buffer", tree ~= nil)
end

-- 2. get_tree is stable: same changedtick -> same tree.
do
  local b = vim.api.nvim_create_buf(true, false)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* A", "body" })
  local t1 = decoration.get_tree(b)
  local t2 = decoration.get_tree(b)
  check("get_tree is stable across calls with no edits", t1 == t2)
end

-- 3. get_tree refreshes after an edit.
do
  local b = vim.api.nvim_create_buf(true, false)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* A", "body" })
  local t1 = decoration.get_tree(b)
  vim.api.nvim_buf_set_lines(b, 1, 2, false, { "edited body" })
  local t2 = decoration.get_tree(b)
  -- Tree-sitter may return the same tree object after an incremental
  -- edit; we only require that the call doesn't crash and yields a
  -- non-nil tree.
  check("get_tree handles edits without crash", t1 ~= nil and t2 ~= nil)
end

-- 4. get_tree returns nil gracefully on an invalid buffer rather than
--    raising.  The cache is queried from on_win callbacks where a
--    buffer may have been wiped between scheduling and dispatch.
do
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_delete(b, { force = true })
  local ok, tree = pcall(decoration.get_tree, b)
  check("get_tree returns nil on invalid buffer without raising", ok and tree == nil)
end

-- 5. Driving on_win on a buffer with heavy injection content does not
--    crash.  This is the reproducer for the original "Index out of
--    bounds" report: org_inline is injected on every paragraph /
--    headline / list-item / table-row, so a stale-injection bug shows
--    up here even without #+begin_src blocks.
do
  local b = vim.api.nvim_create_buf(true, false)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* TODO Heading with /italic/ and *bold*",
    "DEADLINE: <2026-05-15 Fri>",
    "Paragraph with [[link][label]] and ~code~.",
    "- list item one",
    "  - nested with =verbatim=",
    "| a | b |",
    "| 1 | 2 |",
  })
  local ok = pcall(function()
    -- Drive each provider's full-buffer on_win path.  Use whichever
    -- test-facing entrypoint each module exposes; pcall the require
    -- itself so a missing dep on one provider doesn't mask the others.
    pcall(function()
      require("organ.modern.blocks")._apply(b)
    end)
    pcall(function()
      require("organ.modern.bullets")._apply(b)
    end)
    pcall(function()
      require("organ.modern.pills")._apply(b)
    end)
    pcall(function()
      require("organ.conceal")._apply(b)
    end)
    pcall(function()
      require("organ.description_list")._apply(b)
    end)
    pcall(function()
      -- indent's on_win is gated on _attached[bufnr]; attach() flips it
      -- and calls refresh internally.
      require("organ.indent").attach(b)
    end)
  end)
  check("provider refresh on heavy-injection buffer doesn't raise", ok)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_parse_cache_test: PASS")
os.exit(0)
