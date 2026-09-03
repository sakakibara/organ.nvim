-- list.parse_item / block_at / repair / sort.
-- Run via: nvim --headless -l tests/list_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local list = require("organ.list")

-- 1. parse_item.
do
  local p = list.parse_item("- hello")
  assert(p.bullet == "-" and p.content == "hello", "unordered")
  p = list.parse_item("  + nested")
  assert(p.indent == "  " and p.bullet == "+", "indent + alt bullet")
  p = list.parse_item("3. third")
  assert(p.bullet == "3." and p.counter == 3, "ordered")
  p = list.parse_item("not a list")
  assert(p == nil, "non-item")
end

-- 2. block_at: find contiguous list span.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "intro line",
    "- one",
    "- two",
    "- three",
    "after",
  })
  local s, e = list.block_at(b, 3) -- cursor on `- two`
  assert(s == 2 and e == 4, ("block: " .. s .. ".." .. e))
end

-- 3. repair: re-sequence numbered.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "1. a",
    "5. b",
    "9. c",
  })
  local n = list.repair(b, 1)
  assert(n == 2, "expected 2 changes; got " .. n)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "1. a", "first stays: " .. lines[1])
  assert(lines[2] == "2. b", "second renum: " .. lines[2])
  assert(lines[3] == "3. c", "third renum: " .. lines[3])
end

-- 4. repair honors `[@N]` start marker.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "1. [@5] start at 5",
    "1. b",
    "1. c",
  })
  list.repair(b, 1)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "5. [@5] start at 5", "first becomes 5: " .. lines[1])
  assert(lines[2] == "6. b", "second 6: " .. lines[2])
  assert(lines[3] == "7. c", "third 7: " .. lines[3])
end

-- 5. sort alphabetic.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "- charlie",
    "- alpha",
    "- bravo",
  })
  list.sort(b, 1, "alpha")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "- alpha", "1st: " .. lines[1])
  assert(lines[2] == "- bravo", "2nd: " .. lines[2])
  assert(lines[3] == "- charlie", "3rd: " .. lines[3])
end

-- 5b. sort by display length, ties alphabetical.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "- longest one",
    "- bb",
    "- 日本",
    "- aa",
  })
  list.sort(b, 1, "length")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(
    vim.deep_equal(lines, { "- aa", "- bb", "- 日本", "- longest one" }),
    "length sort: " .. vim.inspect(lines)
  )
end

-- 6. sort keeps sub-items with their parent.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "- charlie",
    "  - sub of charlie",
    "- alpha",
    "  - sub of alpha",
  })
  list.sort(b, 1, "alpha")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[1] == "- alpha", "alpha first: " .. lines[1])
  assert(lines[2] == "  - sub of alpha", "alpha's sub follows: " .. lines[2])
  assert(lines[3] == "- charlie", "charlie next: " .. lines[3])
  assert(lines[4] == "  - sub of charlie", "charlie's sub follows: " .. lines[4])
end

-- 8. repair numbers a run from 1 (Emacs `org-list-repair`), while
--    `preserve_start` numbers it from the first item's own number so an
--    unattended sweep cannot rewrite prose that opens with a number.
do
  local function mk(lines)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    return b
  end
  local b = mk({ "3. three", "9. nine", "7. seven" })
  list.repair(b, 1)
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), {
      "1. three",
      "2. nine",
      "3. seven",
    }),
    "repair restarts at 1: " .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  )

  b = mk({ "3. three", "9. nine", "7. seven" })
  list.repair(b, 1, { preserve_start = true })
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), {
      "3. three",
      "4. nine",
      "5. seven",
    }),
    "preserve_start counts on from 3: " .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  )

  -- Already sequential from its own start: nothing to change.
  b = mk({ "1985. It was a good year.", "1986. The following year was quieter." })
  list.repair(b, 1, { preserve_start = true })
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), {
      "1985. It was a good year.",
      "1986. The following year was quieter.",
    }),
    "year-numbered prose is untouched: " .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  )

  -- A real list still gets repaired.
  b = mk({ "1. one", "1. two", "1. three" })
  list.repair(b, 1, { preserve_start = true })
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), {
      "1. one",
      "2. two",
      "3. three",
    }),
    "a real list is still renumbered: " .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  )

  -- An explicit [@N] counter still wins over the first item's number.
  b = mk({ "2. [@7] seven", "1. eight" })
  list.repair(b, 1, { preserve_start = true })
  assert(
    vim.api.nvim_buf_get_lines(b, 0, -1, false)[2] == "8. eight",
    "counter wins: " .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  )
end

-- 9. A raw block body inside an item is not list structure: verse /
--    src / example / export / comment bodies are raw text, so a `1.`
--    line there is not an item (Emacs `org-at-item-p` is nil inside
--    them, t inside a quote block or a drawer).  An unterminated
--    `#+begin_` opens nothing, so its "body" is ordinary text.
do
  local function mk(lines)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    return b
  end

  local b = mk({
    "1. one",
    "   #+begin_src text",
    "   1. not a list",
    "   1. also not",
    "   #+end_src",
    "1. two",
  })
  list.repair(b, 1)
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), {
      "1. one",
      "   #+begin_src text",
      "   1. not a list",
      "   1. also not",
      "   #+end_src",
      "2. two",
    }),
    "src body untouched, list continues past it: "
      .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  )

  -- The cursor sitting on a raw body line finds no structure at all.
  b = mk({ "1. one", "   #+begin_example", "   1. not a list", "   #+end_example" })
  assert(list.repair(b, 3) == 0, "no structure inside a block body")

  -- Quote blocks and drawers hold real elements.
  b = mk({ "1. one", "   #+begin_quote", "   1. real", "   1. real2", "   #+end_quote" })
  list.repair(b, 1)
  assert(
    vim.api.nvim_buf_get_lines(b, 0, -1, false)[4] == "   2. real2",
    "quote body is a real list: " .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  )

  b = mk({ "1. one", "   :MYD:", "   1. real", "   1. real2", "   :END:" })
  list.repair(b, 1)
  assert(
    vim.api.nvim_buf_get_lines(b, 0, -1, false)[4] == "   2. real2",
    "drawer body is a real list: " .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  )

  b = mk({ "1. one", "   #+begin_src text", "   1. real", "   1. real2" })
  list.repair(b, 1)
  assert(
    vim.api.nvim_buf_get_lines(b, 0, -1, false)[4] == "   2. real2",
    "unterminated begin_src opens nothing: "
      .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  )

  -- A block does not span a headline, so neither does its raw body.
  b = mk({ "1. one", "   #+begin_src text", "   1. real", "   1. real2", "* H", "   #+end_src" })
  list.repair(b, 1)
  assert(
    vim.api.nvim_buf_get_lines(b, 0, -1, false)[4] == "   2. real2",
    "close past a headline does not close: "
      .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  )
end

io.write("list ok\n")
os.exit(0)
