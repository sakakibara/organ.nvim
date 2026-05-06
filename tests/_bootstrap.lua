-- Common test bootstrap — sets up runtimepath + verifies that fresh-
-- clone setup steps have been run.  Source this from any test:
--
--   dofile(vim.fn.getcwd() .. "/tests/_bootstrap.lua")
--
-- Prints a clear "run `make test` first" message on missing deps so a
-- developer hitting a fresh clone doesn't have to spelunk the rtp
-- prepend lines to figure out what's missing.

local root = vim.fn.getcwd()

local function fail(msg)
  io.stderr:write("\n")
  io.stderr:write("ERROR: " .. msg .. "\n")
  io.stderr:write("\n")
  io.stderr:write("Run `make test` (or `make deps && make grammar`) first.\n")
  io.stderr:write("\n")
  os.exit(2)
end

if vim.fn.isdirectory(root .. "/tests/deps/tablature.nvim") == 0 then
  fail("tests/deps/tablature.nvim is missing")
end

local parser_so = vim.fn.stdpath("data") .. "/organ/parser/org.so"
if vim.fn.filereadable(parser_so) == 0 then
  fail("tree-sitter grammar not built (missing " .. parser_so .. ")")
end

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/tests/deps/tablature.nvim")
if vim.fn.isdirectory(root .. "/tests/deps/narrow.nvim") == 1 then
  vim.opt.runtimepath:prepend(root .. "/tests/deps/narrow.nvim")
end
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/organ")

-- Register custom tree-sitter predicates (`#org-todo-keyword?`,
-- `#org-stars-level?`, etc.) used by the highlight queries.  In a
-- normal nvim run plugin/organ.lua does this; tests that bypass the
-- plugin entry must do it themselves to avoid "No handler" errors
-- from the highlighter.
pcall(function()
  require("organ.treesitter_directives").register()
end)
