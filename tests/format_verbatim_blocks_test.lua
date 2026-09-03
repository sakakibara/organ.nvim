-- The table-realign and list-repair passes must not reach into a block
-- whose body org-element keeps as raw text (verse / src / example /
-- export / comment), and must still reach into special blocks and
-- drawers, which do hold elements.  Ground truth: `org-at-table-p` /
-- `org-at-item-p` inside each block, GNU Emacs 30.2 / Org 9.7.11.
--
-- Run via: nvim --headless -l tests/format_verbatim_blocks_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local fmt = require("organ.format")
local organ = require("organ")

-- Only the passes under test stay on, so a failure points at one of them.
local CFG = {
  wrap = { enabled = false },
  headline = { tags_column = false, normalize_whitespace = true },
  drawers = { align_values = true },
  blanks = { trim_trailing = true, ensure_final_newline = true, collapse_runs = 0 },
  trim_trailing_whitespace = true,
  tables = { realign = true },
  lists = { repair_numbering = true },
  section = { normalize = false },
}

local function formatted(lines)
  local prev = organ.config.format
  organ.config.format = CFG
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  local ok, err = pcall(fmt.format_buffer, b)
  organ.config.format = prev
  if not ok then
    error(err, 2)
  end
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function unchanged(label, lines)
  local out = formatted(lines)
  check(label, vim.deep_equal(out, lines), vim.inspect(out))
end

-- Verse is the one element where every character is meaningful.
unchanged("verse: pipe lines are not a table", {
  "#+begin_verse",
  "| a stanza line",
  "| another line",
  "#+end_verse",
})

unchanged("src: pipe lines are not a table", {
  "#+begin_src markdown",
  "| a | bb |",
  "| ccc | d |",
  "#+end_src",
})

unchanged("src: ordered list is not renumbered or reindented", {
  "#+begin_src markdown",
  "1. one",
  "    1. deep sub",
  "    1. deep sub two",
  "2. two",
  "#+end_src",
})

unchanged("example: pipe lines are not a table", {
  "#+begin_example",
  "| a | bb |",
  "| ccc | d |",
  "#+end_example",
})

unchanged("export: pipe lines are not a table", {
  "#+begin_export html",
  "| a | bb |",
  "| ccc | d |",
  "#+end_export",
})

unchanged("comment block: ordered list is not renumbered", {
  "#+begin_comment",
  "1. one",
  "1. two",
  "#+end_comment",
})

unchanged("src: drawer-shaped lines are not a drawer", {
  "#+begin_src text",
  ":FOO:",
  ":BAR: baz",
  ":END:",
  "#+end_src",
})

unchanged("src nested in quote: still verbatim", {
  "#+begin_quote",
  "#+begin_src org",
  "| a | bb |",
  "| ccc | d |",
  "#+end_src",
  "#+end_quote",
})

-- Blocks whose bodies org-element DOES parse as elements keep working.
do
  local out = formatted({
    "#+begin_quote",
    "| a | bb |",
    "| ccc | d |",
    "#+end_quote",
  })
  check("quote block: table still realigned", out[2] == "| a   | bb |", vim.inspect(out))
end

do
  local out = formatted({
    "#+begin_quote",
    "1. one",
    "1. two",
    "#+end_quote",
  })
  check("quote block: list still renumbered", out[3] == "2. two", vim.inspect(out))
end

do
  local out = formatted({
    ":MYDRAWER:",
    "| a | bb |",
    "| ccc | d |",
    ":END:",
  })
  check("drawer: table still realigned", out[2] == "| a   | bb |", vim.inspect(out))
end

do
  local out = formatted({
    ":PROPERTIES:",
    ":ID: abc",
    ":END:",
  })
  check("drawer: property values still aligned", out[2] == ":ID:       abc", vim.inspect(out))
end

-- An unterminated `#+begin_` opens no block at all, so the pipe lines
-- below it are an ordinary table (matches `org-element-at-point`).
do
  local out = formatted({
    "#+begin_src markdown",
    "| a | bb |",
    "| ccc | d |",
  })
  check("unterminated begin_src: table realigned", out[2] == "| a   | bb |", vim.inspect(out))
end

-- A table after a closed verbatim block is still reached.
do
  local out = formatted({
    "#+begin_src markdown",
    "| a | bb |",
    "#+end_src",
    "",
    "| a | bb |",
    "| ccc | d |",
  })
  check("after end_src: block body untouched", out[2] == "| a | bb |", vim.inspect(out))
  check("after end_src: following table realigned", out[5] == "| a   | bb |", vim.inspect(out))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_verbatim_blocks_test: PASS")
