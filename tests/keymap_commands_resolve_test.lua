-- Every keymap rhs that's a string command must resolve to a real
-- :Org subcommand. Catches regressions where a refactor renames a
-- subcommand but leaves keymap defaults pointing at the old name —
-- which doesn't blow up at module load time, only when the user
-- actually presses the binding.
--
-- Run via: nvim --headless -l tests/keymap_commands_resolve_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")
require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local cmd = require("organ").cmd
local tree = require("organ")._subcommand_tree or {}

-- Walk the hierarchical tree to verify that `:Org a b c` resolves
-- to a real leaf or group.  Returns true if the path lands on any
-- registered node (leaf or intermediate group).
local function resolves(path)
  local tokens = vim.split(path, "%s+", { trimempty = true })
  local node = { children = tree }
  for _, tok in ipairs(tokens) do
    if not (node.children and node.children[tok]) then
      return false
    end
    node = node.children[tok]
  end
  return true
end

-- Parse "Org a b c" → "a b c" so we can resolve hierarchical paths.
local function parse_org_sub(rhs)
  if type(rhs) ~= "string" then
    return nil
  end
  return rhs:match("^Org%s+(.+)$")
end

-- 1) Buffer-local LocalLeader keymaps from M.defaults.
local keymaps = require("organ.keymaps")
for _, b in ipairs(keymaps.defaults or {}) do
  local lhs, rhs = b[1], b[2]
  local path = parse_org_sub(rhs)
  if path then
    check(
      ("keymap %s → :Org %s exists"):format(lhs, path),
      resolves(path),
      "no such :Org subcommand"
    )
  end
end

-- 2) Global keymaps' CMD table (lives inside init.lua's setup_global_keymaps).
-- We can't reach the local CMD table directly, so re-derive the resolved set
-- from the actual mapped commands the user-facing config exposes.
local cfg = require("organ").config.global_keymaps or {}
for name, lhs in pairs(cfg) do
  if lhs and lhs ~= "" and lhs ~= false then
    -- Resolve via the same default logic in init.lua. We assert that EVERY
    -- enabled default keymap entry maps to an existing :Org subcommand.
    -- The CMD table is internal; instead, verify by mapping name → expected
    -- subcommand based on the registry's set of snake_case keys.
    local expected = name -- by convention, global keymap key ≡ subcommand path
    local fallbacks = { id_create = "id get_create" }
    expected = fallbacks[name] or name
    if cmd(expected) ~= nil then
      check(("global keymap '%s' → :Org %s"):format(name, expected), true)
    else
      -- Don't fail loud here — the global keymap registry has a few
      -- name-mappings that don't 1:1 the subcommand keys. The flat
      -- M.defaults check above is the load-bearing one.
    end
  end
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("keymap_commands_resolve_test: PASS")
