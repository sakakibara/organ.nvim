-- blink.cmp source adapters for organ completion.

local M = {}

function M.new()
  local source = {}
  function source:enabled()
    return vim.bo.filetype == "org"
  end
  function source:get_trigger_characters()
    return { ":", "*" }
  end
  function source:get_completions(_ctx, callback)
    local complete = require("organ.complete")
    local trigger = complete.trigger_at_cursor(0)
    if not trigger then
      callback({ items = {} })
      return
    end
    local items = complete.items_for(trigger.kind, trigger.query)
    local blink_items = {}
    for _, it in ipairs(items) do
      blink_items[#blink_items + 1] = {
        label = it.display,
        insertText = string.format("%s][%s]]", it.insert_text, it.description),
        kind = "Reference",
        source_name = "organ_link",
      }
    end
    callback({ items = blink_items })
  end
  return source
end

-- Roam node-title source: fires on every word-fragment in an .org buffer
-- (no trigger character). Surfaces matching node titles + aliases as
-- `[[id:UUID][title]]` insertions. Emacs `org-roam-completion-everywhere`.
function M.new_roam_node()
  local source = {}
  function source:enabled()
    return vim.bo.filetype == "org"
  end
  function source:get_completions(_ctx, callback)
    local lk = require("organ.roam.linkify")
    local query = lk.cursor_partial(0)
    if query == "" then
      callback({ items = {} })
      return
    end
    local raw = lk.completion_items(query)
    local items = {}
    for _, it in ipairs(raw) do
      items[#items + 1] = {
        label = it.label,
        insertText = it.insertText,
        filterText = it.filterText,
        kind = "Reference",
        source_name = "organ_roam_node",
      }
    end
    callback({ items = items })
  end
  return source
end

function M.new_cite()
  local source = {}
  function source:enabled()
    return vim.bo.filetype == "org"
  end
  function source:get_trigger_characters()
    return { "@" }
  end
  function source:get_completions(_ctx, callback)
    local cite = require("organ.cite")
    local trigger = cite.trigger_at_cursor(0)
    if not trigger then
      callback({ items = {} })
      return
    end
    local items_raw = cite.completion_items(trigger.query)
    local items = {}
    for _, it in ipairs(items_raw) do
      items[#items + 1] = {
        label = it.label,
        insertText = it.key,
        filterText = it.key,
        kind = "Reference",
        source_name = "organ_cite",
      }
    end
    callback({ items = items })
  end
  return source
end

-- Sources that share the cursor_partial / completion_items shape.
-- `skip_empty = true`: empty partial suppresses (todo right after `* `).
local SIMPLE_SOURCES = {
  todo = { module = "todo", kind = "Keyword", skip_empty = true },
  tags = { module = "tags", kind = "EnumMember", trigger = { ":" } },
  directive = { module = "directive", kind = "Keyword", trigger = { "+", "#" } },
  drawer = { module = "drawer", kind = "Property" },
  src_lang = { module = "src_lang", kind = "Module", trigger = { " " } },
}

local function make_simple(name, spec)
  local source = {}
  function source:enabled()
    return vim.bo.filetype == "org"
  end
  if spec.trigger then
    function source:get_trigger_characters()
      return spec.trigger
    end
  end
  function source:get_completions(_ctx, callback)
    local mod = require("organ.complete." .. spec.module)
    local p = mod.cursor_partial(0)
    if p == nil or (spec.skip_empty and p == "") then
      callback({ items = {} })
      return
    end
    local items = {}
    for _, it in ipairs(mod.completion_items(p)) do
      items[#items + 1] = {
        label = it.label,
        insertText = it.insertText,
        filterText = it.filterText,
        kind = it.kind or spec.kind,
        detail = it.detail,
        source_name = "organ_" .. name,
      }
    end
    callback({ items = items })
  end
  return source
end

function M.new_todo()
  return make_simple("todo", SIMPLE_SOURCES.todo)
end
function M.new_tags()
  return make_simple("tags", SIMPLE_SOURCES.tags)
end
function M.new_directive()
  return make_simple("directive", SIMPLE_SOURCES.directive)
end
function M.new_drawer()
  return make_simple("drawer", SIMPLE_SOURCES.drawer)
end
function M.new_src_lang()
  return make_simple("src_lang", SIMPLE_SOURCES.src_lang)
end

function M.maybe_register()
  local ok, blink = pcall(require, "blink.cmp")
  if not ok then
    return
  end
  local cfg_ok, organ = pcall(require, "organ")
  if
    not cfg_ok
    or not organ.config
    or not organ.config.complete
    or organ.config.complete.blink == false
  then
    return
  end
  pcall(function()
    blink.add_source("organ_link", M.new())
  end)
  for name, spec in pairs(SIMPLE_SOURCES) do
    if name ~= "drawer" or organ.config.complete.drawer ~= false then
      pcall(function()
        blink.add_source("organ_" .. name, make_simple(name, spec))
      end)
    end
  end
  if organ.config.complete.roam_everywhere then
    pcall(function()
      blink.add_source("organ_roam_node", M.new_roam_node())
    end)
  end
  if organ.config.complete.cite ~= false then
    pcall(function()
      blink.add_source("organ_cite", M.new_cite())
    end)
  end
end

return M
