-- find: the new `breadcrumb` column shows the outline path
-- (file → ancestor → ancestor → row) so users can disambiguate
-- same-titled rows under different parents.
-- Run via: nvim --headless -l tests/find_breadcrumb_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

-- Sample headline tree — two "Heading" rows under different parents.
-- The breadcrumb must distinguish them.
local SAMPLE = {
  { id = "p1", parent_id = nil, level = 1, title = "ProjectA", file_path = "/work.org" },
  { id = "p2", parent_id = nil, level = 1, title = "ProjectB", file_path = "/work.org" },
  { id = "h1", parent_id = "p1", level = 2, title = "Heading", file_path = "/work.org" },
  { id = "h2", parent_id = "p2", level = 2, title = "Heading", file_path = "/work.org" },
  { id = "n1", parent_id = "h1", level = 3, title = "Note", file_path = "/work.org" },
}

local find = require("organ.find")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- format_columns_segments with the breadcrumb column should compute
-- and emit the OLP. format_columns (plain string) should too.

-- Simulate what build_items does: pre-walk parents and store r.olp.
local function compute_olp(r, idx)
  local olp = {}
  local seen = {}
  local pid = r.parent_id
  while pid and not seen[pid] do
    seen[pid] = true
    local p = idx[pid]
    if not p then
      break
    end
    table.insert(olp, 1, p.title)
    pid = p.parent_id
  end
  return olp
end

local idx = {}
for _, r in ipairs(SAMPLE) do
  idx[r.id] = r
end

local h1 = SAMPLE[3]
h1.olp = compute_olp(h1, idx)
local h2 = SAMPLE[4]
h2.olp = compute_olp(h2, idx)
local n1 = SAMPLE[5]
n1.olp = compute_olp(n1, idx)

check("h1.olp = {ProjectA}", #h1.olp == 1 and h1.olp[1] == "ProjectA")
check("h2.olp = {ProjectB}", #h2.olp == 1 and h2.olp[1] == "ProjectB")
check(
  "n1.olp = {ProjectA, Heading}",
  #n1.olp == 2 and n1.olp[1] == "ProjectA" and n1.olp[2] == "Heading"
)

-- The breadcrumb renderer joins file basename + olp with "/"
-- (Emacs's `org-refile-use-outline-path = 'file` format).
local s_h1 = find.format_columns(h1, { "breadcrumb" })
check(
  "h1 breadcrumb: 'work.org/ProjectA'",
  s_h1:find("work.org/ProjectA", 1, true) ~= nil,
  "got: " .. s_h1
)
local s_h2 = find.format_columns(h2, { "breadcrumb" })
check(
  "h2 breadcrumb: 'work.org/ProjectB' (disambiguated)",
  s_h2:find("work.org/ProjectB", 1, true) ~= nil,
  "got: " .. s_h2
)
local s_n1 = find.format_columns(n1, { "breadcrumb" })
check(
  "n1 breadcrumb: 'work.org/ProjectA/Heading'",
  s_n1:find("work.org/ProjectA/Heading", 1, true) ~= nil,
  "got: " .. s_n1
)

-- Top-level row (no parents): breadcrumb is just the file basename.
local p1 = SAMPLE[1]
p1.olp = compute_olp(p1, idx)
local s_p1 = find.format_columns(p1, { "breadcrumb" })
check("top-level breadcrumb is just the file basename", s_p1 == "work.org", "got: " .. s_p1)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("find_breadcrumb_test: PASS")
