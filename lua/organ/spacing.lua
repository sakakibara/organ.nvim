-- Empty-line policy for headline insert / move / paste / refile.
--
-- Some org users put blank lines between headlines, some don't.  Some
-- put one above, some both.  Some use multiple.  This module detects
-- the buffer's existing pattern and applies it consistently when
-- structure operations create or move headlines, so the result reads
-- like the user wrote it.
--
-- Config (`config.structure.headline_spacing`):
--
--   "auto"            detect the dominant pattern and match
--                     (default; falls back to "none" on an empty buffer)
--   "none"            no empty lines around headlines
--   "before"          one empty line above each headline, none below
--   "after"           one empty line below each headline, none above
--   "both"            one empty line above and below
--   { before=N, after=M }  explicit counts (N, M >= 0)
--
-- The presets resolve to { before, after } pairs.

local M = {}

local PRESETS = {
  none = { before = 0, after = 0 },
  before = { before = 1, after = 0 },
  after = { before = 0, after = 1 },
  both = { before = 1, after = 1 },
}

local function is_headline_line(s)
  return s and s:match("^%*+%s") ~= nil
end

local function is_blank(s)
  return s == nil or s:match("^%s*$") ~= nil
end

-- Read the user-configured policy.  Resolves preset strings to
-- { before, after }; passes through explicit count tables; falls
-- back to "auto" -> detect_policy(bufnr) when not specified.
function M.resolve(bufnr, override)
  local raw = override
  if raw == nil then
    raw = (require("organ").config.structure or {}).headline_spacing
  end
  if raw == nil or raw == "auto" then
    return M.detect(bufnr)
  end
  if type(raw) == "string" then
    return PRESETS[raw] or PRESETS.none
  end
  if type(raw) == "table" then
    return {
      before = math.max(0, tonumber(raw.before) or 0),
      after = math.max(0, tonumber(raw.after) or 0),
    }
  end
  return PRESETS.none
end

-- Detect the buffer's dominant headline-spacing pattern.
--
-- For each heading line H, count:
--   * BEFORE: blank lines IMMEDIATELY above H, up to the previous
--     non-blank line (or start-of-buffer).
--   * AFTER:  blank lines IMMEDIATELY below H, up to the next
--     non-blank / heading line (or end-of-buffer).  We measure on
--     the BODY side because the typical "empty line after a
--     heading" sits between H and its body.
--
-- Returns { before = mode_count, after = mode_count }.  Empty buffer
-- (no headings) -> { before = 0, after = 0 }.  Mixed buffers fall
-- back to the modal value; ties are broken toward the smaller count
-- (matches Emacs's mostly-no-blank default style).
function M.detect(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local n = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
  local before_counts, after_counts = {}, {}

  for i, line in ipairs(lines) do
    if is_headline_line(line) then
      local b = 0
      for j = i - 1, 1, -1 do
        if is_blank(lines[j]) then
          b = b + 1
        else
          break
        end
      end
      -- Don't count leading-of-buffer blanks; they're not a "between"
      -- pattern (no preceding element to be spaced from).
      local prev_non_blank
      for j = i - 1, 1, -1 do
        if not is_blank(lines[j]) then
          prev_non_blank = j
          break
        end
      end
      if prev_non_blank then
        before_counts[#before_counts + 1] = b
      end

      local a = 0
      for j = i + 1, n do
        if is_blank(lines[j]) then
          a = a + 1
        else
          break
        end
      end
      -- Only count when there's a next non-blank element (otherwise
      -- the blanks are trailing-of-buffer noise, not a real pattern).
      local next_non_blank
      for j = i + 1, n do
        if not is_blank(lines[j]) then
          next_non_blank = j
          break
        end
      end
      if next_non_blank then
        after_counts[#after_counts + 1] = a
      end
    end
  end

  local function mode(counts)
    if #counts == 0 then
      return 0
    end
    local hist = {}
    for _, c in ipairs(counts) do
      hist[c] = (hist[c] or 0) + 1
    end
    local best_count, best_freq = 0, -1
    for c, f in pairs(hist) do
      if f > best_freq or (f == best_freq and c < best_count) then
        best_count, best_freq = c, f
      end
    end
    return best_count
  end

  return { before = mode(before_counts), after = mode(after_counts) }
end

-- Apply `policy` (a { before, after } table) to a single headline at
-- `line` (1-based).  Trims existing blank lines on either side, then
-- emits exactly `before` blank lines above and `after` below.
--
-- Boundary semantics: at start-of-buffer, the "before" count
-- collapses to zero (nothing to be spaced from).  At end-of-buffer,
-- "after" likewise collapses (no following element).  This matches
-- the detection logic in M.detect.
-- Clean up a deletion site at `line` (1-based).  Resolves the heading
-- nearest the cut (the heading at `line`, or the first heading on
-- either side within a small distance) and re-applies the spacing
-- policy around it.  No-op if there's no heading to anchor to.
--
-- Use after a subtree has been removed from the buffer (archive,
-- refile out, clipboard cut) so the resulting blank-line state stays
-- consistent with the surrounding pattern.
function M.normalize_at_cut(bufnr, line, policy)
  policy = policy or M.detect(bufnr)
  local total = vim.api.nvim_buf_line_count(bufnr)
  if total == 0 then
    return
  end
  -- The line at `line` (1-based) is now whatever moved up after
  -- deletion.  Walk forward and backward to find the nearest heading.
  local function get(l)
    return vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
  end
  local target
  if line >= 1 and line <= total and is_headline_line(get(line)) then
    target = line
  else
    -- Prefer the heading just below the cut (typical case).
    for j = line, math.min(total, line + 16) do
      if j >= 1 and is_headline_line(get(j)) then
        target = j
        break
      end
    end
    if not target then
      for j = math.min(total, line - 1), math.max(1, line - 16), -1 do
        if is_headline_line(get(j)) then
          target = j
          break
        end
      end
    end
  end
  if target then
    M.normalize_around(bufnr, target, policy)
  end
end

function M.normalize_around(bufnr, line, policy)
  policy = policy or M.detect(bufnr)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, total, false)
  if not is_headline_line(lines[line]) then
    return -- nothing to normalize
  end

  -- Find blank-line spans above + below.
  local above_first = line
  for j = line - 1, 1, -1 do
    if is_blank(lines[j]) then
      above_first = j
    else
      break
    end
  end
  local below_last = line
  for j = line + 1, total do
    if is_blank(lines[j]) then
      below_last = j
    else
      break
    end
  end

  local has_pred = above_first > 1
  local has_succ = below_last < total

  local want_before = has_pred and policy.before or 0
  local want_after = has_succ and policy.after or 0

  local replacement = {}
  for _ = 1, want_before do
    replacement[#replacement + 1] = ""
  end
  replacement[#replacement + 1] = lines[line]
  for _ = 1, want_after do
    replacement[#replacement + 1] = ""
  end

  vim.api.nvim_buf_set_lines(bufnr, above_first - 1, below_last, false, replacement)
end

return M
