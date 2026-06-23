-- Regression tests for GFM pipe-table recognition edge cases in the from_md
-- importer.  The bundled spec.json fixtures cover the common shapes; these are
-- boundary cases found by differential fuzzing against cmark-gfm (the renderer
-- GitHub uses).  Expected values verified against cmark-gfm 0.29.0.gfm.13.
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local from_md = require("organ.ast.from_md")
local cmark = dofile(root .. "/tests/cmark/html.lua")

local function eq(md, html, msg)
  local got = cmark.render(from_md.parse(md))
  assert(
    got == html,
    msg .. "\n  expected: " .. vim.inspect(html) .. "\n  got:      " .. vim.inspect(got)
  )
end

-- A header with no pipe is a single-column row, so it can head a one-column
-- table when the delimiter has one column.
eq(
  "text\n|:-:|\n",
  '<table>\n<thead>\n<tr>\n<th align="center">text</th>\n</tr>\n</thead>\n</table>\n',
  "a no-pipe header heads a single-column table"
)

-- The header is the paragraph's LAST line; earlier lines stay a paragraph.
eq(
  "lead\n| a | b |\n| - | - |\n",
  "<p>lead</p>\n<table>\n<thead>\n<tr>\n<th>a</th>\n<th>b</th>\n</tr>\n</thead>\n</table>\n",
  "lines above the header become their own paragraph"
)

-- A bare run of dashes is a setext underline, not a one-column table delimiter,
-- even when the header has a pipe.
eq("a|b\n---\n", "<h2>a|b</h2>\n", "a `---` underline is a setext heading, not a table")

-- A line that also starts a list item is taken as the list, not a delimiter.
eq("x\n- |\n", "<p>x</p>\n<ul>\n<li>|</li>\n</ul>\n", "a `- |` list item beats a table delimiter")

-- A lone edge pipe is zero columns, so it heads no table.
eq("|\n|:-|\n", "<p>|\n|:-|</p>\n", "a lone `|` header is not a table")

-- Once a valid delimiter row fails the header's column count, the paragraph can
-- never become a table (cmark's TABLE_VISITED): later delimiter rows are inert.
eq(
  "`|`\n|- |\n|-|\nb\n",
  "<p><code>|</code>\n|- |\n|-|\nb</p>\n",
  "a column-count mismatch bars the paragraph from later table starts"
)

-- A lone `|` is not a valid body row: it ends the table and is reparsed.
eq(
  "h\n|-|\nx\n|\n",
  "<table>\n<thead>\n<tr>\n<th>h</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>x</td>\n</tr>\n</tbody>\n</table>\n<p>|</p>\n",
  "a lone `|` body row ends the table"
)

print("from_md_table_test: PASS")
