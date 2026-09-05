-- Texinfo export: full pipeline test via export.texinfo.M.export.
-- Run via: nvim --headless -l tests/export_texinfo_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local p = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = p })

local texi = require("organ.export.texinfo")

local function assert_contains(haystack, needle, msg)
  assert(
    haystack:find(needle, 1, true),
    (msg or "expected to find") .. ": '" .. needle .. "' in:\n" .. haystack
  )
end

-- 1. Headlines map to @chapter/@section/etc.
do
  local out = texi.export([[
#+OPTIONS: H:4
* Top
** Sub
*** Deep
**** Para
]])
  assert_contains(out, "@chapter Top")
  assert_contains(out, "@section Sub")
  assert_contains(out, "@subsection Deep")
  assert_contains(out, "@subsubsection Para")
end

-- 2. Standalone document includes preamble + @bye.
do
  local out = texi.export([[
#+TITLE: My Doc
#+AUTHOR: Sho
* Hi
]])
  assert_contains(out, "\\input texinfo")
  assert_contains(out, "@settitle My Doc")
  assert_contains(out, "@title My Doc")
  assert_contains(out, "@author Sho")
  assert_contains(out, "@bye")
end

-- 3. body_only suppresses preamble.
do
  local out = texi.export("* H\nbody\n", { body_only = true })
  assert(
    not out:find("\\input texinfo", 1, true),
    "body_only should not include preamble:\n" .. out
  )
  assert_contains(out, "@chapter H")
end

-- 4. Inline emphasis / verbatim / links.
do
  local out = texi.export([==[
* H
This is *bold* and =verb= and [[https://example.com][a link]].
]==])
  assert_contains(out, "@strong{bold}")
  assert_contains(out, "@code{verb}")
  assert_contains(out, "@uref{https://example.com, a link}")
end

-- 5. Texinfo special chars escaped (@ -> @@, { -> @{, } -> @}).
do
  local out = texi.export([[
* H
a@b uses {brace}.
]])
  assert_contains(out, "a@@b")
  assert_contains(out, "@{brace@}")
end

-- 6. Lists (two blank lines end a list per Emacs; one blank line keeps
-- following items in the same list).
do
  local out = texi.export([[
* H
- one
- two


1. first
2. second
]])
  assert_contains(out, "@itemize")
  assert_contains(out, "@item one")
  assert_contains(out, "@end itemize")
  assert_contains(out, "@enumerate")
  assert_contains(out, "@item first")
  assert_contains(out, "@end enumerate")
end

-- 7. Tables -> @multitable.
do
  local out = texi.export([[
* H
| name | age |
|------+-----|
| ada  |  36 |
| ben  |  41 |
]])
  assert_contains(out, "@multitable")
  assert_contains(out, "@item name @tab age")
  assert_contains(out, "@item ada @tab 36")
  assert_contains(out, "@end multitable")
end

-- 8. Source block -> @example.
do
  local out = texi.export([[
* H
#+begin_src python
print("hi")
#+end_src
]])
  assert_contains(out, "@example")
  assert_contains(out, 'print("hi")')
  assert_contains(out, "@end example")
end

-- 9. Drawers / planning dropped.
do
  local out = texi.export([[
* H
SCHEDULED: <2026-04-29>
:PROPERTIES:
:ID: abc
:END:
Body content.
]])
  assert(not out:find("SCHEDULED", 1, true), "SCHEDULED must be dropped:\n" .. out)
  assert(not out:find(":PROPERTIES:", 1, true), "PROPERTIES drawer must be dropped")
  assert_contains(out, "Body content")
end

-- 10. export_buffer_to_file defaults to .texi sibling of buffer.
do
  local tmp = vim.fn.tempname() .. ".org"
  local f = assert(io.open(tmp, "w"))
  f:write("* T\nbody\n")
  f:close()
  vim.cmd("edit " .. tmp)
  local path, err = texi.export_buffer_to_file(0)
  assert(path and not err, "export_buffer_to_file failed: " .. tostring(err))
  assert(path:match("%.texi$"), "default path must end in .texi, got " .. path)
  local fd = assert(io.open(path, "r"))
  local content = fd:read("*a")
  fd:close()
  assert_contains(content, "@chapter T")
  os.remove(tmp)
  os.remove(path)
end

io.write("export texinfo ok\n")
os.exit(0)
