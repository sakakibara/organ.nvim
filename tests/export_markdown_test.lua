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

-- 2. TODO keyword and tags stripped from the title.
do
  local out = md.export([[
* TODO Buy milk :shopping:
]])
  assert_contains(out, "# Buy milk")
  assert(not out:find("TODO", 1, true), "TODO must be stripped:\n" .. out)
  assert(not out:find(":shopping:", 1, true), "tags must be stripped")
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
  assert_contains(out, "| --- | --- |")
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
