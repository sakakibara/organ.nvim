-- Inline emphasis open requires a "pre-emphasis" character before
-- the marker (BOL, whitespace, or one of `('"{[`).  Mirrors Emacs's
-- `org-emphasis-regexp-components`.  Without this guard, paths like
-- `archive/2024.org_archive::` opened a spurious italic span on the
-- embedded `/`.
--
-- Run via: nvim --headless -l tests/inline_emphasis_boundary_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local parser_path = require("organ.defaults").parser_path
local indexer = require("organ.indexer")
vim.treesitter.language.add("org", { path = parser_path })
vim.treesitter.language.add("org_inline", { path = indexer._inline_parser_path(parser_path) })

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function inline_node_types(line)
  -- Parse a single line with the inline grammar directly and return
  -- the set of named child types under the root node.
  local trees = vim.treesitter.get_string_parser(line, "org_inline"):parse()
  local root = trees[1]:root()
  local types = {}
  local function walk(n)
    types[n:type()] = true
    for c in n:iter_children() do
      walk(c)
    end
  end
  walk(root)
  return types
end

-- (a) Path with embedded `/` — must NOT open italic.
do
  local types = inline_node_types("archive/2024-completed.org_archive::")
  check(
    "path `archive/2024-...::` does NOT open italic",
    not types.italic,
    "got types: " .. vim.inspect(types)
  )
end

-- (b) Real italic still works after a space.
do
  local types = inline_node_types("here is /italic/ text")
  check(
    "` /italic/ ` (space-bounded) DOES open italic",
    types.italic == true,
    "got types: " .. vim.inspect(types)
  )
end

-- (c) Italic at BOL works.
do
  local types = inline_node_types("/lead-italic/")
  check("`/lead/` at BOL opens italic", types.italic == true, "got types: " .. vim.inspect(types))
end

-- (d) `*bold*` after letter does NOT open bold.
do
  local types = inline_node_types("not*bold*here")
  check(
    "`not*bold*here` does NOT open bold (no pre-char)",
    not types.bold,
    "got types: " .. vim.inspect(types)
  )
end

-- (e) `*bold*` after `(` opens bold.
do
  local types = inline_node_types("(*bold*)")
  check(
    "`(*bold*)` opens bold (paren is valid pre-char)",
    types.bold == true,
    "got types: " .. vim.inspect(types)
  )
end

-- (f) Subscript `H_2O` still works (subscript respects different
-- pre-char rules from underline).
do
  local types = inline_node_types("H_2O")
  -- H_2O parses as an underline+plain or subscript; we just assert
  -- it does NOT spuriously open underline (which would require a
  -- closing `_` and there isn't one).
  check(
    "`H_2O` does NOT open underline (no closing `_`)",
    not types.underline,
    "got types: " .. vim.inspect(types)
  )
end

-- (g) Math context: `\alpha + \beta` -- `+` sits between spaces, so
-- pre-char rule lets it through, but post-char rule rejects (space
-- after).  Strike must NOT open.
do
  local types = inline_node_types("\\alpha + \\beta = \\gamma")
  check(
    "`\\alpha + \\beta` does NOT open strike (space after +)",
    not types.strike,
    "got types: " .. vim.inspect(types)
  )
end

-- (h) Real strike still works: `+strike+` (no spaces).
do
  local types = inline_node_types("here is +struck+ text")
  check(
    "`+struck+` (no surrounding spaces) DOES open strike",
    types.strike == true,
    "got types: " .. vim.inspect(types)
  )
end

-- (i) Bold `* foo*` (space after open) does NOT open.  Leading `*`
-- is rejected by the post-char rule (space after open) and the
-- trailing `*` is rejected by the pre-char rule (letter before).
do
  local types = inline_node_types("* not bold*")
  check(
    "`* foo*` (space after `*`) does NOT open bold",
    not types.bold,
    "got types: " .. vim.inspect(types)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("inline_emphasis_boundary_test: PASS")
