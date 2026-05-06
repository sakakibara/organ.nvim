-- Capture target resolution.

local M = {}

local DEFAULT_DATETREE = { "%Y", "%Y-%m %B", "%Y-%m-%d %A" }

local function expand(p)
  return vim.fn.expand(p)
end

local function ensure_file(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  if not vim.loop.fs_stat(path) then
    vim.fn.writefile({}, path)
  end
end

local function read_lines(path)
  if not vim.loop.fs_stat(path) then
    return {}
  end
  return vim.fn.readfile(path)
end

-- Parse the file into a list of headline records:
--   { line = 1-based, level = N, title = "Heading text" }
local function parse_headlines(lines)
  local hls = {}
  for i, l in ipairs(lines) do
    local stars, title = l:match("^(%*+)%s+(.-)%s*$")
    if stars then
      hls[#hls + 1] = { line = i, level = #stars, title = title }
    end
  end
  return hls
end

-- Returns (line_start, line_end). line_end is the line AFTER the section.
local function section_bounds(hls, hl_idx, total_lines)
  local hl = hls[hl_idx]
  if not hl then
    return nil
  end
  local end_line = total_lines + 1
  for j = hl_idx + 1, #hls do
    if hls[j].level <= hl.level then
      end_line = hls[j].line
      break
    end
  end
  return hl.line, end_line
end

-- Walk an outline path; returns the index in `hls` of the leaf, or nil.
local function find_olp(hls, olp)
  if not olp or #olp == 0 then
    return nil
  end
  local depth = 0
  local last_idx
  for i, hl in ipairs(hls) do
    if hl.level == depth + 1 and hl.title == olp[depth + 1] then
      depth = depth + 1
      last_idx = i
      if depth == #olp then
        return last_idx
      end
    elseif hl.level <= depth then
      depth = math.min(depth, hl.level - 1)
      last_idx = nil
    end
  end
  return nil
end

-- Find first headline whose title exactly matches (any level).
local function find_headline(hls, title)
  for i, hl in ipairs(hls) do
    if hl.title == title then
      return i
    end
  end
  return nil
end

-- Datetree spine resolution.
local function resolve_datetree(hls, parent_idx, now, datetree_format)
  local fmts = datetree_format or DEFAULT_DATETREE
  local titles = {}
  for _, fmt in ipairs(fmts) do
    titles[#titles + 1] = os.date(fmt, now)
  end
  local parent_level = parent_idx and hls[parent_idx].level or 0

  local current_idx = parent_idx
  local current_level = parent_level
  local prelude = {}
  for level_offset, title in ipairs(titles) do
    local target_level = parent_level + level_offset
    local found
    local i = (current_idx and current_idx + 1) or 1
    while i <= #hls do
      local h = hls[i]
      if h.level <= current_level then
        break
      end
      if h.level == target_level and h.title == title then
        found = i
        break
      end
      i = i + 1
    end
    if found then
      current_idx = found
      current_level = target_level
    else
      for k = level_offset, #titles do
        prelude[#prelude + 1] = string.rep("*", parent_level + k) .. " " .. titles[k]
      end
      return current_idx, prelude
    end
  end
  return current_idx, prelude
end

function M.resolve(spec, ctx, prepend)
  local kind = spec.kind

  if kind == "file_function" then
    local path, line = spec.fn(ctx or {})
    return path, line, {}
  end

  local path = expand(spec.path)
  ensure_file(path)
  local lines = read_lines(path)

  if kind == "file" then
    return path, #lines + 1, {}
  end

  if kind == "file_regexp" then
    -- Insert at the FIRST line whose text matches `regexp` (Lua
    -- pattern). Mirrors Emacs `(file+regexp "path" "regex")`. With
    -- `prepend`, insert ABOVE the matched line; otherwise below.
    if type(spec.regexp) ~= "string" or spec.regexp == "" then
      error("capture.target: file_regexp requires `regexp`")
    end
    for i, line in ipairs(lines) do
      if line:find(spec.regexp) then
        return path, prepend and i or (i + 1), {}
      end
    end
    error("capture.target: regex not matched in " .. path .. ": " .. spec.regexp)
  end

  local hls = parse_headlines(lines)

  if kind == "file_headline" then
    local idx = find_headline(hls, spec.headline)
    if not idx then
      error("capture.target: headline not found: " .. spec.headline)
    end
    local s, e = section_bounds(hls, idx, #lines)
    -- Return the target's level as 4th value so capture.finalise
    -- can re-level the inserted entry to become a CHILD (level+1)
    -- instead of a sibling.  Mirrors Emacs's `entry`-type capture
    -- behavior; without it the captured `* TODO ...` lands at
    -- level 1 next to `* Inbox`, leaving a stray blank line and
    -- an awkward fold artifact.
    return path, prepend and (s + 1) or e, {}, hls[idx].level
  end

  if kind == "file_olp" then
    local idx = find_olp(hls, spec.olp)
    if not idx then
      error("capture.target: olp not found: " .. table.concat(spec.olp, " / "))
    end
    local s, e = section_bounds(hls, idx, #lines)
    return path, prepend and (s + 1) or e, {}, hls[idx].level
  end

  if kind == "file_olp_datetree" then
    local parent_idx
    local parent_level = 0
    if spec.olp and #spec.olp > 0 then
      parent_idx = find_olp(hls, spec.olp)
      if not parent_idx then
        error("capture.target: datetree parent olp not found: " .. table.concat(spec.olp, " / "))
      end
      parent_level = hls[parent_idx].level
    end
    local cfg = (require("organ").config.capture or {}).datetree_format
    local fmts = cfg or DEFAULT_DATETREE
    local leaf_level = parent_level + #fmts
    local leaf_idx, prelude = resolve_datetree(hls, parent_idx, (ctx or {}).now or os.time(), cfg)

    if leaf_idx and #prelude == 0 then
      local s, e = section_bounds(hls, leaf_idx, #lines)
      return path, prepend and (s + 1) or e, {}, leaf_level
    end

    local anchor_idx = leaf_idx
    if anchor_idx then
      local _, e = section_bounds(hls, anchor_idx, #lines)
      return path, e, prelude, leaf_level
    else
      return path, #lines + 1, prelude, leaf_level
    end
  end

  error("capture.target: unknown kind: " .. tostring(kind))
end

return M
