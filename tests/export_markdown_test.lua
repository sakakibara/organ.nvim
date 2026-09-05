-- Verifies organ.export.markdown converts org → CommonMark for the
-- common constructs.  Run via: nvim --headless -l tests/export_markdown_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local p = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = p })

local md = require("organ.export.markdown")

local function assert_contains(haystack, needle, msg)
  assert(
    haystack:find(needle, 1, true),
    (msg or "expected to find") .. ": '" .. needle .. "' in:\n" .. haystack
  )
end

-- 1. Headlines map to ATX headers.
do
  local out = md.export([[
* Top
** Sub
*** Deep
]])
  assert_contains(out, "# Top")
  assert_contains(out, "## Sub")
  assert_contains(out, "### Deep")
end

-- 2. TODO keyword and tags reach the title, as ox-md writes them.
do
  local out = md.export([[
* TODO Buy milk :shopping:
]])
  assert_contains(out, "# TODO Buy milk     :shopping:")
end

-- 3. Bold / verbatim / link in body.
do
  local out = md.export([==[
* H
This is *bold* and =verbatim= and [[https://example.com][a link]].
]==])
  assert_contains(out, "**bold**")
  assert_contains(out, "`verbatim`")
  assert_contains(out, "[a link](https://example.com)")
end

-- 4. List with checkboxes.
do
  local out = md.export([[
* H
- [ ] todo
- [X] done
- [-] partial
]])
  assert_contains(out, "- [ ] todo")
  assert_contains(out, "- [x] done")
end

-- 5. Source block with language.
do
  local out = md.export([[
* H
#+begin_src python
print("hi")
#+end_src
]])
  assert_contains(out, "```python")
  assert_contains(out, 'print("hi")')
  assert_contains(out, "```")
end

-- 6a. Multi-rule org table flattens to a single markdown table.
-- Tree-sitter parses every `|---|` rule as a table boundary, so a
-- naive emit produced one markdown table per AST `table` node with
-- a stray blank line and a duplicated divider in between.  Markdown
-- only allows one divider per table, so extra rules are dropped.
do
  local out = md.export([[
* H
| a | b |
|---+---|
| c | d |
|---+---|
| e | f |
]])
  -- Collect contiguous block of pipe-rows, no blanks allowed within.
  local lines = vim.split(out, "\n", { plain = true })
  local in_table, blanks_inside = false, 0
  local table_rows, table_done = {}, false
  for _, line in ipairs(lines) do
    if line:match("^|") then
      in_table = true
      table_rows[#table_rows + 1] = line
    elseif in_table and line == "" and not table_done then
      blanks_inside = blanks_inside + 1
      in_table = false
      table_done = true
    end
  end
  assert(
    blanks_inside <= 1,
    "no blank line inside the merged markdown table; got " .. blanks_inside
  )
  -- 1 header + 1 divider + 2 data rows (`| c | d |`, `| e | f |`).
  -- Mid-table rules collapsed.
  assert(
    #table_rows == 4,
    "merged table should have 4 rows, got "
      .. #table_rows
      .. ":\n"
      .. table.concat(table_rows, "\n")
  )
  local divider_count = 0
  for _, r in ipairs(table_rows) do
    if r:match("^| %-%-%-") then
      divider_count = divider_count + 1
    end
  end
  assert(divider_count == 1, "exactly one markdown divider, got " .. divider_count)
end

-- 6. Table with header divider.
do
  local out = md.export([[
* H
| name | age |
|------+-----|
| ada  |  36 |
| ben  |  41 |
]])
  assert_contains(out, "| name | age |")
  -- `age` holds numbers, so ox-md aligns that column right.
  assert_contains(out, "| --- | ---: |")
  assert_contains(out, "| ada | 36 |")
  -- No phantom trailing column.  The regex that splits cells used to
  -- append `|` to the line, which produced TWO trailing-empty captures
  -- on a properly-closed org row -- the single-pop drop only removed
  -- one, leaving a stray empty column in every row.
  for line in out:gmatch("[^\n]+") do
    if line:match("^|") then
      local pipes = 0
      for _ in line:gmatch("|") do
        pipes = pipes + 1
      end
      assert(
        pipes == 3,
        ("row should have 3 pipes (2 cells + edges), got %d in %q"):format(pipes, line)
      )
    end
  end
end

-- 7. Drawers / planning / properties dropped by default.
do
  local out = md.export([[
* H
SCHEDULED: <2026-04-29>
:PROPERTIES:
:ID: abc
:END:
Real body.
]])
  assert(not out:find("SCHEDULED", 1, true), "SCHEDULED must be dropped:\n" .. out)
  assert(not out:find(":PROPERTIES:", 1, true), "drawer must be dropped")
  assert_contains(out, "Real body")
end

-- 8. Horizontal rule.
do
  local out = md.export([[
* H
Above.
-----
Below.
]])
  assert_contains(out, "---")
end

-- 9. export_buffer_to_file defaults to .md sibling of buffer.
do
  local tmp = vim.fn.tempname() .. ".org"
  local f = assert(io.open(tmp, "w"))
  f:write("* T\n**bold** body\n")
  f:close()
  vim.cmd("edit " .. tmp)
  local path, err = md.export_buffer_to_file(0)
  assert(path and not err, "export_buffer_to_file failed: " .. tostring(err))
  assert(path:match("%.md$"), "default path must end in .md, got " .. path)
  local fd = assert(io.open(path, "r"))
  local content = fd:read("*a")
  fd:close()
  assert_contains(content, "# T")
  os.remove(tmp)
  os.remove(path)
end

io.write("export markdown ok\n")
os.exit(0)
