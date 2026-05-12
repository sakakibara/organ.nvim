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

-- The writer right-aligns the tag block to `config.format.headline.tags_column`.
-- These round-trip cases pin the right-edge column to 77 (Emacs's classic
-- numeric default) by configuring `tags_column = -77`; the helper interprets
-- negative integers as "tag block's RIGHT edge at column |N|".  Pre-compute
-- the expected padded forms so the assertions below stay readable.
local organ = require("organ")
organ.setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  format = { headline = { tags_column = -77 } },
})

local function padded(left, tags, col)
  col = col or 77
  local pad = col - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(tags)
  if pad < 1 then
    pad = 1
  end
  return left .. string.rep(" ", pad) .. tags
end

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
local want = padded("* TODO Heading", ":new:set:")
assert(lines[1] == want, "rewrite: got [" .. lines[1] .. "] want [" .. want .. "]")

-- Replacing with empty list strips the tag block (no trailing whitespace).
assert(writer.write(b, 1, {}) == nil)
lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
assert(lines[1] == "* TODO Heading", "strip: '" .. lines[1] .. "'")

-- Adding tags onto a previously untagged headline.
assert(writer.write(b, 1, { "fresh" }) == nil)
lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
want = padded("* TODO Heading", ":fresh:")
assert(lines[1] == want, "add: got [" .. lines[1] .. "] want [" .. want .. "]")

-- Cursor on a body line still finds the parent headline.
local body_read = writer.read(b, 2)
assert(
  body_read and body_read.tags[1] == "fresh",
  "read from body line should find parent headline"
)

vim.fn.delete(tmp, "rf")

-- Alignment behaviour: long headline that already passes tags_column falls
-- back to a single space of padding (helper clamps pad >= 1).
local tmp2 = vim.fn.tempname()
vim.fn.mkdir(tmp2, "p")
local fixture2 = tmp2 .. "/long.org"
local long_body = string.rep("x", 80)
local fh2 = assert(io.open(fixture2, "w"))
fh2:write("* " .. long_body .. "\n")
fh2:close()

local b2 = vim.fn.bufadd(fixture2)
vim.fn.bufload(b2)

assert(writer.write(b2, 1, { "z" }) == nil)
lines = vim.api.nvim_buf_get_lines(b2, 0, -1, false)
assert(
  lines[1] == "* " .. long_body .. " :z:",
  "long line clamps to one space: got [" .. lines[1] .. "]"
)

vim.fn.delete(tmp2, "rf")

-- String-form `tags_column = "textwidth"`: tag block's right edge lands
-- at `vim.bo.textwidth` (with a fallback to 80 when textwidth is 0/unset).
-- Here textwidth on the bufadd-loaded buffer is unset, so the right edge
-- should land at column 80.
organ.config.format.headline.tags_column = "textwidth"

local tmp3 = vim.fn.tempname()
vim.fn.mkdir(tmp3, "p")
local fixture3 = tmp3 .. "/neg.org"
local fh3 = assert(io.open(fixture3, "w"))
fh3:write("* Hi\n")
fh3:close()
local b3 = vim.fn.bufadd(fixture3)
vim.fn.bufload(b3)
assert(writer.write(b3, 1, { "t" }) == nil)
lines = vim.api.nvim_buf_get_lines(b3, 0, -1, false)
want = padded("* Hi", ":t:", 80)
assert(lines[1] == want, '"textwidth" tags_column: got [' .. lines[1] .. "] want [" .. want .. "]")
vim.fn.delete(tmp3, "rf")

-- Restore the test-suite-local pinning for any later test in the same process.
organ.config.format.headline.tags_column = -77

io.write("tag_writer ok\n")
os.exit(0)
