-- Diff-against-Emacs sweep -- verifies our tree-sitter parser produces the
-- same structure as Emacs's org-element parse.  Two fixture sources:
--
--   * tests/fixtures/emacs_interop/parity/*.org -- hand-written, one file
--     per construct a parser is known to get wrong,
--   * tests/_parity_corpus.lua -- documents generated from a fixed seed,
--     for the construct combinations nobody thought to write down.
--
-- Run via: nvim --headless -l tests/parser_emacs_diff_test.lua
--
-- A machine without Emacs skips.  Everything else -- a missing script, an
-- empty fixture set, a dumper that will not run -- FAILS: a parity gate
-- that cannot run is a failure to report, not a pass.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local CORPUS_SEED = 20260904
local CORPUS_SIZE = 300

local function fail(msg)
  io.write("parser emacs diff: FAIL (" .. msg .. ")\n")
  os.exit(1)
end

if vim.fn.executable("emacs") ~= 1 then
  io.write("parser emacs diff: SKIP (emacs not installed)\n")
  os.exit(0)
end

local script = root .. "/scripts/diff-against-emacs.sh"
if vim.fn.executable(script) ~= 1 then
  fail("scripts/diff-against-emacs.sh missing or not executable")
end

local fixtures_dir = root .. "/tests/fixtures/emacs_interop/parity"
if vim.fn.isdirectory(fixtures_dir) ~= 1 then
  fail("no " .. fixtures_dir .. " directory")
end
local fixtures = vim.fn.glob(fixtures_dir .. "/*.org", false, true)
if #fixtures == 0 then
  fail("no .org files in " .. fixtures_dir)
end

local corpus_helper = root .. "/tests/_parity_corpus.lua"
if vim.fn.filereadable(corpus_helper) ~= 1 then
  fail("tests/_parity_corpus.lua missing")
end
local documents = dofile(corpus_helper).documents(CORPUS_SEED, CORPUS_SIZE)
if #documents ~= CORPUS_SIZE then
  fail(string.format("generator produced %d documents, expected %d", #documents, CORPUS_SIZE))
end

local corpus_dir = vim.fn.tempname()
vim.fn.mkdir(corpus_dir, "p")
local files = vim.deepcopy(fixtures)
for i, text in ipairs(documents) do
  local path = string.format("%s/generated-%04d.org", corpus_dir, i)
  local handle = assert(io.open(path, "w"))
  handle:write(text)
  handle:close()
  files[#files + 1] = path
end

local argv = { script }
vim.list_extend(argv, files)
local out = vim.fn.system(argv)
local status = vim.v.shell_error
vim.fn.delete(corpus_dir, "rf")

if status == 0 then
  io.write(
    string.format(
      "parser emacs diff ok (%d fixtures + %d generated documents match Emacs)\n",
      #fixtures,
      #documents
    )
  )
  os.exit(0)
end

io.write(
  string.format(
    "parser emacs diff: FAIL (%d fixtures + %d generated documents, exit %d)\n",
    #fixtures,
    #documents,
    status
  )
)
io.write("  seed " .. CORPUS_SEED .. "; generated-NNNN.org is the NNNNth document from it\n")
for line in out:gmatch("[^\r\n]+") do
  io.write("  " .. line .. "\n")
end
os.exit(1)
