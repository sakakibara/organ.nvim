-- organ.refile: `:Org refile_copy` (Emacs org-refile-copy, C-c M-w).
-- Emacs's org-refile-copy is org-refile with `org-refile-keep` bound to
-- t: the subtree is pasted under the target and re-levelled exactly as a
-- refile would, and the source is simply not deleted.  Verified against
-- Emacs 30 / org 9.7.11 before it was encoded here.
--
-- Run via: nvim --headless -l tests/refile_copy_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local refile = require("organ.refile")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function write_file(path, lines)
  vim.fn.writefile(lines, path)
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  return b
end

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

-- 1. Cross-file copy: the source keeps its subtree, the target gains a
-- re-levelled copy under the chosen headline.
do
  local dir = tmpdir()
  local src_path, tgt_path = dir .. "/src.org", dir .. "/tgt.org"
  local src = write_file(src_path, {
    "* Alpha",
    "  body of alpha",
    "** Alpha child",
    "* Sibling",
  })
  write_file(tgt_path, { "* Target", "  target body" })

  local err = refile.move(src, 1, tgt_path, 1, { copy = true })
  local src_lines = vim.fn.readfile(src_path)
  local tgt_lines = vim.fn.readfile(tgt_path)
  check("copy reports no error", err == nil, tostring(err))
  check(
    "the source subtree is untouched",
    vim.deep_equal(src_lines, { "* Alpha", "  body of alpha", "** Alpha child", "* Sibling" }),
    table.concat(src_lines, " | ")
  )
  check(
    "the target gains a re-levelled copy",
    vim.deep_equal(tgt_lines, {
      "* Target",
      "  target body",
      "** Alpha",
      "  body of alpha",
      "*** Alpha child",
    }),
    table.concat(tgt_lines, " | ")
  )
end

-- 2. The same call without `copy` still MOVES -- the existing contract
-- must not change.
do
  local dir = tmpdir()
  local src_path, tgt_path = dir .. "/src.org", dir .. "/tgt.org"
  local src = write_file(src_path, { "* Alpha", "  body", "* Sibling" })
  write_file(tgt_path, { "* Target" })

  local err = refile.move(src, 1, tgt_path, 1)
  check("a plain refile still moves", err == nil, tostring(err))
  check(
    "the source loses the subtree",
    vim.deep_equal(vim.fn.readfile(src_path), { "* Sibling" }),
    table.concat(vim.fn.readfile(src_path), " | ")
  )
end

-- 3. Same-file copy: the original stays where it was and the copy lands
-- at the end of the target's subtree.
do
  local dir = tmpdir()
  local path = dir .. "/one.org"
  local b = write_file(path, { "* Alpha", "  body", "* Target", "  target body" })
  local err = refile.move(b, 1, path, 3, { copy = true })
  local lines = vim.fn.readfile(path)
  check("same-file copy reports no error", err == nil, tostring(err))
  check(
    "the original and the copy both exist",
    vim.deep_equal(lines, {
      "* Alpha",
      "  body",
      "* Target",
      "  target body",
      "** Alpha",
      "  body",
    }),
    table.concat(lines, " | ")
  )
end

-- 4. The self-descendant guard still applies to a copy: refiling into
-- your own subtree would duplicate without end.
do
  local dir = tmpdir()
  local path = dir .. "/self.org"
  local b = write_file(path, { "* Alpha", "** Child", "* Other" })
  local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local err = refile.move(b, 1, path, 2, { copy = true })
  check(
    "copying into the subtree is refused",
    err == "Cannot refile to position inside the tree or region"
      and vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), before),
    tostring(err)
  )
end

-- 5. A target line that is not a headline is refused, and nothing moves.
do
  local dir = tmpdir()
  local src_path, tgt_path = dir .. "/src.org", dir .. "/tgt.org"
  local src = write_file(src_path, { "* Alpha", "  body" })
  write_file(tgt_path, { "* Target", "  target body" })
  local err = refile.move(src, 1, tgt_path, 2, { copy = true })
  check(
    "a non-headline target is refused",
    err == "target line is not a headline"
      and vim.deep_equal(vim.fn.readfile(src_path), { "* Alpha", "  body" }),
    tostring(err)
  )
end

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\nrefile_copy: all checks passed")
