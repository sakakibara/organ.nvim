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

-- Sources that share the cursor_partial / completion_items shape.
-- `skip_empty = true`: empty partial suppresses (todo right after `* `).
local SIMPLE_SOURCES = {
  todo = { module = "todo", kind_name = "Keyword", skip_empty = true },
  tags = { module = "tags", kind_name = "EnumMember", trigger = { ":" } },
  directive = { module = "directive", kind_name = "Keyword", trigger = { "+", "#" } },
  drawer = { module = "drawer", kind_name = "Property", trigger = { ":" } },
  src_lang = { module = "src_lang", kind_name = "Module", trigger = { " " } },
}

local function make_simple(spec)
  local source = {}
  function source:get_keyword_pattern()
    return [[\k\+]]
  end
  if spec.trigger then
    function source:get_trigger_characters()
      return spec.trigger
    end
  end
  function source:complete(_params, callback)
    if vim.bo.filetype ~= "org" then
      callback({ items = {} })
      return
    end
    local mod = require("organ.complete." .. spec.module)
    local p = mod.cursor_partial(0)
    if p == nil or (spec.skip_empty and p == "") then
      callback({ items = {} })
      return
    end
    local lsp = require("cmp").lsp
    local kind = lsp.CompletionItemKind[spec.kind_name]
    local items = {}
    for _, it in ipairs(mod.completion_items(p)) do
      items[#items + 1] = {
        label = it.label,
        insertText = it.insertText,
        -- Block openers carry ${1:...} / $0 snippet syntax.
        insertTextFormat = it.snippet and lsp.InsertTextFormat.Snippet or nil,
        filterText = it.filterText,
        detail = it.detail,
        kind = kind,
      }
    end
    callback({ items = items })
  end
  return source
end

function M.new_drawer()
  return make_simple(SIMPLE_SOURCES.drawer)
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
  return make_simple(SIMPLE_SOURCES.todo)
end
function M.new_tags()
  return make_simple(SIMPLE_SOURCES.tags)
end
function M.new_directive()
  return make_simple(SIMPLE_SOURCES.directive)
end
function M.new_src_lang()
  return make_simple(SIMPLE_SOURCES.src_lang)
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
    or not require("organ.buf_config").read(nil, "complete")
    or require("organ.buf_config").read(nil, "complete.cmp") == false
  then
    return
  end
  cmp.register_source("organ_link", M.new())
  cmp.register_source("organ_todo", M.new_todo())
  cmp.register_source("organ_tags", M.new_tags())
  cmp.register_source("organ_directive", M.new_directive())
  cmp.register_source("organ_src_lang", M.new_src_lang())
  if require("organ.buf_config").read(nil, "complete.drawer") ~= false then
    cmp.register_source("organ_drawer", M.new_drawer())
  end
  if require("organ.buf_config").read(nil, "complete.roam_everywhere") then
    cmp.register_source("organ_roam_node", M.new_roam_node())
  end
  if require("organ.buf_config").read(nil, "complete.cite") ~= false then
    cmp.register_source("organ_cite", M.new_cite())
  end
end

return M
