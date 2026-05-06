-- column_view: parse #+COLUMNS spec; collect rows; aggregate summaries; render.
-- Run via: nvim --headless -l tests/column_view_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local cv = require("organ.column_view")

-- Spec parser.
do
  local cs = cv.parse_spec("%25ITEM %TODO %3PRIORITY %TAGS %EFFORT(Effort){:}")
  assert(#cs == 5, "5 columns; got " .. #cs)
  assert(cs[1].width == 25 and cs[1].property == "ITEM", "ITEM")
  assert(cs[2].width == nil and cs[2].property == "TODO", "TODO")
  assert(cs[3].width == 3 and cs[3].property == "PRIORITY", "PRIORITY")
  assert(cs[5].label == "Effort" and cs[5].summary == ":", "EFFORT(Effort){:} label/summary parse")
end

-- End-to-end with a fixture.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fixture = tmp .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write([[#+COLUMNS: %ITEM %TODO %EFFORT(Effort){:}
* TODO Project
** TODO Task A
   :PROPERTIES:
   :EFFORT: 1:30
   :END:
** TODO Task B
   :PROPERTIES:
   :EFFORT: 0:45
   :END:
* Other
]])
fh:close()
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)

local spec, root_line = cv.find_spec(b, 1)
assert(spec, "find_spec should locate file-level #+COLUMNS")
assert(root_line == nil, "root_line nil for file-level spec")

local cols = cv.parse_spec(spec)
local rows = cv.collect(b, root_line, cols)
assert(#rows == 4, "4 headlines; got " .. #rows)

-- Project (level 1) has no EFFORT directly; Task A has 1:30, Task B has 0:45.
-- After apply_summaries, Project should aggregate to 2:15.
cv.apply_summaries(rows, cols)

local function row_for_title(t)
  for _, r in ipairs(rows) do
    if r.values[1]:find(t, 1, true) then
      return r
    end
  end
end

local proj = row_for_title("Project")
assert(proj, "no Project row")
assert(
  proj.values[3] == "2:15",
  "Project EFFORT summary should be 2:15; got " .. tostring(proj.values[3])
)

local a = row_for_title("Task A")
assert(a.values[3] == "1:30", "Task A EFFORT preserved; got " .. tostring(a.values[3]))

-- Render produces a header + divider + N data rows.
local lines = cv.render(rows, cols)
assert(#lines == 2 + #rows, "expected " .. (2 + #rows) .. " rendered lines; got " .. #lines)
assert(lines[1]:find("ITEM", 1, true), "header has ITEM column")
assert(lines[2]:find("--", 1, true), "divider line is dashes")

vim.fn.delete(tmp, "rf")
io.write("column view ok\n")
os.exit(0)
