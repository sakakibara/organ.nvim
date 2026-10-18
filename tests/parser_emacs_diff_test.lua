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
-- Each file's two dumps are diffed line by line.  A difference passes
-- only when tests/conformance/parser/signatures.tsv records it, keyed to
-- the divergence-inventory entry that rules on it (see
-- tests/conformance/_signatures.lua).
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

local signatures = dofile(root .. "/tests/conformance/_signatures.lua")
local sig_path = root .. "/tests/conformance/parser/signatures.tsv"
local ok_rows, rows = pcall(signatures.load, sig_path)
if not ok_rows then
  fail(tostring(rows))
end

local out_dir = vim.fn.tempname()
local argv = { script, "--out", out_dir }
vim.list_extend(argv, files)
local out = vim.fn.system(argv)
local status = vim.v.shell_error
vim.fn.delete(corpus_dir, "rf")
if status ~= 0 then
  vim.fn.delete(out_dir, "rf")
  fail("dump failed (exit " .. status .. "): " .. out)
end

-- Split a dump into per-file record lists keyed by the file's basename.
local function by_file(path)
  local files_out, current = {}, nil
  for line in io.lines(path) do
    local f = line:match("^F\t(.*)$")
    if f then
      current = vim.fn.fnamemodify(f, ":t")
      files_out[current] = files_out[current] or {}
    elseif current then
      table.insert(files_out[current], line)
    end
  end
  return files_out
end

local emacs = by_file(out_dir .. "/emacs.txt")
local organ = by_file(out_dir .. "/organ.txt")
vim.fn.delete(out_dir, "rf")

local observed = {}
for name in pairs(vim.tbl_extend("keep", {}, emacs, organ)) do
  local a, b = emacs[name] or {}, organ[name] or {}
  local ta, tb = table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n"
  local hunks = {}
  for _, h in ipairs(vim.diff(ta, tb, { result_type = "indices" })) do
    local parts = {}
    for i = h[1], h[1] + h[2] - 1 do
      parts[#parts + 1] = "-" .. a[i]
    end
    for i = h[3], h[3] + h[4] - 1 do
      parts[#parts + 1] = "+" .. b[i]
    end
    hunks[#hunks + 1] = table.concat(parts, "\n")
  end
  if #hunks > 0 then
    observed[name] = hunks
  end
end

local problems = signatures.check(observed, rows)
if #problems == 0 then
  io.write(
    string.format(
      "parser emacs diff ok (%d fixtures + %d generated documents; %d expected difference(s))\n",
      #fixtures,
      #documents,
      #rows
    )
  )
  os.exit(0)
end

io.write(
  string.format(
    "parser emacs diff: FAIL (%d fixtures + %d generated documents)\n",
    #fixtures,
    #documents
  )
)
io.write("  seed " .. CORPUS_SEED .. "; generated-NNNN.org is the NNNNth document from it\n")
for _, p in ipairs(problems) do
  io.write("  " .. p .. "\n")
end
os.exit(1)
