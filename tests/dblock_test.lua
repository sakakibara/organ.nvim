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

vim.fn.delete(tmp, "rf")
io.write("dblock ok\n")
os.exit(0)
