-- Regression: every multi-key <LocalLeader> prefix organ binds must get a
-- which-key group label.  `<LocalLeader>p` (property set/delete) was missing
-- from keymaps.groups, so the `\p` prefix showed up unlabeled in which-key.
-- Run via: nvim --headless -l tests/which_key_groups_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({})
local km = require("organ.keymaps")

-- Stub which-key and capture what organ registers.
local captured
package.loaded["which-key"] = {
  add = function(entries)
    captured = entries
  end,
}

assert(km.register_which_key() == true, "register_which_key should succeed with which-key present")
assert(captured, "wk.add was not called")

-- Prefix -> group label, as which-key was told.
local labeled = {}
for _, e in ipairs(captured) do
  if e.group then
    labeled[e[1]] = e.group
  end
end

-- The reported gap: the property prefix must be labeled.
assert(
  labeled["<LocalLeader>p"] == "property",
  "property group missing/wrong: " .. tostring(labeled["<LocalLeader>p"])
)

-- Every group entry has a non-empty label and no duplicate prefixes.
local seen = {}
for _, g in ipairs(km.groups) do
  assert(type(g.group) == "string" and g.group ~= "", "empty group label for " .. tostring(g[1]))
  assert(not seen[g[1]], "duplicate group prefix " .. g[1])
  seen[g[1]] = true
end

-- Every multi-key <LocalLeader> prefix in the default bindings is grouped.
for _, b in ipairs(km.defaults) do
  local rest = b[1]:match("^<LocalLeader>(.+)$")
  if rest and #rest >= 2 then
    local prefix = "<LocalLeader>" .. rest:sub(1, 1)
    assert(
      labeled[prefix],
      "no which-key group for prefix " .. prefix .. " (binding " .. b[1] .. ")"
    )
  end
end

print("which_key_groups_test: PASS")
