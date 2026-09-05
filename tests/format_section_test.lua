-- format_buffer: normalize_section pass reorders each headline's
-- planning / property-drawer / LOGBOOK prefix into canonical order.
--
-- Run via: nvim --headless -l tests/format_section_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local fmt = require("organ.format")
local organ = require("organ")

-- Minimal format config that keeps non-section passes quiet so fixture
-- comparisons are easy to reason about: no tag alignment, no rewrap,
-- no blank-policy change, trim trailing whitespace still on (safe default).
local function quiet_format_cfg(extra)
  local base = {
    wrap = { enabled = false },
    headline = { tags_column = false, normalize_whitespace = true },
    drawers = { align_values = false },
    blanks = {
      trim_trailing = true,
      ensure_final_newline = true,
      collapse_runs = 0,
      before_headline = "auto",
      before_block = "auto",
    },
    trim_trailing_whitespace = true,
    tables = { realign = false },
    lists = { repair_numbering = false },
    section = { normalize = true },
  }
  if extra then
    base = vim.tbl_deep_extend("force", base, extra)
  end
  return base
end

-- Install a config into organ so format_cfg() picks it up.
local function with_format_cfg(cfg, fn)
  local prev = organ.config.format
  organ.config.format = cfg
  local ok, err = pcall(fn)
  organ.config.format = prev
  if not ok then
    error(err, 2)
  end
end

local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  pcall(vim.treesitter.get_parser, b, "org")
  return b
end

local function get_lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- 1. Fixpoint idempotency: format(format(x)) == format(x).
--    Canonical section: SCHEDULED / DEADLINE / CLOSED one-per-line,
--    property drawer, LOGBOOK -- all already in order.
do
  local input = {
    "* TODO Idempotency check",
    "  SCHEDULED: <2026-06-09 Mon>",
    "  DEADLINE: <2026-06-10 Tue>",
    "  :PROPERTIES:",
    "  :ID:  abc123",
    "  :END:",
    "  :LOGBOOK:",
    "  CLOCK: [2026-06-09 Mon 09:00]--[2026-06-09 Mon 10:00] =>  1:00",
    "  :END:",
    "  Body text here.",
  }
  local cfg = quiet_format_cfg()
  with_format_cfg(cfg, function()
    local b1 = buf_with(input)
    fmt.format_buffer(b1)
    local after_first = get_lines(b1)

    local b2 = buf_with(after_first)
    fmt.format_buffer(b2)
    local after_second = get_lines(b2)

    local same = #after_first == #after_second
    if same then
      for i = 1, #after_first do
        if after_first[i] ~= after_second[i] then
          same = false
          break
        end
      end
    end
    check(
      "idempotency: format(format(x)) == format(x)",
      same,
      "first=" .. vim.inspect(after_first) .. " second=" .. vim.inspect(after_second)
    )
  end)
end

-- 2. A SCHEDULED line below the property drawer is body text to org
--    (`org-entry-get` reads planning only from the line directly under the
--    headline).  Hoisting it would turn prose into a real deadline, so the
--    section pass leaves the order alone.
do
  local input = {
    "* TODO Repair test",
    "  :PROPERTIES:",
    "  :ID:  repairid",
    "  :END:",
    "  SCHEDULED: <2026-06-09 Mon>",
    "  Body.",
  }
  local cfg = quiet_format_cfg()
  with_format_cfg(cfg, function()
    local b = buf_with(input)
    fmt.format_buffer(b)
    local lines = get_lines(b)

    local sched_row, props_row
    for i, l in ipairs(lines) do
      if l:match("SCHEDULED:") and not sched_row then
        sched_row = i
      end
      if l:match(":PROPERTIES:") and not props_row then
        props_row = i
      end
    end
    check("repair: SCHEDULED present after format", sched_row ~= nil, vim.inspect(lines))
    check("repair: :PROPERTIES: present after format", props_row ~= nil, vim.inspect(lines))
    check(
      "repair: the SCHEDULED line stays below :PROPERTIES:",
      sched_row ~= nil and props_row ~= nil and sched_row > props_row,
      "sched_row="
        .. tostring(sched_row)
        .. " props_row="
        .. tostring(props_row)
        .. " lines="
        .. vim.inspect(lines)
    )

    -- Verify no content was lost: all five original structural lines present.
    local has_id, has_end, has_body = false, false, false
    for _, l in ipairs(lines) do
      if l:match(":ID:") then
        has_id = true
      end
      if l:match("^%s*:END:") then
        has_end = true
      end
      if l:match("Body%.") then
        has_body = true
      end
    end
    check("repair: :ID: preserved", has_id, vim.inspect(lines))
    check("repair: :END: preserved", has_end, vim.inspect(lines))
    check("repair: body preserved", has_body, vim.inspect(lines))
  end)
end

-- 3. No-op on already-canonical: a simple canonical section
--    (headline + SCHEDULED + :PROPERTIES:/:ID:/:END:) is byte-identical
--    after format_buffer.  No tags to realign; quiet_format_cfg disables
--    tag alignment and prose rewrap so the only thing that could change is
--    the section order pass.
do
  local canonical = {
    "* TODO Already canonical",
    "  SCHEDULED: <2026-06-09 Mon>",
    "  :PROPERTIES:",
    "  :ID:  canon1",
    "  :END:",
    "  Body prose.",
  }
  local cfg = quiet_format_cfg()
  with_format_cfg(cfg, function()
    local b = buf_with(canonical)
    fmt.format_buffer(b)
    local after = get_lines(b)

    -- Compare content lines only (trim trailing empty from both sides).
    local function trim_trailing_empty(t)
      local n = #t
      while n > 0 and t[n] == "" do
        n = n - 1
      end
      local out = {}
      for i = 1, n do
        out[i] = t[i]
      end
      return out
    end

    local canon_trimmed = trim_trailing_empty(canonical)
    local after_trimmed = trim_trailing_empty(after)

    local same = #canon_trimmed == #after_trimmed
    if same then
      for i = 1, #canon_trimmed do
        if canon_trimmed[i] ~= after_trimmed[i] then
          same = false
          break
        end
      end
    end
    check(
      "no-op canonical: byte-identical after format",
      same,
      "expected=" .. vim.inspect(canon_trimmed) .. " got=" .. vim.inspect(after_trimmed)
    )
  end)
end

-- 4. Disabled knob: with format.section.normalize = false, the
--    property-before-planning buffer is NOT reordered.
do
  local input = {
    "* TODO Knob disabled",
    "  :PROPERTIES:",
    "  :ID:  knobed",
    "  :END:",
    "  SCHEDULED: <2026-06-09 Mon>",
    "  Body.",
  }
  local cfg = quiet_format_cfg({ section = { normalize = false } })
  with_format_cfg(cfg, function()
    local b = buf_with(input)
    fmt.format_buffer(b)
    local lines = get_lines(b)

    -- When normalize is off, PROPERTIES still comes before SCHEDULED.
    local sched_row, props_row
    for i, l in ipairs(lines) do
      if l:match("SCHEDULED:") and not sched_row then
        sched_row = i
      end
      if l:match(":PROPERTIES:") and not props_row then
        props_row = i
      end
    end
    check(
      "disabled knob: SCHEDULED stays AFTER :PROPERTIES: (not reordered)",
      sched_row ~= nil and props_row ~= nil and props_row < sched_row,
      "sched_row="
        .. tostring(sched_row)
        .. " props_row="
        .. tostring(props_row)
        .. " lines="
        .. vim.inspect(lines)
    )
  end)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_section_test: PASS")
