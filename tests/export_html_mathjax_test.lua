-- HTML export injects MathJax when the buffer uses math, and emits the
-- math regions verbatim (preserving `<` `>` inside them).
-- Run via: nvim --headless -l tests/export_html_mathjax_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local p = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = p })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local html = require("organ.export.html")

local function assert_contains(haystack, needle, msg)
  assert(
    haystack:find(needle, 1, true),
    (msg or "expected to find") .. ": '" .. needle .. "' in:\n" .. haystack
  )
end

-- 1. No math → no MathJax script.
do
  local out = html.export("* H\nplain prose, no math.\n")
  assert(not out:find("MathJax", 1, true), "MathJax must NOT load when no math:\n" .. out)
end

-- 2. Inline `$...$` math → MathJax script + math preserved verbatim.
do
  local out = html.export("* H\nThe formula $\\alpha < \\beta$ illustrates.\n")
  assert_contains(out, "MathJax")
  assert_contains(out, "tex-mml-chtml.js")
  -- The `<` inside the math region must remain literal (NOT escaped to &lt;).
  assert(
    out:find("$\\alpha < \\beta$", 1, true),
    "math region must pass through unchanged:\n" .. out
  )
end

-- 3. Display math `\[ ... \]` also triggers.
do
  local out = html.export("* H\n\\[ E = mc^2 \\]\n")
  assert_contains(out, "MathJax")
  assert(out:find("\\[ E = mc^2 \\]", 1, true), "display math preserved:\n" .. out)
end

-- 4. Config can disable MathJax even when math is present.
do
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    html = { mathjax = false },
  })
  local out = html.export("* H\nformula $x = 1$ here\n")
  assert(not out:find("MathJax", 1, true), "html.mathjax = false must suppress script:\n" .. out)
end

-- 5. Custom URL string is used verbatim.
do
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    html = { mathjax = "https://example.com/mathjax.js" },
  })
  local out = html.export("* H\nformula $x = 1$\n")
  assert(
    out:find("https://example.com/mathjax.js", 1, true),
    "custom MathJax URL should be used:\n" .. out
  )
end

io.write("export html mathjax ok\n")
os.exit(0)
