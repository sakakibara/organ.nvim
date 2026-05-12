-- Foldtext segments must keep the heading's leading stars colored.
-- The org grammar's highlights query has two patterns over (stars):
--   1. `((headline_line stars: (stars) @org.heading.N) (#org-stars-level? @ N))`
--   2. `((headline_line stars: (stars) @_s title: (title) @org.heading.title.N)
--       (#org-stars-level? @_s N))`
-- Pattern 2 captures stars as `@_s` -- a private (underscore-prefixed)
-- intermediate used only to bind the predicate.  nvim's runtime
-- highlighter skips underscore-prefixed captures.  When our segments
-- walker didn't, `@_s.org` (which has no defined highlight) would
-- overwrite `@org.heading.N.org` for the stars columns and the leading
-- `*` glyphs rendered without color.  This test pins the fix.
--
-- Run via: nvim --headless -l tests/fold_foldtext_segments_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})

local fold = require("organ.fold")
local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* TODO Top heading :work:",
  "body line 1",
  "body line 2",
})
vim.bo[b].filetype = "org"
-- Force-attach the highlighter so the org parser is parsed and the
-- predicate machinery is available before we sample foldtext.
pcall(vim.treesitter.start, b, "org")

vim.cmd("let v:foldstart = 1")
vim.cmd("let v:foldend = 3")
local out = fold.foldtext()

check("foldtext returned segment list (TS available)", type(out) == "table", "got " .. type(out))

-- Locate the leading-stars segment (the first segment that contains
-- `*`).  Its hl_group must NOT be `@_s.org` -- if it is, the
-- underscore-skip path didn't fire and the stars rendered uncolored.
local stars_seg = nil
for _, seg in ipairs(out) do
  if type(seg) == "table" and seg[1]:find("%*") then
    stars_seg = seg
    break
  end
end
check("stars segment present", stars_seg ~= nil)
if stars_seg then
  check(
    "stars hl group is NOT the private `@_s.org`",
    stars_seg[2] ~= "@_s.org",
    "got " .. tostring(stars_seg[2])
  )
  -- Positive assertion: stars should land on `@org.heading.N.org`
  -- via pattern 1 (the per-level non-private capture).  Level 1
  -- here.
  check(
    "stars hl group is the level-1 heading capture",
    stars_seg[2] == "@org.heading.1.org",
    "got " .. tostring(stars_seg[2])
  )
end

-- When the heading carries a tag list, the ellipsis lands between
-- the title text and the tag block (not at the end of the line) so
-- folding `* TODO Top heading :work:` renders as
-- `* TODO Top heading…    :work:`.  Locate the ellipsis segment
-- explicitly and verify both its hl and its position relative to
-- the tag segments.
local ellipsis_idx
for i, seg in ipairs(out) do
  if type(seg) == "table" and seg[1] == "…" then
    ellipsis_idx = i
    break
  end
end
check("ellipsis segment present", ellipsis_idx ~= nil)
if ellipsis_idx then
  check(
    "ellipsis hl matches per-level heading title",
    out[ellipsis_idx][2] == "@org.heading.title.1.org",
    "got " .. tostring(out[ellipsis_idx][2])
  )
  -- The segment AFTER the ellipsis is padding spaces with the
  -- same heading-title hl (used to right-align tags).
  local after = out[ellipsis_idx + 1]
  check(
    "padding segment follows the ellipsis",
    type(after) == "table" and after[1]:match("^%s+$") ~= nil,
    "got " .. (type(after) == "table" and ("%q"):format(after[1]) or "nil")
  )
  -- And the tag block follows the padding (@org.tag.* family).
  local has_tag_after = false
  for i = ellipsis_idx + 1, #out do
    if out[i][2] and out[i][2]:match("^@org%.tag") then
      has_tag_after = true
      break
    end
  end
  check("tag segments come AFTER the ellipsis", has_tag_after)
end
-- The full rendered string must place ellipsis right after the
-- title text (no trailing space before "…"), AND must keep the
-- tag block flush to the right (ends with `:work:`).
local function as_string(v)
  local parts = {}
  for _, seg in ipairs(v) do
    parts[#parts + 1] = seg[1]
  end
  return table.concat(parts)
end
local rendered = as_string(out)
check(
  "rendered string contains 'heading…' (no space before ellipsis)",
  rendered:find("heading…", 1, true) ~= nil,
  "got " .. tostring(rendered)
)
check(
  "rendered string ends with the tag block",
  rendered:sub(-#":work:") == ":work:",
  "got " .. tostring(rendered)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_foldtext_segments_test: PASS")
os.exit(0)
