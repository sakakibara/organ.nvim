-- Export-time filtering: exclude / select tags, COMMENT subtrees,
-- `:exports` header args, `#+OPTIONS:` toggles, and the macro / INCLUDE
-- pre-pass that Emacs runs on every export.
--
-- Every expectation below was taken from GNU Emacs 30.2 / Org 9.7.11 via
--   emacs --batch -Q --eval "(with-temp-buffer (insert ...) (org-mode)
--                             (princ (org-export-as 'html nil nil t nil)))"
--
-- Run via: nvim --headless -l tests/export_filter_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local html = require("organ.export.html")
local from_org = require("organ.ast.from_org")
local filter = require("organ.export.filter")
local options = require("organ.export.options")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function has(hay, needle)
  return hay:find(needle, 1, true) ~= nil
end

local function body_of(out)
  return out:match("<body>(.-)</body>") or out
end

-- Exclude tags.  Emacs (org-export-exclude-tags '("noexport")) exports
-- "Public" and "Another public" only.
do
  local out = body_of(html.export([[
* Public
public body

* Private                                                          :noexport:
secret body

** Child of private
also secret

* Another public
tail
]]))
  check("exclude tag: tagged subtree gone", not has(out, "secret body"), out)
  check("exclude tag: inherited by descendants", not has(out, "also secret"), out)
  check("exclude tag: siblings survive", has(out, "public body") and has(out, "tail"), out)
end

-- A custom #+EXCLUDE_TAGS: replaces the default list.
do
  local out = body_of(html.export([[
#+EXCLUDE_TAGS: private

* One                                                              :noexport:
noexport body

* Two                                                               :private:
private body
]]))
  check("EXCLUDE_TAGS: replaces the default", has(out, "noexport body"), out)
  check("EXCLUDE_TAGS: honours the custom tag", not has(out, "private body"), out)
end

-- Select tags.  With any :export: subtree present Emacs exports only the
-- select trees plus their ancestors, and drops the zeroth section.
do
  local out = body_of(html.export([[
Zeroth section text.

* Parent
parent body

** Chosen                                                            :export:
chosen body

*** Grandchild
gc body

* Other
other body
]]))
  check("select tag: zeroth section dropped", not has(out, "Zeroth section text"), out)
  check("select tag: unselected sibling dropped", not has(out, "other body"), out)
  check("select tag: ancestor kept", has(out, "parent body"), out)
  check("select tag: subtree kept", has(out, "chosen body") and has(out, "gc body"), out)
end

-- COMMENT subtrees never export.
do
  local out = body_of(html.export([[
* COMMENT Hidden
commented body

* Shown
shown body
]]))
  check("COMMENT headline: subtree dropped", not has(out, "commented body"), out)
  check("COMMENT headline: title dropped", not has(out, "Hidden"), out)
  check("COMMENT headline: siblings survive", has(out, "shown body"), out)
end

-- `* COMMENT :tag:` is a commented headline with a tag and an empty
-- title, not a headline titled ":tag:".
do
  local doc = from_org.from_lines({ "* COMMENT :tag:" })
  local h = doc.children[1]
  check("COMMENT with tags: commented flag set", h and h.commented == true)
  check("COMMENT with tags: title empty", h and #h.title == 0, h and vim.inspect(h.title))
  check("COMMENT with tags: tag parsed", h and h.tags and h.tags[1] == "tag")
end

-- Org comments (`# ...` and #+begin_comment) never reach a backend.
do
  local out = body_of(html.export([[
# a line comment

#+begin_comment
block comment
#+end_comment

kept
]]))
  check("comments: line comment dropped", not has(out, "a line comment"), out)
  check("comments: comment block dropped", not has(out, "block comment"), out)
  check("comments: body survives", has(out, "kept"), out)
end

-- `:exports` on a source block, and the `#+RESULTS:` element that
-- belongs to it.
do
  local src = [[
#+begin_src emacs-lisp :exports none
(none-code)
#+end_src

#+RESULTS:
: none-result

#+begin_src emacs-lisp :exports code
(code-code)
#+end_src

#+RESULTS:
: code-result

#+begin_src emacs-lisp :exports results
(results-code)
#+end_src

#+RESULTS:
: results-result

#+begin_src emacs-lisp :exports both
(both-code)
#+end_src

#+RESULTS:
: both-result
]]
  local doc = filter.apply(from_org.from_lines(vim.split(src, "\n", { plain = true })))
  local seen = {}
  for _, b in ipairs(doc.children) do
    seen[#seen + 1] = b.body
  end
  local got = table.concat(seen, "|")
  check("exports none: code and results both dropped", not got:find("none", 1, true), "got " .. got)
  check(
    "exports code: code kept, results dropped",
    got:find("(code-code)", 1, true) and not got:find("code-result", 1, true),
    "got " .. got
  )
  check(
    "exports results: results kept, code dropped",
    got:find("results-result", 1, true) and not got:find("(results-code)", 1, true),
    "got " .. got
  )
  check(
    "exports both: code and results kept",
    got:find("(both-code)", 1, true) and got:find("both-result", 1, true),
    "got " .. got
  )
end

-- #+OPTIONS toggles that act on the tree.  Emacs renders this document
-- as "Some *bold* and a_b and \alpha and a footnote and a_{xy}.".
do
  local out = body_of(html.export([[
#+OPTIONS: ^:nil e:nil f:nil *:nil

Some *bold* and a_b and \alpha and a footnote[fn:1] and a_{xy}.

[fn:1] the note
]]))
  check("OPTIONS *:nil: emphasis is literal", has(out, "*bold*"), out)
  check("OPTIONS ^:nil: subscript is literal", has(out, "a_b") and has(out, "a_{xy}"), out)
  check("OPTIONS e:nil: entity is literal", has(out, "\\alpha"), out)
  check("OPTIONS f:nil: footnote reference gone", not has(out, "the note"), out)
end

-- `^:{}` keeps only the braced form (Emacs: "a_b ... a<sub>xy</sub>").
do
  local out = body_of(html.export([[
#+OPTIONS: ^:{}

a_b and a_{xy}.
]]))
  check("OPTIONS ^:{}: bare form literal", has(out, "a_b"), out)
  check("OPTIONS ^:{}: braced form interpreted", has(out, "<sub>xy</sub>"), out)
end

-- `tasks:todo` keeps TODO-type headlines only (Emacs keeps "t1" and
-- "Plain", drops "d1" and "c1").
do
  local out = body_of(html.export([[
#+TODO: TODO NEXT | DONE CANCELLED
#+OPTIONS: tasks:todo

* TODO t1
* DONE d1
* CANCELLED c1
* Plain
]]))
  check("OPTIONS tasks:todo: todo-type kept", has(out, "t1") and has(out, "Plain"), out)
  check("OPTIONS tasks:todo: done-type dropped", not has(out, "d1") and not has(out, "c1"), out)
end

-- Drawers: the default (not "LOGBOOK") hides LOGBOOK and keeps others;
-- d:nil hides every drawer.
do
  local src = [[
* H
:LOGBOOK:
log line
:END:

:NOTES:
note line
:END:
]]
  local function drawer_names(o)
    local doc = filter.apply(from_org.from_lines(vim.split(src, "\n", { plain = true })), o)
    local names = {}
    for _, b in ipairs(doc.children[1].children or {}) do
      if b.kind == "drawer" then
        names[#names + 1] = b.name
      end
    end
    return table.concat(names, ",")
  end
  check("drawers: default hides LOGBOOK", drawer_names(nil) == "NOTES", drawer_names(nil))
  check("drawers: d:nil hides all", drawer_names({ with_drawers = false }) == "")
  check("drawers: d:t keeps all", drawer_names({ with_drawers = true }) == "LOGBOOK,NOTES")
end

-- Macros and INCLUDE expand on export without the caller asking, which
-- is what Emacs does.  doc/organ.txt used to promise an opts.expand flag
-- no command could set.
do
  local out = body_of(html.export([[
#+MACRO: greet Hello, $1!

{{{greet(world)}}}
]]))
  check("macros: expand by default", has(out, "Hello, world!"), out)
  check("macros: literal form gone", not has(out, "{{{greet"), out)
end

do
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local inc = dir .. "/part.org"
  local fd = io.open(inc, "w")
  fd:write("included body\n")
  fd:close()
  local out = body_of(html.export('#+INCLUDE: "' .. inc .. '"\n'))
  check("INCLUDE: expands by default", has(out, "included body"), out)
  vim.fn.delete(dir, "rf")
end

-- The option table itself.
do
  local o = options.parse({ '#+OPTIONS: H:2 toc:nil d:(not "X") ^:{} tex:verbatim' })
  check("options: H parses as a number", o.headline_levels == 2, tostring(o.headline_levels))
  check("options: toc:nil", o.with_toc == false, tostring(o.with_toc))
  check('options: d:(not "X")', o.with_drawers["not"][1] == "X", vim.inspect(o.with_drawers))
  check("options: ^:{}", o.with_sub_superscript == "{}", tostring(o.with_sub_superscript))
  check("options: tex:verbatim", o.with_latex == "verbatim", tostring(o.with_latex))
  -- Emacs reads keywords through org-element, which never looks inside a
  -- block, so an OPTIONS line in a src block is content, not a setting.
  local inside = options.parse({
    "#+begin_src org",
    "#+OPTIONS: num:nil",
    "#+end_src",
  })
  check("options: a keyword inside a block is ignored", inside.with_section_numbers == true)
  local d = options.defaults()
  check(
    "options: Emacs defaults for exclude/select tags",
    d.exclude_tags[1] == "noexport" and d.select_tags[1] == "export"
  )
  check(
    "options: with_priority defaults off, with_toc on",
    d.with_priority == false and d.with_toc == true
  )
end

-- from_org hangs the resolved options off the document node so the
-- renderers can read them.
do
  local doc = from_org.from_lines({ "#+OPTIONS: num:nil", "* H" })
  check("doc.options: present after from_lines", type(doc.options) == "table")
  check("doc.options: reflects the buffer", doc.options.with_section_numbers == false)
end

-- expand-links (org-export--expand-links / substitute-env-in-file-name).
-- Emacs 30.2 / Org 9.7.11, ORGAN_TEST=/tmp/envdir, `#+OPTIONS: H:2`
-- irrelevant here:
--   file:$ORGAN_TEST/a.txt   -> /tmp/envdir/a.txt
--   file:${ORGAN_TEST}/b.txt -> /tmp/envdir/b.txt
--   file:$NO_SUCH_VAR/c.txt  -> unchanged
--   file:$$literal/d.txt     -> $literal/d.txt
--   ./rel/$ORGAN_TEST/e.png  -> ./rel//tmp/envdir/e.png
--   https://example.com/$ORGAN_TEST -> unchanged
do
  local src = {
    "[[file:$ORGAN_TEST/a.txt][a]]",
    "",
    "[[file:${ORGAN_TEST}/b.txt][b]]",
    "",
    "[[file:$NO_SUCH_VAR_XYZ/c.txt][c]]",
    "",
    "[[file:$$literal/d.txt][d]]",
    "",
    "[[./rel/$ORGAN_TEST/e.png][e]]",
    "",
    "[[https://example.com/$ORGAN_TEST][ext]]",
  }
  local function targets(over)
    vim.env.ORGAN_TEST = "/tmp/envdir"
    local doc = from_org.from_lines(src)
    doc.options = vim.tbl_extend("force", options.defaults(), over or {})
    filter.apply(doc)
    local got = {}
    require("organ.ast").walk(doc, function(n)
      if n.kind == "link" or n.kind == "image" then
        got[#got + 1] = n.target
      end
    end)
    return got
  end

  local on = targets()
  check(
    "expand-links is on by default",
    on[1] == "file:/tmp/envdir/a.txt",
    "got: " .. tostring(on[1])
  )
  check("${NAME} expands too", on[2] == "file:/tmp/envdir/b.txt", "got: " .. tostring(on[2]))
  check(
    "an unset name is left alone",
    on[3] == "file:$NO_SUCH_VAR_XYZ/c.txt",
    "got: " .. tostring(on[3])
  )
  check("$$ is a literal $", on[4] == "file:$literal/d.txt", "got: " .. tostring(on[4]))
  check(
    "an implicit file path expands",
    on[5] == "./rel//tmp/envdir/e.png",
    "got: " .. tostring(on[5])
  )
  check(
    "a non-file link is untouched",
    on[6] == "https://example.com/$ORGAN_TEST",
    "got: " .. tostring(on[6])
  )

  local off = targets({ expand_links = false })
  check(
    "expand-links:nil leaves every path verbatim",
    off[1] == "file:$ORGAN_TEST/a.txt"
      and off[2] == "file:${ORGAN_TEST}/b.txt"
      and off[4] == "file:$$literal/d.txt"
      and off[5] == "./rel/$ORGAN_TEST/e.png",
    "got: " .. vim.inspect(off)
  )

  -- A `::search` suffix is not a path and never expands.
  vim.env.ORGAN_TEST = "/tmp/envdir"
  local doc = from_org.from_lines({ "[[file:$ORGAN_TEST/f.org::$ORGAN_TEST][f]]" })
  doc.options = options.defaults()
  filter.apply(doc)
  check(
    "only the path half of a ::search link expands",
    doc.children[1].inline[1].target == "file:/tmp/envdir/f.org::$ORGAN_TEST",
    "got: " .. tostring(doc.children[1].inline[1].target)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("export_filter_test: PASS")
os.exit(0)
