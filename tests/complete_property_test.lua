-- Unit tests for complete.trigger_at_cursor + complete.items_for for
-- property-value links.
-- Run via: nvim --headless -l tests/complete_property_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/notes"
vim.fn.mkdir(org_dir, "p")

local fixture = org_dir .. "/refs.org"
local fh = assert(io.open(fixture, "w"))
fh:write([=[* HasRoamA
  :PROPERTIES:
  :ROAM_REFS: https://a.example.com
  :END:

* HasRoamB
  :PROPERTIES:
  :ROAM_REFS: https://b.example.com @cite-key
  :END:

* HasBibkey
  :PROPERTIES:
  :BIBKEY: knuth1984
  :END:
]=])
fh:close()

require("organ").setup({
  db_path = tmp .. "/c.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
})
require("organ").scan_blocking(org_dir, 5000)

vim.opt.virtualedit = "onemore" -- allow cursor at col == #line in tests
local complete = require("organ.complete")

-- Set up an org buffer to type into.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo.filetype = "org"

local function place(line_text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line_text })
  vim.api.nvim_win_set_cursor(0, { 1, #line_text })
end

-- 1. [[ROAM_REFS: triggers property_value with empty query.
do
  place("[[ROAM_REFS:")
  local trig = complete.trigger_at_cursor(buf)
  assert(trig, "trigger should fire on [[ROAM_REFS:")
  assert(trig.kind == "property_value", "kind=" .. tostring(trig.kind))
  assert(trig.key == "ROAM_REFS", "key=" .. tostring(trig.key))
  assert(trig.query == "", "query should be empty; got " .. tostring(trig.query))
end

-- 2. [[ROAM_REFS:abc populates the query.
do
  place("[[ROAM_REFS:abc")
  local trig = complete.trigger_at_cursor(buf)
  assert(trig and trig.kind == "property_value")
  assert(trig.query == "abc", "query=" .. tostring(trig.query))
end

-- 3. Reserved scheme [[id:foo still triggers id, NOT property_value.
do
  place("[[id:foo")
  local trig = complete.trigger_at_cursor(buf)
  assert(
    trig and trig.kind == "id",
    "id should be reserved; got kind=" .. tostring(trig and trig.kind)
  )
end

-- 4. items_for("property_value", {key="ROAM_REFS", query=""}) returns
--    deduped tokens with headline title in description.
do
  local items =
    complete.items_for("property_value", { kind = "property_value", key = "ROAM_REFS", query = "" })
  -- Tokens: https://a.example.com (from HasRoamA),
  --         https://b.example.com + @cite-key (from HasRoamB).
  local seen = {}
  for _, it in ipairs(items) do
    seen[it.insert_text] = it
  end
  assert(seen["https://a.example.com"], "a.example missing")
  assert(seen["https://b.example.com"], "b.example missing")
  assert(seen["@cite-key"], "@cite-key missing")
  assert(seen["https://a.example.com"].description == "HasRoamA")
  assert(seen["https://b.example.com"].description == "HasRoamB")
  assert(seen["@cite-key"].description == "HasRoamB")
end

-- 5. Substring filter on query.
do
  local items = complete.items_for(
    "property_value",
    { kind = "property_value", key = "ROAM_REFS", query = "@" }
  )
  assert(#items == 1, "expected 1 @-prefixed item; got " .. #items)
  assert(items[1].insert_text == "@cite-key")
end

-- 6. Different KEY (BIBKEY) returns its own value space.
do
  local items =
    complete.items_for("property_value", { kind = "property_value", key = "BIBKEY", query = "" })
  assert(#items == 1, "expected 1 BIBKEY item; got " .. #items)
  assert(items[1].insert_text == "knuth1984")
  assert(items[1].description == "HasBibkey")
end

-- 7. KEY with no entries returns empty list (menu silently doesn't open).
do
  local items =
    complete.items_for("property_value", { kind = "property_value", key = "NONESUCH", query = "" })
  assert(#items == 0, "expected empty list; got " .. #items)
end

-- 8. Non-property-name shape doesn't trigger.
do
  place("[[123abc:") -- starts with digit, not a property-name shape
  local trig = complete.trigger_at_cursor(buf)
  assert(not trig, "shouldn't trigger on [[123abc:; got " .. vim.inspect(trig))
end

vim.fn.delete(tmp, "rf")
io.write("complete property ok\n")
os.exit(0)
