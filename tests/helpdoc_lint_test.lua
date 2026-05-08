-- doc/organ.txt: vimhelplint must report no Errors.
--
-- vimhelplint (machakann/vim-vimhelplint) parses the help file via the
-- same syntax help.vim ships, then walks the resulting tags + links and
-- reports level-tagged findings.  Levels:
--   1 (W) line width > 78
--   2 (E) duplicate tag in this file
--   3 (E) duplicate tag in another file
--   4 (E) link with no corresponding tag
--   5 (W) tag/link scope inconsistency
--   6 (W) probable mis-typed link
--   8 (W) option name misused as link
--
-- This test gates on Errors only -- Warnings often surface in code
-- blocks (long fixture lines, illustrative `|...|` notation) where
-- rewording loses fidelity.  Run the full report with:
--     make lint-doc
--
-- Run via: nvim --headless -l tests/helpdoc_lint_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local plugin_dir = root .. "/tests/deps/vim-vimhelplint"
if vim.fn.isdirectory(plugin_dir) == 0 then
  io.stderr:write("\nERROR: tests/deps/vim-vimhelplint is missing\n")
  io.stderr:write("Run `make deps` to fetch it.\n")
  os.exit(2)
end

local cmd = {
  vim.v.progpath,
  "-u",
  "NONE",
  "-i",
  "NONE",
  "--headless",
  "--cmd",
  "set rtp+=" .. plugin_dir,
  "--cmd",
  "filetype plugin on",
  "-c",
  "edit " .. root .. "/doc/organ.txt",
  "-c",
  "verb VimhelpLintEcho",
  "-c",
  "qa",
}

local out = vim.fn.system(cmd)

local errors = 0
local warns = 0
for line in (out or ""):gmatch("[^\r\n]+") do
  -- Lines look like: doc/organ.txt:LL:CC:Error:N:msg
  local kind = line:match(":(%a+):%d+:")
  if kind == "Error" then
    errors = errors + 1
    print("ERROR " .. line)
  elseif kind == "Warning" then
    warns = warns + 1
  end
end

print(("vimhelplint: %d error(s), %d warning(s)"):format(errors, warns))
if errors > 0 then
  print()
  print(
    "FAIL  vimhelplint reported " .. errors .. " error(s) -- run `make lint-doc` for full report"
  )
  os.exit(1)
end
print("helpdoc_lint_test: PASS")
