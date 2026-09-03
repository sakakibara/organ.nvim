-- `:Org scan!` clears only rows whose path lies under org_dir: the
-- prefix match must treat `_` / `%` in org_dir literally and stop at a
-- directory boundary.
-- Run via: nvim --headless -l tests/scan_force_prefix_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
local org_dir = tmp .. "/my_org"
local others = { tmp .. "/my-org", tmp .. "/myXorg", tmp .. "/my_org2", tmp .. "/my%org" }
vim.fn.mkdir(org_dir, "p")
for _, d in ipairs(others) do
  vim.fn.mkdir(d, "p")
end

require("organ").setup({
  db_path = tmp .. "/s.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local indexer = require("organ.indexer")
local files = { org_dir .. "/a.org" }
for i, d in ipairs(others) do
  files[#files + 1] = d .. "/o" .. i .. ".org"
end
for _, p in ipairs(files) do
  local f = assert(io.open(p, "w"))
  f:write("* H\n")
  f:close()
  indexer.index_file_sync(p)
end

local function indexed_paths()
  local h = require("organ.runtime").db()
  local s = h:prepare("SELECT path FROM files ORDER BY path")
  local out = {}
  while s:step() == require("organ.db").SQLITE_ROW do
    out[#out + 1] = s:column_text(0)
  end
  s:finalize()
  return out
end
assert(#indexed_paths() == #files, "expected " .. #files .. " indexed rows")

-- Stub the rescan so only the clearing step runs.
local organ = require("organ")
organ._start_scan = function() end
organ._scan_walk = function(_, _) end
indexer.commands.scan.fn({ bang = true })

local remaining = indexed_paths()
local expected = {}
for i = 2, #files do
  expected[#expected + 1] = files[i]
end
table.sort(expected)
assert(
  vim.deep_equal(remaining, expected),
  "rows outside org_dir must survive; got " .. vim.inspect(remaining)
)

vim.fn.delete(tmp, "rf")
io.write("scan force prefix ok\n")
os.exit(0)
