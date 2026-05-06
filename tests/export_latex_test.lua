-- Verifies organ.export.latex converts org → LaTeX for the common
-- constructs.  Run via: nvim --headless -l tests/export_latex_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local p = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = p })

local tex = require("organ.export.latex")

local function assert_contains(haystack, needle, msg)
  assert(
    haystack:find(needle, 1, true),
    (msg or "expected to find") .. ": '" .. needle .. "' in:\n" .. haystack
  )
end

-- 1. Headlines map to article-class section commands.
do
  local out = tex.export([[
* Top
** Sub
*** Deep
**** Para
***** Subpara
]])
  assert_contains(out, "\\section{Top}")
  assert_contains(out, "\\subsection{Sub}")
  assert_contains(out, "\\subsubsection{Deep}")
  assert_contains(out, "\\paragraph{Para}")
  assert_contains(out, "\\subparagraph{Subpara}")
end

-- 2. Standalone document includes preamble + \begin{document}.
do
  local out = tex.export([[
#+TITLE: My Doc
#+AUTHOR: Sho
#+DATE: 2026-05-02
* Hi
]])
  assert_contains(out, "\\documentclass{article}")
  assert_contains(out, "\\title{My Doc}")
  assert_contains(out, "\\author{Sho}")
  assert_contains(out, "\\date{2026-05-02}")
  assert_contains(out, "\\begin{document}")
  assert_contains(out, "\\maketitle")
  assert_contains(out, "\\end{document}")
end

-- 3. body_only suppresses the preamble.
do
  local out = tex.export("* H\nbody\n", { body_only = true })
  assert(
    not out:find("\\documentclass", 1, true),
    "body_only should not include preamble:\n" .. out
  )
  assert_contains(out, "\\section{H}")
end

-- 4. Bold / italic / verbatim / links.
do
  local out = tex.export([==[
* H
This is *bold* and =verb= and [[https://example.com][a link]].
]==])
  assert_contains(out, "\\textbf{bold}")
  assert_contains(out, "\\verb|verb|")
  assert_contains(out, "\\href{https://example.com}{a link}")
end

-- 5. LaTeX special chars in plain text are escaped (math passes through).
do
  local out = tex.export([[
* H
Cost is 50% & $\alpha$ uses literal $.
]])
  assert_contains(out, "50\\%")
  assert_contains(out, "\\&")
  -- Math chunk preserved verbatim (NOT escaped).
  assert_contains(out, "$\\alpha$")
end

-- 6. List + ordered list (separated by blank line so the grammar splits them).
do
  local out = tex.export([[
* H
- one
- two

1. first
2. second
]])
  assert_contains(out, "\\begin{itemize}")
  assert_contains(out, "\\item one")
  assert_contains(out, "\\end{itemize}")
  assert_contains(out, "\\begin{enumerate}")
  assert_contains(out, "\\item first")
  assert_contains(out, "\\end{enumerate}")
end

-- 7. Table → tabular.
do
  local out = tex.export([[
* H
| name | age |
|------+-----|
| ada  |  36 |
| ben  |  41 |
]])
  assert_contains(out, "\\begin{tabular}")
  assert_contains(out, "name & age \\\\")
  assert_contains(out, "ada & 36 \\\\")
  assert_contains(out, "\\hline")
  assert_contains(out, "\\end{tabular}")
end

-- 8. Source block → verbatim.
do
  local out = tex.export([[
* H
#+begin_src python
print("hi")
#+end_src
]])
  assert_contains(out, "\\begin{verbatim}")
  assert_contains(out, 'print("hi")')
  assert_contains(out, "\\end{verbatim}")
end

-- 9. Drawers / planning dropped.
do
  local out = tex.export([[
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

-- 10. export_buffer_to_file defaults to .tex sibling of buffer.
do
  local tmp = vim.fn.tempname() .. ".org"
  local f = assert(io.open(tmp, "w"))
  f:write("* T\nbody\n")
  f:close()
  vim.cmd("edit " .. tmp)
  local path, err = tex.export_buffer_to_file(0)
  assert(path and not err, "export_buffer_to_file failed: " .. tostring(err))
  assert(path:match("%.tex$"), "default path must end in .tex, got " .. path)
  local fd = assert(io.open(path, "r"))
  local content = fd:read("*a")
  fd:close()
  assert_contains(content, "\\section{T}")
  os.remove(tmp)
  os.remove(path)
end

io.write("export latex ok\n")
os.exit(0)
