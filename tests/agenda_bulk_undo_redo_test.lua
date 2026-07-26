-- agenda bulk delete + undo + redo round-trip.
--
-- Setup: two real org files with three top-level headings each. Open
-- the agenda, programmatically mark two rows for delete, drive the
-- public M.bulk_delete_apply / M.undo_last_delete / M.redo_last_delete
-- primitives, assert source-file content at each step.
--
-- Run via: nvim --headless -l tests/agenda_bulk_undo_redo_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

local FILE_A = org_dir .. "/a.org"
local FILE_B = org_dir .. "/b.org"
local LINES_A = {
  "* TODO Alpha one",
  "  body of alpha one",
  "* TODO Alpha two",
  "  body of alpha two",
  "* TODO Alpha three",
}
local LINES_B = {
  "* NEXT Beta one",
  "* NEXT Beta two",
  "  with body",
  "* NEXT Beta three",
}
vim.fn.writefile(LINES_A, FILE_A)
vim.fn.writefile(LINES_B, FILE_B)

require("organ").setup({
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
})

local agenda = require("organ.agenda")

-- Open the agenda buffer (we just need a buf with organ_agenda state
-- set so the primitives can read/write delete_history). The query
-- doesn't need to return anything for this test.
package.loaded["organ.query"] = {
  agenda = function()
    return {}
  end,
  headlines = function()
    return {}
  end,
  files = function()
    return {}
  end,
  links = function()
    return {}
  end,
}
local agenda_bufnr = agenda.open({
  from = "today",
  to = "today",
  types = { "scheduled" },
}, "test_view")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function file_lines(path)
  return vim.fn.readfile(path)
end

local function file_has_heading(path, title)
  for _, l in ipairs(file_lines(path)) do
    if l:find(title, 1, true) then
      return true
    end
  end
  return false
end

-- Sanity baseline.
check("baseline: a.org has 'Alpha two'", file_has_heading(FILE_A, "Alpha two"))
check("baseline: b.org has 'Beta two'", file_has_heading(FILE_B, "Beta two"))

-- bulk_delete_apply
-- Build "marked rows" referring to "Alpha two" (file_a:3) and
-- "Beta two" (file_b:2). Use absolute file paths via bufadd.
local buf_a = vim.fn.bufadd(FILE_A)
vim.fn.bufload(buf_a)
local buf_b = vim.fn.bufadd(FILE_B)
vim.fn.bufload(buf_b)
local marked = {
  { _source_bufnr = buf_a, _source_lnum = 3 }, -- "* TODO Alpha two"
  { _source_bufnr = buf_b, _source_lnum = 2 }, -- "* NEXT Beta two"
}
local snap = agenda.bulk_delete_apply(agenda_bufnr, marked)
check("bulk_delete_apply returned snapshot of 2", #snap == 2)

-- Source files must reflect the cuts.
-- The cut buffers are not yet persisted to disk; reload via the buffer's
-- live lines.
local function buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end
check("after delete: a.org buffer no longer contains 'Alpha two'", not (function()
  for _, l in ipairs(buf_lines(buf_a)) do
    if l:find("Alpha two", 1, true) then
      return true
    end
  end
  return false
end)(), "a.org lines: " .. vim.inspect(buf_lines(buf_a)))
check(
  "after delete: a.org still has 'Alpha one' and 'Alpha three'",
  (function()
    local has1, has3 = false, false
    for _, l in ipairs(buf_lines(buf_a)) do
      if l:find("Alpha one", 1, true) then
        has1 = true
      end
      if l:find("Alpha three", 1, true) then
        has3 = true
      end
    end
    return has1 and has3
  end)()
)
check("after delete: b.org no longer has 'Beta two'", not (function()
  for _, l in ipairs(buf_lines(buf_b)) do
    if l:find("Beta two", 1, true) then
      return true
    end
  end
  return false
end)())

-- delete_history holds one snapshot.
local state = vim.b[agenda_bufnr].organ_agenda
local hist = (type(state) == "table" and state.delete_history) or {}
check("delete_history has 1 entry after the delete", #hist == 1)

-- undo_last_delete
local restored = agenda.undo_last_delete(agenda_bufnr)
check("undo_last_delete returned the snapshot", restored ~= nil and #restored == 2)
check(
  "after undo: a.org has 'Alpha two' again",
  (function()
    for _, l in ipairs(buf_lines(buf_a)) do
      if l:find("Alpha two", 1, true) then
        return true
      end
    end
    return false
  end)()
)
check(
  "after undo: b.org has 'Beta two' again",
  (function()
    for _, l in ipairs(buf_lines(buf_b)) do
      if l:find("Beta two", 1, true) then
        return true
      end
    end
    return false
  end)()
)

-- After undo: delete_history empty, redo_history has one.
state = vim.b[agenda_bufnr].organ_agenda
local d_hist = (type(state) == "table" and state.delete_history) or {}
local r_hist = (type(state) == "table" and state.redo_history) or {}
check("after undo: delete_history empty", #d_hist == 0)
check("after undo: redo_history has 1", #r_hist == 1)

-- redo_last_delete
local re_snap = agenda.redo_last_delete(agenda_bufnr)
check("redo_last_delete returned the snapshot", re_snap ~= nil and #re_snap == 2)
check("after redo: a.org no longer has 'Alpha two'", not (function()
  for _, l in ipairs(buf_lines(buf_a)) do
    if l:find("Alpha two", 1, true) then
      return true
    end
  end
  return false
end)())

-- Empty-stack behavior
agenda.undo_last_delete(agenda_bufnr) -- empties delete_history again (the snapshot we just redid)
local nothing = agenda.undo_last_delete(agenda_bufnr)
check("undo on empty stack returns nil", nothing == nil)
agenda.redo_last_delete(agenda_bufnr) -- empties redo_history (we re-restored)
local nothing2 = agenda.redo_last_delete(agenda_bufnr)
check("redo on empty stack returns nil", nothing2 == nil)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_bulk_undo_redo_test: PASS")
