-- Org accepts planning on exactly one line -- the line directly under the
-- headline -- and every writer edits that line in place, keeping whatever
-- else it carries.  Each expectation below is the output of the matching
-- Emacs form on the same input (org 9.7, `emacs -Q`):
--
--   (org-todo "DONE")            with a DEADLINE range / trailing prose
--   (org-schedule nil DATE)      onto a line with a range or prose
--   (org-entry-get nil "...")    for a keyword line under a blank / drawer
--
-- Run via: nvim --headless -l tests/planning_scope_test.lua

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
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local element = require("organ.element")
local section = require("organ.section")

local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  pcall(vim.treesitter.get_parser, b, "org")
  return b
end

local function lines_of(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- ---------------------------------------------------------------------------
-- What counts as planning

do
  local cases = {
    { "directly under the headline", { "* h", "SCHEDULED: <2026-03-01 Sun>" }, 2 },
    { "after a blank line", { "* h", "", "SCHEDULED: <2026-03-01 Sun>" }, nil },
    {
      "after a property drawer",
      { "* h", ":PROPERTIES:", ":ID: x", ":END:", "SCHEDULED: <2026-03-01 Sun>" },
      nil,
    },
    {
      "on the second keyword line",
      { "* h", "DEADLINE: <2026-02-01 Fri>", "SCHEDULED: <2026-03-01 Sun>" },
      nil,
    },
    { "mid-line in prose", { "* h", "Was SCHEDULED: <2026-03-01 Sun> once" }, nil },
  }
  for _, c in ipairs(cases) do
    local b = buf_with(c[2])
    local got = element.planning_lines(b, 0).scheduled
    check(
      "SCHEDULED " .. c[1] .. (c[3] and " is planning" or " is not planning"),
      got == c[3],
      "got " .. tostring(got)
    )
  end
end

-- A planning line with no timestamp is still the planning line, so the
-- keyword line under it is body (Emacs: `org-planning-line-re` needs no
-- timestamp, and `org-entry-get` returns nil for both).
do
  local b = buf_with({ "* h", "SCHEDULED: soon", "DEADLINE: <2026-02-01 Fri>" })
  local p = element.planning_lines(b, 0)
  check("keywordless planning line reports nothing", p.scheduled == nil and p.deadline == nil)
  check("planning ends after that line", element.planning_end_line(b, 0) == 3)
end

-- ---------------------------------------------------------------------------
-- Writing keeps the rest of the line

do
  local b = buf_with({ "* TODO ship it", "DEADLINE: <2026-02-01 Fri>--<2026-02-05 Tue>", "body" })
  section.set_planning(b, 0, "CLOSED", "[2026-09-04 Fri 04:50]")
  check(
    "a DEADLINE range survives a CLOSED write",
    vim.deep_equal(lines_of(b), {
      "* TODO ship it",
      "CLOSED: [2026-09-04 Fri 04:50] DEADLINE: <2026-02-01 Fri>--<2026-02-05 Tue>",
      "body",
    }),
    vim.inspect(lines_of(b))
  )
end

do
  local b = buf_with({ "* TODO ship it", "SCHEDULED: <2026-01-02 Thu> ask Bob about it", "body" })
  section.set_planning(b, 0, "CLOSED", "[2026-09-04 Fri 04:50]")
  check(
    "trailing prose survives a CLOSED write",
    vim.deep_equal(lines_of(b), {
      "* TODO ship it",
      "CLOSED: [2026-09-04 Fri 04:50] SCHEDULED: <2026-01-02 Thu> ask Bob about it",
      "body",
    }),
    vim.inspect(lines_of(b))
  )
end

do
  local b = buf_with({ "* TODO x", "DEADLINE: <2026-02-01 Fri> mind the gap" })
  section.set_planning(b, 0, "SCHEDULED", "<2026-01-01 Thu>")
  check(
    "setting SCHEDULED puts it first and keeps the rest",
    vim.deep_equal(lines_of(b), {
      "* TODO x",
      "SCHEDULED: <2026-01-01 Thu> DEADLINE: <2026-02-01 Fri> mind the gap",
    }),
    vim.inspect(lines_of(b))
  )
end

-- Removing a keyword takes it up to the next keyword on the line, exactly
-- as org-add-planning-info's delete-region does.
do
  local b = buf_with({
    "* TODO x",
    "SCHEDULED: <2026-01-02 Thu> DEADLINE: <2026-02-01 Fri> note here",
  })
  section.set_planning(b, 0, "SCHEDULED", nil)
  check(
    "removing SCHEDULED leaves the following keyword and its note",
    vim.deep_equal(lines_of(b), { "* TODO x", "DEADLINE: <2026-02-01 Fri> note here" }),
    vim.inspect(lines_of(b))
  )
end

do
  local b = buf_with({ "* TODO x", "SCHEDULED: <2026-01-02 Thu>", "body" })
  section.set_planning(b, 0, "SCHEDULED", nil)
  check(
    "removing the only keyword drops the line",
    vim.deep_equal(lines_of(b), { "* TODO x", "body" }),
    vim.inspect(lines_of(b))
  )
end

-- Only the first occurrence of the keyword is replaced (one
-- `re-search-forward` per type in org-add-planning-info).
do
  local b = buf_with({ "* h", "SCHEDULED: <2026-01-02 Thu> SCHEDULED: <2026-01-09 Thu>" })
  section.set_planning(b, 0, "SCHEDULED", "<2026-02-02 Mon>")
  check(
    "a duplicate keyword later on the line is left alone",
    vim.deep_equal(lines_of(b), {
      "* h",
      "SCHEDULED: <2026-02-02 Mon> SCHEDULED: <2026-01-09 Thu>",
    }),
    vim.inspect(lines_of(b))
  )
end

-- A keyword line that is NOT planning must not be pulled up into one.
do
  local input = { "* h", "SCHEDULED: <2026-01-02 Thu>", "DEADLINE: <2026-02-01 Fri> is the cutoff" }
  local b = buf_with(input)
  section.set_planning(b, 0, "CLOSED", "[2026-09-04 Fri 04:50]")
  check(
    "a body line starting with DEADLINE: is not folded into planning",
    vim.deep_equal(lines_of(b), {
      "* h",
      "CLOSED: [2026-09-04 Fri 04:50] SCHEDULED: <2026-01-02 Thu>",
      "DEADLINE: <2026-02-01 Fri> is the cutoff",
    }),
    vim.inspect(lines_of(b))
  )
end

-- ---------------------------------------------------------------------------
-- Formatting invents nothing

do
  local cases = {
    {
      "a keyword line below a drawer",
      {
        "* h",
        ":PROPERTIES:",
        ":ID: x",
        ":END:",
        "SCHEDULED: <2026-03-01 Sun>",
      },
    },
    { "a keyword line below a blank", { "* h", "", "SCHEDULED: <2026-03-01 Sun>" } },
    { "a range on the planning line", { "* h", "SCHEDULED: <2026-01-02 Thu>--<2026-01-05 Sun>" } },
    { "prose on the planning line", { "* h", "SCHEDULED: <2026-01-02 Thu> ask Bob" } },
    {
      "a duplicate CLOSED below the planning line",
      {
        "* DONE h",
        "CLOSED: [2026-01-02 Thu 10:00] SCHEDULED: <2026-01-01 Wed>",
        "CLOSED: [2026-01-03 Fri 10:00]",
      },
    },
  }
  for _, c in ipairs(cases) do
    local b = buf_with(c[2])
    vim.api.nvim_win_set_buf(0, b)
    require("organ.format").format_buffer(b)
    local got = lines_of(b)
    -- The property drawer pass aligns `:ID: x` -> `:ID:       x`; compare
    -- the planning-bearing lines, which formatting must not touch.
    local same = #got == #c[2]
    if same then
      for i = 1, #got do
        if got[i] ~= c[2][i] and not got[i]:match("^%s*:%u") then
          same = false
        end
      end
    end
    check("format leaves " .. c[1] .. " alone", same, vim.inspect(got))
  end
end

if fails > 0 then
  error(fails .. " checks failed")
end
print("\nAll checks passed.")
