-- query.links(filter) returns join-shaped rows from the links table.
-- Run via: nvim --headless -l tests/query_links_picker_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

-- Fixture: three nodes, several links of different types.
local fh = assert(io.open(org_dir .. "/x.org", "w"))
fh:write([=[* Alpha
  :PROPERTIES:
  :ID:       alpha-id
  :END:
  See [[id:beta-id][Beta link]] and [[https://example.com][example]].

* Beta
  :PROPERTIES:
  :ID:       beta-id
  :END:
  Back to [[id:alpha-id]] and a file [[file:/tmp/x.txt][a file]].

* Gamma
  :PROPERTIES:
  :ID:       gamma-id
  :END:
  Email me at [[mailto:test@example.com]].
]=])
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
require("organ").scan_blocking(org_dir, 5000)

local query = require("organ.query")

-- Unfiltered: 5 links total.
local all = query.links({})
assert(#all == 5, "expected 5 links, got " .. #all)

-- Each row has the expected shape.
for _, r in ipairs(all) do
  assert(r.source_headline_id, "missing source_headline_id")
  assert(r.target_type, "missing target_type")
  assert(r.target, "missing target")
  assert(r.line and r.line > 0, "missing/zero line")
  assert(r.source_headline and r.source_headline.title, "missing source_headline.title")
end

-- target_type filter: id only.
local id_only = query.links({ target_type = "id" })
assert(#id_only == 2, "id-only expected 2, got " .. #id_only)
for _, r in ipairs(id_only) do
  assert(r.target_type == "id")
end

-- Resolved target_headline for id links.
for _, r in ipairs(id_only) do
  if r.target == "beta-id" then
    assert(
      r.target_headline and r.target_headline.title == "Beta",
      "beta-id should resolve to Beta; got " .. vim.inspect(r.target_headline)
    )
  end
end

-- target_type union via comma.
local web = query.links({ target_type = "https,http" })
assert(#web == 1, "web links expected 1, got " .. #web)
assert(web[1].target_type == "https")

-- Filter by source headline id.
local from_alpha = query.links({ source_id = "alpha-id" })
assert(#from_alpha == 2, "from alpha expected 2, got " .. #from_alpha)

-- Filter by exact target.
local to_alpha = query.links({ target = "alpha-id" })
assert(#to_alpha == 1, "to alpha-id expected 1, got " .. #to_alpha)
assert(to_alpha[1].source_headline.title == "Beta")

-- Empty filter set: no matches.
local none = query.links({ target_type = "doesnotexist" })
assert(#none == 0, "expected 0 results, got " .. #none)

vim.fn.delete(tmp, "rf")
io.write("query links picker ok\n")
os.exit(0)
