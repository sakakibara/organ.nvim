-- Tests for Phase 4: backlink count column in OrgFind results.
-- Fixture: 05-links.org (Alpha→Beta, Beta→Alpha; Gamma has no inbound).
-- Run via: nvim --headless -l tests/find_backlinks_column_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
vim.fn.system({ "cp", root .. "/tests/fixtures/05-links.org", org_dir .. "/05.org" })

require("organ").setup({
  db_path = tmp .. "/bl.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = {
    backend = "_test_stub",
    columns = { "title", "backlinks" },
    match_fields = { "title" },
  },
})
require("organ").scan_blocking(org_dir, 5000)

local find = require("organ.find")
local query = require("organ.query")

-- 1. hydrate_backlink_counts via query.headlines.
do
  local rows = query.headlines({ include_backlink_counts = true })
  local by_id = {}
  for _, r in ipairs(rows) do
    by_id[r.id] = r
  end

  -- Alpha is linked TO by Beta (id:alpha-id in Beta body) → count = 1.
  local alpha = by_id["alpha-id"]
  assert(alpha, "alpha not found in rows")
  assert(
    alpha.backlink_count == 1,
    "expected alpha backlink_count = 1; got " .. tostring(alpha.backlink_count)
  )

  -- Beta is linked TO by Alpha (id:beta-id in Alpha body) → count = 1.
  local beta = by_id["beta-id"]
  assert(beta, "beta not found in rows")
  assert(
    beta.backlink_count == 1,
    "expected beta backlink_count = 1; got " .. tostring(beta.backlink_count)
  )

  -- Gamma has no inbound id-links → count = 0.
  local gamma = by_id["gamma-id"]
  assert(gamma, "gamma not found in rows")
  assert(
    gamma.backlink_count == 0,
    "expected gamma backlink_count = 0; got " .. tostring(gamma.backlink_count)
  )
end

-- 2. find.format_columns renders backlinks column correctly.
do
  local rec_with = {
    title = "Beta",
    backlink_count = 1,
    file_path = "/x.org",
    line_start = 0,
    tags = {},
    level = 1,
    todo_state = nil,
    priority = nil,
  }
  local s = find.format_columns(rec_with, { "title", "backlinks" })
  assert(s:find("Beta", 1, true), "title in display: " .. s)
  assert(
    s:find("\xe2\x86\x901", 1, true) or s:find("(", 1, true),
    "backlink indicator in display: " .. s
  )

  local rec_zero = {
    title = "Gamma",
    backlink_count = 0,
    file_path = "/x.org",
    line_start = 0,
    tags = {},
    level = 1,
    todo_state = nil,
    priority = nil,
  }
  local s0 = find.format_columns(rec_zero, { "title", "backlinks" })
  assert(s0 == "Gamma", "zero backlinks should not add indicator; got: " .. s0)
end

-- 3. find.pick with backlinks column hydrates counts and passes them to items.
do
  local backend_stub = require("organ.find.backend")._test_stub
  backend_stub.last = nil

  find.pick({ source = "headlines", filter = {}, default_action = "jump" })

  local last = backend_stub.last
  assert(last and last.items, "stub should have received items")

  local by_title = {}
  for _, item in ipairs(last.items) do
    by_title[item.title] = item
  end

  local alpha_item = by_title["Alpha"]
  assert(alpha_item, "Alpha item missing")
  assert(
    type(alpha_item.backlink_count) == "number",
    "backlink_count should be a number; got " .. type(alpha_item.backlink_count)
  )
  assert(
    alpha_item.backlink_count >= 1,
    "Alpha should have >= 1 backlink; got " .. tostring(alpha_item.backlink_count)
  )

  local gamma_item = by_title["Gamma Section"]
  assert(gamma_item, "Gamma item missing")
  assert(
    gamma_item.backlink_count == 0,
    "Gamma should have 0 backlinks; got " .. tostring(gamma_item.backlink_count)
  )
end

-- 4. defaults.lua includes "backlinks" in find.columns.
do
  local defaults = require("organ.defaults")
  local found = false
  for _, col in ipairs(defaults.find.columns) do
    if col == "backlinks" then
      found = true
      break
    end
  end
  assert(
    found,
    "'backlinks' not found in defaults.find.columns: " .. vim.inspect(defaults.find.columns)
  )
end

vim.fn.delete(tmp, "rf")
io.write("find backlinks column ok\n")
os.exit(0)
