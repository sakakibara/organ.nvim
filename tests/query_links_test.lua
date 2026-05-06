-- Exercises query.links_from / query.links_to / query.get_by_id / query.resolve.
-- Run via: nvim --headless -l tests/query_links_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db_path = tmp .. "/ql.db"
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
vim.fn.system({ "cp", root .. "/tests/fixtures/05-links.org", org_dir .. "/05.org" })

require("organ").setup({
  db_path = db_path,
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
})
require("organ").scan_blocking(org_dir, 5000)

local query = require("organ.query")

-- get_by_id
local alpha = query.get_by_id("alpha-id")
assert(alpha and alpha.title == "Alpha", "get_by_id alpha: " .. vim.inspect(alpha))
assert(query.get_by_id("nonexistent") == nil)

-- links_from alpha → two links (id:beta-id, https://example.com)
local outs = query.links_from("alpha-id")
assert(#outs == 2, "alpha outs = " .. #outs)
local by_target = {}
for _, l in ipairs(outs) do
  by_target[l.target] = l
end
assert(
  by_target["beta-id"]
    and by_target["beta-id"].target_type == "id"
    and by_target["beta-id"].description == "Beta"
    and by_target["beta-id"].target_headline ~= nil
    and by_target["beta-id"].target_headline.title == "Beta"
)
assert(
  by_target["https://example.com"]
    and by_target["https://example.com"].target_type == "https"
    and by_target["https://example.com"].target_headline == nil
)

-- links_to beta → one incoming from alpha.
local ins = query.links_to("beta-id")
assert(#ins == 1, "beta ins = " .. #ins)
assert(ins[1].source_headline and ins[1].source_headline.title == "Alpha")
assert(ins[1].description == "Beta")
assert(ins[1].target == "beta-id" and ins[1].target_type == "id")

-- Accept a headline record directly too.
local ins2 = query.links_to(query.get_by_id("alpha-id"))
assert(#ins2 == 1, "alpha ins = " .. #ins2)
assert(ins2[1].source_headline and ins2[1].source_headline.title == "Beta")

-- resolve delegation
local tt, ts = query.resolve("id:abc")
assert(tt == "id" and ts == "abc")

vim.fn.delete(tmp, "rf")
io.write("query links ok\n")
os.exit(0)
