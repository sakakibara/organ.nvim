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

-- 4. file_headline: not found → error.
do
  local p = fixture("tasks2.org", "* Foo\n  body\n")
  local ok, err = pcall(
    target.resolve,
    { kind = "file_headline", path = p, headline = "Bogus" },
    {},
    false
  )
  assert(not ok, "expected error on missing headline")
  assert(err:find("Bogus", 1, true), "err should name missing headline: " .. tostring(err))
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

-- 11. prepend = true on file_headline: insert at section START + 1.
do
  local p = fixture(
    "prepend.org",
    [=[* Inbox
  body line
* Other
]=]
  )
  local path, line, prelude = target.resolve(
    { kind = "file_headline", path = p, headline = "Inbox" },
    {},
    true
  )
  assert(line == 2, "expected line 2 (after headline); got " .. line)
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
