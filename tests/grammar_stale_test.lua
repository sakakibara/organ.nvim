-- Regression: grammar_install.check_stale() must warn exactly when an
-- installed parser is older than the source revision the build hook last
-- fetched -- the silent-degradation case where an update pulled a new
-- grammar revision but its build failed, leaving the parser frozen.
--
-- The check compares the build manifest's recorded revision against the
-- source clone's current HEAD, using only local git.  This test drives it
-- against a sandboxed data dir (own XDG_DATA_HOME) with a real throwaway
-- git clone, and captures vim.notify.
--
-- Run via: nvim --headless -l tests/grammar_stale_test.lua

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local gi = require("organ.grammar_install")

-- Capture notifications instead of surfacing them.
local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = msg, level = level }
end

local function git(dir, ...)
  local res = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  if res.code ~= 0 then
    error(("git %s failed: %s"):format(table.concat({ ... }, " "), res.stderr or ""))
  end
  return (res.stdout or ""):gsub("%s+$", "")
end

-- Sandbox stdpath("data") by pointing XDG_DATA_HOME at a temp dir.  nvim
-- resolves stdpath("data") = $XDG_DATA_HOME/nvim, cached per process, so
-- set it before the first stdpath("data") call this test cares about.
local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox, "p")
vim.env.XDG_DATA_HOME = sandbox

-- Hermetic git env: don't inherit the dev's global config (which may
-- enable commit.gpgsign and need a signing agent the test sandbox
-- doesn't run). Empty config files work cross-platform.
local empty_cfg = sandbox .. "/empty.gitconfig"
io.open(empty_cfg, "w"):close()
vim.env.GIT_CONFIG_GLOBAL = empty_cfg
vim.env.GIT_CONFIG_SYSTEM = empty_cfg
local data = vim.fn.stdpath("data") .. "/organ"
assert(data:find(sandbox, 1, true), "sandbox not in effect: " .. data)

local parser_dir = data .. "/parser"
local src_root = data .. "/src"
vim.fn.mkdir(parser_dir, "p")
vim.fn.mkdir(src_root, "p")

-- A real one-commit git clone standing in for the fetched source tree.
local repo = "tree-sitter-organ"
local src = src_root .. "/" .. repo
vim.fn.mkdir(src, "p")
git(src, "init", "--quiet")
git(src, "config", "user.email", "t@e.st")
git(src, "config", "user.name", "t")
vim.fn.writefile({ "v1" }, src .. "/grammar.js")
git(src, "add", "grammar.js")
git(src, "commit", "--quiet", "-m", "one")
local rev1 = git(src, "rev-parse", "HEAD")

local function write_manifest(rev)
  local fd = assert(io.open(parser_dir .. "/.build-manifest.json", "w"))
  fd:write(vim.json.encode({ ["org.so"] = { repo = repo, rev = rev } }))
  fd:close()
end

local function reset_check_state()
  -- check_stale() warns once per session; reload the module to clear its
  -- private _stale_warned flag between cases.
  package.loaded["organ.grammar_install"] = nil
  gi = require("organ.grammar_install")
end

-- Case 1: manifest matches HEAD -> silent.
notes = {}
write_manifest(rev1)
reset_check_state()
gi.check_stale()
assert(#notes == 0, "in-sync install must not warn, got: " .. vim.inspect(notes))

-- Case 2: source clone advances past the recorded rev -> one WARN.
vim.fn.writefile({ "v2" }, src .. "/grammar.js")
git(src, "add", "grammar.js")
git(src, "commit", "--quiet", "-m", "two")
notes = {}
reset_check_state()
gi.check_stale()
assert(#notes == 1, "stale install must warn exactly once, got: " .. #notes)
assert(notes[1].level == vim.log.levels.WARN, "warning must be WARN level")
assert(notes[1].msg:find("org.so", 1, true), "message must name the stale parser")

-- Case 3: warned-once guard -> a second call in the same session is silent.
notes = {}
gi.check_stale()
assert(#notes == 0, "check_stale must warn at most once per session, got: " .. #notes)

-- Case 4: no manifest (installed before the feature / prebuilt path) -> silent.
vim.fn.delete(parser_dir .. "/.build-manifest.json")
notes = {}
reset_check_state()
gi.check_stale()
assert(#notes == 0, "missing manifest must be silent, got: " .. vim.inspect(notes))

-- Case 5: manifest present but no source clone -> silent (can't compare).
write_manifest(rev1)
vim.fn.delete(src, "rf")
notes = {}
reset_check_state()
gi.check_stale()
assert(#notes == 0, "absent source clone must be silent, got: " .. vim.inspect(notes))

io.write("grammar stale detection ok\n")
os.exit(0)
