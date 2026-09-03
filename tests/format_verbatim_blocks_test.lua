-- The table-realign and list-repair passes must not reach into a block
-- whose body org-element keeps as raw text (verse / src / example /
-- export / comment), and must still reach into special blocks and
-- drawers, which do hold elements.  A `#+begin_` line opens nothing
-- unless a matching `#+end_` follows before the next headline, so
-- neither pass -- nor prose wrapping -- may treat the rest of the
-- buffer as block body.  Ground truth: `org-element-at-point` /
-- `org-at-table-p` / `org-at-item-p`, GNU Emacs 30.2 / Org 9.7.11.
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

-- The list-repair sweep starts outside the block, so it must stop at the
-- block boundary rather than renumber the raw body it walks into.
do
  local out = formatted({
    "1. one",
    "   #+begin_src text",
    "   1. not a list",
    "   1. also not",
    "   #+end_src",
    "1. two",
  })
  check("repair from outside: src body untouched", out[4] == "   1. also not", vim.inspect(out))
  check("repair from outside: list continues past the block", out[6] == "2. two", vim.inspect(out))
end

-- Filling stops at a verbatim body only.  A quote or center block holds
-- ordinary paragraphs, and Emacs fills them: verified with
-- `org-fill-paragraph` at fill-column 40 (Emacs 30.2 / Org 9.7.11),
-- which wraps quote and center but leaves verse, example and src.
do
  local long =
    "this is a fairly long quoted sentence that certainly goes past the fill column limit here"
  local function wrapped(kind, close)
    return fmt.format_lines({ "#+begin_" .. kind, long, "#+end_" .. (close or kind) }, {
      wrap = { width = 40 },
      headline = { normalize_whitespace = false },
      blanks = {},
    }, nil)
  end
  for _, kind in ipairs({ "quote", "center" }) do
    local out = wrapped(kind)
    check(kind .. ": body is filled", #out == 5, vim.inspect(out))
    check(
      kind .. ": first body line wraps at the width",
      out[2] == "this is a fairly long quoted sentence",
      vim.inspect(out)
    )
    check(
      kind .. ": fences survive",
      out[1] == "#+begin_" .. kind and out[#out] == "#+end_" .. kind,
      vim.inspect(out)
    )
  end
  for _, kind in ipairs({ "verse", "example", "export", "comment" }) do
    local out = wrapped(kind)
    check(kind .. ": body is left verbatim", #out == 3 and out[2] == long, vim.inspect(out))
  end
  local src = wrapped("src text", "src")
  check("src: body is left verbatim", #src == 3 and src[2] == long, vim.inspect(src))
end

-- Prose wrapping obeys the same rule: an unterminated `#+begin_` must
-- not suppress wrapping to end of buffer.
do
  local prev = organ.config.format
  organ.config.format = vim.tbl_deep_extend("force", CFG, { wrap = { enabled = true } })
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 40
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* H",
    "#+begin_src text",
    "alpha beta gamma delta epsilon zeta eta theta iota kappa",
    "",
    "* H2",
    "alpha beta gamma delta epsilon zeta eta theta iota kappa",
  })
  vim.bo[b].filetype = "org"
  local ok, err = pcall(fmt.format_buffer, b)
  organ.config.format = prev
  if not ok then
    error(err)
  end
  local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "unterminated begin_src: text under it wraps",
    out[3] == "alpha beta gamma delta epsilon zeta eta",
    vim.inspect(out)
  )
  check(
    "unterminated begin_src: next section wraps",
    out[7] == "alpha beta gamma delta epsilon zeta eta",
    vim.inspect(out)
  )
end

-- A `#+end_` past a headline does not close the block either.
do
  local prev = organ.config.format
  organ.config.format = vim.tbl_deep_extend("force", CFG, { wrap = { enabled = true } })
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 40
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* H",
    "#+begin_src text",
    "alpha beta gamma delta epsilon zeta eta theta iota kappa",
    "* H2",
    "#+end_src",
  })
  vim.bo[b].filetype = "org"
  local ok, err = pcall(fmt.format_buffer, b)
  organ.config.format = prev
  if not ok then
    error(err)
  end
  local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "close past a headline: text still wraps",
    out[3] == "alpha beta gamma delta epsilon zeta eta",
    vim.inspect(out)
  )
end

-- A closed block still shields its body from the wrap pass.
do
  local prev = organ.config.format
  organ.config.format = vim.tbl_deep_extend("force", CFG, { wrap = { enabled = true } })
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 40
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* H",
    "#+begin_src text",
    "alpha beta gamma delta epsilon zeta eta theta iota kappa",
    "#+end_src",
  })
  vim.bo[b].filetype = "org"
  local ok, err = pcall(fmt.format_buffer, b)
  organ.config.format = prev
  if not ok then
    error(err)
  end
  local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "closed block: body is not wrapped",
    out[3] == "alpha beta gamma delta epsilon zeta eta theta iota kappa",
    vim.inspect(out)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_verbatim_blocks_test: PASS")
