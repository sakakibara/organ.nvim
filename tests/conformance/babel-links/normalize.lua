-- Output normalization for the babel-links gate (see NORMALIZE.md).

local UUID = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

return function(text)
  local ids, n = {}, 0
  text = text:gsub(UUID, function(id)
    local key = id:lower()
    if not ids[key] then
      n = n + 1
      ids[key] = "<ID" .. n .. ">"
    end
    return ids[key]
  end)
  return (text:gsub("\226\128\139", "<U+200B>"))
end
