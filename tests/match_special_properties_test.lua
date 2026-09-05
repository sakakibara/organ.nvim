-- The org-match special properties over a real buffer: SCHEDULED,
-- DEADLINE, CLOSED and CATEGORY have to resolve from the entry's
-- planning line and category, not from its property drawer.
--
-- Every expectation below was taken from GNU Emacs 30.2 running
-- `org-map-entries` with the same query over the same file on
-- 2026-09-04, which is the day `now_override` pins here.
--
-- Run via: nvim --headless -l tests/match_special_properties_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local sparse = require("organ.sparse")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("organ").setup({
  db_path = tmp .. "/m.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  agenda = { now_override = "2026-09-04T10:00" },
})

local FIXTURE = {
  "#+CATEGORY: cat1",
  "* B1 :work:",
  "DEADLINE: <2026-08-01 Sat>",
  "* B2 :work:",
  "DEADLINE: <2026-12-01 Tue> SCHEDULED: <2026-09-01 Tue>",
  "* B3 :home:",
  "SCHEDULED: <2026-08-20 Thu>",
  "* B4",
  ":PROPERTIES:",
  ":CATEGORY: other",
  ":END:",
  "* B5",
  "CLOSED: [2026-09-02 Wed] SCHEDULED: <2026-09-03 Thu>",
}

local path = tmp .. "/cat1.org"
vim.fn.writefile(FIXTURE, path)
local buf = vim.fn.bufadd(path)
vim.fn.bufload(buf)
vim.bo[buf].filetype = "org"

local function matches(query)
  local pred = require("organ.match").predicate(query, { bufnr = buf })
  local hit = {}
  sparse._compute_visible(vim.api.nvim_buf_get_lines(buf, 0, -1, false), function(h)
    local ok = pred(h)
    if ok then
      hit[#hit + 1] = h.title
    end
    return ok
  end, buf)
  return table.concat(hit, " ")
end

-- Each pair is { query, the headings Emacs selects }.
local CASES = {
  { 'DEADLINE=""', "B3 B4 B5" },
  { 'DEADLINE<>""', "B1 B2" },
  { 'DEADLINE=*""', "" },
  { 'SCHEDULED=""', "B1 B4" },
  { 'CLOSED=""', "B1 B2 B3 B4" },
  { 'CLOSED<>""', "B5" },
  { 'DEADLINE<"<today>"', "B1" },
  { 'DEADLINE<"<2026-09-03 Thu>"', "B1" },
  { 'SCHEDULED>="<-1w>"', "B2 B5" },
  { "DEADLINE={2026}", "B1 B2" },
  { 'CATEGORY="cat1"', "B1 B2 B3 B5" },
  { 'CATEGORY<>"cat1"', "B4" },
  { 'CATEGORY="other"', "B4" },
  { 'PRIORITY="B"', "B1 B2 B3 B4 B5" },
  { "ITEM={B}", "B1 B2 B3 B4 B5" },
}

for _, case in ipairs(CASES) do
  local query, want = case[1], case[2]
  local got = matches(query)
  assert(got == want, string.format("%s\nwant %q\ngot  %q", query, want, got))
end

-- A `:CATEGORY:` property covers the whole subtree, and a file with no
-- `#+CATEGORY:` keyword at all reads as its own basename.
do
  local nested = tmp .. "/nested.org"
  vim.fn.writefile({
    "#+CATEGORY: cat1",
    "* P1",
    ":PROPERTIES:",
    ":CATEGORY: sub",
    ":END:",
    "** C1",
    "* P2",
    "** C2",
  }, nested)
  local plain = tmp .. "/plainfile.org"
  vim.fn.writefile({ "* N1", "** N2" }, plain)
  local function in_file(file, query)
    local b = vim.fn.bufadd(file)
    vim.fn.bufload(b)
    vim.bo[b].filetype = "org"
    local pred = require("organ.match").predicate(query, { bufnr = b })
    local hit = {}
    sparse._compute_visible(vim.api.nvim_buf_get_lines(b, 0, -1, false), function(h)
      if pred(h) then
        hit[#hit + 1] = h.title
      end
      return false
    end, b)
    return table.concat(hit, " ")
  end
  assert(in_file(nested, 'CATEGORY="sub"') == "P1 C1", "subtree inherits :CATEGORY:")
  assert(in_file(nested, 'CATEGORY="cat1"') == "P2 C2", "the rest falls back to #+CATEGORY:")
  assert(in_file(plain, 'CATEGORY="plainfile"') == "N1 N2", "basename fallback")
end

-- The same queries over indexed agenda rows (`:Org agenda tags ...`),
-- which carry their planning and category on different fields than a
-- sparse-tree record does.
require("organ.indexer").index_file_sync(path)
local rows = require("organ.query").agenda({ files = { path }, include_properties = true })
assert(#rows == 5, "indexed " .. #rows .. " rows")

local function row_matches(query)
  local pred = require("organ.match").predicate(query)
  local hit = {}
  for _, r in ipairs(rows) do
    if pred(r) then
      hit[#hit + 1] = r.title
    end
  end
  table.sort(hit)
  return table.concat(hit, " ")
end

for _, case in ipairs(CASES) do
  local query, want = case[1], case[2]
  local got = row_matches(query)
  assert(got == want, string.format("agenda row %s\nwant %q\ngot  %q", query, want, got))
end

vim.fn.delete(tmp, "rf")
io.write("match special properties ok\n")
os.exit(0)
