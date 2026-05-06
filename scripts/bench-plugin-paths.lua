-- Benchmark plugin-level hot paths against a synthetic org corpus.
-- Run via: nvim --headless -l scripts/bench-plugin-paths.lua [N_FILES] [HEADLINES_PER_FILE]

local n_files     = tonumber(arg[1]) or 200
local per_file    = tonumber(arg[2]) or 50

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local function make_corpus(dir)
  vim.fn.mkdir(dir, "p")
  for i = 1, n_files do
    local path = string.format("%s/n%04d.org", dir, i)
    local fh = assert(io.open(path, "w"))
    fh:write("#+TITLE: Note ", i, "\n")
    fh:write("#+FILETAGS: :proj_", (i % 7), ":\n\n")
    for j = 1, per_file do
      local kw = ({ "TODO", "DONE", "WAITING", "TODO" })[(j % 4) + 1]
      local pri = (j % 5 == 0) and "[#A] " or ""
      local sched = (j % 3 == 0)
        and string.format("SCHEDULED: <2026-05-%02d>\n",
            math.max(1, math.min(28, j)))
        or ""
      fh:write(string.format("* %s %sHeadline %d-%d :tag%d:\n%s",
        kw, pri, i, j, j % 5, sched))
      fh:write("Some body text. With a [[file:other.org][link]] and *bold*.\n")
      fh:write("Another paragraph for line count. ", string.rep("x ", 20), "\n\n")
    end
    fh:close()
  end
end

local function bench(label, n, fn)
  collectgarbage("collect")
  local t0 = vim.uv.hrtime()
  for _ = 1, n do fn() end
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  io.write(string.format("  %-40s %6d run(s)  %9.2f ms  (avg %7.3f ms)\n",
    label, n, elapsed_ms, elapsed_ms / n))
  return elapsed_ms / n
end

-- Setup
local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
make_corpus(org_dir)
io.write(string.format("corpus: %d files * %d headlines = %d total\n",
  n_files, per_file, n_files * per_file))

dofile(root .. "/plugin/organ.lua")
require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

io.write("\n== Phase 1: cold scan (file -> tree-sitter -> SQLite) ==\n")
local t0 = vim.uv.hrtime()
require("organ").scan_blocking(org_dir, 60000)
io.write(string.format("  scan_blocking:                                       %9.2f ms\n",
  (vim.uv.hrtime() - t0) / 1e6))

io.write("\n== Phase 2: agenda views (open + render full path) ==\n")
local agenda = require("organ.agenda")
local function open_and_close(view_name)
  local b = agenda.open({ name = view_name })
  if b and vim.api.nvim_buf_is_valid(b) then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end
bench("agenda overview open", 10, function() open_and_close("overview") end)
bench("agenda todos open",    10, function() open_and_close("todos") end)
bench("agenda today open",    10, function() open_and_close("today") end)

io.write("\n== Phase 3: query layer ==\n")
local query = require("organ.query")
bench("query.headlines all", 50, function()
  return query.headlines({})
end)
bench("query.headlines TODO-only", 50, function()
  return query.headlines({ todo = { include = { "TODO" } } })
end)
bench("query.headlines tag filter", 50, function()
  return query.headlines({ tags = { include = { "tag1" } } })
end)

io.write("\n== Phase 4: incremental rescan (no body change) ==\n")
local indexer = require("organ.indexer")
local sample_path = org_dir .. "/n0001.org"
bench("index_file_sync (re-index, hash-skip)", 50, function()
  indexer.index_file_sync(sample_path)
end)

-- Make a file dirty (touch + tiny edit) and time a full re-index.
local fh = io.open(sample_path, "a"); fh:write("\n* TODO Extra\n"); fh:close()
bench("index_file_sync (changed body)", 20, function()
  indexer.index_file_sync(sample_path)
end)

io.write("\nDone.\n")
