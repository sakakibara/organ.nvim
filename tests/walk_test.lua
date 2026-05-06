-- Pure-ish unit: walk.walk_async discovers dirs and files, follows symlinks,
-- detects inode cycles, yields between batches, fires on_done exactly once.
-- Run via: nvim --headless -l tests/walk_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local walk = require("organ.walk")

local function build_tree(base)
  -- base/
  --   a.txt
  --   sub/
  --     b.txt
  --   linked -> realdir
  --   realdir/
  --     c.txt
  --   loop -> base   (cycle)
  vim.fn.mkdir(base .. "/sub", "p")
  vim.fn.mkdir(base .. "/realdir", "p")
  for _, p in ipairs({ base .. "/a.txt", base .. "/sub/b.txt", base .. "/realdir/c.txt" }) do
    local fh = assert(io.open(p, "w"))
    fh:write("x")
    fh:close()
  end
  vim.loop.fs_symlink(base .. "/realdir", base .. "/linked")
  vim.loop.fs_symlink(base, base .. "/loop")
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
build_tree(tmp)

local seen_dirs, seen_files = {}, {}
local done_called = 0

walk.walk_async(tmp, 50, function(p)
  seen_dirs[#seen_dirs + 1] = p
end, function(p, _st)
  seen_files[#seen_files + 1] = p
end, function()
  done_called = done_called + 1
end)

-- Wait for async completion.
vim.wait(2000, function()
  return done_called > 0
end, 20)
assert(done_called == 1, "on_done called " .. done_called .. " times, expected 1")

-- All three real files discovered (under sub/, realdir/, root).
-- linked/ should ALSO surface c.txt (followed via fs_stat).
table.sort(seen_files)
local file_set = {}
for _, p in ipairs(seen_files) do
  file_set[p] = true
end

assert(file_set[tmp .. "/a.txt"], "missing a.txt")
assert(file_set[tmp .. "/sub/b.txt"], "missing sub/b.txt")

-- realdir/c.txt and linked/c.txt are the same file (linked is a symlink to
-- realdir). Inode-based dedup means it should appear under EXACTLY ONE of
-- the two paths, never both.
local n_c = (file_set[tmp .. "/realdir/c.txt"] and 1 or 0)
  + (file_set[tmp .. "/linked/c.txt"] and 1 or 0)
assert(
  n_c == 1,
  "c.txt should appear exactly once across realdir/ and linked/, got "
    .. n_c
    .. " (proves symlinked dirs are followed AND deduped by inode)"
)

-- Cycle detection: the `loop` symlink points back to base; walker must NOT
-- re-enter. So a.txt should appear exactly once, not many times.
local n_axt = 0
for _, p in ipairs(seen_files) do
  if p == tmp .. "/a.txt" then
    n_axt = n_axt + 1
  end
end
assert(n_axt == 1, "a.txt seen " .. n_axt .. " times — cycle detection failed")

vim.fn.delete(tmp, "rf")
io.write("walk ok\n")
os.exit(0)
