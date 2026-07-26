-- cite: trigger_at_cursor + completion_items + discover_paths.
--
-- These are the surfaces the cmp / blink adapters call. Untested
-- previously — and the cmp/blink adapters mock them out, so a regression
-- here would slip through both this and the adapter tests.
--
-- Run via: nvim --headless -l tests/cite_completion_test.lua

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

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Helper: install text + place cursor + ask trigger_at_cursor.
local function probe(line, col_1based)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, col_1based - 1 })
  return cite.trigger_at_cursor(buf)
end

-- trigger_at_cursor — the completion source dispatch point.
do
  -- Cursor at col 11 = byte index 10 (0-based). "[cite:@knu" is 10 chars,
  -- so cursor lands ON the position past 'u'. Trailing space gives us a
  -- real byte to land on so the cursor isn't clamped.
  local t = probe("[cite:@knu ", 11)
  check(
    "trigger: detects [cite:@<partial>",
    t and t.kind == "cite_key" and t.query == "knu",
    "got " .. vim.inspect(t)
  )
end

do
  -- Trailing space so the cursor at col 14 lands on a real byte (the space)
  -- rather than being clamped past end-of-line.
  local t = probe("[cite/text:@a ", 14)
  check("trigger: detects [cite/STYLE:@<partial>", t and t.query == "a", "got " .. vim.inspect(t))
end

do
  local t = probe("[cite:@a;@bo ", 13)
  check(
    "trigger: detects second-key inside a multi-key cite",
    t and t.query == "bo",
    "got " .. vim.inspect(t)
  )
end

-- Note: trigger_at_cursor scans only LEFT of cursor for `@`; it doesn't
-- inspect chars between `@` and cursor, so a cursor past `]` still triggers
-- if there's an `@` somewhere left of it. In practice cmp/blink fire WHILE
-- the user is typing the key, before the closing `]` exists, so this is
-- not exercised in real use. We don't assert nil-here for that reason.

do
  local t = probe("plain text @nope", 16)
  check(
    "trigger: returns nil for a bare @ outside any [cite:...]",
    t == nil,
    "got " .. vim.inspect(t)
  )
end

do
  -- Cursor at col 8 (1-based) = byte offset 7 (0-based) → just AFTER `@`,
  -- BEFORE `a`. Query should be empty (the typing-just-began state).
  local t = probe("[cite:@a]", 8)
  check(
    "trigger: empty query when cursor sits right after `@`",
    t and t.query == "",
    "got " .. vim.inspect(t)
  )
end

-- completion_items — filtering, sorting, item shape.
local tmp_bib = vim.fn.tempname() .. ".bib"
do
  local fd = io.open(tmp_bib, "w")
  fd:write([[
@book{knuth1968,
  author = {Knuth, Donald E.},
  title  = {The Art of Computer Programming},
  year   = {1968}
}

@article{smith2024,
  author = {Smith, Foo},
  title  = {Some Recent Paper},
  year   = {2024}
}

@misc{anonymous,
  title = {Untitled work},
}
]])
  fd:close()
end

cite.clear_cache()
local items = cite.completion_items("", { paths = { tmp_bib } })
check("completion_items: returns one item per bibtex entry", #items == 3, "got " .. #items)
check(
  "completion_items: items are sorted by key (deterministic)",
  items[1].key == "anonymous" and items[2].key == "knuth1968" and items[3].key == "smith2024",
  "got "
    .. table.concat(
      vim.tbl_map(function(i)
        return i.key
      end, items),
      ", "
    )
)
check(
  "completion_items: each item has key/label/description/entry",
  items[1].key and items[1].label and items[1].description and items[1].entry,
  "got " .. vim.inspect(items[1])
)
check(
  "completion_items: label contains author family + year for knuth1968",
  items[2].label:find("Knuth", 1, true) and items[2].label:find("1968", 1, true),
  "got " .. items[2].label
)

-- Filter by query: substring against key + author.family + title (case-insens).
do
  local hits = cite.completion_items("knu", { paths = { tmp_bib } })
  check(
    "completion_items: query 'knu' matches knuth1968 by key",
    #hits == 1 and hits[1].key == "knuth1968",
    "got " .. #hits .. " hits"
  )

  local by_author = cite.completion_items("smith", { paths = { tmp_bib } })
  check(
    "completion_items: query 'smith' matches by author family",
    #by_author == 1 and by_author[1].key == "smith2024",
    "got " .. #by_author .. " hits"
  )

  local by_title = cite.completion_items("recent paper", { paths = { tmp_bib } })
  check(
    "completion_items: query matches against title (case-insens)",
    #by_title == 1 and by_title[1].key == "smith2024",
    "got " .. #by_title .. " hits"
  )

  local none = cite.completion_items("nonexistent term", { paths = { tmp_bib } })
  check("completion_items: zero hits when nothing matches", #none == 0)
end

-- Dedup across multiple bib files: same key in two files → one item.
do
  local dup_bib = vim.fn.tempname() .. ".bib"
  local fd = io.open(dup_bib, "w")
  fd:write([[
@article{smith2024,
  author = {Smith, Foo},
  title  = {Different copy},
  year   = {2024}
}
]])
  fd:close()
  cite.clear_cache()
  local hits = cite.completion_items("smith", { paths = { tmp_bib, dup_bib } })
  check("completion_items: dedups same key across multiple bib files", #hits == 1, "got " .. #hits)
  vim.fn.delete(dup_bib)
end

-- find_bibliographies / find_cite_export — directive scanning.
do
  local text = [[
#+TITLE: Notes
#+bibliography: refs.bib
#+BIBLIOGRAPHY: papers.bib
#+cite_export: csl harvard
* Heading
some text [cite:@knuth1968].
]]
  local bibs = cite.find_bibliographies(text)
  check(
    "find_bibliographies: finds both directives (case-insens)",
    #bibs == 2,
    "got " .. #bibs .. ": " .. vim.inspect(bibs)
  )
  check("find_bibliographies: order preserved", bibs[1] == "refs.bib" and bibs[2] == "papers.bib")

  local style, proc = cite.find_cite_export(text)
  check(
    "find_cite_export: returns (style, processor)",
    style == "harvard" and proc == "csl",
    "got style=" .. tostring(style) .. " proc=" .. tostring(proc)
  )
end

vim.fn.delete(tmp_bib)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("cite_completion_test: PASS")
