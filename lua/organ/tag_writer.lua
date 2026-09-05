-- Headline tag-block reader/writer. Pure buffer operations.
--
-- A headline's tag block is a trailing run of `:tag1:tag2:` separated from the
-- title by whitespace (or standing alone after the stars). Tag chars match
-- `[%w_@#%%]` plus non-ASCII bytes. This module finds the headline owning a
-- line, parses its current tags, and rewrites the trailing tag block,
-- leaving stars / TODO state / priority / title intact.

local M = {}

local obuf = require("organ.buf")
local TAG_SET = "%w_@#%%\128-\255"
local TAG_CHARS = "[" .. TAG_SET .. "]"
local TAG_BLOCK = "(:[" .. TAG_SET .. ":]+:)%s*$"

local function find_headline(buf_lines, line)
  local hl = line
  while hl >= 1 and not buf_lines[hl]:match("^%*+ ") do
    hl = hl - 1
  end
  if hl < 1 then
    return nil
  end
  return hl
end

-- Split a headline line into (prefix_until_title_end, tags_list).
-- prefix is the part WITHOUT a trailing tag block; tags is { "tag1", ... }.
local function parse_headline(line)
  local stars, rest = line:match("^(%*+) +(.*)$")
  if not stars then
    return nil
  end
  local body, tag_run = rest:match("^(.-)%s+" .. TAG_BLOCK)
  if not body then
    tag_run = rest:match("^" .. TAG_BLOCK)
    body = tag_run and "" or nil
  end
  if not tag_run then
    return { stars = stars, body = rest:gsub("%s+$", ""), tags = {} }
  end
  local tags = {}
  for tag in tag_run:gmatch(":(" .. TAG_CHARS .. "+)") do
    tags[#tags + 1] = tag
  end
  return { stars = stars, body = body:gsub("%s+$", ""), tags = tags }
end

-- Render the tag block for the right edge of the headline.
-- Returns the empty string when no tags.
local function render_tag_block(tags)
  if not tags or #tags == 0 then
    return ""
  end
  return ":" .. table.concat(tags, ":") .. ":"
end

-- Read the headline's tags. Returns { tags = {...}, hl_line = N } or nil.
function M.read(bufnr, line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hl = find_headline(lines, line)
  if not hl then
    return nil
  end
  local parsed = parse_headline(lines[hl])
  if not parsed then
    return nil
  end
  return { tags = parsed.tags, hl_line = hl }
end

-- Replace the headline's tag block with `new_tags`. Re-emits the headline as:
--   <stars> <body><pad><tag-block>
-- where pad right-aligns the tag block to `config.format.headline.tags_column`
-- via `format.align_tag_block`. Empty `new_tags` removes the tag block and
-- leaves only `<stars> <body>` (no trailing whitespace).
function M.write(bufnr, line, new_tags)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hl = find_headline(lines, line)
  if not hl then
    return "no headline at or above cursor"
  end
  local parsed = parse_headline(lines[hl])
  if not parsed then
    return "headline parse failed"
  end
  local block = render_tag_block(new_tags)
  local left
  if parsed.body == "" then
    left = parsed.stars
  else
    left = parsed.stars .. " " .. parsed.body
  end
  local format = require("organ.format")
  local new_line = format.align_tag_block(left, block)
  obuf.set_lines(bufnr, hl - 1, hl, { new_line })
  return nil
end

M._parse_headline = parse_headline
M._render_tag_block = render_tag_block
M._find_headline = find_headline

return M
