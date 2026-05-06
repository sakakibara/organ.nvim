-- tag_select pure helpers — alist normalisation, key auto-derivation,
-- mutually-exclusive group toggling, render layout.
-- Run via: nvim --headless -l tests/tag_select_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local sel = require("organ.tag_select")

-- Auto-key picks first available char (lowercase), skips collisions.
local used = {}
local k1 = sel._auto_key("work", used)
used[k1] = true
local k2 = sel._auto_key("wide", used)
used[k2] = true
assert(k1 == "w", "first chunk → 'w'")
assert(k2 ~= "w" and k2 ~= nil, "collision avoided → '" .. (k2 or "?") .. "'")

-- Normalise: explicit, string, group markers, buffer extras.
local items = sel._normalise_alist({
  { name = "work", key = "w" },
  "home",
  ":newline",
  { startgroup = "context" },
  "deep",
  "shallow",
  { endgroup = true },
}, { "extra1", "deep" }) -- "deep" already present → dedup

local kinds = {}
for _, it in ipairs(items) do
  kinds[#kinds + 1] = it.kind
end
assert(
  table.concat(kinds, ",") == "tag,tag,newline,startgroup,tag,tag,endgroup,tag",
  "kinds: " .. table.concat(kinds, ",")
)

-- Group_id propagates to tags inside startgroup/endgroup only.
for _, it in ipairs(items) do
  if it.kind == "tag" then
    if it.name == "deep" or it.name == "shallow" then
      assert(it.group_id ~= nil, "expected group_id on " .. it.name)
    else
      assert(it.group_id == nil, "unexpected group_id on " .. it.name)
    end
  end
end

-- Toggle inside a group is mutually exclusive.
local sel_set = {}
local function find_idx(name)
  for i, it in ipairs(items) do
    if it.kind == "tag" and it.name == name then
      return i
    end
  end
end
sel._toggle(items, find_idx("deep"), sel_set)
sel._toggle(items, find_idx("shallow"), sel_set)
assert(
  sel_set["deep"] == nil and sel_set["shallow"] == true,
  "shallow should evict deep within group"
)

-- Toggle outside the group leaves group state alone.
sel._toggle(items, find_idx("work"), sel_set)
assert(sel_set["work"] == true and sel_set["shallow"] == true, "work + shallow should coexist")

-- Render produces lines that include marks for selected tags.
local lines, key_to_idx = sel._render_lines(items, sel_set)
local joined = table.concat(lines, "\n")
assert(joined:find("[X] w  work", 1, true), "expected selected mark for work")
assert(joined:find("[X]", 1, true) ~= nil, "selection mark present")
assert(joined:find("[ ]", 1, true) ~= nil, "unselected mark present")

-- Each tag's key maps back to its alist index.
for _, it in ipairs(items) do
  if it.kind == "tag" and it.key then
    assert(key_to_idx[it.key], "key " .. it.key .. " missing from map")
  end
end

-- buffer_tags walks headlines, skipping body.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fixture = tmp .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write([[* TODO First :alpha:beta:
  body :should:not:appear:
* DONE Second :gamma:
]])
fh:close()
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)
local found = sel._buffer_tags(b)
local set = {}
for _, t in ipairs(found) do
  set[t] = true
end
assert(set.alpha and set.beta and set.gamma, "expected alpha/beta/gamma")
assert(not set.should, "body 'should' must not be picked up as tag")

vim.fn.delete(tmp, "rf")
io.write("tag_select ok\n")
os.exit(0)
