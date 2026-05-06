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

io.write("cite ok\n")
os.exit(0)
