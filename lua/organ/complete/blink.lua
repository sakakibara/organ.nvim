-- blink.cmp source adapter for organ link completion.

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

-- Cite-key source: fires after `[cite:@<partial>` and offers keys
-- discovered from `#+bibliography:` directives + the cite config.
-- Inserts the bare key (without the `@`, since that's already typed).
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

-- Drawer-name source: fires when cursor is right after a typed `:` at the
-- start of a line inside a headline section. Mirrors `org-complete` for
-- drawer keywords.
function M.new_drawer()
  local source = {}
  function source:enabled()
    return vim.bo.filetype == "org"
  end
  function source:get_completions(_ctx, callback)
    local d = require("organ.complete.drawer")
    local partial = d.cursor_partial(0)
    if not partial then
      callback({ items = {} })
      return
    end
    local items = {}
    for _, it in ipairs(d.completion_items(partial)) do
      items[#items + 1] = {
        label = it.label,
        insertText = it.insertText,
        filterText = it.filterText,
        kind = "Property",
        source_name = "organ_drawer",
      }
    end
    callback({ items = items })
  end
  return source
end

-- TODO-keyword source: completes the first word on a headline.
function M.new_todo()
  local source = {}
  function source:enabled()
    return vim.bo.filetype == "org"
  end
  function source:get_completions(_ctx, callback)
    local todo = require("organ.complete.todo")
    local p = todo.cursor_partial(0)
    if p == "" or p == nil then
      callback({ items = {} })
      return
    end
    local items = {}
    for _, it in ipairs(todo.completion_items(p)) do
      items[#items + 1] = {
        label = it.label,
        insertText = it.insertText,
        filterText = it.filterText,
        kind = "Keyword",
        source_name = "organ_todo",
      }
    end
    callback({ items = items })
  end
  return source
end

-- Tag source: completes inside `:tag1:tag2:|` slot.
function M.new_tags()
  local source = {}
  function source:enabled()
    return vim.bo.filetype == "org"
  end
  function source:get_trigger_characters()
    return { ":" }
  end
  function source:get_completions(_ctx, callback)
    local tags = require("organ.complete.tags")
    local p = tags.cursor_partial(0)
    if p == nil then
      callback({ items = {} })
      return
    end
    local items = {}
    for _, it in ipairs(tags.completion_items(p)) do
      items[#items + 1] = {
        label = it.label,
        insertText = it.insertText,
        filterText = it.filterText,
        kind = "EnumMember",
        detail = it.detail,
        source_name = "organ_tags",
      }
    end
    callback({ items = items })
  end
  return source
end

-- Directive source: completes `#+TIT<Tab>` → `#+TITLE: ` etc.
function M.new_directive()
  local source = {}
  function source:enabled()
    return vim.bo.filetype == "org"
  end
  function source:get_trigger_characters()
    return { "+", "#" }
  end
  function source:get_completions(_ctx, callback)
    local d = require("organ.complete.directive")
    local p = d.cursor_partial(0)
    if p == nil then
      callback({ items = {} })
      return
    end
    local items = {}
    for _, it in ipairs(d.completion_items(p)) do
      items[#items + 1] = {
        label = it.label,
        insertText = it.insertText,
        filterText = it.filterText,
        kind = it.kind or "Keyword",
        detail = it.detail,
        source_name = "organ_directive",
      }
    end
    callback({ items = items })
  end
  return source
end

function M.new_src_lang()
  local source = {}
  function source:enabled()
    return vim.bo.filetype == "org"
  end
  function source:get_trigger_characters()
    return { " " }
  end
  function source:get_completions(_ctx, callback)
    local sl = require("organ.complete.src_lang")
    local p = sl.cursor_partial(0)
    if p == nil then
      callback({ items = {} })
      return
    end
    local items = {}
    for _, it in ipairs(sl.completion_items(p)) do
      items[#items + 1] = {
        label = it.label,
        insertText = it.insertText,
        filterText = it.filterText,
        kind = "Module",
        detail = it.detail,
        source_name = "organ_src_lang",
      }
    end
    callback({ items = items })
  end
  return source
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
  pcall(function()
    blink.add_source("organ_todo", M.new_todo())
  end)
  pcall(function()
    blink.add_source("organ_tags", M.new_tags())
  end)
  pcall(function()
    blink.add_source("organ_directive", M.new_directive())
  end)
  pcall(function()
    blink.add_source("organ_src_lang", M.new_src_lang())
  end)
  if organ.config.complete.drawer ~= false then
    pcall(function()
      blink.add_source("organ_drawer", M.new_drawer())
    end)
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
