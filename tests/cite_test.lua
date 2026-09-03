-- cite: scan + parse + per-backend render + replace_in.
-- Run via: nvim --headless -l tests/cite_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local cite = require("organ.cite")

-- 1. Single-key form.
do
  local p = cite.parse("[cite:@knuth1968]")
  assert(p, "parse minimal form")
  assert(p.style == "default", "style: " .. p.style)
  assert(
    #p.refs == 1 and p.refs[1].key == "knuth1968",
    "ref key: " .. tostring(p.refs[1] and p.refs[1].key)
  )
end

-- 2. Multi-key + custom style.
do
  local p = cite.parse("[cite/text:@a;@b;@c]")
  assert(p.style == "text", "style: " .. p.style)
  assert(#p.refs == 3, "3 refs; got " .. #p.refs)
  assert(p.refs[1].key == "a" and p.refs[3].key == "c", "key order")
end

-- 3. Per-key prefix + suffix.
do
  local p = cite.parse("[cite:see @smith pg. 5]")
  assert(p.refs[1].key == "smith", "key parsed")
  assert(p.refs[1].prefix == "see", "prefix: " .. tostring(p.refs[1].prefix))
  assert(p.refs[1].suffix == "pg. 5", "suffix: " .. tostring(p.refs[1].suffix))
end

-- 4. scan finds positions of multiple cites in a paragraph.
do
  local hits = cite.scan("Foo [cite:@x] bar [cite:@y;@z] baz")
  assert(#hits == 2, "2 hits; got " .. #hits)
  assert(hits[1].parsed.refs[1].key == "x")
  assert(hits[2].parsed.refs[2].key == "z")
end

-- 5. Per-backend render shapes.
do
  local p = cite.parse("[cite:@knuth1968]")
  assert(cite.render(p, "latex") == "\\cite{knuth1968}", "latex")
  assert(cite.render(p, "markdown") == "[@knuth1968]", "md")
  assert(cite.render(p, "ascii") == "[knuth1968]", "ascii")
  local html = cite.render(p, "html")
  assert(html:find('href="#bib-knuth1968"', 1, true), "html: " .. html)

  local p2 = cite.parse("[cite/author:@smith]")
  assert(cite.render(p2, "latex") == "\\citeauthor{smith}", "author style")
end

-- 6. replace_in substitutes EVERY citation in a paragraph.
do
  local out = cite.replace_in("see [cite:@a] and [cite:@b]", "ascii")
  assert(out == "see [a] and [b]", "ascii out: " .. out)
end

-- 7. End-to-end through HTML exporter — `<` `>` inside the cite anchor
--    survive because we stash before html_escape. Requires the org parser
--    to be installed; skip gracefully when running in environments
--    without it (CI image, fresh checkout before grammar install).
local parser_path = require("organ.defaults").parser_path
local ok_parser = pcall(vim.treesitter.language.add, "org", { path = parser_path })
if ok_parser then
  local html = require("organ.export.html").export("* H\nsee [cite:@knuth1968].\n")
  assert(html:find('class="citation"', 1, true), "html cite anchor present")
  assert(html:find('href="#bib-knuth1968"', 1, true), "html cite href present")
else
  io.write("(skipped HTML exporter check: org tree-sitter parser not installed)\n")
end

-- 8. scan matches only `[cite` + optional `/style` + `:`; the closing
--    bracket balances nested brackets; a body without a key is not a
--    citation.
do
  local out = cite.replace_in("Text [cites] foo: bar [cite:@x] end", "ascii")
  assert(out == "Text [cites] foo: bar [x] end", "cites: " .. out)
  local plain = "Text [citation needed] foo: bar. Later line ] tail"
  assert(cite.replace_in(plain, "ascii") == plain, "no citation: untouched")
  assert(#cite.scan("[cite:no key here]") == 0, "body without key is not a citation")
  assert(#cite.scan("[cite@x] [cite-x:@y]") == 0, "prefix must end with a colon")
  local hits = cite.scan("[cite:@a [x]] tail")
  assert(#hits == 1 and hits[1].e == 13, "balanced brackets: " .. vim.inspect(hits))
  assert(hits[1].parsed.refs[1].suffix == "[x]", "suffix: " .. vim.inspect(hits[1].parsed))
end

-- 9. Short style names alias the long ones; variants are split off.
do
  assert(cite.parse("[cite/t:@a]").style == "text", "t -> text")
  assert(cite.parse("[cite/na:@a]").style == "noauthor", "na -> noauthor")
  assert(cite.parse("[cite/a:@a]").style == "author", "a -> author")
  assert(cite.parse("[cite/n:@a]").style == "nocite", "n -> nocite")
  assert(cite.parse("[cite/nb:@a]").style == "numeric", "nb -> numeric")
  local p = cite.parse("[cite/t/c:@a]")
  assert(p.style == "text" and p.variant == "caps", "variant: " .. vim.inspect(p))
  assert(cite.render(cite.parse("[cite/t:@a;@b]"), "latex") == "\\citet{a,b}", "latex citet")
  assert(cite.render(cite.parse("[cite/n:@a]"), "latex") == "\\nocite{a}", "latex nocite")
  assert(cite.render(cite.parse("[cite/n:@a]"), "html") == "", "html nocite renders nothing")
  local idx = {
    a = {
      key = "a",
      type = "article",
      fields = {},
      author = { { family = "Doe", given = "J" } },
      year = 2020,
    },
  }
  local render = require("organ.cite.render")
  local function r(src, style)
    return (render.render_text(src, idx, style))
  end
  assert(r("[cite/t:@a]", "apa") == "Doe (2020)", "apa text: " .. r("[cite/t:@a]", "apa"))
  assert(r("[cite/na:@a]", "apa") == "(2020)", "apa noauthor: " .. r("[cite/na:@a]", "apa"))
  assert(r("[cite/a:@a]", "apa") == "Doe", "apa author: " .. r("[cite/a:@a]", "apa"))
  assert(
    r("[cite/t:@a]", "chicago") == "Doe (2020)",
    "chicago text: " .. r("[cite/t:@a]", "chicago")
  )
  assert(r("[cite/n:@a]", "apa") == "", "apa nocite: " .. r("[cite/n:@a]", "apa"))

  -- Entries without author or year end in a single period.
  local sparse = {
    noyear = { key = "noyear", type = "book", fields = { title = "No Year Title" } },
    nothing = { key = "nothing", type = "book", fields = {} },
  }
  local _, bibl = render.render_text("[cite:@noyear;@nothing]", sparse, "apa")
  assert(
    vim.deep_equal(bibl, { "No Year Title.", "nothing." }),
    "apa sparse bibliography: " .. vim.inspect(bibl)
  )
end

-- 10. texinfo renderer.
do
  local p = cite.parse("[cite:@doe2020]")
  assert(cite.render(p, "texinfo") == "[doe2020]", "texinfo render")
  assert(cite.replace_in("see [cite:@doe2020]", "texinfo") == "see [doe2020]", "texinfo replace")
end

-- 11. Key characters follow org-element-citation-key-re.
do
  local r = cite.parse("[cite:@c++11]").refs[1]
  assert(r.key == "c++11" and r.suffix == nil, "plus: " .. vim.inspect(r))
  r = cite.parse("[cite:@müller2020 p. 3]").refs[1]
  assert(r.key == "müller2020" and r.suffix == "p. 3", "non-ascii: " .. vim.inspect(r))
  r = cite.parse("[cite:see @a/b:c.d]").refs[1]
  assert(r.key == "a/b:c.d" and r.prefix == "see", "punctuation: " .. vim.inspect(r))
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "[cite:@c+ " })
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, 9 })
  local t = cite.trigger_at_cursor(bufnr)
  assert(t and t.query == "c+", "trigger query with plus: " .. vim.inspect(t))
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- 12. Native citations are escaped per backend before substitution;
--     LaTeX keeps bibliography fields raw.
if ok_parser then
  local bib = vim.fn.tempname() .. ".bib"
  local f = assert(io.open(bib, "w"))
  f:write(
    "@article{tj, author = {{Tom & Jerry}}, title = {Cats & Mice @ <script>alert(1)</script>},"
      .. " journal = {J & J}, year = 2020}\n"
  )
  f:close()
  local src = { "Text [cite:@tj] here.", "", "#+print_bibliography:" }
  local opts = { cite_native = true, bib_files = { bib }, cite_style = "apa" }
  local html = require("organ.export.html").export(src, opts)
  assert(not html:find("<script>", 1, true), "html: raw bib markup escaped: " .. html)
  assert(html:find("Cats &amp; Mice @ &lt;script&gt;", 1, true), "html escaped bib: " .. html)
  assert(html:find("<em>J &amp; J</em>", 1, true), "html italics kept: " .. html)
  assert(html:find("(Tom &amp; Jerry, 2020)", 1, true), "html escaped cite: " .. html)
  local tex = require("organ.export.latex").export(src, opts)
  assert(tex:find("Cats & Mice @ <script>", 1, true), "latex keeps raw fields: " .. tex)
  local tinfo = require("organ.export.texinfo").export(src, opts)
  assert(tinfo:find("Cats & Mice @@ <script>", 1, true), "texinfo escaped bib: " .. tinfo)
  assert(tinfo:find("@emph{J & J}", 1, true), "texinfo italics kept: " .. tinfo)
  os.remove(bib)
end

io.write("cite ok\n")
os.exit(0)
