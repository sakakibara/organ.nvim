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
  assert(joined:find("| TOTAL", 1, true), "TOTAL row present")
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
  local orig = q.clock_entries
  local seen
  q.clock_entries = function(opts)
    seen = opts
    return {
      { title = "日本語の見出し", total_seconds = 3600 },
      { title = "ascii", total_seconds = 60 },
    }
  end
  local lines = db.writers.clocktable(
    db.parse_params(':tstart "<2024-01-01 Mon 10:00>" :tend "<2024-01-31 Wed>"'),
    { bufnr = 0 }
  )
  q.clock_entries = orig
  assert(seen.from == "2024-01-01", "from: " .. tostring(seen.from))
  assert(seen.to == "2024-01-31", "to: " .. tostring(seen.to))
  local w = vim.fn.strdisplaywidth(lines[2])
  for i = 3, #lines do
    assert(
      vim.fn.strdisplaywidth(lines[i]) == w,
      ("line %d width %d, expected %d: %s"):format(i, vim.fn.strdisplaywidth(lines[i]), w, lines[i])
    )
  end
  assert(lines[4]:find("日本語の見出し", 1, true), "cjk row present: " .. lines[4])
end

vim.fn.delete(tmp, "rf")
io.write("dblock ok\n")
os.exit(0)
