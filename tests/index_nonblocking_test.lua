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

-- One large file (~600 headings ~5000 lines): a synchronous extract of
-- this blocks ~90-150ms; sliced, its largest slice is the (unchunkable)
-- DB-write transaction, a fraction of that.
vim.fn.writefile(big_file(600), tmp .. "/big.org")

local organ = require("organ")
organ.setup({
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  db_path = tmp .. "/organ.db",
  -- Disable the mtime/hash short-circuits so re-enqueuing the same file
  -- genuinely re-indexes it: this test indexes it twice (a synchronous
  -- baseline, then the cooperative path) and needs both to do real work.
  incremental = false,
  mtime_skip = false,
  hash_skip = false,
})

local queue = require("organ.queue")

-- Index big.org once at the given walk-slice budget and return the largest
-- main-thread slice and the slice count.  `write_body` deletes the file's
-- prior rows first, so re-indexing is idempotent (headline count stays 600).
local function index_once(budget_ms)
  organ.config.scan_budget_ms = budget_ms
  organ._index_stats.max_slice_ms = 0
  organ._index_stats.slices = 0
  queue.enqueue_background(tmp .. "/big.org")
  assert(
    vim.wait(30000, function()
      return queue.is_empty()
    end, 10),
    "indexing did not finish"
  )
  return organ._index_stats.max_slice_ms, organ._index_stats.slices
end

-- Baseline: a huge budget makes the extract walk never yield, so the whole
-- walk runs as one synchronous slice -- the blocking cost we're guarding
-- against, measured on THIS machine right now.
local sync_ms, sync_slices = index_once(1e9)
-- Cooperative: the real 8ms budget splits the walk into many slices.
local coop_ms, coop_slices = index_once(8)

print(
  string.format(
    "synchronous: %.1fms / %d slices    cooperative: %.1fms / %d slices    ratio %.2f",
    sync_ms,
    sync_slices,
    coop_ms,
    coop_slices,
    coop_ms / sync_ms
  )
)

-- The cooperative walk must produce many more slices than the synchronous
-- one (which is parse + one walk slice + DB write).
check(
  "cooperative indexing splits the walk into many slices",
  coop_slices >= 5 and coop_slices > sync_slices,
  string.format("cooperative=%d, synchronous=%d", coop_slices, sync_slices)
)

-- Self-calibrating headroom check: the cooperative path's largest slice must
-- stay well below a synchronous index of the same file on the same runner.
-- Observed ratio is ~0.4 (the unchunkable DB-write transaction vs the whole
-- walk); a regression to synchronous extraction drives it to ~1.0.  Both
-- measurements share the runner, so load inflates them together and the
-- ratio -- not an absolute millisecond ceiling -- is what's asserted, which
-- is why this no longer flakes on a loaded CI box.
local MAX_RATIO = 0.7
check(
  "cooperative slicing keeps the max slice well below a synchronous index",
  coop_ms < sync_ms * MAX_RATIO,
  string.format(
    "cooperative %.1fms vs synchronous %.1fms (ratio %.2f, limit %.2f)",
    coop_ms,
    sync_ms,
    coop_ms / sync_ms,
    MAX_RATIO
  )
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
