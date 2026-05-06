#!/usr/bin/env -S nvim -l
-- Deterministically right-align vim-help tags in `doc/organ.txt`
-- (and any path passed as `arg[1]`) to column 78.
--
-- A "tag" here is a *...* marker.  Convention:
--   * Lines whose ONLY tag sits at column 0 (left-aligned command
--     tags like `*:Org-foo*`) stay where they are.
--   * Every other tag-bearing line ends at column 78 -- the trailing
--     `*` lands at byte 78.  That covers:
--       - indented tag-only lines (`   *organ-config-foo*`)
--       - heading + tag lines (`Foo    *organ-config-foo*`)
--       - dual-tag lines (`*:Org-foo*    *organ-cmd-foo*`)
--
-- Run as: nvim -l scripts/align-help-tags.lua [path]
-- Default path is doc/organ.txt.

local WIDTH = 78
local PATH = arg[1] or "doc/organ.txt"

local function rtrim(s)
  return (s:gsub("%s+$", ""))
end

local function ends_with_tag(line)
  return rtrim(line):match("(%*[%w_%-:%.]+%*)$")
end

local function align(line)
  -- Lines that start with `*` are either single left-aligned tag
  -- declarations (`*:Org-foo*`) or multi-tag command-list headers
  -- (`*a* / *b* / *c*`).  Both stay where they are.
  if line:match("^%*") then
    return line
  end
  local tag = ends_with_tag(line)
  if not tag then
    return line
  end
  local trimmed = rtrim(line)
  -- Strip the trailing tag and any whitespace right before it.
  local prefix = trimmed:sub(1, #trimmed - #tag):gsub("%s+$", "")
  local pad = WIDTH - #prefix - #tag
  if pad < 1 then
    pad = 1
  end
  return prefix .. string.rep(" ", pad) .. tag
end

local f = assert(io.open(PATH, "r"))
local out = {}
local changed = 0
for line in f:lines() do
  local new = align(line)
  if new ~= line then
    changed = changed + 1
  end
  out[#out + 1] = new
end
f:close()

if changed > 0 then
  local w = assert(io.open(PATH, "w"))
  for _, l in ipairs(out) do
    w:write(l, "\n")
  end
  w:close()
end

io.write(("aligned %d lines in %s\n"):format(changed, PATH))
