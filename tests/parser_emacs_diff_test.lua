-- Diff-against-Emacs sweep — verifies our tree-sitter parser produces the
-- same structure as Emacs's org-element parse for every fixture in
-- tests/fixtures/*.org. Skipped gracefully if Emacs isn't installed.
--
-- Run via: nvim --headless -l tests/parser_emacs_diff_test.lua
--
-- This is a regression net for grammar changes — parser bugs that would
-- otherwise ship show up here as Emacs-vs-organ divergences.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Skip if no Emacs.
local emacs = vim.fn.executable("emacs")
if emacs ~= 1 then
  io.write("parser emacs diff: SKIP (emacs not installed)\n")
  os.exit(0)
end

-- Skip if no fixtures.
local fixtures_dir = root .. "/tests/fixtures"
local has_fixtures = vim.fn.isdirectory(fixtures_dir) == 1
if not has_fixtures then
  io.write("parser emacs diff: SKIP (no tests/fixtures/ directory)\n")
  os.exit(0)
end

local fixtures = vim.fn.glob(fixtures_dir .. "/*.org", false, true)
if #fixtures == 0 then
  io.write("parser emacs diff: SKIP (no .org files in tests/fixtures/)\n")
  os.exit(0)
end

-- Run scripts/diff-against-emacs.sh on each fixture.
local script = root .. "/scripts/diff-against-emacs.sh"
if vim.fn.executable(script) ~= 1 then
  io.write("parser emacs diff: SKIP (scripts/diff-against-emacs.sh not executable)\n")
  os.exit(0)
end

local divergent = {}
local total = 0
for _, fixture in ipairs(fixtures) do
  total = total + 1
  -- Use vim.fn.system to capture output + exit code.
  local out = vim.fn.system({ script, fixture })
  local exit_code = vim.v.shell_error
  if exit_code ~= 0 then
    divergent[#divergent + 1] = {
      fixture = vim.fn.fnamemodify(fixture, ":t"),
      exit_code = exit_code,
      output = out,
    }
  end
end

if #divergent > 0 then
  io.write(string.format("parser emacs diff: FAIL (%d/%d fixtures divergent)\n", #divergent, total))
  for _, d in ipairs(divergent) do
    io.write(string.format("  %s (exit %d):\n", d.fixture, d.exit_code))
    -- Indent output for readability.
    for line in d.output:gmatch("[^\r\n]+") do
      io.write("    " .. line .. "\n")
    end
  end
  os.exit(1)
end

io.write(string.format("parser emacs diff ok (%d fixtures match Emacs)\n", total))
