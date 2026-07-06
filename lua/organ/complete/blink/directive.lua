-- blink.cmp source: #+TITLE: / #+AUTHOR: / etc. directive keys.

local M = {}

function M.new(_opts, _source_config)
  return setmetatable({}, { __index = M })
end

function M:enabled()
  return vim.bo.filetype == "org"
end

function M:get_trigger_characters()
  return { "+", "#" }
end

function M:get_completions(_ctx, callback)
  local mod = require("organ.complete.directive")
  local p = mod.cursor_partial(0)
  if p == nil then
    callback({ items = {} })
    return
  end
  local out = {}
  for _, it in ipairs(mod.completion_items(p)) do
    out[#out + 1] = {
      label = it.label,
      insertText = it.insertText,
      -- Block openers are LSP snippets (${1:...} / $0); 2 = Snippet.
      insertTextFormat = it.snippet and 2 or 1,
      filterText = it.filterText,
      kind = it.kind or "Keyword",
      detail = it.detail,
      source_name = "organ_directive",
    }
  end
  callback({ items = out })
end

return M
