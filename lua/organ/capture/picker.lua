-- Capture picker: snacks + vim.ui.select fallback.

local M = {}

local function format_item(t)
  local key = t.key or " "
  local desc = t.description and ("  —  " .. t.description) or ""
  return string.format("[%s]  %s%s", key, t.name, desc)
end

function M.pick(templates, on_select)
  if not templates or #templates == 0 then
    require("organ.notify").warn("no capture templates configured")
    return
  end

  vim.ui.select(templates, {
    prompt = "Capture template: ",
    format_item = format_item,
  }, function(choice)
    if choice and on_select then
      on_select(choice)
    end
  end)
end

return M
