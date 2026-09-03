-- Native CSL processor: BibTeX / CSL-JSON parsing + built-in styles.
-- Run via: nvim --headless -l tests/cite_csl_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local bibtex = require("organ.cite.bibtex")
local csl_json = require("organ.cite.csl_json")
local styles = require("organ.cite.styles")
local render = require("organ.cite.render")
local cite = require("organ.cite")

-- BibTeX parser

do
  local src = [[
@article{knuth1968,
  author  = {Donald E. Knuth},
  title   = {The Art of Computer Programming},
  journal = {Addison-Wesley},
  year    = {1968},
  volume  = {1},
}

@book{lamport1986,
  author    = {Leslie Lamport},
  title     = {LaTeX: A Document Preparation System},
  publisher = {Addison-Wesley},
  year      = {1986},
}
  ]]
  local entries = bibtex.normalize(bibtex.parse(src))
  assert(#entries == 2, "two entries; got " .. #entries)
  assert(entries[1].key == "knuth1968", "first key")
  assert(entries[1].type == "article")
  assert(entries[1].fields.title == "The Art of Computer Programming")
  assert(entries[1].author and entries[1].author[1].family == "Knuth", "author family")
  assert(entries[1].author[1].given == "Donald E.", "author given")
  assert(entries[1].year == 1968, "year normalized")
  assert(entries[2].type == "book")
end

-- BibTeX with quoted values
do
  local src = [[
@misc{q,
  author = "Anonymous",
  note   = "Note with {nested} braces and \"quotes\"",
}
  ]]
  local entries = bibtex.parse(src)
  assert(#entries == 1)
  assert(entries[1].fields.author == "Anonymous")
  assert(entries[1].fields.note:match("nested"))
end

-- BibTeX with multiple authors using `and`
do
  local src = [[
@article{x,
  author = {Doe, John and Smith, Jane and {van der Berg}, Pieter},
}
  ]]
  local entries = bibtex.normalize(bibtex.parse(src))
  assert(entries[1].author and #entries[1].author == 3, "three authors")
  assert(
    entries[1].author[3].family == "van der Berg",
    "brace-protected family: " .. entries[1].author[3].family
  )
end

-- BibTeX skips @comment / @string / @preamble
do
  local src = [[
@string{aw = "Addison-Wesley"}
@comment{this is just a comment}
@article{key, author = {Foo}, title = {Bar}, year = {2020}}
  ]]
  local entries = bibtex.parse(src)
  assert(#entries == 1, "skipped @string and @comment")
end

-- Latin name parsing edge cases
do
  -- "First Last" form
  local n = bibtex._parse_name("Albert Einstein")
  assert(n.family == "Einstein" and n.given == "Albert")
  -- "Last, First" form
  n = bibtex._parse_name("Einstein, Albert")
  assert(n.family == "Einstein" and n.given == "Albert")
  -- "Last, Suffix, First"
  n = bibtex._parse_name("King, Jr., Martin Luther")
  assert(n.family == "King" and n.given == "Martin Luther" and n.suffix == "Jr.")
end

-- CSL-JSON parser

do
  local json = [=[
[
  {
    "id": "knuth1968",
    "type": "book",
    "author": [{ "family": "Knuth", "given": "Donald E." }],
    "title": "The Art of Computer Programming",
    "issued": { "date-parts": [[1968]] },
    "publisher": "Addison-Wesley",
    "volume": 1
  }
]
  ]=]
  local entries = csl_json.parse(json)
  assert(#entries == 1)
  assert(entries[1].key == "knuth1968")
  assert(entries[1].author[1].family == "Knuth")
  assert(entries[1].year == 1968)
  assert(entries[1].fields.publisher == "Addison-Wesley")
end

-- Render: APA

do
  local entries = bibtex.normalize(bibtex.parse([[
@article{doe2020,
  author  = {Doe, John and Smith, Jane},
  title   = {On Things},
  journal = {Journal of Things},
  year    = {2020},
  volume  = {1},
  number  = {2},
  pages   = {3--5},
}
  ]]))
  local idx = bibtex.index(entries)
  local parsed = cite.parse("[cite:@doe2020]")
  local ctx = render.new_ctx()
  local cited = render.render_cite(parsed, idx, "apa", ctx)
  assert(cited == "(Doe & Smith, 2020)", "APA cite: " .. cited)
  local bib = render.render_bibliography(idx, "apa", ctx)
  assert(#bib == 1)
  assert(bib[1]:match("Doe, J., & Smith, J%."), "APA bib authors: " .. bib[1])
  assert(bib[1]:match("On Things"), "APA bib title: " .. bib[1])
  assert(bib[1]:match("3–5"), "APA bib pages with en-dash: " .. bib[1])
  assert(bib[1]:match("1%(2%)"), "APA bib volume(issue): " .. bib[1])
end

-- Render: Chicago author-date

do
  local entries = bibtex.normalize(bibtex.parse([[
@article{doe2020,
  author  = {Doe, John and Smith, Jane},
  title   = {On Things},
  journal = {Journal of Things},
  year    = {2020},
  volume  = {1},
  pages   = {3--5},
}
  ]]))
  local idx = bibtex.index(entries)
  local parsed = cite.parse("[cite:@doe2020]")
  local ctx = render.new_ctx()
  local cited = render.render_cite(parsed, idx, "chicago", ctx)
  assert(cited == "(Doe and Smith 2020)", "Chicago cite: " .. cited)
  local bib = render.render_bibliography(idx, "chicago", ctx)
  assert(#bib == 1)
  assert(bib[1]:match("Doe, John, and Jane Smith%."), "Chicago authors: " .. bib[1])
  assert(bib[1]:match('"On Things%."'), "Chicago title in quotes: " .. bib[1])
end

-- Render: IEEE numeric

do
  local entries = bibtex.normalize(bibtex.parse([[
@article{a, author = {Foo, A}, title = {First}, year = {2010}}
@article{b, author = {Bar, B}, title = {Second}, year = {2011}}
@article{c, author = {Baz, C}, title = {Third}, year = {2012}}
  ]]))
  local idx = bibtex.index(entries)
  local ctx = render.new_ctx()
  -- Cite c first (gets [1]), then a (gets [2]), then c again (still [1])
  assert(render.render_cite(cite.parse("[cite:@c]"), idx, "ieee", ctx) == "[1]")
  assert(render.render_cite(cite.parse("[cite:@a]"), idx, "ieee", ctx) == "[2]")
  assert(render.render_cite(cite.parse("[cite:@c]"), idx, "ieee", ctx) == "[1]")
  -- Multi-key cite
  assert(
    render.render_cite(cite.parse("[cite:@b;@a]"), idx, "ieee", ctx) == "[3, 2]",
    "compound cite"
  )
  local bib = render.render_bibliography(idx, "ieee", ctx)
  -- IEEE bib uses occurrence order: c, a, b (then b for the multi-cite)
  assert(#bib == 3, "ieee bib: 3 entries")
  assert(bib[1]:match("^%[1%]"), "first is [1]")
  assert(bib[2]:match("^%[2%]"), "second is [2]")
  assert(bib[3]:match("^%[3%]"), "third is [3]")
end

-- render_text: scan a buffer + emit citations + bibliography

do
  local entries = bibtex.normalize(bibtex.parse([[
@article{x, author = {Doe, J}, title = {X}, year = {2020}}
@article{y, author = {Roe, R}, title = {Y}, year = {2021}}
  ]]))
  local idx = bibtex.index(entries)
  local prose = "See [cite:@x] and [cite:@y] for details."
  local out_text, bib = render.render_text(prose, idx, "apa")
  assert(out_text == "See (Doe, 2020) and (Roe, 2021) for details.", "render_text: " .. out_text)
  assert(#bib == 2, "two bib entries")
end

-- Unknown style falls back to APA without crashing

do
  local entries = bibtex.normalize(bibtex.parse([[
@article{q, author = {X, Y}, year = {2020}}
  ]]))
  local idx = bibtex.index(entries)
  local cited = render.render_cite(cite.parse("[cite:@q]"), idx, "vancouver", {})
  assert(cited:match("X, 2020"), "fallback to apa: " .. cited)
end

-- Per-key prefix / suffix from org-cite syntax flow through into renderers.

do
  local entries = bibtex.normalize(bibtex.parse([[
@article{doe2020, author = {Doe, J}, title = {X}, year = {2020}}
  ]]))
  local idx = bibtex.index(entries)
  local ctx = render.new_ctx()
  -- Suffix appended inside the parens.
  local out = render.render_cite(cite.parse("[cite:@doe2020 p. 5]"), idx, "apa", ctx)
  assert(out == "(Doe, 2020, p. 5)", "APA cite with suffix: " .. out)
  -- Chicago variant.
  ctx = render.new_ctx()
  out = render.render_cite(cite.parse("[cite:@doe2020 p. 5]"), idx, "chicago", ctx)
  assert(out == "(Doe 2020, p. 5)", "Chicago cite with suffix: " .. out)
  -- IEEE locator inside brackets.
  ctx = render.new_ctx()
  out = render.render_cite(cite.parse("[cite:@doe2020 p. 5]"), idx, "ieee", ctx)
  assert(out == "[1, p. 5]", "IEEE cite with locator: " .. out)
  -- Prefix.
  ctx = render.new_ctx()
  out = render.render_cite(cite.parse("[cite:see @doe2020]"), idx, "apa", ctx)
  assert(out == "(see Doe, 2020)", "APA cite with prefix: " .. out)
end

-- Year disambiguation: two entries with same author+year get a/b suffixes.

do
  local entries = bibtex.normalize(bibtex.parse([[
@article{doe2020a, author = {Doe, J}, title = {First}, year = {2020}}
@article{doe2020b, author = {Doe, J}, title = {Second}, year = {2020}}
@article{doe2021,  author = {Doe, J}, title = {Third},  year = {2021}}
  ]]))
  local idx = bibtex.index(entries)
  local out, bib =
    render.render_text("[cite:@doe2020a] [cite:@doe2020b] [cite:@doe2021]", idx, "apa")
  assert(out == "(Doe, 2020a) (Doe, 2020b) (Doe, 2021)", "disambiguated cites: " .. out)
  assert(#bib == 3)
  -- bib lines in alpha order — same author, so chronological by year+suffix
  assert(bib[1]:match("2020a"), "bib line 1: " .. bib[1])
  assert(bib[2]:match("2020b"), "bib line 2: " .. bib[2])
  assert(bib[3]:match("2021"), "bib line 3: " .. bib[3])
end

-- noauthor / author / year cite styles

do
  local entries = bibtex.normalize(bibtex.parse([[
@article{doe2020, author = {Doe, J and Smith, J}, title = {X}, year = {2020}}
  ]]))
  local idx = bibtex.index(entries)
  local ctx = render.new_ctx()
  -- noauthor: just year in parens
  local out = render.render_cite(cite.parse("[cite/noauthor:@doe2020]"), idx, "apa", ctx)
  assert(out == "(2020)", "noauthor: " .. out)
  -- author: just authors (no parens, no year)
  out = render.render_cite(cite.parse("[cite/author:@doe2020]"), idx, "apa", ctx)
  assert(out == "Doe & Smith", "author: " .. out)
end

-- Backend italic substitution

do
  local entries = bibtex.normalize(bibtex.parse([[
@article{x, author = {Doe, J}, title = {Title}, journal = {J}, year = {2020},
            volume = {1}, pages = {3--5}}
  ]]))
  local idx = bibtex.index(entries)
  -- HTML backend wraps italics with <em>
  local _, bib_html = render.render_text("[cite:@x]", idx, "apa", { backend = "html" })
  assert(bib_html[1]:match("<em>J</em>"), "html italics: " .. bib_html[1])
  -- LaTeX backend
  local _, bib_tex = render.render_text("[cite:@x]", idx, "apa", { backend = "latex" })
  assert(bib_tex[1]:match("\\emph{J}"), "latex italics: " .. bib_tex[1])
  -- Markdown
  local _, bib_md = render.render_text("[cite:@x]", idx, "apa", { backend = "markdown" })
  assert(bib_md[1]:match("%*J%*"), "markdown italics: " .. bib_md[1])
  -- Org
  local _, bib_org = render.render_text("[cite:@x]", idx, "apa", { backend = "org" })
  assert(bib_org[1]:match("/J/"), "org italics: " .. bib_org[1])
  -- Default strips the markers
  local _, bib_plain = render.render_text("[cite:@x]", idx, "apa")
  assert(not bib_plain[1]:match("\1"), "no control bytes leaked: " .. bib_plain[1])
end

-- Conference proceedings + thesis bibliography formatting

do
  local entries = bibtex.normalize(bibtex.parse([[
@inproceedings{p, author = {Foo, A}, title = {Paper}, booktitle = {Proc. WWW},
               year = {2020}, pages = {1--10}, publisher = {ACM}}
@phdthesis{t,    author = {Bar, B}, title = {Diss}, school = {MIT}, year = {2021}}
  ]]))
  local idx = bibtex.index(entries)
  local ctx = render.new_ctx()
  render.render_cite(cite.parse("[cite:@p;@t]"), idx, "apa", ctx)
  local bib = render.render_bibliography(idx, "apa", ctx)
  assert(#bib == 2)
  -- Conference: "In <booktitle> (pp. ...). Publisher."
  local proc_line = bib[1]:match("Foo") and bib[1] or bib[2]
  assert(proc_line:match("In Proc%. WWW"), "proc bib: " .. proc_line)
  assert(proc_line:match("pp%. 1–10"), "proc pages: " .. proc_line)
  assert(proc_line:match("ACM"), "proc publisher: " .. proc_line)
  -- Thesis: "[Doctoral dissertation, MIT]."
  local thesis_line = bib[1]:match("Bar") and bib[1] or bib[2]
  assert(thesis_line:match("Doctoral dissertation, MIT"), "thesis bib: " .. thesis_line)
end

-- Bibliography directive discovery

do
  local text = [[
#+title: My Doc
#+bibliography: refs.bib
#+bibliography: ~/library.json
#+bibliography: refs.bib

Body text [cite:@x].
  ]]
  local paths = cite.find_bibliographies(text)
  assert(#paths == 2, "dedup'd: " .. #paths)
  assert(paths[1] == "refs.bib")
  assert(paths[2] == "~/library.json")
end

-- #+cite_export discovery

do
  local s, p = cite.find_cite_export("#+cite_export: csl chicago-author-date.csl\n")
  assert(
    s == "chicago-author-date" and p == "csl",
    "export: " .. tostring(s) .. " / " .. tostring(p)
  )
  -- Style-only form
  s, p = cite.find_cite_export("#+cite_export: apa\n")
  assert(s == "apa" and p == nil)
end

-- High-level cite.process() — full pipeline

do
  local prose = "See [cite:@x] for details."
  local entries = bibtex.normalize(bibtex.parse([[
@article{x, author = {Doe, J}, title = {Title}, year = {2020}}
  ]]))
  local idx = bibtex.index(entries)
  local out_text, bib = cite.process(prose, { bib_index = idx, style = "apa" })
  assert(out_text == "See (Doe, 2020) for details.", "process: " .. out_text)
  assert(#bib == 1)
end

-- :Org cite bibliography — replace #+print_bibliography in the buffer

do
  -- Write a temp .bib file, set up a buffer, run the cmd.
  local bib_path = "/tmp/cite_csl_test_refs.bib"
  local f = assert(io.open(bib_path, "wb"))
  f:write([[
@article{doe2020, author = {Doe, J}, title = {Title}, year = {2020}}
]])
  f:close()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "#+title: Test",
    "#+bibliography: " .. bib_path,
    "",
    "Body [cite:@doe2020] text.",
    "",
    "#+print_bibliography:",
  })
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].filetype = "org"

  require("organ.cite").commands["cite bibliography"].fn({ args = "apa" })
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Last line should be the rendered bibliography (replacing the directive).
  local found
  for _, l in ipairs(lines) do
    if l:match("Doe, J%.") and l:match("2020") then
      found = l
      break
    end
  end
  assert(found, "bibliography line not found in buffer:\n  " .. table.concat(lines, "\n  "))
  -- Directive should no longer be present.
  for _, l in ipairs(lines) do
    assert(not l:match("^#%+print_bibliography"), "directive should have been replaced")
  end

  os.remove(bib_path)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- Export pipeline integration: cite_native = true on every backend

do
  local bib_path = "/tmp/cite_csl_test_export_refs.bib"
  local f = assert(io.open(bib_path, "wb"))
  f:write([[
@article{doe2020, author = {Doe, J}, title = {On Things},
  journal = {J Sci}, year = {2020}, volume = {1}, pages = {3--5}}
]])
  f:close()

  local org_src = table.concat({
    "#+title: Test",
    "#+bibliography: " .. bib_path,
    "",
    "* Intro",
    "Body [cite:@doe2020] continues.",
    "",
    "#+print_bibliography:",
  }, "\n")

  local function check_common(out, fmt)
    assert(out:match("%(Doe, 2020%)"), fmt .. " inline cite: " .. out)
    assert(not out:find("\1"), fmt .. " no sentinels left")
    assert(not out:match("%[cite:"), fmt .. " raw cite removed")
    assert(not out:match("#%+print_bibliography"), fmt .. " bib directive replaced")
  end

  local opts = { cite_native = true, cite_style = "apa" }

  local md = require("organ.export.markdown").export(org_src, opts)
  check_common(md, "markdown")
  assert(md:match("%*J Sci%*"), "markdown italics: " .. md)

  local html = require("organ.export.html").export(org_src, opts)
  check_common(html, "html")
  assert(html:match("<em>J Sci</em>"), "html italics: " .. html)

  local tex = require("organ.export.latex").export(org_src, opts)
  check_common(tex, "latex")
  assert(tex:match("\\emph{J Sci}"), "latex italics: " .. tex)

  local txt = require("organ.export.ascii").export(org_src, opts)
  check_common(txt, "ascii")
  -- ascii strips italics — just check the journal name is present.
  assert(txt:match("J Sci"), "ascii journal name: " .. txt)

  local tinfo = require("organ.export.texinfo").export(org_src, opts)
  check_common(tinfo, "texinfo")
  assert(tinfo:match("@emph{J Sci}"), "texinfo italics: " .. tinfo)

  os.remove(bib_path)
end

-- IEEE numeric cites round-trip through markdown export

do
  local bib_path = "/tmp/cite_csl_test_ieee_refs.bib"
  local f = assert(io.open(bib_path, "wb"))
  f:write([[
@article{a, author = {Foo, A}, title = {First}, year = {2010}}
@article{b, author = {Bar, B}, title = {Second}, year = {2011}}
]])
  f:close()
  local org_src = table.concat({
    "#+bibliography: " .. bib_path,
    "",
    "First [cite:@b] then [cite:@a] then [cite:@b] again.",
    "",
    "#+print_bibliography:",
  }, "\n")
  local ok_parser = pcall(function()
    return vim.treesitter.get_string_parser("", "org")
  end)
  if ok_parser then
    local md =
      require("organ.export.markdown").export(org_src, { cite_native = true, cite_style = "ieee" })
    -- @b cited first → [1], @a → [2], @b again → [1].
    assert(
      md:match("First %[1%] then %[2%] then %[1%] again"),
      "IEEE numbering across export: " .. md
    )
  end
  os.remove(bib_path)
end

-- Cite-key trigger detection at cursor

do
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- Helper: place line and cursor at the given 0-based byte col, run
  -- trigger. Lines have a trailing " " so normal-mode clamping doesn't
  -- snap the cursor inward off the position we're testing.
  local function probe(line, col)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, col })
    return cite.trigger_at_cursor(bufnr)
  end

  -- "Body [cite:@do " — 0-based col 14 sits just past the 'o'.
  local t = probe("Body [cite:@do ", 14)
  assert(t and t.kind == "cite_key", "cite_key trigger after @")
  assert(t.query == "do", "cite_key query: " .. tostring(t and t.query))
  -- Inside [cite/style:@<partial>
  t = probe("[cite/author:@k ", 15)
  assert(t and t.kind == "cite_key", "styled cite_key trigger")
  assert(t.query == "k", "styled cite_key query: " .. tostring(t and t.query))
  -- Compound: [cite:@a; @bee<cursor>
  t = probe("[cite:@a; @bee ", 14)
  assert(t and t.kind == "cite_key", "compound cite_key trigger")
  assert(t.query == "bee", "compound query: " .. tostring(t and t.query))
  -- After the closing ] — not a trigger.
  t = probe("[cite:@a] more ", 14)
  assert(t == nil, "no trigger after closing ]")
  -- Plain @ outside cite — not a trigger.
  t = probe("email @user here", 12)
  assert(t == nil, "no trigger outside cite block")
  -- Bare [cite: with no @ yet — not a trigger.
  t = probe("[cite: ", 6)
  assert(t == nil, "no trigger before @")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- Completion items + mtime-aware cache

do
  cite.clear_cache()
  local bib_path = "/tmp/cite_csl_test_complete.bib"
  local f = assert(io.open(bib_path, "wb"))
  f:write([[
@article{einstein1905, author = {Einstein, A}, title = {Relativity}, year = {1905}}
@article{turing1936,   author = {Turing, A}, title = {Computability}, year = {1936}}
]])
  f:close()

  local items = cite.completion_items("", { paths = { bib_path } })
  assert(#items == 2, "two items: " .. #items)
  -- Sorted by key: einstein1905 < turing1936
  assert(items[1].key == "einstein1905", "sort order: " .. items[1].key)
  assert(items[2].key == "turing1936", "sort order: " .. items[2].key)
  -- Label includes author + year + title.
  assert(items[1].label:match("Einstein"), "label has author: " .. items[1].label)
  assert(items[1].label:match("1905"), "label has year")
  assert(items[1].label:match("Relativity"), "label has title")

  -- Query filter: substring against key OR author OR title.
  local filtered = cite.completion_items("turing", { paths = { bib_path } })
  assert(
    #filtered == 1 and filtered[1].key == "turing1936",
    "key filter: " .. (#filtered > 0 and filtered[1].key or "<empty>")
  )
  filtered = cite.completion_items("RELATIVITY", { paths = { bib_path } })
  assert(#filtered == 1 and filtered[1].key == "einstein1905", "title filter (case-insens)")
  filtered = cite.completion_items("einstein", { paths = { bib_path } })
  assert(#filtered == 1, "author filter")

  -- Cache: parse once, hit cache twice. Modify mtime → re-parse.
  local before_mtime = vim.uv.fs_stat(bib_path).mtime.sec
  -- Touch the file so mtime advances by at least 1 second.
  os.execute("sleep 1 && touch " .. bib_path)
  local after_mtime = vim.uv.fs_stat(bib_path).mtime.sec
  assert(after_mtime > before_mtime, "mtime advanced for cache test")
  -- Append a new entry, verify cache picks it up.
  f = assert(io.open(bib_path, "wb"))
  f:write([[
@article{einstein1905, author = {Einstein, A}, title = {Relativity}, year = {1905}}
@article{turing1936,   author = {Turing, A}, title = {Computability}, year = {1936}}
@article{godel1931,    author = {Godel, K}, title = {Incompleteness}, year = {1931}}
]])
  f:close()
  os.execute("touch " .. bib_path)
  local refreshed = cite.completion_items("", { paths = { bib_path } })
  assert(#refreshed == 3, "cache invalidated on mtime: got " .. #refreshed)

  os.remove(bib_path)
  cite.clear_cache()
end

-- BibTeX `#` concatenation and @string macros

do
  local src = [[
@string{aw = "Addison-Wesley"}
@string(jn = "Journal of " # "Things")
@book{a, title = "Foo" # " Bar", publisher = aw, journal = jn, year = 1999 }
@book{b, title = {Second}, year = 2000 }
  ]]
  local entries = bibtex.normalize(bibtex.parse(src))
  assert(#entries == 2, "hash-concat: two entries; got " .. #entries)
  assert(entries[1].fields.title == "Foo Bar", "concat: " .. tostring(entries[1].fields.title))
  assert(
    entries[1].fields.publisher == "Addison-Wesley",
    "@string: " .. tostring(entries[1].fields.publisher)
  )
  assert(
    entries[1].fields.journal == "Journal of Things",
    "@string concat: " .. tostring(entries[1].fields.journal)
  )
  assert(entries[2].key == "b", "second entry parsed")
end

-- `and` followed by a newline still splits authors

do
  local entries = bibtex.normalize(
    bibtex.parse(
      "@article{x,\n  author = {John Doe and\n            Jane Roe},\n  year = 2001\n}\n"
    )
  )
  assert(#entries[1].author == 2, "and-newline: " .. vim.inspect(entries[1].author))
  assert(entries[1].author[1].family == "Doe", "first author")
  assert(
    entries[1].author[2].family == "Roe" and entries[1].author[2].given == "Jane",
    "second author: " .. vim.inspect(entries[1].author[2])
  )
end

-- Text outside entries is a comment

do
  local entries = bibtex.parse("This file was created by Foo.\n@article{y, title={T}, year=2002}\n")
  assert(#entries == 1, "junk-before: " .. #entries)
  entries = bibtex.parse(
    "@article{y1, title={T}, year=2002}\nsome text\n@article{y2, title={U}, year=2003}\n"
  )
  assert(#entries == 2 and entries[2].key == "y2", "junk-between: " .. #entries)
end

-- Braces protect quotes inside a quoted value

do
  local entries = bibtex.parse(
    '@article{z, title = "The {"}quoted{"} word", year = 2004}\n'
      .. "@article{z2, title = {Next}, year = 2005}\n"
  )
  assert(#entries == 2, "quote-brace: " .. #entries)
  assert(
    entries[1].fields.title == 'The {"}quoted{"} word',
    "quote-brace title: " .. tostring(entries[1].fields.title)
  )
  assert(entries[2].key == "z2", "entry after quote-brace")
end

-- Name parsing: brace groups, von parts, `Last, Jr, First`

do
  local n = bibtex._parse_name("Jan {van der Berg}")
  assert(n.family == "van der Berg" and n.given == "Jan", "brace group: " .. vim.inspect(n))
  n = bibtex._parse_name("King, Jr., Martin Luther")
  assert(
    n.family == "King" and n.given == "Martin Luther" and n.suffix == "Jr.",
    "Last, Jr, First: " .. vim.inspect(n)
  )
  n = bibtex._parse_name("Ludwig van Beethoven")
  assert(n.family == "van Beethoven" and n.given == "Ludwig", "von part: " .. vim.inspect(n))
end

-- LaTeX accent commands decode to unicode; leftover braces are dropped

do
  local entries = bibtex.normalize(
    bibtex.parse(
      "@article{s, author = {Erwin Schr{\\\"o}dinger and Jos{\\'e} {\\~N}u{\\~n}ez},\n"
        .. ' title = {\\"Uber das Ph{\\"a}nomen of {Linux} \\& \\v{C}apek}, journal = {J}, year = 1926}\n'
    )
  )
  local e = entries[1]
  assert(e.author[1].family == "Schrödinger", "accent family: " .. e.author[1].family)
  assert(
    e.author[2].family == "Ñuñez" and e.author[2].given == "José",
    "accent author 2: " .. vim.inspect(e.author[2])
  )
  assert(
    e.fields.title == "Über das Phänomen of Linux & Čapek",
    "accent title: " .. e.fields.title
  )
end

-- CSL-JSON authors without given/family and JSON null fields

do
  local entries = csl_json.parse([=[
[
 {"id":"fam","type":"book","title":"Fam Only","author":[{"family":"Doe"}],"issued":{"date-parts":[[2020]]}},
 {"id":"lit","type":"report","title":"WHO Report","author":[{"literal":"World Health Organization"}],"issued":{"date-parts":[[2021]]}},
 {"id":"nul","type":"article-journal","title":"Null issue","author":[{"family":"Roe","given":"Jane"}],"container-title":"J","volume":3,"issue":null,"page":null,"issued":{"date-parts":[[2022]]}}
]
]=])
  local idx = csl_json.index(entries)
  assert(idx.nul.fields.number == nil and idx.nul.fields.pages == nil, "null fields dropped")
  for _, style in ipairs({ "apa", "chicago", "ieee" }) do
    local c, b = render.render_text("[cite:@fam;@lit;@nul]", idx, style)
    b = table.concat(b, "\n")
    assert(
      style == "ieee" or c:find("World Health Organization", 1, true),
      style .. " literal author cite: " .. c
    )
    assert(b:find("World Health Organization", 1, true), style .. " literal author bib: " .. b)
    assert(not b:find("vim.NIL", 1, true), style .. " bib: " .. b)
  end
  local _, b = render.render_text("[cite:@fam]", idx, "apa")
  assert(b[1]:match("^Doe %(2020%)"), "family-only apa bib: " .. b[1])
end

-- Year suffixes consider cited entries only

do
  local idx = bibtex.index(bibtex.normalize(bibtex.parse([[
@article{doe_a, author = {Doe, J}, title = {A}, year = {2020}}
@article{doe_b, author = {Doe, J}, title = {B}, year = {2020}}
  ]])))
  local out, bib = render.render_text("[cite:@doe_b]", idx, "apa")
  assert(out == "(Doe, 2020)", "lone cite gets no suffix: " .. out)
  assert(bib[1]:match("%(2020%)%."), "lone bib entry: " .. bib[1])
end

-- Entries without author fall back to the title

do
  local idx = { m = { key = "m", type = "misc", fields = { title = "Anon report" }, year = 2019 } }
  local out, bib = render.render_text("[cite:@m]", idx, "apa")
  assert(out == "(Anon report, 2019)", "apa no-author cite: " .. out)
  assert(bib[1] == "Anon report. (2019).", "apa no-author bib: " .. bib[1])
  out, bib = render.render_text("[cite:@m]", idx, "chicago")
  assert(out == "(Anon report 2019)", "chicago no-author cite: " .. out)
  assert(bib[1] == "Anon report. 2019.", "chicago no-author bib: " .. bib[1])
  out, bib = render.render_text("[cite:@m]", idx, "ieee")
  assert(bib[1]:match('^%[1%] "Anon report,"'), "ieee no-author bib: " .. bib[1])
end

-- Alphabetical bibliographies fold accents when sorting

do
  local function entry(key, family)
    return {
      key = key,
      type = "article",
      fields = { title = key },
      author = { { family = family, given = "A" } },
      year = 2000,
    }
  end
  local idx = { z = entry("z", "Zola"), e = entry("e", "Émile"), b = entry("b", "Brown") }
  local _, bib = render.render_text("[cite:@z;@e;@b]", idx, "apa")
  assert(
    bib[1]:match("^Brown") and bib[2]:match("^Émile") and bib[3]:match("^Zola"),
    "accent-folded order: " .. table.concat(bib, " | ")
  )
end

io.write("cite csl ok\n")
os.exit(0)
