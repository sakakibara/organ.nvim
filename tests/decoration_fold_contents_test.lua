-- Unit test for the fold/contents provider via organ.decoration.
-- This provider uses on_lines_only -- no per-line decoration.
--
-- Run via: nvim --headless -l tests/decoration_fold_contents_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
require("organ.fold.contents")

local decoration = require("organ.decoration")
local providers, _ = decoration._providers()

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

check("fold_contents provider registered", providers.fold_contents ~= nil)
check(
  "fold_contents uses on_lines_only (no on_line)",
  providers.fold_contents
    and providers.fold_contents.on_lines_only ~= nil
    and providers.fold_contents.on_line == nil,
  providers.fold_contents
      and (
        "on_lines_only="
        .. tostring(providers.fold_contents.on_lines_only)
        .. " on_line="
        .. tostring(providers.fold_contents.on_line)
      )
    or "missing"
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_fold_contents_test: PASS")
os.exit(0)
