-- nvim-cmp / blink.cmp adapter contract tests.
--
-- Both plugins are external — the bug class we hit with snacks (item-shape
-- mismatch silently producing blank/broken UX) repeats here. This test
-- mocks each plugin and asserts:
--   - source object exposes the methods the host plugin calls;
--   - items returned have all fields the host plugin reads;
--   - the four sources (link, drawer, roam_node, cite) all produce
--     well-formed items;
--   - maybe_register honors config flags AND doesn't crash when the
--     host plugin is absent;
--   - sources guard on filetype == "org" (no firing in random buffers);
--   - empty-trigger paths return `{ items = {} }` not nil/error.
--
-- Run via: nvim --headless -l tests/complete_adapters_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Stub backing modules so adapters get controlled inputs/outputs.
package.loaded["organ.complete"] = {
  trigger_at_cursor = function(_)
    return { kind = "id", query = "fo" }
  end,
  items_for = function(_kind, _query)
    return {
      { display = "Foo headline", insert_text = "id:abc", description = "Foo headline" },
      { display = "Foobar item", insert_text = "id:def", description = "Foobar item" },
    }
  end,
}

package.loaded["organ.complete.drawer"] = {
  cursor_partial = function(_)
    return "PROP"
  end,
  completion_items = function(_)
    return {
      { label = ":PROPERTIES:", insertText = ":PROPERTIES:", filterText = "PROPERTIES" },
    }
  end,
}

package.loaded["organ.roam.linkify"] = {
  cursor_partial = function(_)
    return "topic"
  end,
  completion_items = function(_)
    return {
      {
        label = "Topic Note",
        insertText = "[[id:xxxx][Topic Note]]",
        filterText = "Topic Note",
      },
    }
  end,
}

package.loaded["organ.cite"] = {
  trigger_at_cursor = function(_)
    return { query = "smi" }
  end,
  completion_items = function(_)
    return { { label = "smith2024 — Smith, Foo (2024)", key = "smith2024" } }
  end,
}

require("organ").setup({ org_dir = "/tmp" })

-- Test rig
local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Switch to an org buffer so filetype guards pass.
local buf = vim.api.nvim_create_buf(true, true)
vim.bo[buf].filetype = "org"
vim.api.nvim_set_current_buf(buf)

-- Capture the callback invocation synchronously: each adapter calls
-- callback(result) inline, so we can stash it and assert.
local function run_complete(source, getter)
  local captured
  source[getter](source, {}, function(result)
    captured = result
  end)
  return captured
end

-- nvim-cmp adapter
package.loaded["cmp"] = {
  lsp = { CompletionItemKind = { Reference = 18, Property = 10 } },
  register_source = function() end,
}

local cmp_adapter = require("organ.complete.cmp")

do
  local s = cmp_adapter.new()
  check(
    "cmp link: source exposes get_trigger_characters",
    type(s.get_trigger_characters) == "function"
  )
  check("cmp link: source exposes get_keyword_pattern", type(s.get_keyword_pattern) == "function")
  check("cmp link: source exposes complete", type(s.complete) == "function")
  check(
    "cmp link: trigger characters are { ':', '*' }",
    vim.deep_equal(s:get_trigger_characters(), { ":", "*" })
  )

  local result = run_complete(s, "complete")
  check(
    "cmp link: returns { items = ... }",
    type(result) == "table" and type(result.items) == "table"
  )
  check("cmp link: yields one item per upstream item", #result.items == 2, "got " .. #result.items)
  local it = result.items[1]
  check("cmp link: item.label set", type(it.label) == "string" and #it.label > 0)
  check(
    "cmp link: item.insertText carries `]description]]` suffix",
    it.insertText == "id:abc][Foo headline]]",
    "got " .. tostring(it.insertText)
  )
  check("cmp link: item.kind is Reference (18)", it.kind == 18)
  check("cmp link: item.filterText set", type(it.filterText) == "string")
end

do
  local s = cmp_adapter.new_drawer()
  check(
    "cmp drawer: trigger characters are { ':' }",
    vim.deep_equal(s:get_trigger_characters(), { ":" })
  )
  local result = run_complete(s, "complete")
  check("cmp drawer: yields drawer items", #result.items == 1)
  check("cmp drawer: kind is Property (10)", result.items[1].kind == 10)
end

do
  local s = cmp_adapter.new_roam_node()
  local result = run_complete(s, "complete")
  check("cmp roam: yields roam items", #result.items == 1)
  check(
    "cmp roam: insertText is preserved verbatim",
    result.items[1].insertText == "[[id:xxxx][Topic Note]]"
  )
end

do
  local s = cmp_adapter.new_cite()
  check(
    "cmp cite: trigger characters are { '@' }",
    vim.deep_equal(s:get_trigger_characters(), { "@" })
  )
  local result = run_complete(s, "complete")
  check("cmp cite: yields cite items", #result.items == 1)
  check("cmp cite: insertText is the bare key (no @)", result.items[1].insertText == "smith2024")
end

-- Guard: non-org buffer → empty items, no crash. Switch buffers.
do
  local non_org = vim.api.nvim_create_buf(true, true)
  vim.bo[non_org].filetype = "lua"
  vim.api.nvim_set_current_buf(non_org)
  for _, ctor in ipairs({ "new_drawer", "new_roam_node", "new_cite" }) do
    local s = cmp_adapter[ctor]()
    local r = run_complete(s, "complete")
    check("cmp " .. ctor .. ": non-org buffer yields empty items", r and r.items and #r.items == 0)
  end
  vim.api.nvim_set_current_buf(buf)
end

-- maybe_register: honors config flags. Use a counting register_source.
do
  local registered = {}
  package.loaded["cmp"].register_source = function(name, _src)
    registered[name] = true
  end
  local organ = require("organ")
  organ.config.complete = { drawer = false, cite = false } -- only "link" survives
  cmp_adapter.maybe_register()
  check("cmp maybe_register: registers organ_link", registered.organ_link == true)
  check("cmp maybe_register: skips organ_drawer when disabled", not registered.organ_drawer)
  check("cmp maybe_register: skips organ_cite when disabled", not registered.organ_cite)
  check("cmp maybe_register: skips organ_roam_node by default", not registered.organ_roam_node)
  organ.config.complete = nil
end

-- maybe_register: cmp absent → silent no-op
do
  package.loaded["cmp"] = nil
  local ok = pcall(function()
    cmp_adapter.maybe_register()
  end)
  check("cmp maybe_register: no crash when nvim-cmp is absent", ok)
end

-- blink.cmp adapter

-- Each per-source module exposes M.new(opts, source_config) returning a
-- source-class table. blink calls m:enabled() / m:get_trigger_characters()
-- / m:get_completions(ctx, cb). We stub blink's runtime API
-- (add_source_provider + add_filetype_source) and assert organ wires
-- each source through that API, not the v0 blink.add_source.

local blink_providers = {}
local blink_filetype = {}
package.loaded["blink.cmp"] = {
  add_source_provider = function(id, config)
    blink_providers[id] = config
  end,
  add_filetype_source = function(filetype, id)
    blink_filetype[#blink_filetype + 1] = { filetype, id }
  end,
}

local blink_adapter = require("organ.complete.blink")

local link_source = require("organ.complete.blink.link")
local drawer_source = require("organ.complete.blink.drawer")
local roam_source = require("organ.complete.blink.roam_node")
local cite_source = require("organ.complete.blink.cite")

do
  local s = link_source.new({}, {})
  check("blink link: source exposes enabled", type(s.enabled) == "function")
  check(
    "blink link: source exposes get_trigger_characters",
    type(s.get_trigger_characters) == "function"
  )
  check("blink link: source exposes get_completions", type(s.get_completions) == "function")
  check("blink link: enabled() is true in org buffer", s:enabled())

  local result = run_complete(s, "get_completions")
  check(
    "blink link: returns { items = ... }",
    type(result) == "table" and type(result.items) == "table"
  )
  check("blink link: yields one item per upstream", #result.items == 2)
  local it = result.items[1]
  check("blink link: item.kind is string 'Reference'", it.kind == "Reference")
  check("blink link: item.source_name set", it.source_name == "organ_link")
  check(
    "blink link: insertText carries `]desc]]` suffix",
    it.insertText == "id:abc][Foo headline]]"
  )
end

do
  local s = drawer_source.new({}, {})
  local result = run_complete(s, "get_completions")
  check("blink drawer: yields drawer items", #result.items == 1)
  check("blink drawer: kind is 'Property' (string)", result.items[1].kind == "Property")
  check("blink drawer: source_name is organ_drawer", result.items[1].source_name == "organ_drawer")
end

do
  local s = roam_source.new({}, {})
  local result = run_complete(s, "get_completions")
  check("blink roam: yields roam items", #result.items == 1)
  check(
    "blink roam: source_name is organ_roam_node",
    result.items[1].source_name == "organ_roam_node"
  )
end

do
  local s = cite_source.new({}, {})
  check(
    "blink cite: trigger characters are { '@' }",
    vim.deep_equal(s:get_trigger_characters(), { "@" })
  )
  local result = run_complete(s, "get_completions")
  check("blink cite: yields cite items", #result.items == 1)
  check("blink cite: source_name is organ_cite", result.items[1].source_name == "organ_cite")
end

-- Filetype guard via :enabled()
do
  local non_org = vim.api.nvim_create_buf(true, true)
  vim.bo[non_org].filetype = "lua"
  vim.api.nvim_set_current_buf(non_org)
  for label, mod in pairs({
    link = link_source,
    drawer = drawer_source,
    roam_node = roam_source,
    cite = cite_source,
  }) do
    local s = mod.new({}, {})
    check("blink " .. label .. ": enabled() is false in non-org buffer", not s:enabled())
  end
  vim.api.nvim_set_current_buf(buf)
end

-- maybe_register honors flags: registers via add_source_provider +
-- add_filetype_source with the correct module paths.
do
  blink_providers, blink_filetype = {}, {}
  local organ = require("organ")
  organ.config.complete = { drawer = false }
  blink_adapter.maybe_register()
  check(
    "blink maybe_register: organ_link registered as provider",
    type(blink_providers.organ_link) == "table"
  )
  check(
    "blink maybe_register: organ_link.module points to per-source path",
    blink_providers.organ_link and blink_providers.organ_link.module == "organ.complete.blink.link"
  )
  check(
    "blink maybe_register: organ_link.name set",
    blink_providers.organ_link and blink_providers.organ_link.name == "organ_link"
  )
  check(
    "blink maybe_register: organ_cite registered (default-on)",
    type(blink_providers.organ_cite) == "table"
  )
  check(
    "blink maybe_register: skips organ_drawer when disabled",
    blink_providers.organ_drawer == nil
  )
  check(
    "blink maybe_register: skips organ_roam_node by default",
    blink_providers.organ_roam_node == nil
  )
  -- Each registered provider must also be attached to filetype "org".
  local link_attached = false
  for _, entry in ipairs(blink_filetype) do
    if entry[1] == "org" and entry[2] == "organ_link" then
      link_attached = true
      break
    end
  end
  check("blink maybe_register: organ_link attached to filetype 'org'", link_attached)
  organ.config.complete = nil
end

-- maybe_register tolerates duplicate registration (add_source_provider
-- asserts on a re-add; pcall must absorb that).
do
  blink_providers, blink_filetype = {}, {}
  -- Make add_source_provider mimic blink's behavior: throw on duplicate.
  local seen = {}
  package.loaded["blink.cmp"].add_source_provider = function(id, config)
    assert(seen[id] == nil, "Provider with id " .. id .. " already exists")
    seen[id] = true
    blink_providers[id] = config
  end
  local organ = require("organ")
  organ.config.complete = nil
  blink_adapter.maybe_register()
  local ok = pcall(function()
    blink_adapter.maybe_register()
  end)
  check("blink maybe_register: re-registration does not crash", ok)
  organ.config.complete = nil
  -- Restore non-throwing stub for downstream tests.
  package.loaded["blink.cmp"].add_source_provider = function(id, config)
    blink_providers[id] = config
  end
end

-- maybe_register survives missing blink.cmp (defers via autocmds).
do
  package.loaded["blink.cmp"] = nil
  local ok = pcall(function()
    blink_adapter.maybe_register()
  end)
  check("blink maybe_register: no crash when blink.cmp is absent", ok)
end

-- Deferred registration: when blink isn't loaded at maybe_register time,
-- an autocmd on `User LazyLoad` (pattern blink.cmp) must trigger
-- registration when emitted.
do
  package.loaded["blink.cmp"] = nil
  -- Drop existing autocmds for the User pattern so we don't see a
  -- carry-over from the earlier "blink.cmp absent" check.
  pcall(vim.api.nvim_clear_autocmds, { event = "User", pattern = "LazyLoad" })
  pcall(vim.api.nvim_clear_autocmds, { event = "FileType", pattern = "org" })

  blink_adapter.maybe_register()

  -- An autocmd should now exist for User LazyLoad.
  local user_autos = vim.api.nvim_get_autocmds({ event = "User", pattern = "LazyLoad" })
  check(
    "blink maybe_register: defers via User LazyLoad autocmd when blink absent",
    #user_autos >= 1
  )

  -- Now make blink "load" and fire the lazy.nvim event.
  local deferred_providers = {}
  package.loaded["blink.cmp"] = {
    add_source_provider = function(id, config)
      deferred_providers[id] = config
    end,
    add_filetype_source = function(_, _) end,
  }
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "LazyLoad", data = "blink.cmp" })
  check(
    "blink maybe_register: User LazyLoad fires registration",
    type(deferred_providers.organ_link) == "table"
  )
end

-- complete = false short-circuits both adapters
do
  package.loaded["cmp"] = {
    register_source = function() end,
    lsp = { CompletionItemKind = { Reference = 18, Property = 10 } },
  }
  package.loaded["blink.cmp"] = {
    add_source_provider = function() end,
    add_filetype_source = function() end,
  }
  local cmp_called, blink_called = false, false
  package.loaded["cmp"].register_source = function()
    cmp_called = true
  end
  package.loaded["blink.cmp"].add_source_provider = function()
    blink_called = true
  end
  local organ = require("organ")
  organ.config.complete = { cmp = false, blink = false }
  cmp_adapter.maybe_register()
  blink_adapter.maybe_register()
  check("cmp maybe_register: complete.cmp=false skips registration", not cmp_called)
  check("blink maybe_register: complete.blink=false skips registration", not blink_called)
  organ.config.complete = nil
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("complete_adapters_test: PASS")
