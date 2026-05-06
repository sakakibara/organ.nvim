-- End-to-end highlight test: parses a fixture .org file, walks the
-- highlights query exactly like the treesitter highlighter does
-- (via vim.treesitter.get_range + metadata[capture]), and asserts
-- which captures cover which buffer rows.
--
-- Catches the class of bugs we hit:
--   - @org.heading.N spanning the whole subtree (heading capture wasn't
--     narrowed to the heading line via the org-heading-line! directive)
--   - @org.todo.<kw> not registered (per-keyword directive rewrites
--     @org.todo.active to a name with no link)
--   - Per-keyword captures suppressing parent heading captures
--
-- Run via: nvim --headless -l tests/highlights_render_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Make the parsers discoverable. Probes (in order):
--   1. The user's installed location (post-`grammar_install.install()`)
--   2. The dev build directory next to organ.nvim's source tree
local function find_parser()
  local plat = (vim.uv.os_uname().sysname or ""):lower() .. "-" .. (vim.uv.os_uname().machine or "")
  local candidates = {
    vim.fn.stdpath("data") .. "/organ/parser/org.so",
  }
  -- Walk up from cwd looking for a tree-sitter-organ sibling
  local cwd = vim.fn.getcwd()
  for _, base in ipairs({ cwd, vim.fn.fnamemodify(cwd, ":h"), vim.fn.fnamemodify(cwd, ":h:h") }) do
    candidates[#candidates + 1] = base .. "/tree-sitter-organ/build/" .. plat .. "/org.so"
  end
  for _, p in ipairs(candidates) do
    if vim.uv.fs_stat(p) then
      return p
    end
  end
  return nil
end

local org_so = find_parser()
if org_so then
  pcall(vim.treesitter.language.add, "org", { path = org_so })
else
  print(
    "SKIP: no org.so parser available — run `:lua require('organ.grammar_install').install()` first"
  )
  os.exit(0)
end

require("organ.treesitter_directives").register()
require("organ").setup({
  org_dir = "/tmp",
  todo = { sequence = { "TODO", "NEXT", "WAITING", "HOLD", "PROJ", "|", "DONE", "CANCELLED" } },
})

-- Fixture: covers heading levels 1-3, body lines, an active TODO, a done
-- TODO, and nested headings. Each scenario gets its own row so we can
-- assert per-row.
local fixture = {
  "* Top heading", -- row 0  (heading L1)
  "Body of top heading.", -- row 1  (body, NOT heading)
  "** Sub heading", -- row 2  (heading L2)
  "Body of sub.", -- row 3  (body)
  "*** DONE Done thing", -- row 4  (heading L3 + DONE keyword)
  "Body of done.", -- row 5  (body)
  "*** NEXT Active thing", -- row 6  (heading L3 + NEXT keyword)
  "Body of active.", -- row 7  (body)
}

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, fixture)
vim.bo[bufnr].filetype = "org"
local parser = vim.treesitter.get_parser(bufnr, "org")
parser:parse(true)

local query = vim.treesitter.query.get("org", "highlights")
assert(query, "highlights query loaded")

-- Compute effective captures per row, mirroring the highlighter's
-- range-resolution logic (vim.treesitter.get_range with metadata).
local per_row = {}
for cid, node, metadata, _ in query:iter_captures(parser:trees()[1]:root(), bufnr, 0, -1) do
  local name = query.captures[cid]
  local r = vim.treesitter.get_range(node, bufnr, metadata and metadata[cid])
  -- Range6: { sr, sc, sb, er, ec, eb }
  local sr, er, ec = r[1], r[4], r[5]
  -- Range covers rows sr..er. If ec == 0, the end is exclusive at row er.
  for row = sr, (ec == 0 and er - 1 or er) do
    per_row[row] = per_row[row] or {}
    per_row[row][name] = true
  end
end

local function has(row, capture_substr)
  local caps = per_row[row] or {}
  for name in pairs(caps) do
    if name:find(capture_substr, 1, true) then
      return true
    end
  end
  return false
end

local fails = 0
local function check(label, ok)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label)
  end
end

-- Heading rows have heading captures
check("row 0 (* Top): has @org.heading.1", has(0, "org.heading.1"))
check("row 2 (** Sub): has @org.heading.2", has(2, "org.heading.2"))
check("row 4 (*** DONE): has @org.heading.3", has(4, "org.heading.3"))
check("row 6 (*** NEXT): has @org.heading.3", has(6, "org.heading.3"))

-- Body rows MUST NOT have any @org.heading capture (this is the bug
-- where (headline) spans the whole subtree without the directive)
check("row 1 (body of top): NO @org.heading", not has(1, "org.heading"))
check("row 3 (body of sub): NO @org.heading", not has(3, "org.heading"))
check("row 5 (body of done): NO @org.heading", not has(5, "org.heading"))
check("row 7 (body of active): NO @org.heading", not has(7, "org.heading"))

-- TODO captures fire on the right rows
check("row 4 (DONE): has @org.todo.done", has(4, "org.todo.done"))
check("row 6 (NEXT): has @org.todo.active", has(6, "org.todo.active"))

-- Nested headings: row 2 (** Sub) should NOT have @org.heading.1 of
-- the top heading bleeding into it (without the narrowing, it would).
check("row 2 (** Sub): NO @org.heading.1 bleed", not has(2, "org.heading.1"))
check("row 4 (*** DONE): NO @org.heading.1 bleed", not has(4, "org.heading.1"))
check("row 4 (*** DONE): NO @org.heading.2 bleed", not has(4, "org.heading.2"))

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("highlights_render_test: PASS")
