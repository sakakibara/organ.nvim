-- roam.linkify: replace prose matches with [[id:UUID][text]] links;
-- skip already-bracketed text; honor word boundaries; longest match wins.
-- Run via: nvim --headless -l tests/roam_linkify_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local lk = require("organ.roam.linkify")

local entries = {
  { lower = "neovim", title = "Neovim", id = "uuid-1" },
  { lower = "tree-sitter", title = "Tree-sitter", id = "uuid-2" },
  { lower = "tree", title = "Tree", id = "uuid-3" }, -- shorter; longest-wins should pick tree-sitter
}
table.sort(entries, function(a, b)
  return #a.lower > #b.lower
end)

-- 1. Single match.
do
  local out, n = lk.linkify_line("I love Neovim.", entries)
  assert(n == 1, "n=" .. n)
  assert(out == "I love [[id:uuid-1][Neovim]].", "out: " .. out)
end

-- 2. Word-boundary respected: "neovim2" should NOT match.
do
  local out, n = lk.linkify_line("neovim2 is fake", entries)
  assert(n == 0, "no match expected; got " .. n)
  assert(out == "neovim2 is fake", "out: " .. out)
end

-- 3. Already-bracketed text is skipped.
do
  local out, n = lk.linkify_line("see [[id:other][Neovim]] for details", entries)
  assert(n == 0, "should skip protected; got " .. n)
end

-- 4. Multiple matches in one line.
do
  local out, n = lk.linkify_line("Neovim plus Tree-sitter rocks", entries)
  assert(n == 2, "n=" .. n)
  assert(out:find("[[id:uuid-1][Neovim]]", 1, true), "neovim link missing")
  assert(out:find("[[id:uuid-2][Tree-sitter]]", 1, true), "tree-sitter link missing")
end

-- 5. Longest wins: "Tree-sitter" trumps "Tree" prefix.
do
  local out, n = lk.linkify_line("I learned Tree-sitter today.", entries)
  assert(n == 1, "n=" .. n)
  assert(out:find("[[id:uuid-2][Tree-sitter]]", 1, true), "longest match should win; got: " .. out)
  assert(not out:find("[[id:uuid-3]", 1, true), "shorter 'Tree' must not also match")
end

-- 6. Case-insensitive.
do
  local out, n = lk.linkify_line("NEOVIM is great", entries)
  assert(n == 1, "case-insensitive match")
  assert(out == "[[id:uuid-1][NEOVIM]] is great", "preserves original casing: " .. out)
end

-- 7. completion_items honors min_chars.
do
  -- Build a one-shot stub by monkey-patching M.build_index for this case.
  local orig = lk.build_index
  lk.build_index = function()
    return entries
  end
  local short = lk.completion_items("n", 2)
  assert(#short == 0, "1-char query should be empty under min_chars=2")
  local hit = lk.completion_items("ne", 2)
  assert(#hit > 0, "ne should match neovim")
  assert(
    hit[1].insertText == "[[id:uuid-1][Neovim]]",
    "completion insertText: " .. hit[1].insertText
  )
  lk.build_index = orig
end

-- 8. build_index memoizes; invalidate_index forces a fresh build.
do
  lk.invalidate_index() -- start from a clean cache
  local n_calls = 0
  local orig_uncached = lk._build_index_uncached
  lk._build_index_uncached = function()
    n_calls = n_calls + 1
    return { { lower = "foo", title = "Foo", id = "fid" } }
  end
  local _ = lk.build_index()
  local _ = lk.build_index()
  assert(n_calls == 1, "second build_index should hit cache; got " .. n_calls)
  lk.invalidate_index()
  local _ = lk.build_index()
  assert(n_calls == 2, "invalidate_index should force rebuild; got " .. n_calls)
  lk._build_index_uncached = orig_uncached
  lk.invalidate_index() -- don't leak stubbed entries across tests
end

io.write("roam linkify ok\n")
os.exit(0)
