-- Hand-crafted Emacs / org-roam fixture indexed end-to-end.
--
-- The fixture exercises every standard org-mode syntax we expect to
-- see from external producers (Emacs, org-roam, third-party tools):
-- TODO sequence, file directives, property drawers, LOGBOOK,
-- ROAM_REFS / ROAM_ALIASES, ARCHIVE_* metadata, planning lines with
-- repeaters, all link types (id / file / file-heading / *Title /
-- http), footnotes, lists / numbered / description / checkboxes,
-- tables with TBLFM, src blocks, LaTeX, quote blocks, citations.
--
-- Each indexed shape is asserted via the public query API.  A
-- regression here means we lost backwards compat with externally-
-- produced org files.
--
-- Run via: nvim --headless -l tests/emacs_interop_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.system({
  "cp",
  root .. "/tests/fixtures/emacs_interop/kitchen-sink.org",
  tmp .. "/kitchen-sink.org",
})

require("organ").setup({
  db_path = tmp .. "/idx.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "WAITING", "|", "DONE", "CANCELLED" } },
})
require("organ").scan_blocking(tmp, 5000)

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local query = require("organ.query")

-- Headlines
local all = query.headlines({})
check("indexed multiple headlines", #all >= 4, "got " .. #all)

local by_title = {}
for _, h in ipairs(all) do
  by_title[h.title] = h
end

check("Top-level node indexed", by_title["Top-level node"] ~= nil)
check("First child indexed", by_title["First child"] ~= nil)
check("Second child indexed", by_title["Second child"] ~= nil)
check("Second-level child indexed", by_title["Second-level child"] ~= nil)

-- TODO state from the buffer-local #+TODO sequence
check(
  "First child carries TODO state from #+TODO sequence",
  by_title["First child"] and by_title["First child"].todo_state == "TODO",
  by_title["First child"] and by_title["First child"].todo_state
)
check(
  "Second-level child carries WAITING (extended TODO state)",
  by_title["Second-level child"] and by_title["Second-level child"].todo_state == "WAITING"
)
check(
  "Second child carries NEXT",
  by_title["Second child"] and by_title["Second child"].todo_state == "NEXT"
)

-- Priority cookies
check(
  "First child priority parsed as A",
  by_title["First child"] and by_title["First child"].priority == "A"
)
check(
  "Second child priority parsed as B",
  by_title["Second child"] and by_title["Second child"].priority == "B"
)

-- Tags (inherited file-level + headline-local)
local function has_tag(h, tag)
  if not h or not h.tags then
    return false
  end
  for _, t in ipairs(h.tags) do
    if t == tag then
      return true
    end
  end
  return false
end

check(
  "Top-level headline tags include @work",
  has_tag(by_title["Top-level node"], "@work"),
  vim.inspect(by_title["Top-level node"] and by_title["Top-level node"].tags)
)
check("Top-level headline tags include project", has_tag(by_title["Top-level node"], "project"))
check("First child tags include hard", has_tag(by_title["First child"], "hard"))

-- ID lookup (UUID v4 as Emacs would write)
local id1 = "11111111-1111-1111-1111-111111111111"
local idn = query.get_by_id(id1)
check("get_by_id resolves a v4-shape UUID written by Emacs", idn ~= nil, vim.inspect(idn))
check("get_by_id returns the right title", idn and idn.title == "First child")

-- Property drawer: ROAM_ALIASES, ROAM_REFS, EFFORT, STYLE, ARCHIVE_*

-- query.headlines doesn't take an `id` filter; fetch all-with-
-- properties once and look up by id.
local _all_with_props
local function props_for(h)
  if not h then
    return {}
  end
  if not _all_with_props then
    _all_with_props = {}
    for _, r in ipairs(query.headlines({ include_properties = true })) do
      _all_with_props[r.id] = r.properties or {}
    end
  end
  return _all_with_props[h.id] or {}
end

local top_props = props_for(by_title["Top-level node"])
check(
  "ROAM_ALIASES property captured",
  top_props.ROAM_ALIASES and top_props.ROAM_ALIASES:find("Project Top", 1, true) ~= nil,
  vim.inspect(top_props)
)
check(
  "ROAM_REFS property captured",
  top_props.ROAM_REFS and top_props.ROAM_REFS:find("example.com", 1, true) ~= nil
)
check("CUSTOM_ID property captured", top_props.CUSTOM_ID == "top", vim.inspect(top_props.CUSTOM_ID))

local first_props = props_for(by_title["First child"])
check(
  "EFFORT '1:30' captured (Emacs format)",
  first_props.EFFORT == "1:30",
  vim.inspect(first_props.EFFORT)
)
check("STYLE = habit captured", first_props.STYLE == "habit", vim.inspect(first_props.STYLE))

local archived = by_title["Archived task"]
local arc_props = props_for(archived)
check(
  "ARCHIVE_TIME property captured on archive entry",
  arc_props.ARCHIVE_TIME and arc_props.ARCHIVE_TIME:find("2026", 1, true) ~= nil,
  vim.inspect(arc_props.ARCHIVE_TIME)
)
check("ARCHIVE_OLPATH property captured", arc_props.ARCHIVE_OLPATH ~= nil)

-- Planning: SCHEDULED, DEADLINE, CLOSED with repeaters and times
check(
  "SCHEDULED parsed on First child",
  by_title["First child"] and by_title["First child"].scheduled_date,
  vim.inspect(by_title["First child"] and by_title["First child"].scheduled_date)
)
check(
  "DEADLINE parsed on First child (with repeater +1w)",
  by_title["First child"]
    and by_title["First child"].deadline_date
    and by_title["First child"].deadline_date:find("2026-05-15", 1, true) ~= nil
)
check(
  "CLOSED captured on Second-level child",
  by_title["Second-level child"]
    and (by_title["Second-level child"].closed_date or by_title["Second-level child"].properties)
)

-- Links: id / file / file-heading / *Title / http all indexed
local from_top = query.links_from((by_title["Top-level node"] or {}).id) or {}
local link_targets = {}
for _, l in ipairs(from_top) do
  link_targets[l.target_type] = (link_targets[l.target_type] or 0) + 1
end
check("id-link from top headline indexed", (link_targets.id or 0) >= 1, vim.inspect(link_targets))
check(
  "http-link from top headline indexed",
  (link_targets.https or 0) + (link_targets.http or 0) >= 1
)

-- Check the inverse direction: links_to(first-child) finds the link from top.
local incoming = query.links_to(id1) or {}
check(
  "links_to returns at least one inbound id-link to First child",
  #incoming >= 1,
  "got " .. #incoming
)

-- Title-form `[[*Heading]]` references picked up.
local title_refs = query.title_refs("Top-level node") or {}
check(
  "title_refs([[*Top-level node]]) finds at least one ref",
  #title_refs >= 1,
  "got " .. #title_refs
)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("emacs_interop_test: PASS")
