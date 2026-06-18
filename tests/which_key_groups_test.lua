-- Regression: every multi-key prefix organ binds must get a which-key group
-- label.  `<LocalLeader>p` (property set/delete) was missing from
-- keymaps.groups, and the global `<Leader>o` prefix had no group either, so
-- both showed up unlabeled in which-key.
-- Run via: nvim --headless -l tests/which_key_groups_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Stub which-key BEFORE setup so both the global-prefix registration (during
-- setup) and the buffer-group registration are captured.  Accumulate across
-- every wk.add() call.
local added = {} -- prefix -> group label
package.loaded["which-key"] = {
  add = function(entries)
    for _, e in ipairs(entries) do
      if e.group then
        added[e[1]] = e.group
      end
    end
  end,
}

require("organ").setup({})
local km = require("organ.keymaps")

-- The global <Leader>o prefix is grouped as "org" (registered during setup).
assert(
  added["<Leader>o"] == "org",
  "global <Leader>o group missing/wrong: " .. tostring(added["<Leader>o"])
)

-- Buffer LocalLeader groups are registered via register_which_key.
assert(km.register_which_key() == true, "register_which_key should succeed with which-key present")

-- The reported gap: the property prefix must be labeled.
assert(
  added["<LocalLeader>p"] == "property",
  "property group missing/wrong: " .. tostring(added["<LocalLeader>p"])
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
    assert(added[prefix], "no which-key group for prefix " .. prefix .. " (binding " .. b[1] .. ")")
  end
end

print("which_key_groups_test: PASS")
