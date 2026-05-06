-- spacing.detect / spacing.resolve / spacing.normalize_around exercise
-- every case the policy needs to handle: no-blank, one-above, one-below,
-- both, multiple-blank, mixed counts, mixed positions.
--
-- Run via: nvim --headless -l tests/spacing_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Required by spacing's `require("organ").config` lookup.
require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local spacing = require("organ.spacing")

local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function eq_policy(got, want)
  return got and got.before == want.before and got.after == want.after
end

-- ---------------------------------------------------------------------------
-- detect: no-blank style
-- ---------------------------------------------------------------------------
do
  local b = buf_with({
    "* H1",
    "body 1",
    "* H2",
    "body 2",
    "* H3",
  })
  local p = spacing.detect(b)
  check(
    "no blanks anywhere -> { before=0, after=0 }",
    eq_policy(p, { before = 0, after = 0 }),
    vim.inspect(p)
  )
end

-- one-blank-above style
do
  local b = buf_with({
    "preamble",
    "",
    "* H1",
    "body",
    "",
    "* H2",
    "body",
  })
  local p = spacing.detect(b)
  check(
    "one blank above each headline -> { before=1, after=0 }",
    eq_policy(p, { before = 1, after = 0 }),
    vim.inspect(p)
  )
end

-- one-blank-below style (after the heading line, before the body)
do
  local b = buf_with({
    "* H1",
    "",
    "body",
    "* H2",
    "",
    "body",
  })
  local p = spacing.detect(b)
  check(
    "one blank after each headline -> { before=0, after=1 }",
    eq_policy(p, { before = 0, after = 1 }),
    vim.inspect(p)
  )
end

-- both above and below
do
  local b = buf_with({
    "preamble",
    "",
    "* H1",
    "",
    "body",
    "",
    "* H2",
    "",
    "body",
  })
  local p = spacing.detect(b)
  check(
    "blank before AND after -> { before=1, after=1 }",
    eq_policy(p, { before = 1, after = 1 }),
    vim.inspect(p)
  )
end

-- multiple blanks (consistent count of 2)
do
  local b = buf_with({
    "preamble",
    "",
    "",
    "* H1",
    "body",
    "",
    "",
    "* H2",
    "body",
  })
  local p = spacing.detect(b)
  check("two blanks above each -> before=2", p.before == 2, vim.inspect(p))
end

-- mixed counts: majority wins, tie -> smaller
do
  -- 3 headlines: 0 blanks before H2, 1 before H3, 0 before next.
  -- Modal "before" count = 0.
  local b = buf_with({
    "* H1",
    "body",
    "* H2",
    "body",
    "",
    "* H3",
    "body",
    "* H4",
  })
  local p = spacing.detect(b)
  check("mixed counts (0,0,1,0) -> mode=0", p.before == 0, vim.inspect(p) .. " (zeros should win)")
end

-- mixed positions: some have blanks above, some below, modal pattern
do
  -- H1 has nothing; H2 has 1 above, 1 below; H3 has 1 above, 1 below.
  -- before counts collected = [0, 1, 1]; mode = 1.
  -- after counts collected = [0, 1, 1] (only when there's a successor).
  local b = buf_with({
    "* H1",
    "body",
    "",
    "* H2",
    "",
    "body",
    "",
    "* H3",
    "",
    "body",
  })
  local p = spacing.detect(b)
  check("majority above (0,1,1) -> before=1", p.before == 1, vim.inspect(p))
  check("majority after  (0,1,1) -> after=1", p.after == 1, vim.inspect(p))
end

-- empty buffer
do
  local b = buf_with({})
  local p = spacing.detect(b)
  check(
    "empty buffer -> { before=0, after=0 }",
    eq_policy(p, { before = 0, after = 0 }),
    vim.inspect(p)
  )
end

-- buffer with no headlines
do
  local b = buf_with({ "just prose", "more prose" })
  local p = spacing.detect(b)
  check(
    "prose-only -> { before=0, after=0 }",
    eq_policy(p, { before = 0, after = 0 }),
    vim.inspect(p)
  )
end

-- ---------------------------------------------------------------------------
-- resolve: presets and overrides
-- ---------------------------------------------------------------------------
do
  local b = buf_with({ "* H" })
  check(
    "preset 'none' -> { 0, 0 }",
    eq_policy(spacing.resolve(b, "none"), { before = 0, after = 0 })
  )
  check(
    "preset 'before' -> { 1, 0 }",
    eq_policy(spacing.resolve(b, "before"), { before = 1, after = 0 })
  )
  check(
    "preset 'after' -> { 0, 1 }",
    eq_policy(spacing.resolve(b, "after"), { before = 0, after = 1 })
  )
  check(
    "preset 'both' -> { 1, 1 }",
    eq_policy(spacing.resolve(b, "both"), { before = 1, after = 1 })
  )
  check(
    "explicit { before=2, after=3 } passes through",
    eq_policy(spacing.resolve(b, { before = 2, after = 3 }), { before = 2, after = 3 })
  )
  -- "auto" delegates to detect
  local p = spacing.resolve(b, "auto")
  check("preset 'auto' delegates to detect", eq_policy(p, spacing.detect(b)), vim.inspect(p))
end

-- config fallback: when override is nil, read config.structure.headline_spacing
do
  require("organ").config.structure = require("organ").config.structure or {}
  require("organ").config.structure.headline_spacing = "both"
  local b = buf_with({ "* H" })
  check(
    "config.structure.headline_spacing = 'both' picked up when no override",
    eq_policy(spacing.resolve(b, nil), { before = 1, after = 1 })
  )
  require("organ").config.structure.headline_spacing = nil
end

-- ---------------------------------------------------------------------------
-- normalize_around: enforces the policy at a specific headline
-- ---------------------------------------------------------------------------

local function lines_of(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- Insert a heading too tight; normalize to "both".
do
  local b = buf_with({
    "preamble",
    "* H1",
    "body",
  })
  spacing.normalize_around(b, 2, { before = 1, after = 1 })
  local got = lines_of(b)
  check(
    "normalize tight -> blank before and after",
    got[1] == "preamble" and got[2] == "" and got[3] == "* H1" and got[4] == "" and got[5] == "body",
    table.concat(got, "|")
  )
end

-- Heading with too-many blanks gets trimmed to policy.
do
  local b = buf_with({
    "preamble",
    "",
    "",
    "",
    "* H1",
    "",
    "",
    "body",
  })
  spacing.normalize_around(b, 5, { before = 1, after = 1 })
  local got = lines_of(b)
  check(
    "normalize over-spaced -> exactly { before=1, after=1 }",
    got[1] == "preamble" and got[2] == "" and got[3] == "* H1" and got[4] == "" and got[5] == "body",
    table.concat(got, "|")
  )
end

-- Boundary: heading at start-of-buffer doesn't get a phantom blank line above.
do
  local b = buf_with({
    "* H1",
    "body",
  })
  spacing.normalize_around(b, 1, { before = 1, after = 1 })
  local got = lines_of(b)
  check(
    "start-of-buffer heading: 'before' collapses to 0",
    got[1] == "* H1" and got[2] == "" and got[3] == "body",
    table.concat(got, "|")
  )
end

-- Boundary: heading at end-of-buffer doesn't get a phantom blank line below.
do
  local b = buf_with({
    "body",
    "* H1",
  })
  spacing.normalize_around(b, 2, { before = 1, after = 1 })
  local got = lines_of(b)
  check(
    "end-of-buffer heading: 'after' collapses to 0",
    got[1] == "body" and got[2] == "" and got[3] == "* H1",
    table.concat(got, "|")
  )
end

-- ---------------------------------------------------------------------------
-- Exhaustive policy combinations: every (before, after) in {0..3} x {0..3}
-- against an over-spaced source buffer.  Asserts the heading is at the
-- expected line, with exactly N blanks before it and M blanks after.
-- ---------------------------------------------------------------------------
for before = 0, 3 do
  for after = 0, 3 do
    local b = buf_with({
      "preamble",
      "",
      "",
      "",
      "",
      "* H1",
      "",
      "",
      "",
      "",
      "body",
    })
    -- find the heading first
    local heading_line
    for i, line in ipairs(lines_of(b)) do
      if line:match("^%*") then
        heading_line = i
        break
      end
    end
    spacing.normalize_around(b, heading_line, { before = before, after = after })
    local got = lines_of(b)
    -- Find new heading position
    local new_pos
    for i, line in ipairs(got) do
      if line:match("^%*") then
        new_pos = i
        break
      end
    end
    -- Verify exactly `before` blanks above, `after` below.
    local blanks_before = 0
    for i = new_pos - 1, 1, -1 do
      if got[i] == "" then
        blanks_before = blanks_before + 1
      else
        break
      end
    end
    local blanks_after = 0
    for i = new_pos + 1, #got do
      if got[i] == "" then
        blanks_after = blanks_after + 1
      else
        break
      end
    end
    check(
      string.format("policy { before=%d, after=%d } applied exactly", before, after),
      blanks_before == before and blanks_after == after,
      string.format(
        "got before=%d, after=%d (lines: %s)",
        blanks_before,
        blanks_after,
        table.concat(got, "|")
      )
    )
  end
end

-- ---------------------------------------------------------------------------
-- Edge: two consecutive headings with policy (1,1) -- the shared gap
-- between them resolves to one blank line, not two.  normalize_around
-- on the SECOND heading should leave the first heading's "after" gap
-- as part of its own region, not double up.
-- ---------------------------------------------------------------------------
do
  local b = buf_with({
    "* H1",
    "* H2",
    "body",
  })
  spacing.normalize_around(b, 2, { before = 1, after = 1 })
  local got = lines_of(b)
  check(
    "two-back-to-back headings: policy(1,1) on H2 inserts 1 blank above H2",
    got[1] == "* H1" and got[2] == "" and got[3] == "* H2" and got[4] == "" and got[5] == "body",
    table.concat(got, "|")
  )
end

-- ---------------------------------------------------------------------------
-- Detection adversarial: bimodal pattern (half headings at 0 blanks,
-- half at 2 blanks before).  Mode should pick whichever is more
-- frequent; tie -> smaller.
-- ---------------------------------------------------------------------------
do
  -- before counts: H2 -> 0, H3 -> 2, H4 -> 0, H5 -> 2.  Tie -> 0.
  local b = buf_with({
    "* H1",
    "body",
    "* H2",
    "body",
    "",
    "",
    "* H3",
    "body",
    "* H4",
    "body",
    "",
    "",
    "* H5",
    "body",
  })
  local p = spacing.detect(b)
  check("bimodal (0,2,0,2): tie-break to smaller (before=0)", p.before == 0, vim.inspect(p))
end

-- ---------------------------------------------------------------------------
-- Detection adversarial: clear majority of 2 blanks despite some 0s.
-- ---------------------------------------------------------------------------
do
  -- before counts: 0, 2, 2, 2 -> mode = 2.
  local b = buf_with({
    "* H1",
    "body",
    "* H2",
    "body",
    "",
    "",
    "* H3",
    "body",
    "",
    "",
    "* H4",
    "body",
    "",
    "",
    "* H5",
    "body",
  })
  local p = spacing.detect(b)
  check("majority of 2 blanks (one zero outlier): before=2", p.before == 2, vim.inspect(p))
end

-- ---------------------------------------------------------------------------
-- Detection: leading-of-buffer blanks don't poison the count for the
-- first heading.
-- ---------------------------------------------------------------------------
do
  local b = buf_with({
    "",
    "",
    "",
    "* H1",
    "body",
    "* H2",
    "body",
  })
  local p = spacing.detect(b)
  check("leading-of-buffer blanks ignored: before=0", p.before == 0, vim.inspect(p))
end

-- ---------------------------------------------------------------------------
-- Detection: trailing-of-buffer blanks don't poison the count for the
-- last heading.
-- ---------------------------------------------------------------------------
do
  local b = buf_with({
    "* H1",
    "body",
    "* H2",
    "body",
    "",
    "",
    "",
  })
  local p = spacing.detect(b)
  check("trailing-of-buffer blanks ignored: after=0", p.after == 0, vim.inspect(p))
end

-- ---------------------------------------------------------------------------
-- Detection: nested headings (different levels) all contribute to the
-- same count.  Not level-aware -- a single dominant pattern wins
-- across all depths.
-- ---------------------------------------------------------------------------
do
  local b = buf_with({
    "* H1",
    "",
    "** Sub",
    "",
    "*** Subsub",
    "",
    "* H2",
  })
  local p = spacing.detect(b)
  -- before counts: H1 -> (no pred, ignored), Sub -> 1, Subsub -> 1, H2 -> 1.
  -- mode = 1.
  check("nested levels share the same count -> before=1", p.before == 1, vim.inspect(p))
end

-- ---------------------------------------------------------------------------
-- normalize_around applied repeatedly is idempotent: running twice
-- with the same policy produces the same result as running once.
-- ---------------------------------------------------------------------------
do
  local b = buf_with({
    "preamble",
    "",
    "* H1",
    "body",
  })
  spacing.normalize_around(b, 3, { before = 1, after = 1 })
  local once = vim.fn.deepcopy(lines_of(b))
  -- Heading may have moved; re-find.
  local pos
  for i, l in ipairs(once) do
    if l:match("^%*") then
      pos = i
      break
    end
  end
  spacing.normalize_around(b, pos, { before = 1, after = 1 })
  local twice = lines_of(b)
  check(
    "normalize_around is idempotent",
    table.concat(once, "|") == table.concat(twice, "|"),
    string.format("once=%s twice=%s", table.concat(once, "|"), table.concat(twice, "|"))
  )
end

-- Multiple-blank policy (preserve count of 2)
do
  local b = buf_with({
    "preamble",
    "* H1",
    "body",
  })
  spacing.normalize_around(b, 2, { before = 2, after = 2 })
  local got = lines_of(b)
  check(
    "policy { before=2, after=2 } yields 2 blank lines on each side",
    got[1] == "preamble"
      and got[2] == ""
      and got[3] == ""
      and got[4] == "* H1"
      and got[5] == ""
      and got[6] == ""
      and got[7] == "body",
    table.concat(got, "|")
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("spacing_test: PASS")
