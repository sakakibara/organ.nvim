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

-- The trailing ellipsis segment must use the heading-title hl, not
-- `Folded` -- so it matches the heading color the user reads above
-- it instead of a separate gray.
local last = out[#out]
check("last segment is the ellipsis", type(last) == "table" and last[1] == "…")
if type(last) == "table" then
  check(
    "ellipsis hl matches per-level heading title",
    last[2] == "@org.heading.title.1.org",
    "got " .. tostring(last[2])
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_foldtext_segments_test: PASS")
os.exit(0)
