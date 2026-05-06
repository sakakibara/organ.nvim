-- Verifies the tag column is rendered as a `right_align` virt_text
-- extmark (default), not baked into the buffer line.  This is the
-- "better than Emacs" mechanism: window resizes re-align tags via
-- Neovim's render layer with no buffer churn / refresh.

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

local agenda = require("organ.agenda")

-- Render one row with tags.
local rows = {
  {
    id = "h1",
    title = "Submit expense report",
    todo_state = "NEXT",
    priority = "A",
    scheduled_date = "2026-05-04",
    tags = { "@office", "deep" },
    n_direct_tags = 2,
    file_path = "/tasks.org",
    line_start = 5,
    level = 1,
  },
}

local out = agenda.render({
  {
    block = {
      kind = "agenda",
      from = "2026-05-04",
      to = "2026-05-04",
      group_by = "day",
    },
    rows = rows,
  },
}, { now = "2026-05-04" })

-- Find the row line — the one carrying the title.
local row_line, row_lnum
for i, l in ipairs(out.lines) do
  if l:find("Submit expense report", 1, true) then
    row_line, row_lnum = l, i
    break
  end
end
check("rendered row line found", row_line ~= nil)

-- Buffer line must NOT contain the tag chars (tags moved to virt_text).
check(
  "row line excludes literal tag string",
  not (row_line and row_line:find(":@office:deep:", 1, true)),
  "got: " .. (row_line or "nil")
)

-- An extmark with virt_text + virt_text_pos = "right_align" must
-- exist on the row line.
local found_virt = false
for _, mk in ipairs(out.extmarks) do
  if
    mk[1] == row_lnum
    and mk[2] == "_virt"
    and type(mk[5]) == "table"
    and mk[5].virt_text_pos == "right_align"
  then
    -- chunk text matches the tag string
    local chunk = mk[5].virt_text and mk[5].virt_text[1]
    if chunk and chunk[1] == ":@office:deep:" then
      found_virt = true
      break
    end
  end
end
check("right-aligned virt_text extmark for tag block", found_virt)

-- Opt-out path: with `tags_virt_align = false`, tags appear in the
-- line as before (baked in with padding spaces).
require("organ").config.agenda = require("organ").config.agenda or {}
require("organ").config.agenda.tags_virt_align = false
local out2 = agenda.render({
  {
    block = {
      kind = "agenda",
      from = "2026-05-04",
      to = "2026-05-04",
      group_by = "day",
    },
    rows = rows,
  },
}, { now = "2026-05-04" })
local found_inline = false
for _, l in ipairs(out2.lines) do
  if l:find("Submit expense report", 1, true) and l:find(":@office:deep:", 1, true) then
    found_inline = true
    break
  end
end
check("opt-out: tags_virt_align=false bakes tags into line text", found_inline)

-- Inline-mode gutter regression: with `tags_column = -1` (window-
-- relative) and a window that has a non-zero gutter (sign column,
-- line numbers, fold column), tag padding must subtract `textoff`
-- so the tag block lands inside the visible text area.  Otherwise
-- tags are pushed off the right edge of the content area by exactly
-- `textoff` characters.
do
  local saved_getwininfo = vim.fn.getwininfo
  local saved_get_current_win = vim.api.nvim_get_current_win
  local saved_win_get_width = vim.api.nvim_win_get_width
  -- Pretend the agenda window is 100 cols total with a 4-col gutter
  -- (typical: signcolumn=yes:1 + number=3).  Both APIs are mocked so
  -- the old gutter-naive `nvim_win_get_width(0)` path AND the new
  -- gutter-aware `getwininfo()[1].textoff` path see the same window.
  vim.fn.getwininfo = function()
    return { { width = 100, textoff = 4 } }
  end
  vim.api.nvim_get_current_win = function()
    return 1
  end
  vim.api.nvim_win_get_width = function()
    return 100
  end
  local out3 = agenda.render({
    {
      block = {
        kind = "agenda",
        from = "2026-05-04",
        to = "2026-05-04",
        group_by = "day",
      },
      rows = rows,
    },
  }, { now = "2026-05-04" })
  vim.fn.getwininfo = saved_getwininfo
  vim.api.nvim_get_current_win = saved_get_current_win
  vim.api.nvim_win_get_width = saved_win_get_width
  local content_width = 100 - 4 -- 96 visible text cols
  local row_w
  for _, l in ipairs(out3.lines) do
    if l:find("Submit expense report", 1, true) then
      row_w = vim.fn.strdisplaywidth(l)
      break
    end
  end
  check(
    "gutter-aware: rendered line fits within content area",
    row_w ~= nil and row_w <= content_width,
    ("row width %s, content width %d"):format(tostring(row_w), content_width)
  )
end

-- Overflow marker: when title + 2-char gap + tag block exceeds the
-- visible content area, title visibility wins.  Both paths drop the
-- full tag run and emit a single-cell `tags_overflow_marker` (default
-- `›`) at the right edge so users know tags exist on the row.
do
  local saved_getwininfo = vim.fn.getwininfo
  local saved_get_current_win = vim.api.nvim_get_current_win
  -- Tiny window: 50 cols total, 0 gutter.  The "Submit expense report"
  -- row's prefix + title alone is ~45 cols, leaving no room for the
  -- 16-cell `:@office:deep:` tag run.
  vim.fn.getwininfo = function()
    return { { width = 50, textoff = 0 } }
  end
  vim.api.nvim_get_current_win = function()
    return 1
  end

  -- (a) virt_text path: extmark carries the marker, NOT the full tag.
  require("organ").config.agenda.tags_virt_align = true
  local out_v = agenda.render({
    {
      block = {
        kind = "agenda",
        from = "2026-05-04",
        to = "2026-05-04",
        group_by = "day",
      },
      rows = rows,
    },
  }, { now = "2026-05-04" })
  local saw_full_tag, saw_marker = false, false
  for _, mk in ipairs(out_v.extmarks) do
    if mk[2] == "_virt" and type(mk[5]) == "table" and mk[5].virt_text then
      local chunk = mk[5].virt_text[1]
      if chunk and chunk[1] == ":@office:deep:" then
        saw_full_tag = true
      end
      if chunk and chunk[1] == "›" then
        saw_marker = true
      end
    end
  end
  check("overflow virt_text: marker emitted", saw_marker)
  check("overflow virt_text: full tag NOT emitted", not saw_full_tag)

  -- (b) inline path: line text contains the marker, NOT the full tag.
  require("organ").config.agenda.tags_virt_align = false
  local out_i = agenda.render({
    {
      block = {
        kind = "agenda",
        from = "2026-05-04",
        to = "2026-05-04",
        group_by = "day",
      },
      rows = rows,
    },
  }, { now = "2026-05-04" })
  vim.fn.getwininfo = saved_getwininfo
  vim.api.nvim_get_current_win = saved_get_current_win
  local row_line
  for _, l in ipairs(out_i.lines) do
    if l:find("Submit expense report", 1, true) then
      row_line = l
      break
    end
  end
  check(
    "overflow inline: row contains marker",
    row_line and row_line:find("›", 1, true) ~= nil,
    "row: " .. tostring(row_line)
  )
  check(
    "overflow inline: row does NOT contain full tag",
    row_line and not row_line:find(":@office:deep:", 1, true),
    "row: " .. tostring(row_line)
  )
end

-- Restore default for remainder of test runner.
require("organ").config.agenda.tags_virt_align = nil

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_tag_virt_align_test: PASS")
