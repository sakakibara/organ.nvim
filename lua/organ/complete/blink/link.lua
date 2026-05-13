-- blink.cmp source: [[id: / [[* / [[file: / [[attachment: / [[<PROP>: link
-- completion. Delegates to organ.complete.{trigger_at_cursor,items_for}.

local M = {}

function M.new(_opts, _source_config)
  return setmetatable({}, { __index = M })
end

function M:enabled()
  return vim.bo.filetype == "org"
end

function M:get_trigger_characters()
  return { ":", "*" }
end

function M:get_completions(_ctx, callback)
  local complete = require("organ.complete")
  local trigger = complete.trigger_at_cursor(0)
  if not trigger then
    callback({ items = {} })
    return
  end
  local items = complete.items_for(trigger.kind, trigger.query) or {}
  local out = {}
  for _, it in ipairs(items) do
    out[#out + 1] = {
      label = it.display,
      insertText = string.format("%s][%s]]", it.insert_text, it.description),
      kind = "Reference",
      source_name = "organ_link",
    }
  end
  callback({ items = out })
end

return M
