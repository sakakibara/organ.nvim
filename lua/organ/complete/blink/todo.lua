-- blink.cmp source: TODO keyword at headline start.

local M = {}

function M.new(_opts, _source_config)
  return setmetatable({}, { __index = M })
end

function M:enabled()
  return vim.bo.filetype == "org"
end

function M:get_completions(_ctx, callback)
  local mod = require("organ.complete.todo")
  local p = mod.cursor_partial(0)
  -- skip_empty: empty partial suppresses (todo right after `* `).
  if p == nil or p == "" then
    callback({ items = {} })
    return
  end
  local out = {}
  for _, it in ipairs(mod.completion_items(p)) do
    out[#out + 1] = {
      label = it.label,
      insertText = it.insertText,
      filterText = it.filterText,
      kind = it.kind or "Keyword",
      detail = it.detail,
      source_name = "organ_todo",
    }
  end
  callback({ items = out })
end

return M
