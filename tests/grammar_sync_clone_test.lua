-- The grammar clone is brought to exactly the pinned revision with real
-- git: a fresh clone, a reused one with local edits and build output, an
-- unreachable pin that leaves the clone in place, and a clone a killed
-- git left locked.
-- Run via: nvim --headless -l tests/grammar_sync_clone_test.lua

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox, "p")
vim.env.XDG_DATA_HOME = sandbox
local empty_cfg = sandbox .. "/empty.gitconfig"
io.open(empty_cfg, "w"):close()
vim.env.GIT_CONFIG_GLOBAL = empty_cfg
vim.env.GIT_CONFIG_SYSTEM = empty_cfg

local gi = require("organ.grammar_install")
vim.notify = function() end

local function git(dir, ...)
  local res = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  assert(res.code == 0, ("git %s: %s"):format(table.concat({ ... }, " "), res.stderr or ""))
  return (res.stdout or ""):gsub("%s+$", "")
end

-- An upstream with the pin behind its tip, as after a grammar push.
local upstream = sandbox .. "/upstream"
vim.fn.mkdir(upstream, "p")
git(upstream, "init", "--quiet")
git(upstream, "config", "user.email", "t@e.st")
git(upstream, "config", "user.name", "t")
vim.fn.writefile({ "one" }, upstream .. "/grammar.js")
git(upstream, "add", "grammar.js")
git(upstream, "commit", "--quiet", "-m", "one")
local pin = git(upstream, "rev-parse", "HEAD")
vim.fn.writefile({ "two" }, upstream .. "/grammar.js")
git(upstream, "commit", "--quiet", "-am", "two")
local url = "file://" .. upstream

local failures = 0
local function check(label, ok, detail)
  if not ok then
    failures = failures + 1
    io.write("FAIL  " .. label .. (detail and ("\n     " .. tostring(detail)) or "") .. "\n")
  end
end

local dest = sandbox .. "/src/tree-sitter-organ"

local ok, err = gi._fetch_pinned(url, dest, pin)
check("a fresh clone syncs", ok, err)
check("a fresh clone checks out the pin, not the tip", git(dest, "rev-parse", "HEAD") == pin)
check("the pinned content", vim.fn.readfile(dest .. "/grammar.js")[1] == "one")

vim.fn.writefile({ "edited" }, dest .. "/grammar.js")
vim.fn.mkdir(dest .. "/build", "p")
vim.fn.writefile({ "x" }, dest .. "/build/org.so")
ok, err = gi._fetch_pinned(url, dest, pin)
check("a reused clone syncs", ok, err)
check("local edits are dropped", vim.fn.readfile(dest .. "/grammar.js")[1] == "one")
check("build output is cleaned", vim.fn.isdirectory(dest .. "/build") == 0)

ok, err = gi._fetch_pinned(url, dest, string.rep("0", 40))
check("an unreachable pin fails", not ok)
check("the failure names git's error", type(err) == "string" and err ~= "", err)
check("a failed fetch keeps the clone it had", git(dest, "rev-parse", "HEAD") == pin)

ok, err = gi._fetch_pinned(url, dest, pin)
check("a clone recovers after a failed sync", ok, err)
vim.fn.writefile({}, dest .. "/.git/index.lock")
ok, err = gi._fetch_pinned(url, dest, pin)
check("a clone left locked by a killed git is started over", ok, err)
check("and ends at the pin", git(dest, "rev-parse", "HEAD") == pin)
check("without the lock", vim.fn.filereadable(dest .. "/.git/index.lock") == 0)

-- A user's url.<base>.insteadOf rewrite of the grammar URL is not a
-- different remote: the clone is kept, not deleted and fetched again.
local alias = sandbox .. "/alias"
vim.uv.fs_symlink(upstream, alias)
local marker = dest .. "/.git/organ-keep-marker"
vim.fn.writefile({}, marker)
local f = assert(io.open(empty_cfg, "w"))
f:write(('[url "file://%s"]\n\tinsteadOf = %s\n'):format(alias, url))
f:close()
ok, err = gi._fetch_pinned(url, dest, pin)
io.open(empty_cfg, "w"):close()
check("an insteadOf rewrite syncs", ok, err)
check("an insteadOf rewrite keeps the clone", vim.fn.filereadable(marker) == 1)

vim.fn.delete(sandbox, "rf")
if failures > 0 then
  io.write(("FAILED %d checks\n"):format(failures))
  os.exit(1)
end
io.write("grammar sync clone ok\n")
