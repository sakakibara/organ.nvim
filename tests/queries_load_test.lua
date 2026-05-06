-- queries/org/*.scm load against the installed tree-sitter-organ /
-- tree-sitter-organ-inline grammars; capture iteration on fixtures
-- yields non-empty captures for known nodes.
-- Run via: nvim --headless -l tests/queries_load_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

-- Register custom predicates used by queries/org/highlights.scm
-- (e.g. #org-heading-level?). Normally plugin/organ.lua does this at startup;
-- under `nvim --headless -l`, plugin sourcing varies, so do it explicitly.
require("organ.treesitter_directives").register()

local function read(path)
  local fh = assert(io.open(path, "r"))
  local body = fh:read("*a")
  fh:close()
  return body
end

-- 1. highlights.scm parses.
local hl_src = read(root .. "/queries/org/highlights.scm")
local ok, hl_query = pcall(vim.treesitter.query.parse, "org", hl_src)
assert(ok, "highlights.scm parse error: " .. tostring(hl_query))

-- 2. folds.scm parses.
local fold_src = read(root .. "/queries/org/folds.scm")
local ok2, fold_query = pcall(vim.treesitter.query.parse, "org", fold_src)
assert(ok2, "folds.scm parse error: " .. tostring(fold_query))

-- 3. indents.scm parses.
local ind_src = read(root .. "/queries/org/indents.scm")
local ok3, ind_query = pcall(vim.treesitter.query.parse, "org", ind_src)
assert(ok3, "indents.scm parse error: " .. tostring(ind_query))

-- 4. Capture iteration on fixture 01 produces at least one @org.heading.1 capture.
local fixture = root .. "/tests/fixtures/01-headlines.org"
local src = read(fixture)
local parser = vim.treesitter.get_string_parser(src, "org")
local tree = parser:parse()[1]
local found_h1 = false
for id, _node in hl_query:iter_captures(tree:root(), src) do
  local name = hl_query.captures[id]
  if name == "org.heading.1" then
    found_h1 = true
    break
  end
end
assert(found_h1, "expected at least one @org.heading.1 capture in fixture 01")

-- 5. folds.scm produces at least one @fold capture for fixture 01.
local found_fold = false
for id, _node in fold_query:iter_captures(tree:root(), src) do
  if fold_query.captures[id] == "fold" then
    found_fold = true
    break
  end
end
assert(found_fold, "expected at least one @fold capture in fixture 01")

io.write("queries load ok\n")
os.exit(0)
