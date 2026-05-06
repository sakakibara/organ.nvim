-- nvim-cmp source adapter for organ link completion.

local M = {}

function M.new()
  local source = {}
  function source:get_trigger_characters()
    return { ":", "*" }
  end
  function source:get_keyword_pattern()
    return [==[\v(\[\[(id:|file:|attachment:|\*))@<=[^]]*]==]
  end
  function source:complete(_params, callback)
    local complete = require("organ.complete")
    local trigger = complete.trigger_at_cursor(0)
    if not trigger then
      callback({ items = {} })
      return
    end
    local items = complete.items_for(trigger.kind, trigger.query)
    local cmp_items = {}
    for _, it in ipairs(items) do
      cmp_items[#cmp_items + 1] = {
        label = it.display,
        insertText = string.format("%s][%s]]", it.insert_text, it.description),
        filterText = it.display,
        kind = require("cmp").lsp.CompletionItemKind.Reference,
      }
    end
    callback({ items = cmp_items })
  end
  return source
end

-- Roam node-title source: fires on every word in an .org buffer (no trigger
-- char). Mirrors Emacs `org-roam-completion-everywhere`.
function M.new_roam_node()
  local source = {}
  function source:get_keyword_pattern()
    return [[\k\+]]
  end
  function source:complete(_params, callback)
    if vim.bo.filetype ~= "org" then
      callback({ items = {} })
      return
    end
    local lk = require("organ.roam.linkify")
    local query = lk.cursor_partial(0)
    if query == "" then
      callback({ items = {} })
      return
    end
    local raw = lk.completion_items(query)
    local cmp_items = {}
    for _, it in ipairs(raw) do
      cmp_items[#cmp_items + 1] = {
        label = it.label,
        insertText = it.insertText,
        filterText = it.filterText,
        kind = require("cmp").lsp.CompletionItemKind.Reference,
      }
    end
    callback({ items = cmp_items })
  end
  return source
end

function M.new_drawer()
  local source = {}
  function source:get_keyword_pattern()
    return [[\k\+]]
  end
  function source:get_trigger_characters()
    return { ":" }
  end
  function source:complete(_params, callback)
    if vim.bo.filetype ~= "org" then
      callback({ items = {} })
      return
    end
    local d = require("organ.complete.drawer")
    local partial = d.cursor_partial(0)
    if not partial then
      callback({ items = {} })
      return
    end
    local cmp_items = {}
    for _, it in ipairs(d.completion_items(partial)) do
      cmp_items[#cmp_items + 1] = {
        label = it.label,
        insertText = it.insertText,
        filterText = it.filterText,
        kind = require("cmp").lsp.CompletionItemKind.Property,
      }
    end
    callback({ items = cmp_items })
  end
  return source
end

function M.new_cite()
  local source = {}
  function source:get_keyword_pattern()
    return [[\k\+]]
  end
  function source:get_trigger_characters()
    return { "@" }
  end
  function source:complete(_params, callback)
    if vim.bo.filetype ~= "org" then
      callback({ items = {} })
      return
    end
    local cite = require("organ.cite")
    local trigger = cite.trigger_at_cursor(0)
    if not trigger then
      callback({ items = {} })
      return
    end
    local items_raw = cite.completion_items(trigger.query)
    local cmp_items = {}
    for _, it in ipairs(items_raw) do
      cmp_items[#cmp_items + 1] = {
        label = it.label,
        insertText = it.key,
        filterText = it.key,
        kind = require("cmp").lsp.CompletionItemKind.Reference,
      }
    end
    callback({ items = cmp_items })
  end
  return source
end

function M.new_todo()
  local source = {}
  function source:get_keyword_pattern()
    return [[\k\+]]
  end
  function source:complete(_params, callback)
    if vim.bo.filetype ~= "org" then
      callback({ items = {} })
      return
    end
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
        kind = require("cmp").lsp.CompletionItemKind.Keyword,
      }
    end
    callback({ items = items })
  end
  return source
end

function M.new_tags()
  local source = {}
  function source:get_keyword_pattern()
    return [[\k\+]]
  end
  function source:get_trigger_characters()
    return { ":" }
  end
  function source:complete(_params, callback)
    if vim.bo.filetype ~= "org" then
      callback({ items = {} })
      return
    end
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
        detail = it.detail,
        kind = require("cmp").lsp.CompletionItemKind.EnumMember,
      }
    end
    callback({ items = items })
  end
  return source
end

function M.new_directive()
  local source = {}
  function source:get_keyword_pattern()
    return [[\k\+]]
  end
  function source:get_trigger_characters()
    return { "+", "#" }
  end
  function source:complete(_params, callback)
    if vim.bo.filetype ~= "org" then
      callback({ items = {} })
      return
    end
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
        detail = it.detail,
        kind = require("cmp").lsp.CompletionItemKind.Keyword,
      }
    end
    callback({ items = items })
  end
  return source
end

function M.maybe_register()
  local ok, cmp = pcall(require, "cmp")
  if not ok then
    return
  end
  local cfg_ok, organ = pcall(require, "organ")
  if
    not cfg_ok
    or not organ.config
    or not organ.config.complete
    or organ.config.complete.cmp == false
  then
    return
  end
  cmp.register_source("organ_link", M.new())
  cmp.register_source("organ_todo", M.new_todo())
  cmp.register_source("organ_tags", M.new_tags())
  cmp.register_source("organ_directive", M.new_directive())
  if organ.config.complete.drawer ~= false then
    cmp.register_source("organ_drawer", M.new_drawer())
  end
  if organ.config.complete.roam_everywhere then
    cmp.register_source("organ_roam_node", M.new_roam_node())
  end
  if organ.config.complete.cite ~= false then
    cmp.register_source("organ_cite", M.new_cite())
  end
end

return M
