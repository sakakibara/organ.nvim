-- `refile.targets` + `refile.use_outline_path` mirror Emacs `org-refile-
-- targets` + `org-refile-use-outline-path`.  We test the filter
-- assembly logic by stubbing `find.pick` to capture the filter dict
-- the refile command builds — exhaustive E2E refile-flow coverage
-- already lives in tests/refile_to_index_e2e_test.lua.
--
-- Run via: nvim --headless -l tests/refile_targets_test.lua

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

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  agenda_files = { "/tmp/work.org", "/tmp/personal.org" },
})

-- OrgRefile builds a `capture_ctx` that calls `expand("<cword>")` —
-- that fails in a headless empty buffer.  Put a non-empty line under
-- the cursor so capture_ctx succeeds.
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "* TODO Source heading" })
vim.api.nvim_win_set_cursor(0, { 1, 5 })

-- Stub out `find.pick` and `find.make_refile_action` so OrgRefile's
-- filter-assembly path runs in isolation.
local captured
package.loaded["organ.find"] = {
  pick = function(opts)
    captured = opts
  end,
  make_refile_action = function()
    return function() end
  end,
}
local cmd = {
  OrgRefile = require("organ.refile").commands.refile.fn,
}

-- Stub agenda.resolve_agenda_files because the real one walks the
-- file system and skips paths that don't exist.
require("organ.agenda").resolve_agenda_files = function(spec)
  if type(spec) == "table" then
    return spec
  end
  if spec == nil then
    return nil
  end
  return { spec }
end

-- (a) No `refile.targets`: filter is empty (every indexed headline).
require("organ").config.refile = nil
captured = nil
cmd.OrgRefile()
check(
  "no targets: empty filter (all-headlines fallback)",
  captured and next(captured.filter) == nil,
  "filter: " .. vim.inspect(captured and captured.filter)
)

-- (b) `targets = { { files = "agenda_files", max_level = 3 } }`.
require("organ").config.refile = {
  targets = { { files = "agenda_files", max_level = 3 } },
}
captured = nil
cmd.OrgRefile()
check(
  "agenda_files target: filter.files populated from config.agenda_files",
  captured
    and captured.filter.files
    and #captured.filter.files == 2
    and vim.tbl_contains(captured.filter.files, "/tmp/work.org")
    and vim.tbl_contains(captured.filter.files, "/tmp/personal.org"),
  "filter.files: " .. vim.inspect(captured and captured.filter.files)
)
check(
  "max_level=3: filter.level.max=3",
  captured and captured.filter.level and captured.filter.level.max == 3,
  "filter.level: " .. vim.inspect(captured and captured.filter.level)
)

-- (c) Multiple rules union.
require("organ").config.refile = {
  targets = {
    { files = { "/tmp/notes.org" }, max_level = 2 },
    { files = { "/tmp/inbox.org" }, max_level = 5 },
  },
}
captured = nil
cmd.OrgRefile()
local files_set = {}
for _, p in ipairs(captured.filter.files or {}) do
  files_set[p] = true
end
check(
  "multiple rules: files set is the union",
  files_set["/tmp/notes.org"] and files_set["/tmp/inbox.org"]
)
check(
  "multiple rules: max_level is the maximum across rules",
  captured.filter.level and captured.filter.level.max == 5,
  "filter.level: " .. vim.inspect(captured.filter.level)
)

-- (d) `use_outline_path = "file"` — picker columns include `path`,
-- not `breadcrumb`.
require("organ").config.refile = { use_outline_path = "file" }
captured = nil
cmd.OrgRefile()
local has_path, has_breadcrumb = false, false
for _, c in ipairs(captured.columns or {}) do
  if c == "path" then
    has_path = true
  end
  if c == "breadcrumb" then
    has_breadcrumb = true
  end
end
check(
  "use_outline_path='file': picker uses 'path' column, not 'breadcrumb'",
  has_path and not has_breadcrumb,
  "cols: " .. vim.inspect(captured.columns)
)

-- (e) `use_outline_path = "outline"` (default) — breadcrumb column.
require("organ").config.refile = { use_outline_path = "outline" }
captured = nil
cmd.OrgRefile()
local has_breadcrumb_d = false
for _, c in ipairs(captured.columns or {}) do
  if c == "breadcrumb" then
    has_breadcrumb_d = true
  end
end
check(
  "use_outline_path='outline': picker uses 'breadcrumb' column",
  has_breadcrumb_d,
  "cols: " .. vim.inspect(captured.columns)
)

require("organ").config.refile = nil

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("refile_targets_test: PASS")
