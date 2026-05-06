-- tag_writer.read / write — parse and rewrite a headline's :tag1:tag2: block
-- without disturbing stars / TODO / priority / title.
-- Run via: nvim --headless -l tests/tag_writer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local writer = require("organ.tag_writer")

-- Pure parse cases.
local cases = {
  ["* TODO Write tests :work:nvim:"] = {
    stars = "*",
    body = "TODO Write tests",
    tags = { "work", "nvim" },
  },
  ["** [#A] Untagged headline"] = {
    stars = "**",
    body = "[#A] Untagged headline",
    tags = {},
  },
  ["* DONE Stuff :@home:"] = {
    stars = "*",
    body = "DONE Stuff",
    tags = { "@home" },
  },
  ["* Title :only:tag:"] = {
    stars = "*",
    body = "Title",
    tags = { "only", "tag" },
  },
  -- Trailing colons in body are not a tag block.
  ["* Title with: colon"] = {
    stars = "*",
    body = "Title with: colon",
    tags = {},
  },
}
for line, want in pairs(cases) do
  local got = writer._parse_headline(line)
  assert(got, "parse failed: " .. line)
  assert(got.stars == want.stars, "stars mismatch on: " .. line)
  assert(got.body == want.body, "body mismatch on: " .. line .. " got=" .. got.body)
  assert(#got.tags == #want.tags, "tag count mismatch on: " .. line)
  for i, t in ipairs(want.tags) do
    assert(got.tags[i] == t, "tag " .. i .. " mismatch on: " .. line)
  end
end

-- Render block.
assert(writer._render_tag_block({}) == "", "empty → empty")
assert(writer._render_tag_block({ "a" }) == ":a:", "single")
assert(writer._render_tag_block({ "a", "b", "c" }) == ":a:b:c:", "multi")

-- read/write round-trip in a real buffer.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fixture = tmp .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write("* TODO Heading :old:tag:\n  body\n")
fh:close()

local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)

local read = writer.read(b, 1)
assert(read.tags[1] == "old" and read.tags[2] == "tag", "read: tag list")

assert(writer.write(b, 1, { "new", "set" }) == nil)
local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
assert(lines[1] == "* TODO Heading :new:set:", "rewrite: '" .. lines[1] .. "'")

-- Replacing with empty list strips the tag block.
assert(writer.write(b, 1, {}) == nil)
lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
assert(lines[1] == "* TODO Heading", "strip: '" .. lines[1] .. "'")

-- Adding tags onto a previously untagged headline.
assert(writer.write(b, 1, { "fresh" }) == nil)
lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
assert(lines[1] == "* TODO Heading :fresh:", "add: '" .. lines[1] .. "'")

-- Cursor on a body line still finds the parent headline.
local body_read = writer.read(b, 2)
assert(
  body_read and body_read.tags[1] == "fresh",
  "read from body line should find parent headline"
)

vim.fn.delete(tmp, "rf")
io.write("tag_writer ok\n")
os.exit(0)
