-- blink.cmp source: [cite:@key / [@key citation-key completion.

local M = {}

function M.new(_opts, _source_config)
  return setmetatable({}, { __index = M })
end

function M:enabled()
  return vim.bo.filetype == "org"
end

function M:get_trigger_characters()
  return { "@" }
end

function M:get_completions(_ctx, callback)
  local cite = require("organ.cite")
  local trigger = cite.trigger_at_cursor(0)
  if not trigger then
    callback({ items = {} })
    return
  end
  local items_raw = cite.completion_items(trigger.query)
  local out = {}
  for _, it in ipairs(items_raw) do
    out[#out + 1] = {
      label = it.label,
      insertText = it.key,
      filterText = it.key,
      kind = "Reference",
      source_name = "organ_cite",
    }
  end
  callback({ items = out })
end

return M
