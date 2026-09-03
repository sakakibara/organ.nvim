-- Beamer export: each level-1 headline → \begin{frame}…\end{frame};
-- preamble honors #+BEAMER_THEME / #+BEAMER_HEADER / #+TITLE.
-- Run via: nvim --headless -l tests/export_beamer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local p = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = p })

local beamer = require("organ.export.beamer")

local function assert_contains(haystack, needle, msg)
  assert(
    haystack:find(needle, 1, true),
    (msg or "expected to find") .. ": '" .. needle .. "' in:\n" .. haystack
  )
end

-- Standalone Beamer document with two slides.
local out = beamer.export([[
#+TITLE: Talk
#+AUTHOR: Sho
#+BEAMER_THEME: metropolis
#+BEAMER_HEADER: \setbeamersize{text margin left=10pt}

* First slide
- bullet 1
- bullet 2

* Second slide
Some prose with *bold* and =verb=.
]])

assert_contains(out, "\\documentclass[presentation]{beamer}")
assert_contains(out, "\\usetheme{metropolis}")
assert_contains(out, "\\setbeamersize{text margin left=10pt}")
assert_contains(out, "\\title{Talk}")
assert_contains(out, "\\author{Sho}")
assert_contains(out, "\\frame{\\titlepage}")
assert_contains(out, "\\begin{frame}{First slide}")
assert_contains(out, "\\begin{frame}{Second slide}")
-- Two frames means two `\end{frame}`s.
local nframes = 0
for _ in out:gmatch("\\end{frame}") do
  nframes = nframes + 1
end
assert(nframes == 2, "expected 2 \\end{frame}; got " .. nframes)

-- Body inherits LaTeX renderer's emphasis + lists.
assert_contains(out, "\\begin{itemize}")
assert_contains(out, "\\item bullet 1")
assert_contains(out, "\\textbf{bold}")
assert_contains(out, "\\verb|verb|")

-- body_only suppresses preamble.
local body = beamer.export("* Slide\nbody\n", { body_only = true })
assert(
  not body:find("\\documentclass", 1, true),
  "body_only should not include preamble:\n" .. body
)
assert_contains(body, "\\begin{frame}{Slide}")
assert_contains(body, "\\end{frame}")

-- Nested headlines become blocks, and every block is closed.
do
  local out2 = beamer.export(
    { "* Frame", "** Block A", "text a", "** Block B", "text b" },
    { body_only = true }
  )
  local _, opens = out2:gsub("\\begin{block}", "")
  local _, closes = out2:gsub("\\end{block}", "")
  assert(opens == 2 and closes == 2, "expected 2 open/close block pairs in:\n" .. out2)
  assert(
    out2:find("\\begin{block}{Block A}\ntext a\n\n\\end{block}", 1, true),
    "block A closes before block B opens:\n" .. out2
  )
end

-- Footnote bodies come from this document, not from an earlier LaTeX
-- export in the same process.
do
  local src = "* Slide\nA claim[fn:1] here.\n\n[fn:1] the body\n"
  local first = beamer.export(src)
  assert_contains(first, "A claim\\footnote{the body} here.", "fresh beamer export")
  require("organ.export.latex").export(src)
  local second = beamer.export(src)
  assert_contains(second, "A claim\\footnote{the body} here.", "beamer export after latex")
end

io.write("export beamer ok\n")
os.exit(0)
