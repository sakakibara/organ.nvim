-- Pure unit: find.segments_to_ranges + find.segments_to_ansi adapt
-- the shared { text, hl } segment list into the shapes telescope
-- (byte-range highlights) and fzf-lua (ANSI-wrapped) need so all
-- backends render the same per-column colors.
--
-- Run via: nvim --headless -l tests/find_segments_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local find = require("organ.find")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Build a representative record + columns.
local rec = {
  level = 2,
  todo_state = "TODO",
  priority = "A",
  title = "Plan release",
  tags = { "work", "urgent" },
  file_path = "/tmp/x.org",
  line_start = 0,
}
local cols = { "level", "todo", "priority", "title", "tags", "path" }
local segs = find.format_columns_segments(rec, cols)

-- (a) segments_to_ranges roundtrip.
do
  local text, ranges = find.segments_to_ranges(segs)
  check("ranges: text matches plain format_columns", text == find.format_columns(rec, cols), text)
  check("ranges: at least one highlight range produced", #ranges > 0)
  -- Every range must address bytes that are in-bounds.
  local in_bounds = true
  for _, r in ipairs(ranges) do
    local s, e = r[1][1], r[1][2]
    if s < 0 or e > #text or s > e then
      in_bounds = false
    end
  end
  check("ranges: every range is in-bounds", in_bounds)
  -- The title segment "Plan release" must be range-covered by an hl group.
  local title_start = text:find("Plan release", 1, true)
  local title_covered = false
  for _, r in ipairs(ranges) do
    if r[1][1] == title_start - 1 and r[1][2] == title_start - 1 + #"Plan release" then
      title_covered = true
    end
  end
  check(
    "ranges: title bytes carry @organ.find.title",
    title_covered,
    "ranges: " .. vim.inspect(ranges)
  )
end

-- (b) segments_to_ansi: when fzf-lua is absent, returns plain text +
-- can_ansi=false.  When present, each colored segment is wrapped in
-- ANSI escapes that the plain text doesn't contain.
do
  local s, can_ansi = find.segments_to_ansi(segs)
  -- This sandbox doesn't have fzf-lua loaded.
  check("ansi: degrades cleanly without fzf-lua loaded", can_ansi == false)
  check("ansi: fallback string equals plain format_columns", s == find.format_columns(rec, cols), s)
end

-- (c) Empty segments -> empty results, no crash.
do
  local text, ranges = find.segments_to_ranges({})
  check("empty: text is empty", text == "")
  check("empty: ranges is empty", #ranges == 0)
  local s, _ = find.segments_to_ansi({})
  check("empty: ansi text is empty", s == "")
end

-- (d) Segment without hl group passes through (no range emitted, but
-- text still contributes to the assembled string).
do
  local segs_mixed = { { "abc", "@organ.find.title" }, { " " }, { "def" } }
  local text, ranges = find.segments_to_ranges(segs_mixed)
  check("mixed: assembled text", text == "abc def", text)
  check("mixed: only the colored segment got a range", #ranges == 1)
  check(
    "mixed: range covers `abc` (bytes 0..3)",
    ranges[1][1][1] == 0 and ranges[1][1][2] == 3,
    vim.inspect(ranges[1])
  )
end

-- (e) Link rows: format_link_segments emits source / target /
-- description / location segments with hl groups.  Display string
-- assembled from segments must equal the plain format_link.
do
  local r = {
    source_headline = { title = "Alpha", file_path = vim.fn.getcwd() .. "/x.org" },
    target_type = "id",
    target = "beta-id",
    description = "Beta link",
    line = 5,
    target_headline = { title = "Beta" },
  }
  local segs = find.format_link_segments(r)
  local text = find.segments_to_ranges(segs)
  check("link segments: assembled text matches format_link", text == find.format_link(r), text)
  -- Source title ("Alpha") and target title ("Beta") must be covered.
  local alpha_seg, beta_seg = false, false
  for _, s in ipairs(segs) do
    if s[1] == "Alpha" and s[2] == "@organ.find.title" then
      alpha_seg = true
    end
    if s[1] == "Beta" and s[2] == "@organ.find.title" then
      beta_seg = true
    end
  end
  check("link segments: source title carries @organ.find.title", alpha_seg)
  check("link segments: target title carries @organ.find.title", beta_seg)
end

-- (f) File rows: format_file_segments produces basename / count /
-- path with semantic colors.
do
  local r = { file_path = "/tmp/notes.org", basename = "notes.org", headline_count = 7 }
  local segs = find.format_file_segments(r)
  local seen_basename, seen_count, seen_path = false, false, false
  for _, s in ipairs(segs) do
    if s[2] == "@org.heading.1" and s[1]:match("notes%.org") then
      seen_basename = true
    end
    if s[2] == "@organ.find.backlinks" and s[1] == "7" then
      seen_count = true
    end
    if s[2] == "@organ.find.path" and s[1]:match("notes%.org") then
      seen_path = true
    end
  end
  check("file segments: basename has @org.heading.1", seen_basename)
  check("file segments: count has @organ.find.backlinks", seen_count)
  check("file segments: path has @organ.find.path", seen_path)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("find_segments_test: PASS")
