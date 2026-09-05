-- capture.target datetree placement under a non-default
-- `capture.datetree_format`.  Levels must stay distinct and ordered
-- however the format renders a date.
-- Run via: nvim --headless -l tests/capture_datetree_format_test.lua

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

local organ = require("organ")
local target = require("organ.capture.target")

local function fixture(name, content)
  local p = vim.fn.resolve(tmp .. "/" .. name)
  local f = assert(io.open(p, "w"))
  f:write(content)
  f:close()
  return p
end

local function with_format(fmt, fn)
  organ.config.capture = organ.config.capture or {}
  organ.config.capture.datetree_format = fmt
  local ok, err = pcall(fn)
  organ.config.capture.datetree_format = nil
  assert(ok, err)
end

-- 1. Week format: a new week gets its own headline instead of landing
-- under the existing one.
with_format({ "%Y", "%Y-W%V" }, function()
  local p = fixture("weeks.org", "* 2026\n** 2026-W35\n*** old entry\n")
  local now = os.time({ year = 2026, month = 9, day = 3, hour = 12, min = 0, sec = 0 })
  local _, line, prelude = target.resolve(
    { kind = "file_olp_datetree", path = p },
    { now = now },
    false
  )
  assert(#prelude == 1, "expected a new week headline; got " .. vim.inspect(prelude))
  assert(prelude[1] == "** 2026-W36", "got: " .. prelude[1])
  assert(line == 4, "expected line 4 (after the W35 subtree); got " .. line)

  now = os.time({ year = 2026, month = 8, day = 26, hour = 12, min = 0, sec = 0 })
  local _, l2, p2 = target.resolve({ kind = "file_olp_datetree", path = p }, { now = now }, false)
  assert(#p2 == 0, "W35 already exists; got " .. vim.inspect(p2))
  assert(l2 == 4, "expected the end of the W35 section; got " .. l2)

  now = os.time({ year = 2026, month = 8, day = 20, hour = 12, min = 0, sec = 0 })
  local _, l3, p3 = target.resolve({ kind = "file_olp_datetree", path = p }, { now = now }, false)
  assert(#p3 == 1 and p3[1] == "** 2026-W34", "got " .. vim.inspect(p3))
  assert(l3 == 2, "an earlier week sorts above W35 at line 2; got " .. l3)
end)

-- 2. Day-first format: chronological order, not lexical digit order.
with_format({ "%Y", "%d-%m-%Y" }, function()
  local p = fixture("dayfirst.org", "* 2026\n** 31-08-2026\n")
  local now = os.time({ year = 2026, month = 9, day = 4, hour = 12, min = 0, sec = 0 })
  local _, line, prelude = target.resolve(
    { kind = "file_olp_datetree", path = p },
    { now = now },
    false
  )
  assert(#prelude == 1 and prelude[1] == "** 04-09-2026", "got " .. vim.inspect(prelude))
  assert(line == 3, "September sorts after 31 August, at line 3; got " .. line)

  now = os.time({ year = 2026, month = 8, day = 4, hour = 12, min = 0, sec = 0 })
  local _, l2, p2 = target.resolve({ kind = "file_olp_datetree", path = p }, { now = now }, false)
  assert(#p2 == 1 and p2[1] == "** 04-08-2026", "got " .. vim.inspect(p2))
  assert(l2 == 2, "4 August sorts above 31 August, at line 2; got " .. l2)
end)

-- 3. Month-name-only format still orders by month.
with_format({ "%Y", "%B" }, function()
  local p = fixture("monthname.org", "* 2026\n** February\n** November\n")
  local now = os.time({ year = 2026, month = 5, day = 1, hour = 12, min = 0, sec = 0 })
  local _, line, prelude = target.resolve(
    { kind = "file_olp_datetree", path = p },
    { now = now },
    false
  )
  assert(#prelude == 1 and prelude[1] == "** May", "got " .. vim.inspect(prelude))
  assert(line == 3, "May sorts between February and November, at line 3; got " .. line)
end)

-- 4. The default format is unchanged: year / month / day spine.
do
  local p = fixture("default.org", "* 2026\n** 2026-03 March\n*** 2026-03-10 Tuesday\n")
  local now = os.time({ year = 2026, month = 3, day = 18, hour = 12, min = 0, sec = 0 })
  local _, line, prelude = target.resolve(
    { kind = "file_olp_datetree", path = p },
    { now = now },
    false
  )
  assert(#prelude == 1 and prelude[1] == "*** 2026-03-18 Wednesday", "got " .. vim.inspect(prelude))
  assert(line == 4, "expected line 4; got " .. line)
end

vim.fn.delete(tmp, "rf")
io.write("capture datetree format ok\n")
os.exit(0)
