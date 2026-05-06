-- OPML export: nested <outline> per headline, _note attr from first body line.
-- Run via: nvim --headless -l tests/export_opml_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local opml = require("organ.export.opml")

local function assert_contains(haystack, needle, msg)
  assert(
    haystack:find(needle, 1, true),
    (msg or "expected to find") .. ": '" .. needle .. "' in:\n" .. haystack
  )
end

local out = opml.export([[
#+TITLE: My Outline
* Top
  first body line
** Sub
*** Deep
* Sibling
  another note
]])

assert_contains(out, '<?xml version="1.0"')
assert_contains(out, '<opml version="2.0">')
assert_contains(out, "<title>My Outline</title>")
-- Headlines with right nesting.
assert_contains(out, '<outline text="Top"')
assert_contains(out, '_note="first body line"')
assert_contains(out, '<outline text="Sub"')
assert_contains(out, '<outline text="Deep"')
assert_contains(out, '<outline text="Sibling"')

-- 4 headlines means 4 closing tags.
local n_close = 0
for _ in out:gmatch("</outline>") do
  n_close = n_close + 1
end
assert(n_close == 4, "expected 4 </outline>; got " .. n_close)

-- TODO + tags are stripped from the title attribute.
local sanitised = opml.export("* TODO Buy milk :shopping:\n")
assert(
  not sanitised:find("TODO", 1, true),
  "TODO must be stripped from outline text:\n" .. sanitised
)
assert(not sanitised:find(":shopping:", 1, true), "tags must be stripped:\n" .. sanitised)
assert(
  sanitised:find('text="Buy milk"', 1, true),
  "title preserved without keyword/tags:\n" .. sanitised
)

-- XML special chars escaped.
local esc = opml.export("* A & B <test>\n")
assert(esc:find('text="A &amp; B &lt;test&gt;"', 1, true), "XML escaping:\n" .. esc)

io.write("export opml ok\n")
os.exit(0)
