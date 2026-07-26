-- Performance budgets for hot paths.
--
-- These are LOOSE budgets — they don't enforce a target, they catch a
-- 5-10× regression. The numbers come from measuring "feels good" in
-- interactive use:
--   * Agenda render < 80ms with 100 rows  (target ~16ms; 80ms is the
--     "noticeable lag" boundary; bigger means user feels keystrokes
--     bunch up)
--   * Identical-refresh < 5ms              (must be near-free; this
--     fires on every keypress in the agenda)
--   * Single-row toggle refresh < 30ms     (one extmark + one line write)
--   * Find/snacks item building < 50ms for 500 rows
--
-- Synthetic data; no real files / DB. So the test runs fast everywhere.
--
-- Run via: nvim --headless -l tests/perf_budget_test.lua
--
-- Reports actual measurements so regressions are visible even when the
-- budget hasn't been crossed.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Time a function in milliseconds. Discard the first call (JIT / module
-- load); average the next N. Returns the mean ms.
local function bench(fn, samples)
  fn() -- warm-up
  samples = samples or 5
  local t = vim.uv.hrtime()
  for _ = 1, samples do
    fn()
  end
  local elapsed_ns = vim.uv.hrtime() - t
  return (elapsed_ns / samples) / 1e6 -- ms
end

-- Synth dataset
local NUM_ROWS = 100
local rows = {}
for i = 1, NUM_ROWS do
  rows[i] = {
    id = ("h%d"):format(i),
    file_path = ("/tmp/file%d.org"):format((i % 10) + 1),
    title = ("Headline number %d"):format(i),
    line_start = i * 4,
    level = 1 + (i % 3),
    todo_state = (i % 3 == 0) and "DONE" or "TODO",
    priority = (i % 5 == 0) and "A" or nil,
    tags = (i % 4 == 0) and { "work" } or {},
  }
end

package.loaded["organ.query"] = {
  agenda = function()
    return rows
  end,
  headlines = function()
    return rows
  end,
  files = function()
    return {}
  end,
  links = function()
    return {}
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  agenda = {
    views = {
      perf = {
        blocks = {
          {
            source = "headlines",
            title = "All",
            line_format = "{title} [{todo_state}]",
          },
        },
      },
    },
  },
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
})

-- 1. Agenda full render: 100 rows, cold start.
local agenda = require("organ.agenda")

local ms_open = bench(function()
  agenda.open({ name = "perf" })
  vim.cmd("silent! bwipeout!")
end, 5)
print(string.format("       agenda.open(100 rows): %.2f ms", ms_open))
check("perf: agenda.open with 100 rows < 80ms", ms_open < 80, string.format("got %.2f ms", ms_open))

-- 2. Identical refresh: no rows changed → must short-circuit.
agenda.open({ name = "perf" })
local agenda_buf = vim.api.nvim_get_current_buf()

local ms_identical = bench(function()
  agenda.refresh(agenda_buf)
end, 10)
print(string.format("       agenda.refresh(no change): %.2f ms", ms_identical))
check(
  "perf: identical refresh < 5ms (must short-circuit)",
  ms_identical < 5,
  string.format("got %.2f ms", ms_identical)
)

-- 3. Single-row toggle refresh: change one row's todo state.
local toggle_idx = 1
local ms_toggle = bench(function()
  toggle_idx = toggle_idx + 1
  rows[toggle_idx % NUM_ROWS + 1].todo_state = rows[toggle_idx % NUM_ROWS + 1].todo_state == "TODO"
      and "NEXT"
    or "TODO"
  agenda.refresh(agenda_buf)
end, 10)
print(string.format("       agenda.refresh(1 row changed): %.2f ms", ms_toggle))
check(
  "perf: single-row toggle refresh < 30ms",
  ms_toggle < 30,
  string.format("got %.2f ms", ms_toggle)
)

-- 4. Find backend item shaping (snacks): 500 rows.
local big_rows = {}
for i = 1, 500 do
  big_rows[i] = {
    id = ("b%d"):format(i),
    file_path = "/tmp/x.org",
    title = ("Big headline %d with extra body text"):format(i),
    line_start = i * 4,
    level = 1,
    todo_state = "TODO",
  }
end
package.loaded["organ.query"].headlines = function()
  return big_rows
end
package.loaded["snacks.picker"] = {
  pick = function(_opts) end, -- no-op, we measure item construction
}
local find = require("organ.find")
local ms_find = bench(function()
  find.pick("headlines", { backend = "snacks" })
end, 5)
print(string.format("       find.pick snacks (500 rows): %.2f ms", ms_find))
check(
  "perf: snacks find shaping for 500 rows < 50ms",
  ms_find < 50,
  string.format("got %.2f ms", ms_find)
)

-- 5. Cite parse: 200 cites in a paragraph. Hot path during export.
local cite = require("organ.cite")
local big_text = {}
for i = 1, 200 do
  big_text[#big_text + 1] = "[cite:@key" .. i .. "]"
end
local cite_blob = "preamble " .. table.concat(big_text, " between ") .. " end"

local ms_cite = bench(function()
  cite.scan(cite_blob)
end, 5)
print(string.format("       cite.scan(200 cites): %.2f ms", ms_cite))
check("perf: cite.scan 200 cites < 25ms", ms_cite < 25, string.format("got %.2f ms", ms_cite))

-- 6. Indexer single-file extract: 100-headline org file. Hot path on every
--    save — must be fast enough that the user doesn't feel the lag.
local parser_path = require("organ.defaults").parser_path
if vim.fn.filereadable(parser_path) == 1 then
  local doc_lines = {}
  for i = 1, 100 do
    doc_lines[#doc_lines + 1] = string.format("* TODO Headline number %d :tag%d:", i, i % 5)
    doc_lines[#doc_lines + 1] = "  :PROPERTIES:"
    doc_lines[#doc_lines + 1] = string.format("  :ID: id-%d-abcdef", i)
    doc_lines[#doc_lines + 1] = "  :END:"
    doc_lines[#doc_lines + 1] = "  body of the headline; one paragraph here."
  end
  local doc_src = table.concat(doc_lines, "\n") .. "\n"

  local indexer = require("organ.indexer")
  local ms_index = bench(function()
    indexer.extract(doc_src, "/tmp/perf.org", parser_path)
  end, 5)
  print(string.format("       indexer.extract(100 headlines): %.2f ms", ms_index))
  check(
    "perf: indexer.extract 100-headline file < 100ms",
    ms_index < 100,
    string.format("got %.2f ms", ms_index)
  )
else
  print("       (indexer perf skipped: parser not installed)")
end

-- 7. Query.headlines on a stub-backed dataset of 1000 rows. The pure
--    iteration / row-shaping cost — DB cost is on top in real use.
local query_rows = {}
for i = 1, 1000 do
  query_rows[i] = {
    id = ("q%d"):format(i),
    file_path = "/tmp/q.org",
    title = "Row " .. i,
    line_start = i * 4,
    level = 1,
    todo_state = (i % 2 == 0) and "TODO" or "DONE",
  }
end
package.loaded["organ.query"].headlines = function()
  return query_rows
end
local ms_iter = bench(function()
  local out = {}
  for _, r in ipairs(package.loaded["organ.query"].headlines()) do
    if r.todo_state == "TODO" then
      out[#out + 1] = r
    end
  end
end, 10)
print(string.format("       headlines + filter (1000 rows): %.2f ms", ms_iter))
check("perf: 1000-row iteration + filter < 5ms", ms_iter < 5, string.format("got %.2f ms", ms_iter))

print()
if fails > 0 then
  print("FAILED " .. fails .. " perf budgets")
  os.exit(1)
end
print("perf_budget_test: PASS")
