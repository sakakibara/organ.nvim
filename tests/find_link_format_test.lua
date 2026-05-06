-- find.format_link(row) renders the display string per spec section 4.2.
-- Run via: nvim --headless -l tests/find_link_format_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local find = require("organ.find")

-- Resolved id-typed link: target headline title appears, NOT the raw id.
local r1 = {
  source_headline = { title = "Alpha", file_path = vim.fn.getcwd() .. "/x.org" },
  target_type = "id",
  target = "beta-id",
  description = "Beta link",
  line = 5,
  target_headline = { title = "Beta" },
}
local s1 = find.format_link(r1)
assert(s1:find("Alpha", 1, true), "source title in: " .. s1)
assert(s1:find("Beta", 1, true), "target headline title in: " .. s1)
assert(not s1:find("beta-id", 1, true), "raw id should NOT appear: " .. s1)
assert(s1:find('"Beta link"', 1, true), "quoted description in: " .. s1)
assert(s1:match("%(.-x%.org:5%)"), "trailing (path:line) in: " .. s1)

-- Unresolved http link: [type] target appears.
local r2 = {
  source_headline = { title = "Gamma", file_path = vim.fn.getcwd() .. "/x.org" },
  target_type = "https",
  target = "https://example.com",
  description = nil,
  line = 3,
  target_headline = nil,
}
local s2 = find.format_link(r2)
assert(s2:find("[https] https://example.com", 1, true), "expected [type] target form: " .. s2)
assert(not s2:find('"', 1, true), "no quoted description when nil: " .. s2)

-- Empty description treated like nil.
local r3 = {
  source_headline = { title = "A", file_path = vim.fn.getcwd() .. "/x.org" },
  target_type = "file",
  target = "/tmp/x.txt",
  description = "",
  line = 1,
  target_headline = nil,
}
local s3 = find.format_link(r3)
assert(not s3:find('"', 1, true), "empty description should not produce quotes: " .. s3)

io.write("find link format ok\n")
os.exit(0)
