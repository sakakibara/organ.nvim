-- Side-by-side visual comparison of organ's agenda render against the
-- documented Emacs org-mode and nvim-orgmode formats.
--
-- We exercise both view kinds Emacs has different defaults for:
--   * todo (M-x org-todo-list, prefix " %i %-12:c"): flat list, just
--     category + headline, no time/sched columns.
--   * agenda (M-x org-agenda a, prefix " %i %-12:c%?-12t% s"): grouped
--     by day, time + Scheduled:/Deadline: tag, hides undated rows.
--
-- We can't *run* Emacs in CI but we CAN pin our literal output AND echo
-- the documented Emacs output for the same sample, so a render change
-- forces an explicit snapshot-and-doc update.
--
-- Run via: nvim --headless -l tests/agenda_emacs_comparison_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
-- Snapshot tests assert inline tag chars; opt out of the new
-- virt_text right-align path so the buffer-line text contains tags.
require("organ").config.agenda = require("organ").config.agenda or {}
require("organ").config.agenda.tags_virt_align = false

local SAMPLE = {
  {
    id = "h1",
    file_path = "/work.org",
    title = "Standup",
    line_start = 4,
    level = 1,
    todo_state = "TODO",
    priority = "A",
    scheduled_date = "2026-05-03T09:00",
    tags = { "work", "urgent" },
  },
  {
    id = "h2",
    file_path = "/work.org",
    title = "Code review",
    line_start = 12,
    level = 1,
    todo_state = "NEXT",
    priority = "B",
    tags = { "work" },
  },
  {
    id = "h3",
    file_path = "/personal.org",
    title = "Buy groceries",
    line_start = 1,
    level = 1,
    todo_state = "DONE",
    tags = { "errand" },
  },
  {
    id = "h4",
    file_path = "/work.org",
    title = "Untagged plain heading",
    line_start = 20,
    level = 1,
  },
  {
    id = "h5",
    file_path = "/work.org",
    title = "Notes for later",
    line_start = 30,
    level = 1,
    priority = "C",
    tags = { "ref" },
  },
}

package.loaded["organ.query"] = {
  agenda = function()
    return SAMPLE
  end,
  headlines = function()
    return SAMPLE
  end,
  files = function()
    return {}
  end,
  links = function()
    return {}
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
})

local agenda = require("organ.agenda")

-- ---------------------------------------------------------------------------
-- Render directly via the pure renderer so we can target both view kinds.
-- ---------------------------------------------------------------------------
local function render_block_lines(block)
  local out = agenda.render({ { block = block, rows = SAMPLE } }, { now = "2026-05-03" })
  -- Strip empty trailing lines.
  while #out.lines > 0 and out.lines[#out.lines] == "" do
    table.remove(out.lines)
  end
  return out.lines
end

local todo_lines = render_block_lines({ kind = "todo" })
local agenda_lines = render_block_lines({ kind = "agenda", from = "2026-05-03", to = "2026-05-03" })

print()
print("============== TODO list view (organ.nvim) ==============")
for _, l in ipairs(todo_lines) do
  print(l)
end
print("=========================================================")
print()
print("============== TODO list view (Emacs org-todo-list) =====")
print('(prefix-format = " %i %-12:c"; flat list; no time;')
print("  no Scheduled:/Deadline: tag)")
print("")
print("  work:        TODO [#A] Standup                              :work:urgent:")
print("  work:        NEXT [#B] Code review                                  :work:")
print("  work:             Untagged plain heading")
print("  personal:    DONE Buy groceries                                   :errand:")
print("  work:             [#C] Notes for later                               :ref:")
print("=========================================================")
print()
print("============== AGENDA view (organ.nvim) =================")
for _, l in ipairs(agenda_lines) do
  print(l)
end
print("=========================================================")
print()
print("============== AGENDA view (Emacs org-agenda a) =========")
print('(prefix-format = " %i %-12:c%?-12t% s"; day-grouped header;')
print("  timed rows separated by `┄┄┄┄┄`; Scheduled: prefix; undated hidden)")
print("")
print("Sunday      3 May 2026")
print("  work:        9:00 ┄┄┄┄┄ Scheduled:  TODO [#A] Standup        :work:urgent:")
print("=========================================================")
print()
print("============== Format parity =========================")
print("organ.nvim mirrors Emacs's `org-agenda-prefix-format`")
print("per-view-type defaults:")
print('  agenda  → "  %-12:c %?-12t %?s "')
print('  todo    → "  %-12:c "')
print('  stuck   → "  %-12:c "')
print()
print("Customize via `organ.config.agenda.prefix_format`. Pass a")
print("string to apply to all kinds, a table keyed by kind, or a")
print("function for full control. See `:h organ-agenda-format`.")
print("======================================================")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Pin the TODO-view rows literally.  Lines pad to one column shy of
-- the test-render edge (tags_column = -1 default puts the last char
-- of the tag block at the right edge).
local TODO_EXPECTED = {
  "  work:        TODO [#A] Standup                                  :work:urgent:",
  "  work:             Untagged plain heading",
  "  personal:    DONE Buy groceries                                      :errand:",
  "  work:        NEXT [#B] Code review                                     :work:",
  "  work:             [#C] Notes for later                                  :ref:",
}

check(
  "todo view: 5 row lines emitted",
  #todo_lines == #TODO_EXPECTED,
  "got " .. #todo_lines .. ": " .. vim.inspect(todo_lines)
)
for i = 1, math.max(#todo_lines, #TODO_EXPECTED) do
  check(
    ("todo view row %d: matches snapshot"):format(i),
    todo_lines[i] == TODO_EXPECTED[i],
    ("\n  got:  %q\n  want: %q"):format(
      todo_lines[i] or "(missing)",
      TODO_EXPECTED[i] or "(missing)"
    )
  )
end

-- Pin the agenda-view structure (date header + only-Standup-shown).
check(
  "agenda view: at least 2 lines (date header + Standup)",
  #agenda_lines >= 2,
  "got " .. #agenda_lines .. ": " .. vim.inspect(agenda_lines)
)
-- The buffer's first line is now the "Day-agenda (Wnn):" view header.
-- Find the first day-of-week line for the date-header check.
local function find_date_header_line(lines)
  for _, l in ipairs(lines) do
    if l:match("^%a+%s+%d+%s+%a+%s+%d%d%d%d") then
      return l
    end
  end
end
check(
  "agenda view: contains a full-name date header line",
  find_date_header_line(agenda_lines) ~= nil,
  "got lines: " .. vim.inspect(agenda_lines)
)
check(
  "agenda view: only the SCHEDULED row is shown (undated hidden)",
  (function()
    local n_data = 0
    for _, l in ipairs(agenda_lines) do
      -- Indented + non-blank; not a date header; not the "← now"
      -- marker; not an EMPTY time-grid line (`HH:00 ┄┄┄┄┄ ┄┄...`,
      -- distinguished by the second ┄-group from a timed row's
      -- `9:00 ┄┄┄┄┄ Scheduled:` shape); not the top-of-buffer
      -- "Day-agenda (Wnn):" view header. Everything else is data.
      if
        l:match("^%s+%S")
        and not l:match("^%a+%s+%d")
        and not l:find("← now", 1, true)
        and not l:find("┄┄┄┄┄ ┄┄", 1, true)
        and not l:find("agenda %(W")
      then
        n_data = n_data + 1
      end
    end
    return n_data == 1
  end)(),
  "lines: " .. vim.inspect(agenda_lines)
)
check(
  "agenda view: Standup row carries `9:00 ┄┄┄┄┄` separator (Emacs style)",
  (function()
    for _, l in ipairs(agenda_lines) do
      if l:find("Standup", 1, true) then
        return l:find("9:00 ┄┄┄┄┄", 1, true) ~= nil
      end
    end
    return false
  end)(),
  "lines: " .. vim.inspect(agenda_lines)
)
check(
  "agenda view: Standup row carries `Scheduled:` tag",
  (function()
    for _, l in ipairs(agenda_lines) do
      if l:find("Standup", 1, true) then
        return l:find("Scheduled:", 1, true) ~= nil
      end
    end
    return false
  end)(),
  "lines: " .. vim.inspect(agenda_lines)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  print()
  print("If the divergence is intentional, update the EXPECTED tables AND")
  print("doc/organ.txt under `AGENDA FORMAT`.")
  os.exit(1)
end
print()
print("agenda_emacs_comparison_test: PASS")
