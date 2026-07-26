-- Macro / SETUPFILE / INCLUDE expansion.
-- Run via: nvim --headless -l tests/expand_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local expand = require("organ.expand")

-- Basic user-defined macro

do
  local src = [[
#+MACRO: greet Hello, $1!

Body: {{{greet(world)}}}
  ]]
  local out = expand.process(src)
  assert(out:match("Body: Hello, world!"), "user macro: " .. out)
end

-- Multiple args, with escaped comma

do
  local src = [[
#+MACRO: pair ($1, $2)

X = {{{pair(a\, b, c)}}}
  ]]
  local out = expand.process(src)
  assert(out:match("X = %(a, b, c%)"), "escaped comma: " .. out)
end

-- Built-ins: title / author / email / date(no-arg) from keywords

do
  local src = [[
#+TITLE: My Doc
#+AUTHOR: Jane
#+EMAIL: j@example.com
#+DATE: 2026-05-02

T={{{title}}} A={{{author}}} E={{{email}}} D={{{date}}}
  ]]
  local out = expand.process(src)
  assert(out:match("T=My Doc A=Jane E=j@example.com D=2026%-05%-02"), "keyword built-ins: " .. out)
end

-- date(FMT) → strftime

do
  local out = expand.process("[{{{date(%Y)}}}]")
  local year = os.date("%Y")
  assert(out:match("%[" .. year .. "%]"), "date(FMT): " .. out)
end

-- property(KEY) from passed-in property table

do
  local out = expand.process("v={{{property(VERSION)}}}", { properties = { VERSION = "1.2.3" } })
  assert(out:match("v=1%.2%.3"), "property: " .. out)
end

-- n(VAR) counter

do
  local src = "{{{n(a)}}} {{{n(a)}}} {{{n(a)}}} {{{n(b)}}} {{{n(a,10)}}} {{{n(a)}}}"
  local out = expand.process(src)
  assert(out == "1 2 3 1 10 11", "counters: " .. out)
end

-- Nested macros: a macro body invokes another macro

do
  local src = [[
#+MACRO: outer wrapped[{{{inner($1)}}}]
#+MACRO: inner *$1*

X = {{{outer(hi)}}}
  ]]
  local out = expand.process(src)
  assert(out:match("X = wrapped%[%*hi%*%]"), "nested: " .. out)
end

-- Macro with no args; bare {{{name}}}

do
  local src = [[
#+MACRO: sig --signed

Hello{{{sig}}}
  ]]
  local out = expand.process(src)
  assert(out:match("Hello%-%-signed"), "no-arg macro: " .. out)
end

-- INCLUDE: verbatim, line-range, type wrappers, headline search

do
  -- Set up an included file in /tmp.
  local incl = "/tmp/expand_test_incl.org"
  local f = assert(io.open(incl, "wb"))
  f:write([[
Top intro line
* Section A
A1
A2
* Section B
B1
B2
]])
  f:close()

  -- Verbatim
  local src1 = '#+INCLUDE: "' .. incl .. '"'
  local out1 = expand.process(src1)
  assert(out1:match("Top intro line"), "verbatim include: " .. out1)
  assert(out1:match("Section B"), "full content included")

  -- Line range :lines "2-3"
  local src2 = string.format('#+INCLUDE: "%s" :lines "2-3"', incl)
  local out2 = expand.process(src2)
  assert(out2:match("Section A"), "lines slice: " .. out2)
  assert(out2:match("A1"), "lines slice second")
  assert(not out2:match("B1"), "lines exclusion")

  -- Headline search: ::*Section A
  local src3 = string.format('#+INCLUDE: "%s::*Section A"', incl)
  local out3 = expand.process(src3)
  assert(out3:match("A1") and out3:match("A2"), "headline search body: " .. out3)
  assert(not out3:match("B1"), "headline scope")

  -- Wrap as example block
  local src4 = string.format('#+INCLUDE: "%s" example :lines "1-1"', incl)
  local out4 = expand.process(src4)
  assert(out4:match("#%+begin_example"), "example wrap: " .. out4)
  assert(out4:match("Top intro line"), "example body")
  assert(out4:match("#%+end_example"), "example end")

  -- Wrap as src block with language
  local src5 = string.format('#+INCLUDE: "%s" src lua :lines "1-1"', incl)
  local out5 = expand.process(src5)
  assert(out5:match("#%+begin_src lua"), "src wrap: " .. out5)
  assert(out5:match("#%+end_src"), "src end")

  -- minlevel: promote a level-1 headline to level 2
  local src6 = string.format('#+INCLUDE: "%s::*Section A" :minlevel 2', incl)
  local out6 = expand.process(src6)
  -- The included Section A is `* Section A`; with minlevel=2 it becomes `**`.
  assert(out6:match("%*%* Section A"), "minlevel promote: " .. out6)

  os.remove(incl)
end

-- SETUPFILE: chain pulls macros + keywords from external file

do
  local setup = "/tmp/expand_test_setup.org"
  local f = assert(io.open(setup, "wb"))
  f:write([[
#+TITLE: Inherited
#+MACRO: brand AcmeCorp
]])
  f:close()

  local src = string.format(
    [[
#+SETUPFILE: "%s"

T={{{title}}} B={{{brand}}}
  ]],
    setup
  )
  local out = expand.process(src)
  assert(out:match("T=Inherited"), "setupfile keyword: " .. out)
  assert(out:match("B=AcmeCorp"), "setupfile macro: " .. out)

  os.remove(setup)
end

-- SETUPFILE cycle is broken without infinite loop

do
  local a = "/tmp/expand_test_a.org"
  local b = "/tmp/expand_test_b.org"
  local f = assert(io.open(a, "wb"))
  f:write(string.format('#+SETUPFILE: "%s"\n#+MACRO: x A\n', b))
  f:close()
  f = assert(io.open(b, "wb"))
  f:write(string.format('#+SETUPFILE: "%s"\n#+MACRO: y B\n', a))
  f:close()

  local src = string.format('#+SETUPFILE: "%s"\n{{{x}}}-{{{y}}}\n', a)
  local out = expand.process(src)
  assert(out:match("A%-B"), "cycle resolved: " .. out)

  os.remove(a)
  os.remove(b)
end

-- INCLUDE inside another INCLUDE

do
  local inner = "/tmp/expand_test_inner.org"
  local outer = "/tmp/expand_test_outer.org"
  local f = assert(io.open(inner, "wb"))
  f:write("Inner content here\n")
  f:close()
  f = assert(io.open(outer, "wb"))
  f:write(string.format('Before\n#+INCLUDE: "%s"\nAfter\n', inner))
  f:close()

  local src = string.format('Doc start\n#+INCLUDE: "%s"\nDoc end\n', outer)
  local out = expand.process(src)
  assert(out:match("Before"), "outer include: " .. out)
  assert(out:match("Inner content here"), "transitive include")
  assert(out:match("After"), "outer trailing")

  os.remove(inner)
  os.remove(outer)
end

-- Edge cases: missing macro, recursive expansion limit

do
  -- Missing macro → empty string (matches Emacs default).
  local out = expand.process("X={{{nonexistent}}}Y")
  assert(out == "X=Y", "missing macro: " .. out)
end

do
  -- Self-recursive macro doesn't loop forever.
  local src = "#+MACRO: r {{{r}}}\n\n{{{r}}}"
  local ok = pcall(function()
    expand.process(src)
  end)
  assert(ok, "self-recursive macro should terminate")
end

-- Markdown export with expand=true picks up macros + INCLUDE

do
  local incl = "/tmp/expand_test_md_incl.org"
  local f = assert(io.open(incl, "wb"))
  f:write("Content from include.\n")
  f:close()

  local org_src = string.format(
    [[
#+TITLE: Doc
#+MACRO: brand AcmeCorp

* {{{title}}}

By {{{brand}}}.

#+INCLUDE: "%s"
]],
    incl
  )

  local ok_parser = pcall(function()
    return vim.treesitter.get_string_parser("", "org")
  end)
  if ok_parser then
    local md = require("organ.export.markdown").export(org_src, { expand = true })
    assert(md:match("# Doc"), "title macro in heading: " .. md)
    assert(md:match("By AcmeCorp%."), "brand macro: " .. md)
    assert(md:match("Content from include%."), "include expanded: " .. md)
    assert(not md:match("{{{"), "no macro markers left")
    assert(not md:match("#%+INCLUDE"), "no include directive left")
  end

  os.remove(incl)
end

io.write("expand ok\n")
os.exit(0)
