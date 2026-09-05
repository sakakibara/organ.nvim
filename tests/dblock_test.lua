-- dblock: parse_params, find_dblock_at, register, update_at_cursor + clocktable.
-- Run via: nvim --headless -l tests/dblock_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local db = require("organ.dblock")

-- 1. parse_params: ":k v" pairs, type coercion.
do
  local p = db.parse_params(":scope file :maxlevel 3 :fileskip0 yes :tstart 2026-05-01")
  assert(p.scope == "file", "scope: " .. tostring(p.scope))
  assert(p.maxlevel == 3, "maxlevel: " .. tostring(p.maxlevel))
  assert(p.fileskip0 == true, "fileskip0: " .. tostring(p.fileskip0))
  assert(p.tstart == "2026-05-01", "tstart: " .. tostring(p.tstart))
end

-- 2. find_dblock_at locates #+BEGIN: / #+END: pair.
do
  local fixture = org_dir .. "/d.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write([[
#+BEGIN: clocktable :scope file
old body
#+END:

* H
]])
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  local hit = db.find_dblock_at(b, 2) -- cursor on "old body"
  assert(hit, "expected dblock hit")
  assert(hit.name == "clocktable", "name: " .. hit.name)
  assert(hit.params.scope == "file", "scope param: " .. tostring(hit.params.scope))
end

-- 3. Custom writer dispatch.
do
  db.register("hello", function(params, ctx)
    return { "Hello " .. (params.name or "world") }
  end)
  local fixture = org_dir .. "/h.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write([[
#+BEGIN: hello :name there
stale
#+END:
]])
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local ok, n = db.update_at_cursor(b)
  assert(ok, "update failed: " .. tostring(n))
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[2] == "Hello there", "body: " .. lines[2])
  -- The #+END: line should now be at line 3.
  assert(lines[3] == "#+END:", "end: " .. lines[3])
end

-- 4. clocktable writer produces an org table even with no clock entries.
do
  local fixture = org_dir .. "/c.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write([[
#+BEGIN: clocktable :scope file
#+END:
]])
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local ok = db.update_at_cursor(b)
  assert(ok, "clocktable update should succeed even with no entries")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  -- Header line + capture + table header + sep + total + #+END:
  local joined = table.concat(lines, "\n")
  assert(joined:find("#+CAPTION: Clock summary", 1, true), "caption present")
  assert(joined:find("| Headline", 1, true), "table header present")
  assert(joined:find("| *Total time* | *0:00* |", 1, true), "total row present:\n" .. joined)
  assert(joined:find("#+END:", 1, true), "end marker preserved")
end

-- 5. parse_params: quoted values may contain ":" and keep their text.
do
  local p = db.parse_params(':tstart "<2024-01-01 Mon 10:00>" :tend "<2024-01-31 Wed>" :scope file')
  assert(p.tstart == "<2024-01-01 Mon 10:00>", "tstart: " .. tostring(p.tstart))
  assert(p.tend == "<2024-01-31 Wed>", "tend: " .. tostring(p.tend))
  assert(p.scope == "file", "scope: " .. tostring(p.scope))
  local n = 0
  for _ in pairs(p) do
    n = n + 1
  end
  assert(n == 3, "exactly 3 params, got " .. n)
end

-- 6. clocktable: :tstart/:tend timestamps reach the query as dates,
--    and column widths are display widths, not byte counts.
do
  local q = require("organ.query")
  local orig_clock, orig_headlines = q.clock_entries, q.headlines
  local seen
  q.clock_entries = function(opts)
    seen = opts
    return {
      {
        headline_id = "h1",
        file_path = "/f.org",
        title = "日本語の見出し",
        total_seconds = 3600,
      },
      { headline_id = "h2", file_path = "/f.org", title = "ascii", total_seconds = 60 },
    }
  end
  q.headlines = function()
    return {
      { id = "h1", level = 1, line_start = 0, title = "日本語の見出し" },
      { id = "h2", level = 1, line_start = 4, title = "ascii" },
    }
  end
  local lines = db.writers.clocktable(
    db.parse_params(':tstart "<2024-01-01 Mon 10:00>" :tend "<2024-01-31 Wed>"'),
    { bufnr = 0 }
  )
  q.clock_entries, q.headlines = orig_clock, orig_headlines
  assert(seen.from == "2024-01-01", "from: " .. tostring(seen.from))
  assert(seen.to == "2024-01-31", "to: " .. tostring(seen.to))
  local w = vim.fn.strdisplaywidth(lines[2])
  for i = 3, #lines do
    assert(
      vim.fn.strdisplaywidth(lines[i]) == w,
      ("line %d width %d, expected %d: %s"):format(i, vim.fn.strdisplaywidth(lines[i]), w, lines[i])
    )
  end
  assert(table.concat(lines, "\n"):find("日本語の見出し", 1, true), "cjk row present")
end

-- 7. clocktable shape matches `org-clocktable-write-default`.
--
-- `emacs --batch -Q`, org 9.7.11, on the fixture below with `#+BEGIN:
-- clocktable :maxlevel 3` emits exactly (modulo the caption timestamp):
--
--   #+CAPTION: Clock summary at [2026-09-04 Fri 07:32]
--   | Headline     |   Time |      |      |
--   |--------------+--------+------+------|
--   | *Total time* | *3:35* |      |      |
--   |--------------+--------+------+------|
--   | Project      |   3:15 |      |      |
--   | \_  Task A   |        | 1:30 |      |
--   | \_  Task B   |        | 1:45 |      |
--   | \_    Sub B1 |        |      | 1:00 |
--   | Other        |   0:20 |      |      |
--
-- and with `:block 2026-01` the caption gains ", for January 2026."
do
  local fixture = org_dir .. "/shape.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write(table.concat({
    "* Project",
    "** Task A",
    ":LOGBOOK:",
    "CLOCK: [2026-01-01 Thu 09:00]--[2026-01-01 Thu 10:30] =>  1:30",
    ":END:",
    "** Task B",
    ":LOGBOOK:",
    "CLOCK: [2026-01-02 Fri 09:00]--[2026-01-02 Fri 09:45] =>  0:45",
    ":END:",
    "*** Sub B1",
    ":LOGBOOK:",
    "CLOCK: [2026-01-02 Fri 10:00]--[2026-01-02 Fri 11:00] =>  1:00",
    ":END:",
    "* Other",
    ":LOGBOOK:",
    "CLOCK: [2026-01-03 Sat 08:00]--[2026-01-03 Sat 08:20] =>  0:20",
    ":END:",
    "",
  }, "\n"))
  fh:close()
  require("organ").scan_blocking(org_dir, 5000)
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)

  local got = db.writers.clocktable(db.parse_params(":maxlevel 3"), { bufnr = b })
  local want = {
    "| Headline     |   Time |      |      |",
    "|--------------+--------+------+------|",
    "| *Total time* | *3:35* |      |      |",
    "|--------------+--------+------+------|",
    "| Project      |   3:15 |      |      |",
    "| \\_  Task A   |        | 1:30 |      |",
    "| \\_  Task B   |        | 1:45 |      |",
    "| \\_    Sub B1 |        |      | 1:00 |",
    "| Other        |   0:20 |      |      |",
  }
  assert(
    got[1]:match("^#%+CAPTION: Clock summary at %[%d%d%d%d%-%d%d%-%d%d %a%a%a %d%d:%d%d%]$"),
    "caption: " .. tostring(got[1])
  )
  for i, line in ipairs(want) do
    assert(got[i + 1] == line, ("row %d\n got %q\nwant %q"):format(i, tostring(got[i + 1]), line))
  end
  assert(#got == #want + 1, "extra rows: " .. table.concat(got, "\n"))

  -- `:maxlevel 2` drops the level-3 row AND its time column.
  local got2 = db.writers.clocktable(db.parse_params(":maxlevel 2"), { bufnr = b })
  assert(got2[2] == "| Headline     |   Time |      |", "maxlevel 2 header: " .. got2[2])
  assert(
    not table.concat(got2, "\n"):find("Sub B1", 1, true),
    "maxlevel 2 must drop level 3:\n" .. table.concat(got2, "\n")
  )

  -- `:block` adds the period to the caption, ending with a period.
  local got3 = db.writers.clocktable(db.parse_params(":block thismonth"), { bufnr = b })
  assert(got3[1]:find(", for ", 1, true) and got3[1]:sub(-1) == ".", "block caption: " .. got3[1])
end

vim.fn.delete(tmp, "rf")
io.write("dblock ok\n")
os.exit(0)
