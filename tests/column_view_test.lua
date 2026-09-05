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

-- Built-in columns: TODO is a configured keyword, not any capitalised word;
-- TAGS is the whole trailing block.
do
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* API design review :work:home:",
    "* TODO NASA launch :a:",
    "* Plain",
  })
  vim.api.nvim_set_current_buf(b)
  local rows = cv.collect(b, nil, cv.parse_spec("%ITEM %TODO %TAGS"))
  assert(rows[1].values[1] == "API design review", "ITEM keeps a capitalised first word")
  assert(rows[1].values[2] == "", "TODO is empty without a keyword")
  assert(rows[1].values[3] == ":work:home:", "TAGS is the whole block: " .. rows[1].values[3])
  assert(rows[2].values[1] == "NASA launch", "ITEM strips the keyword only")
  assert(rows[2].values[2] == "TODO", "TODO keyword")
  assert(rows[2].values[3] == ":a:", "single tag")
  assert(rows[3].values[3] == "", "no tags")
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

-- Emacs `org-columns-compile-format` parity (org 9.7.11).  Verified against
-- `emacs --batch -Q`, which compiles each of these to:
--   "%ITEM %Effort{:}"                    -> (("ITEM" "ITEM" nil nil nil)
--                                             ("EFFORT" "Effort" nil ":" nil))
--   "%ITEM %10Effort(Estimated Effort){:}"-> (... ("EFFORT" "Estimated Effort" 10 ":" nil))
--   "%ITEM %Time-Spent{:} %Cost{+;%.2f}"  -> (... ("TIME-SPENT" "Time-Spent" nil ":" nil)
--                                                 ("COST" "Cost" nil "+" "%.2f"))
do
  local cs = cv.parse_spec("%ITEM %Effort{:}")
  assert(cs[2].property == "EFFORT", "mixed-case property upcases: " .. cs[2].property)
  assert(cs[2].label == "Effort", "label keeps the written case: " .. tostring(cs[2].label))
  assert(cs[2].summary == ":", "summary survives")

  cs = cv.parse_spec("%ITEM %10Effort(Estimated Effort){:}")
  assert(#cs == 2, "a label with a space is one column, got " .. #cs)
  assert(cs[2].width == 10 and cs[2].property == "EFFORT", "width/property")
  assert(cs[2].label == "Estimated Effort", "label with space: " .. tostring(cs[2].label))
  assert(cs[2].summary == ":", "summary after a spaced label: " .. tostring(cs[2].summary))

  cs = cv.parse_spec("%ITEM %Time-Spent{:} %Cost{+;%.2f}")
  assert(cs[2].property == "TIME-SPENT", "hyphen is part of the name: " .. cs[2].property)
  assert(cs[3].summary == "+" and cs[3].format == "%.2f", "`;fmt` suffix is split off")
end

-- A mixed-case spec reads the drawer case-insensitively, as `org-entry-get`
-- does; `emacs -Q` renders `1:30` for `%Effort` against `:Effort: 1:30`.
do
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Parent",
    "** A",
    ":PROPERTIES:",
    ":Effort: 0:30",
    ":END:",
    "** B",
    ":PROPERTIES:",
    ":Effort: 1:30",
    ":END:",
  })
  vim.api.nvim_set_current_buf(b)
  local cols = cv.parse_spec("%ITEM %Effort{:}")
  local rows = cv.collect(b, nil, cols)
  assert(rows[2].values[2] == "0:30", "mixed-case cell A: " .. ("%q"):format(rows[2].values[2]))
  assert(rows[3].values[2] == "1:30", "mixed-case cell B: " .. ("%q"):format(rows[3].values[2]))
  cv.apply_summaries(rows, cols)
  assert(rows[1].values[2] == "2:00", "parent summary: " .. ("%q"):format(rows[1].values[2]))
end

-- The summary REPLACES a parent's own value (Emacs shows 2:00 on a parent
-- carrying `:EFFORT: 1:00` above children of 0:30 + 1:30), but a parent whose
-- descendants contributed nothing keeps its own.
do
  local cols = cv.parse_spec("%ITEM %EFFORT{:}")
  local rows = {
    { hl_line = 1, level = 1, values = { "Parent", "1:00" } },
    { hl_line = 2, level = 2, values = { "A", "0:30" } },
    { hl_line = 3, level = 2, values = { "B", "1:30" } },
  }
  cv.apply_summaries(rows, cols)
  assert(rows[1].values[2] == "2:00", "summary overrides own value: " .. rows[1].values[2])

  local rows2 = {
    { hl_line = 1, level = 1, values = { "Parent", "1:00" } },
    { hl_line = 2, level = 2, values = { "A", "" } },
    { hl_line = 3, level = 2, values = { "B", "" } },
  }
  cv.apply_summaries(rows2, cols)
  assert(
    rows2[1].values[2] == "1:00",
    "own value kept with no child values: " .. rows2[1].values[2]
  )
end

-- The `;fmt` suffix formats the aggregate.
do
  local cols = cv.parse_spec("%ITEM %COST{+;%.2f}")
  local rows = {
    { hl_line = 1, level = 1, values = { "Parent", "" } },
    { hl_line = 2, level = 2, values = { "A", "1.5" } },
    { hl_line = 3, level = 2, values = { "B", "2.25" } },
  }
  cv.apply_summaries(rows, cols)
  assert(rows[1].values[2] == "3.75", "formatted sum: " .. rows[1].values[2])
end

vim.fn.delete(tmp, "rf")
io.write("column view ok\n")
os.exit(0)
