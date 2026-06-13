-- Regression: file indexing must never block the UI thread in one shot.
-- The cooperative indexer parses off the main thread and time-slices the
-- extract walk, so a large file is indexed across many short slices
-- rather than one synchronous extract (which froze the UI ~150ms+ per
-- file, recurring on every startup scan / save / rescan).
--
-- Bounds: the largest single main-thread slice stays well under a
-- synchronous extract, and a large file is split into many slices.
--
-- Run via: nvim --headless -l tests/index_nonblocking_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = "/tmp/organ_index_nonblocking"
vim.fn.delete(tmp, "rf")
vim.fn.mkdir(tmp, "p")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local link = "[[https://example.com/page][see this]]"
local sentence = "Some *bold* and /italic/ with " .. link .. " and another " .. link .. ". "
local function big_file(n_headings)
  local l = {}
  for i = 1, n_headings do
    l[#l + 1] = "* TODO Heading " .. i .. " :tag:"
    l[#l + 1] = "SCHEDULED: <2026-06-09 Tue>"
    for _ = 1, 6 do
      l[#l + 1] = sentence
    end
  end
  return l
end

-- One large file (~600 headings ~5000 lines) -- a synchronous extract of
-- this blocks ~150ms; sliced, no single slice should come close.
vim.fn.writefile(big_file(600), tmp .. "/big.org")

local organ = require("organ")
organ.setup({
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  db_path = tmp .. "/organ.db",
})

organ._index_stats.max_slice_ms = 0
organ._index_stats.slices = 0

local queue = require("organ.queue")
queue.enqueue_background(tmp .. "/big.org")

assert(
  vim.wait(30000, function()
    return queue.is_empty()
  end, 10),
  "indexing did not finish"
)

local stats = organ._index_stats
print(
  string.format("max main-thread slice: %.1fms over %d slices", stats.max_slice_ms, stats.slices)
)

-- The big file must be split into many cooperative slices, not indexed in
-- one blocking call.
check("indexing was chunked into many slices", stats.slices >= 5, "slices = " .. stats.slices)

-- No single slice should approach a synchronous extract (~150ms). 60ms is
-- generous headroom over the observed ~20-40ms (DB write is the largest
-- slice) while still catching a regression to synchronous extraction.
check(
  "no main-thread slice >= 60ms",
  stats.max_slice_ms < 60,
  string.format("max slice = %.1fms", stats.max_slice_ms)
)

-- Correctness: the file was actually indexed. Query by the canonical
-- path the indexer stores under -- on macOS /tmp resolves to /private/tmp,
-- so the raw path would miss the row the symlink-resolved write created.
local h = require("organ.runtime").db()
local s = assert(h:prepare("SELECT COUNT(*) FROM headlines WHERE file_path = ?"))
s:bind_text(1, require("organ.path").canonical(tmp .. "/big.org") or (tmp .. "/big.org"))
assert(s:step())
local n = s:column_int(0)
s:finalize()
check("all headlines indexed", n >= 600, "headlines = " .. n)

if fails > 0 then
  error(fails .. " check(s) failed")
end
print("\nAll checks passed.")
