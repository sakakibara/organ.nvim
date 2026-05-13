-- blink.cmp source: :tag: completion in tag block.

local M = {}

function M.new(_opts, _source_config)
  return setmetatable({}, { __index = M })
end

function M:enabled()
  return vim.bo.filetype == "org"
end

function M:get_trigger_characters()
  return { ":" }
end

function M:get_completions(_ctx, callback)
  local mod = require("organ.complete.tags")
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
      filterText = it.filterText,
      kind = it.kind or "EnumMember",
      detail = it.detail,
      source_name = "organ_tags",
    }
  end
  callback({ items = out })
end

return M
