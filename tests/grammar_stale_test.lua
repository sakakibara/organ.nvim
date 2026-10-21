-- Regression: grammar_install.check_stale() must warn exactly when an
-- installed parser is not the pinned revision (organ updated, grammars
-- not rebuilt) or is not the file the last completed install built (a
-- partial install replaced it), and stay silent otherwise.
--
-- Drives check_stale() against a sandboxed data dir (own XDG_DATA_HOME)
-- with a stand-in parser file and manifest, and captures vim.notify.
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

-- Sandbox stdpath("data") by pointing XDG_DATA_HOME at a temp dir.  nvim
-- resolves stdpath("data") = $XDG_DATA_HOME/nvim, cached per process, so
-- set it before the first stdpath("data") call this test cares about.
local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox, "p")
vim.env.XDG_DATA_HOME = sandbox
local data = vim.fn.stdpath("data") .. "/organ"
assert(data:find(sandbox, 1, true), "sandbox not in effect: " .. data)

local parser_dir = data .. "/parser"
vim.fn.mkdir(parser_dir, "p")

local repo = "tree-sitter-organ"
local rev1 = "1111111111111111111111111111111111111111"
local pin = rev1

vim.fn.writefile({ "built parser" }, parser_dir .. "/org.so")
local built_sha = vim.fn.sha256("built parser\n")

local function write_manifest(rev, local_src)
  local fd = assert(io.open(parser_dir .. "/.build-manifest.json", "w"))
  fd:write(vim.json.encode({
    ["org.so"] = { repo = repo, rev = rev, sha256 = built_sha, local_src = local_src },
  }))
  fd:close()
end

local function reset_check_state()
  -- check_stale() warns once per session; reload the module to clear its
  -- private _stale_warned flag between cases.
  package.loaded["organ.grammar_install"] = nil
  gi = require("organ.grammar_install")
  gi.pins = function()
    return { [repo] = pin }
  end
end

local function run()
  notes = {}
  reset_check_state()
  gi.check_stale()
end

-- Case 1: the pinned revision, the file the install built -> silent.
write_manifest(rev1)
run()
assert(#notes == 0, "in-sync install must not warn, got: " .. vim.inspect(notes))

-- Case 2: organ pins another revision (updated without a rebuild) -> one
-- WARN naming the pin mismatch.
pin = "0123456789abcdef0123456789abcdef01234567"
run()
assert(#notes == 1, "unpinned install must warn exactly once, got: " .. #notes)
assert(notes[1].level == vim.log.levels.WARN, "warning must be WARN level")
assert(notes[1].msg:find("org.so not the grammar revision", 1, true), notes[1].msg)

-- Case 3: warned-once guard -> a second call in the same session is silent.
notes = {}
gi.check_stale()
assert(#notes == 0, "check_stale must warn at most once per session, got: " .. #notes)

-- Case 4: a parser built from ORGAN_GRAMMAR_SRC is not checked against
-- the pin while that override is set; once it is unset the local build
-- is off the pin and warns.
write_manifest(rev1, "/src/tree-sitter-organ")
vim.env.ORGAN_GRAMMAR_SRC = "/src"
run()
assert(#notes == 0, "local-source build must be silent, got: " .. vim.inspect(notes))
vim.env.ORGAN_GRAMMAR_SRC = nil
run()
assert(#notes == 1, "local-source build without the override must warn, got: " .. #notes)
assert(notes[1].msg:find("org.so not the grammar revision", 1, true), notes[1].msg)
pin = rev1

-- Case 5: the installed file is not the one the manifest records (a
-- partial install replaced it) -> one WARN, local source or not.
vim.fn.writefile({ "another parser" }, parser_dir .. "/org.so")
write_manifest(rev1)
run()
assert(#notes == 1, "replaced parser must warn, got: " .. vim.inspect(notes))
assert(notes[1].msg:find("not the parser the last completed install built", 1, true), notes[1].msg)
write_manifest(rev1, "/src/tree-sitter-organ")
run()
assert(#notes == 1, "replaced local-source parser must warn, got: " .. vim.inspect(notes))
vim.fn.writefile({ "built parser" }, parser_dir .. "/org.so")

-- Case 6: no manifest (installed before the feature / prebuilt path) -> silent.
vim.fn.delete(parser_dir .. "/.build-manifest.json")
run()
assert(#notes == 0, "missing manifest must be silent, got: " .. vim.inspect(notes))

-- Case 7: a manifest from before hashes were recorded is checked against
-- the pin only.
local fd = assert(io.open(parser_dir .. "/.build-manifest.json", "w"))
fd:write(vim.json.encode({ ["org.so"] = { repo = repo, rev = rev1 } }))
fd:close()
vim.fn.writefile({ "another parser" }, parser_dir .. "/org.so")
run()
assert(#notes == 0, "hashless in-pin manifest must be silent, got: " .. vim.inspect(notes))

io.write("grammar stale detection ok\n")
os.exit(0)
