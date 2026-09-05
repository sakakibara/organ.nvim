-- organ.logbook.add_note: `:Org add_note` (Emacs org-add-note, C-c C-z).
-- The entry shape is what real Emacs 30 / org 9.7.11 writes, checked with
--   emacs --batch -Q -l org  (org-add-note + org-store-log-note)
-- before it was encoded here: `- Note taken on [ts] \\` followed by the
-- note, indented two columns; no ` \\` when the note is empty; newest
-- first inside an existing drawer.
--
-- Run via: nvim --headless -l tests/add_note_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local logbook = require("organ.logbook")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local TS = "%[%d%d%d%d%-%d%d%-%d%d %a%a%a %d%d:%d%d%]"

-- 1. The entry text: Emacs's `Note taken on %t` heading, with the note
-- on continuation lines behind a ` \\` marker.
do
  local e = logbook.build_note_entry("my note line")
  check(
    "a note gets the `\\\\` marker and an indented body",
    #e == 2
      and e[1]:match("^%- Note taken on " .. TS .. " \\\\$") ~= nil
      and e[2] == "  my note line",
    table.concat(e, " | ")
  )
end
do
  local e = logbook.build_note_entry("")
  check(
    "an empty note is a bare timestamp line",
    #e == 1 and e[1]:match("^%- Note taken on " .. TS .. "$") ~= nil,
    table.concat(e, " | ")
  )
  check("nil is the same as an empty note", vim.deep_equal(logbook.build_note_entry(nil), e))
end
do
  local e = logbook.build_note_entry("line one\nline two")
  check(
    "every line of a multi-line note is indented",
    #e == 3 and e[2] == "  line one" and e[3] == "  line two",
    table.concat(e, " | ")
  )
end

-- 2. Into the buffer: a fresh drawer is created below the property
-- drawer, and the entry lands inside it.
local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  return b
end

do
  local b = mkbuf({ "* Task", ":PROPERTIES:", ":ID: x", ":END:", "body" })
  local row = logbook.add_note(b, 1, "my note")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "a new LOGBOOK drawer is created after the properties",
    row == 1
      and got[5]:match("^%s*:LOGBOOK:$") ~= nil
      and got[6]:match("Note taken on") ~= nil
      and got[7]:match("my note$") ~= nil
      and got[8]:match("^%s*:END:$") ~= nil
      and got[9] == "body",
    table.concat(got, " | ")
  )
end

-- 3. An existing drawer takes the entry at the top: newest first.
do
  local b = mkbuf({
    "* Task",
    ":LOGBOOK:",
    "- Note taken on [2026-01-01 Thu 00:00] \\\\",
    "  old",
    ":END:",
    "body",
  })
  logbook.add_note(b, 1, "new note")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "the newest note goes first in an existing drawer",
    got[3]:match("Note taken on") ~= nil
      and got[4]:match("new note$") ~= nil
      and got[5] == "- Note taken on [2026-01-01 Thu 00:00] \\\\"
      and got[6] == "  old",
    table.concat(got, " | ")
  )
end

-- 4. From a body line, the note attaches to the enclosing headline.
do
  local b = mkbuf({ "* Task", "body", "more body" })
  local row = logbook.add_note(b, 3, "from below")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "a body line notes its own headline",
    row == 1 and got[3]:match("Note taken on") ~= nil,
    table.concat(got, " | ")
  )
end

-- 5. Off any headline it refuses and writes nothing.
do
  local b = mkbuf({ "no headings here" })
  local row, why = logbook.add_note(b, 1, "x")
  check(
    "a buffer with no headline refuses",
    row == nil
      and why == "not inside a headline"
      and vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "no headings here" }),
    tostring(why)
  )
end

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\nadd_note: all checks passed")
