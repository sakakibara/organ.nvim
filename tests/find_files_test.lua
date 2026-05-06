-- query.files() returns one record per indexed file; find.pick({source="files"})
-- builds items with kind="file" and correct basenames/display.
-- Run via: nvim --headless -l tests/find_files_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

-- Create two org files with different headline counts.
local fh1 = assert(io.open(org_dir .. "/alpha.org", "w"))
fh1:write([[* Headline One
* Headline Two
]])
fh1:close()

local fh2 = assert(io.open(org_dir .. "/zeta.org", "w"))
fh2:write([[* Only One
]])
fh2:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
})
require("organ").scan_blocking(org_dir, 5000)

-- ── 1. query.files() returns both files sorted by basename ───────────────────
local query = require("organ.query")
local files = query.files()
assert(#files == 2, "expected 2 files, got " .. #files)
assert(files[1].basename == "alpha.org", "expected alpha.org first, got " .. files[1].basename)
assert(files[2].basename == "zeta.org", "expected zeta.org second, got " .. files[2].basename)
assert(
  files[1].headline_count == 2,
  "alpha.org should have 2 headlines, got " .. files[1].headline_count
)
assert(
  files[2].headline_count == 1,
  "zeta.org should have 1 headline, got " .. files[2].headline_count
)

-- ── 2. find.pick({source="files"}) produces items with kind="file" ───────────
local find = require("organ.find")
find.pick({ source = "files", title = "Find file", default_action = "jump" })

local stub = require("organ.find.backend")._test_stub
assert(stub.last, "backend was not invoked")
local items = stub.last.items
assert(#items == 2, "expected 2 items, got " .. #items)

-- Items are sorted by basename (alpha first).
assert(items[1].kind == "file", "item 1 kind should be 'file', got " .. tostring(items[1].kind))
assert(items[2].kind == "file", "item 2 kind should be 'file', got " .. tostring(items[2].kind))
assert(
  items[1].title == "alpha.org",
  "item 1 title should be alpha.org, got " .. tostring(items[1].title)
)
assert(
  items[2].title == "zeta.org",
  "item 2 title should be zeta.org, got " .. tostring(items[2].title)
)

-- Display should contain the basename.
assert(
  items[1].display:find("alpha.org", 1, true),
  "item 1 display missing 'alpha.org': " .. items[1].display
)
-- Display now spells out "N headlines" instead of bare "(N)" so users
-- without docs handy can tell what the number means.
assert(
  items[1].display:find("2 headlines", 1, true),
  "item 1 display missing headline count '2 headlines': " .. items[1].display
)

-- Opts: prompt forwarded, default_action jump.
assert(
  stub.last.opts.title == "Find file",
  "title should be 'Find file', got " .. tostring(stub.last.opts.title)
)
assert(stub.last.opts.default_action == "jump")

-- ── 3. jump action opens the file (no cursor set for file items) ──────────────
local actions = stub.last.opts.actions
assert(type(actions.jump) == "function", "jump action should be a function")
actions.jump(items[1])
assert(
  vim.api.nvim_buf_get_name(0):match("/alpha%.org$"),
  "jump should open alpha.org, got: " .. vim.api.nvim_buf_get_name(0)
)

vim.fn.delete(tmp, "rf")
io.write("find files ok\n")
os.exit(0)
