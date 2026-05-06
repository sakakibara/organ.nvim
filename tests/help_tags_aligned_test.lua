-- doc/organ.txt: every right-aligned tag must end at column 78.
-- Catches "tag landed at col 76 instead of 78" mistakes that are
-- otherwise easy to miss in a diff.  Auto-fixer:
--     nvim -l scripts/align-help-tags.lua
--
-- Run via: nvim --headless -l tests/help_tags_aligned_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local WIDTH = 78
local PATH = root .. "/doc/organ.txt"

local fails = 0
local function fail(label, detail)
  fails = fails + 1
  print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
end

local f = assert(io.open(PATH, "r"))
local lineno = 0
for raw in f:lines() do
  lineno = lineno + 1
  local trimmed = raw:gsub("%s+$", "")
  local tag = trimmed:match("(%*[%w_%-:%.]+%*)$")
  -- Lines that begin with `*` are left-aligned tag declarations (single
  -- command tag) or multi-tag command-list headers (`*a* / *b* / *c*`)
  -- -- both are intentionally NOT right-aligned.
  if tag and not trimmed:match("^%*") and #trimmed ~= WIDTH then
    fail(("L%d: trailing tag should end at col %d (got %d)"):format(lineno, WIDTH, #trimmed), raw)
  end
end
f:close()

if fails > 0 then
  print()
  print(("FAILED %d checks -- run `nvim -l scripts/align-help-tags.lua` to fix"):format(fails))
  os.exit(1)
end
print("help_tags_aligned_test: PASS")
os.exit(0)
