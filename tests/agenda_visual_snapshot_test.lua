-- Agenda visual snapshot — pins the rendered structure (text + extmark
-- highlight groups) of the agenda buffer for a known input.
--
-- The default render mirrors Emacs's `org-agenda-prefix-format`. Each row:
--
--   "  category    09:00       TODO [#A] Title              :tag:tag:"
--   ^^             ^^^^^       ^^^^ ^^^^                    ^
--   indent (2)     time-pad    todo prio cookie             tags right-aligned
--                              (auto-fit width)             at column 80
--
-- Customizable via `agenda.{ category_width, time_width, todo_width,
-- tags_column, prefix_format }`.
--
-- A regression in any of these visual rules will fail this snapshot.
--
-- Run via: nvim --headless -l tests/agenda_visual_snapshot_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
-- Snapshot tests assert inline tag chars; opt out of the new
-- virt_text right-align path so the buffer-line text contains tags.
require("organ").config.agenda = require("organ").config.agenda or {}
require("organ").config.agenda.tags_virt_align = false

-- Stub the query so we have a deterministic input set.
local sample = {
  {
    id = "h1",
    file_path = "/tmp/work.org",
    title = "Ship feature",
    line_start = 4,
    level = 1,
    todo_state = "TODO",
    priority = "A",
    tags = { "work", "urgent" },
  },
  {
    id = "h2",
    file_path = "/tmp/work.org",
    title = "Code review",
    line_start = 12,
    level = 1,
    todo_state = "NEXT",
    priority = "B",
  },
  {
    id = "h3",
    file_path = "/tmp/personal.org",
    title = "Buy groceries",
    line_start = 1,
    level = 1,
    todo_state = "DONE",
    tags = { "errand" },
  },
  {
    id = "h4",
    file_path = "/tmp/work.org",
    title = "Untagged plain heading",
    line_start = 20,
    level = 1,
  },
}
package.loaded["organ.query"] = {
  agenda = function()
    return sample
  end,
  headlines = function()
    return sample
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
  agenda = {
    views = {
      snap = { blocks = { { source = "headlines" } } },
    },
  },
})

local agenda = require("organ.agenda")
agenda.open({ name = "snap" })
local bufnr = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

-- Strip the empty trailing line (renderer-emit artifact).
while #lines > 0 and lines[#lines] == "" do
  lines[#lines] = nil
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

print()
print("---- agenda snapshot ----")
for i, l in ipairs(lines) do
  print(string.format("%2d: %s", i, l))
end
print("-------------------------")
print()

-- Find the line for each known title.
local function find_line(needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return l
    end
  end
  return nil
end

local row_a = find_line("Ship feature")
local row_b = find_line("Code review")
local row_c = find_line("Buy groceries")
local row_d = find_line("Untagged plain heading")

check("snapshot: each headline gets a line", row_a and row_b and row_c and row_d)

-- ---------------------------------------------------------------------------
-- Format invariants (text-level)
-- ---------------------------------------------------------------------------
check("format: two-space left indent", row_a:sub(1, 2) == "  ", "got `" .. row_a:sub(1, 4) .. "`")

-- Category prefix on the left with trailing colon (Emacs `%-12:c`
-- default; defaults to filename stem).
check(
  "format: category prefix `work:` for /tmp/work.org row",
  row_a:match("^%s+work:") ~= nil,
  "got `" .. row_a .. "`"
)
check(
  "format: category prefix `personal:` for /tmp/personal.org row",
  row_c:match("^%s+personal:") ~= nil,
  "got `" .. row_c .. "`"
)

-- Priority cookie: `[#A]` (matches the org source spec). NO placeholder
-- when priority is unset (mirrors Emacs).
check(
  "format: priority `[#A]` cookie present for high-priority row",
  row_a:find("[#A]", 1, true) ~= nil
)
check(
  "format: NO placeholder for unprioritized row (no `[#` substring)",
  not row_d:find("[#", 1, true),
  "got `" .. row_d .. "`"
)

-- TODO column auto-fits to the longest keyword in view. With TODO/NEXT/DONE
-- present the width is 4; rows include a trailing separator space.
check(
  "format: TODO column contains `TODO ` (auto-fit width 4 + sep)",
  row_a:find("TODO ", 1, true) ~= nil
)
check("format: NEXT column rendered", row_b:find("NEXT ", 1, true) ~= nil)
check("format: DONE column rendered", row_c:find("DONE ", 1, true) ~= nil)
-- Unset TODO state on row_d → padded with spaces (column stays aligned).
-- We don't pin exact whitespace count; just confirm no spurious cookie.
check("format: untagged + unprioritized row has no `[#` cookie", not row_d:find("[#", 1, true))

-- The location column is GONE — Emacs uses category prefix on the left
-- to identify rows; line numbers aren't shown.
check(
  "format: no `file.org:N` suffix in default render",
  not row_a:find("%.org:%d"),
  "got `" .. row_a .. "`"
)

-- Tags rendered as `:a:b:`.
check(
  "format: tags rendered as `:work:urgent:`",
  row_a:find(":work:urgent:", 1, true) ~= nil,
  "got `" .. row_a .. "`"
)
check(
  "format: untagged row has no `:tag:` segment",
  not row_d:find(":[%w_]+:"),
  "got `" .. row_d .. "`"
)

-- ---------------------------------------------------------------------------
-- Highlight invariants (extmark-level)
-- ---------------------------------------------------------------------------
local NS = vim.api.nvim_get_namespaces()["organ-agenda"]
check("snapshot: organ-agenda namespace registered", NS ~= nil)

local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
local hl_groups = {}
for _, m in ipairs(marks) do
  local hg = m[4] and m[4].hl_group
  if hg then
    hl_groups[hg] = (hl_groups[hg] or 0) + 1
  end
end

check(
  "hl: priority A uses @organ.agenda.priority_A",
  (hl_groups["@organ.agenda.priority_A"] or 0) >= 1,
  "groups: " .. vim.inspect(hl_groups)
)
check(
  "hl: priority B uses @organ.agenda.priority_B",
  (hl_groups["@organ.agenda.priority_B"] or 0) >= 1
)
check(
  "hl: TODO state uses @organ.agenda.todo_todo",
  (hl_groups["@organ.agenda.todo_todo"] or 0) >= 1
)
check(
  "hl: NEXT state uses @organ.agenda.todo_next",
  (hl_groups["@organ.agenda.todo_next"] or 0) >= 1
)
check(
  "hl: DONE state uses @organ.agenda.todo_done",
  (hl_groups["@organ.agenda.todo_done"] or 0) >= 1
)
check(
  "hl: category column uses @organ.agenda.category",
  (hl_groups["@organ.agenda.category"] or 0) >= 1
)
check("hl: tag column uses @organ.agenda.tag", (hl_groups["@organ.agenda.tag"] or 0) >= 1)

-- ---------------------------------------------------------------------------
-- Highlight groups have catppuccin/native fallbacks (link-with-default)
-- so the agenda is never unstyled when the user's colorscheme doesn't
-- define them.
-- ---------------------------------------------------------------------------
for _, g in ipairs({
  "@organ.agenda.priority_A",
  "@organ.agenda.priority_B",
  "@organ.agenda.todo_todo",
  "@organ.agenda.todo_next",
  "@organ.agenda.todo_done",
  "@organ.agenda.category",
  "@organ.agenda.tag",
}) do
  local h = vim.api.nvim_get_hl(0, { name = g })
  -- Either it has fg/bg/links somewhere, or it's defined-as-link.
  local defined = next(h) ~= nil
  check(
    "hl-fallback: " .. g .. " has a definition (no unstyled groups)",
    defined,
    "got " .. vim.inspect(h)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_visual_snapshot_test: PASS")
