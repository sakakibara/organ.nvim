-- Pure unit: watcher.should_handle filters file paths by extension + ignore patterns.
-- Run via: nvim --headless -l tests/watcher_filter_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local watcher = require("organ.watcher")
local ignore = { "%.git/", "%.swp$", "^%.#", "~$", "%.tmp$" }

local cases = {
  { "/x/notes.org", true },
  { "/x/y/notes.org_archive", true },
  { "/x/.git/config.org", false },
  { "/x/notes.org.swp", false },
  { "/x/.#notes.org", false },
  { "/x/notes.org~", false },
  { "/x/notes.org.tmp", false },
  { "/x/README.md", false },
  { "", false },
  { "notes.org", false }, -- relative paths rejected
}

for _, c in ipairs(cases) do
  local got = watcher.should_handle(c[1], ignore)
  if got ~= c[2] then
    io.stderr:write(
      string.format("should_handle(%q) = %s, expected %s\n", c[1], tostring(got), tostring(c[2]))
    )
    os.exit(1)
  end
end

io.write("watcher filter ok\n")
os.exit(0)
