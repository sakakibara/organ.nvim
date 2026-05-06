-- copy_artifact must produce a FRESH inode at the destination (not
-- truncate-in-place) and preserve the source's mode bits.  macOS
-- Sequoia caches dylib code-signature validity by inode, so an
-- in-place rewrite at a stable parser path SIGKILLs nvim with
-- "Code Signature Invalid" the next time the parser is dlopen'd.
-- The mode-bit check guards against +x being stripped on copy
-- (umask) which dlopen also rejects on some versions.
--
-- Run via: nvim --headless -l tests/grammar_install_copy_artifact_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local gi = require("organ.grammar_install")
-- copy_artifact is a local in the module; expose for tests.  When
-- not exposed yet, fail loudly so the next refactor remembers to.
local copy_artifact = gi._copy_artifact or gi.copy_artifact
if not copy_artifact then
  print("FAIL  organ.grammar_install does not expose copy_artifact for tests")
  os.exit(1)
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local src = tmp .. "/src.so"
local dst = tmp .. "/dst.so"

-- Build a plausible "executable" source file with mode 0755 so the
-- copy has a real +x bit to preserve.
vim.fn.writefile({ "ELF or Mach-O bytes go here" }, src)
vim.uv.fs_chmod(src, tonumber("755", 8))

-- Pre-seed dst with different content so we can detect inode reuse.
vim.fn.writefile({ "old content" }, dst)
vim.uv.fs_chmod(dst, tonumber("644", 8))
local pre_stat = vim.uv.fs_stat(dst)
local pre_inode = pre_stat and pre_stat.ino

-- Copy.
local ok, err = copy_artifact(src, dst)
check("copy_artifact returns ok", ok == true, tostring(err))

-- (a) Content matches.
do
  local got = table.concat(vim.fn.readfile(dst, "b"), "")
  local want = table.concat(vim.fn.readfile(src, "b"), "")
  check("dst content matches src", got == want, "got=" .. got .. " want=" .. want)
end

-- (b) Executable bit preserved.
do
  local stat = vim.uv.fs_stat(dst)
  -- mode is full file mode incl. type bits; mask to permission bits.
  local perms = bit.band(stat.mode, tonumber("777", 8))
  -- Source was 0755; expect dst >= 0700 with +x for owner.
  local owner_x = bit.band(perms, tonumber("100", 8)) ~= 0
  check("dst preserves owner +x bit", owner_x, string.format("perms=%o", perms))
end

-- (c) Inode changed -- atomic rename guarantees a fresh inode.
do
  local post_stat = vim.uv.fs_stat(dst)
  local post_inode = post_stat and post_stat.ino
  check(
    "dst inode changed (fresh inode, not in-place truncate)",
    pre_inode ~= nil and post_inode ~= nil and pre_inode ~= post_inode,
    string.format("pre=%s post=%s", tostring(pre_inode), tostring(post_inode))
  )
end

-- (d) No leftover .tmp file in the destination directory.
do
  local entries = vim.fn.glob(tmp .. "/*.tmp.*", false, true)
  check("no .tmp.<pid> files left behind", #entries == 0, table.concat(entries, ","))
end

-- (e) Missing source surfaces a clear error, no exception.
do
  local ok2, err2 = copy_artifact(tmp .. "/nonexistent", tmp .. "/wherever.so")
  check("missing source returns false", ok2 == false)
  check(
    "missing source error mentions the source path",
    type(err2) == "string" and err2:find("nonexistent", 1, true) ~= nil,
    tostring(err2)
  )
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("grammar_install_copy_artifact_test: PASS")
