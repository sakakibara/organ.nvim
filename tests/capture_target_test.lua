-- Unit tests for capture.target.resolve — five target kinds + datetree.
-- Run via: nvim --headless -l tests/capture_target_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  db_path = tmp .. "/t.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local target = require("organ.capture.target")

-- Helper: write fixture, return its path.
local function fixture(name, content)
  local p = vim.fn.resolve(tmp .. "/" .. name)
  local f = assert(io.open(p, "w"))
  f:write(content)
  f:close()
  return p
end

-- 1. file kind: insert at end-of-file.
do
  local p = fixture("inbox.org", "* Existing\n  body\n")
  local path, line, prelude = target.resolve({ kind = "file", path = p }, {}, false)
  assert(path == p, "path=" .. path)
  assert(line == 3, "expected line 3 (end-of-file + 1); got " .. line)
  assert(#prelude == 0, "no prelude expected")
end

-- 2. file kind: missing file is created (empty), insert_line = 1.
do
  local p = vim.fn.resolve(tmp .. "/new-inbox.org")
  vim.fn.delete(p)
  local path, line, prelude = target.resolve({ kind = "file", path = p }, {}, false)
  assert(vim.loop.fs_stat(p), "file should be created")
  assert(line == 1, "empty file insert_line should be 1; got " .. line)
  assert(#prelude == 0)
end

-- 3. file_headline: insert at end of named section.
do
  local p = fixture(
    "tasks.org",
    [=[* Inbox
  inbox body
* Other
  other body
]=]
  )
  local path, line, prelude = target.resolve(
    { kind = "file_headline", path = p, headline = "Inbox" },
    {},
    false
  )
  -- "Inbox" is lines 1-2, "Other" starts at line 3. End-of-Inbox = line 3.
  assert(line == 3, "expected line 3; got " .. line)
  assert(#prelude == 0)
end

-- 4. file_headline: not found → auto-create the headline at end of file
-- (Emacs org-capture parity, see org-capture.el `(file+headline ...)` clause).
do
  local p = fixture("tasks2.org", "* Foo\n  body\n")
  local path, line, prelude, level = target.resolve(
    { kind = "file_headline", path = p, headline = "Tasks" },
    {},
    false
  )
  assert(path == p, "path=" .. tostring(path))
  -- File has 2 lines; new headline appended → prelude carries it, insert_line
  -- positions captured entry AFTER the prelude headline.
  assert(line == 3, "expected line 3 (after existing content); got " .. tostring(line))
  assert(#prelude == 1, "expected 1 prelude line; got " .. #prelude)
  assert(prelude[1] == "* Tasks", "expected prelude `* Tasks`; got: " .. tostring(prelude[1]))
  assert(level == 1, "auto-created headline is top-level; got level=" .. tostring(level))
end

-- 4a. file_headline: auto-create on EMPTY file (the user's actual bug).
do
  local p = vim.fn.resolve(tmp .. "/empty-inbox.org")
  vim.fn.delete(p)
  local path, line, prelude, level = target.resolve(
    { kind = "file_headline", path = p, headline = "Tasks" },
    {},
    false
  )
  assert(vim.loop.fs_stat(p), "ensure_file should have created the empty file")
  assert(line == 1, "empty file: insert_line = 1; got " .. tostring(line))
  assert(prelude[1] == "* Tasks", "prelude should add the missing headline")
  assert(level == 1)
end

-- 4b. file_headline: match a `* TODO Tasks` headline (TODO keyword does not
-- break match — Emacs org-complex-heading-regexp-format consumes it before
-- the name).
do
  local p = fixture("tasks_todo.org", "* TODO Tasks\n  body\n* Other\n")
  local path, line, prelude, level = target.resolve(
    { kind = "file_headline", path = p, headline = "Tasks" },
    {},
    false
  )
  assert(#prelude == 0, "headline EXISTS (* TODO Tasks) — no auto-create expected")
  -- "* TODO Tasks" + body is lines 1-2; "* Other" starts at line 3.
  -- End-of-section = line 3.
  assert(line == 3, "expected line 3 (end of TODO Tasks section); got " .. tostring(line))
  assert(level == 1)
end

-- 4c. file_headline: match a headline with priority cookie `* [#A] Tasks`.
do
  local p = fixture("tasks_pri.org", "* [#A] Tasks\n  body\n* Other\n")
  local _, line, prelude = target.resolve(
    { kind = "file_headline", path = p, headline = "Tasks" },
    {},
    false
  )
  assert(#prelude == 0, "priority does not break match")
  assert(line == 3, "expected line 3; got " .. tostring(line))
end

-- 4d. file_headline: match a headline with trailing tags `* Tasks :work:`.
do
  local p = fixture("tasks_tags.org", "* Tasks :work:home:\n  body\n* Other\n")
  local _, line, prelude = target.resolve(
    { kind = "file_headline", path = p, headline = "Tasks" },
    {},
    false
  )
  assert(#prelude == 0, "tags do not break match")
  assert(line == 3, "expected line 3; got " .. tostring(line))
end

-- 4e. file_headline: match a headline with stats cookies `* Tasks [2/5]`.
do
  local p = fixture("tasks_stats.org", "* Tasks [2/5]\n  body\n* Other\n")
  local _, line, prelude = target.resolve(
    { kind = "file_headline", path = p, headline = "Tasks" },
    {},
    false
  )
  assert(#prelude == 0, "stats cookie does not break match")
  assert(line == 3, "expected line 3; got " .. tostring(line))
end

-- 5. file_olp: nested headline walk.
do
  local p = fixture(
    "proj.org",
    [=[* Projects
** OrganNvim
*** Inbox
    inbox body
*** Other
    other body
** OtherProj
]=]
  )
  local path, line, prelude = target.resolve(
    { kind = "file_olp", path = p, olp = { "Projects", "OrganNvim", "Inbox" } },
    {},
    false
  )
  -- "Inbox" is lines 3-4, "Other" starts at line 5. End-of-Inbox = line 5.
  assert(line == 5, "expected line 5; got " .. line)
end

-- 6. file_olp: missing leaf → error.
do
  local p = fixture("proj2.org", "* Projects\n** OrganNvim\n")
  local ok, err = pcall(
    target.resolve,
    { kind = "file_olp", path = p, olp = { "Projects", "OrganNvim", "MissingLeaf" } },
    {},
    false
  )
  assert(not ok)
  assert(err:find("MissingLeaf", 1, true))
end

-- 7. file_olp_datetree: empty file → year/month/day spine in prelude.
do
  local p = fixture("journal.org", "")
  local now = os.time({ year = 2026, month = 4, day = 26, hour = 12, min = 0, sec = 0 })
  local path, line, prelude = target.resolve(
    { kind = "file_olp_datetree", path = p },
    { now = now },
    false
  )
  assert(#prelude == 3, "expected 3 spine lines; got " .. #prelude .. ": " .. vim.inspect(prelude))
  assert(prelude[1]:match("^%* 2026$"), "year line: " .. prelude[1])
  assert(prelude[2]:match("^%*%* 2026%-04 April$"), "month line: " .. prelude[2])
  assert(prelude[3]:match("^%*%*%* 2026%-04%-26 Sunday$"), "day line: " .. prelude[3])
  assert(line == 1, "expected line 1; got " .. line)
end

-- 8. file_olp_datetree: existing year/month, missing day.
do
  local p = fixture(
    "journal2.org",
    [=[* 2026
** 2026-04 April
*** 2026-04-25 Saturday
    yesterday body
]=]
  )
  local now = os.time({ year = 2026, month = 4, day = 26, hour = 12, min = 0, sec = 0 })
  local path, line, prelude = target.resolve(
    { kind = "file_olp_datetree", path = p },
    { now = now },
    false
  )
  assert(#prelude == 1, "expected 1 spine line; got " .. #prelude)
  assert(prelude[1]:match("^%*%*%* 2026%-04%-26 Sunday$"), "day line: " .. prelude[1])
  assert(line == 5, "expected line 5; got " .. line)
end

-- 9. file_olp_datetree with olp prefix.
do
  local p = fixture("journal3.org", "* Journal\n  parent body\n")
  local now = os.time({ year = 2026, month = 4, day = 26, hour = 12, min = 0, sec = 0 })
  local path, line, prelude = target.resolve(
    { kind = "file_olp_datetree", path = p, olp = { "Journal" } },
    { now = now },
    false
  )
  assert(prelude[1]:match("^%*%* 2026$"))
  assert(prelude[2]:match("^%*%*%* 2026%-04 April$"))
  assert(prelude[3]:match("^%*%*%*%* 2026%-04%-26 Sunday$"))
end

-- 10. file_function: returns whatever fn returns.
do
  local p = fixture("custom.org", "* X\n")
  local path, line, prelude = target.resolve({
    kind = "file_function",
    fn = function(_ctx)
      return p, 42
    end,
  }, {}, false)
  assert(path == p)
  assert(line == 42)
  assert(#prelude == 0)
end

-- 11. prepend = true on file_headline: insert before the first child
-- headline (org-capture.el `outline-next-heading`), i.e. after the
-- target's drawer, planning and body.
do
  local p = fixture(
    "prepend.org",
    [=[* Inbox
  body line
* Other
]=]
  )
  local _, line = target.resolve({ kind = "file_headline", path = p, headline = "Inbox" }, {}, true)
  assert(line == 3, "expected line 3 (after the body); got " .. line)

  p = fixture(
    "prepend2.org",
    [=[* Inbox
:PROPERTIES:
:ID: abc
:END:
SCHEDULED: <2026-01-01 Thu>
some body
** Old child
* Other
]=]
  )
  _, line = target.resolve({ kind = "file_headline", path = p, headline = "Inbox" }, {}, true)
  assert(line == 7, "expected line 7 (before ** Old child); got " .. line)
  _, line = target.resolve({ kind = "file_olp", path = p, olp = { "Inbox" } }, {}, true)
  assert(line == 7, "olp prepend: expected line 7; got " .. line)
end

-- 11b. Datetree spine goes in chronological position: before the first
-- later sibling (org-datetree.el `org-datetree--find-create-subheading`).
do
  local p = fixture(
    "journal_order.org",
    [=[* 2025
** 2025-12 December
* 2026
** 2026-03 March
*** 2026-03-10 Tuesday
**** old entry
** 2026-05 May
* 2027
]=]
  )
  local now = os.time({ year = 2026, month = 1, day = 5, hour = 12, min = 0, sec = 0 })
  local _, line, prelude = target.resolve(
    { kind = "file_olp_datetree", path = p },
    { now = now },
    false
  )
  assert(#prelude == 2, "expected month+day spine; got " .. vim.inspect(prelude))
  assert(line == 4, "expected line 4 (before ** 2026-03 March); got " .. line)

  now = os.time({ year = 2026, month = 4, day = 1, hour = 12, min = 0, sec = 0 })
  _, line = target.resolve({ kind = "file_olp_datetree", path = p }, { now = now }, false)
  assert(line == 7, "expected line 7 (between March and May); got " .. line)

  now = os.time({ year = 2026, month = 3, day = 2, hour = 12, min = 0, sec = 0 })
  _, line, prelude = target.resolve({ kind = "file_olp_datetree", path = p }, { now = now }, false)
  assert(#prelude == 1 and line == 5, "expected day before 2026-03-10 at line 5; got " .. line)

  now = os.time({ year = 2024, month = 6, day = 1, hour = 12, min = 0, sec = 0 })
  _, line, prelude = target.resolve({ kind = "file_olp_datetree", path = p }, { now = now }, false)
  assert(#prelude == 3 and line == 1, "expected full spine before * 2025 at line 1; got " .. line)
end

-- 11c. Headline matching ignores a trailing tag block with non-ASCII tags.
do
  local p = fixture("tagged.org", "* Inbox :仕事:\n* Other\n")
  local path, line, prelude = target.resolve(
    { kind = "file_headline", path = p, headline = "Inbox" },
    {},
    false
  )
  assert(
    #prelude == 0 and line == 2,
    "expected existing Inbox; got line " .. line .. " " .. vim.inspect(prelude)
  )
end

-- 12. Custom datetree_format: { "%Y-%m-%d" } → flat (one level).
do
  local p = fixture("flat.org", "")
  local now = os.time({ year = 2026, month = 4, day = 26, hour = 12, min = 0, sec = 0 })
  require("organ").config.capture = require("organ").config.capture or {}
  require("organ").config.capture.datetree_format = { "%Y-%m-%d" }

  local path, line, prelude = target.resolve(
    { kind = "file_olp_datetree", path = p },
    { now = now },
    false
  )
  assert(#prelude == 1, "expected 1 spine line; got " .. #prelude)
  assert(prelude[1] == "* 2026-04-26", "got: " .. prelude[1])

  require("organ").config.capture.datetree_format = nil
end

vim.fn.delete(tmp, "rf")
io.write("capture target ok\n")
os.exit(0)
