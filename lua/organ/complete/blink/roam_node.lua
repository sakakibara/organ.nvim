-- blink.cmp source: org-roam node-title completion. Fires on every
-- word-fragment in an .org buffer (no trigger character). Surfaces
-- matching node titles + aliases as `[[id:UUID][title]]` insertions.
-- Mirrors Emacs `org-roam-completion-everywhere`.

local M = {}

function M.new(_opts, _source_config)
  return setmetatable({}, { __index = M })
end

function M:enabled()
  return vim.bo.filetype == "org"
end

function M:get_completions(_ctx, callback)
  local lk = require("organ.roam.linkify")
  local query = lk.cursor_partial(0)
  if query == "" then
    callback({ items = {} })
    return
  end
  local raw = lk.completion_items(query)
  local out = {}
  for _, it in ipairs(raw) do
    out[#out + 1] = {
      label = it.label,
      insertText = it.insertText,
      filterText = it.filterText,
      kind = "Reference",
      source_name = "organ_roam_node",
    }
  end
  callback({ items = out })
end

return M
