-- Normalization for the todo-time gate; each rule is justified in
-- NORMALIZE.md.
return function(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^%*+ ") then
      line = line:gsub("[ \t]+$", "")
    end
    out[#out + 1] = line
  end
  if out[#out] == "" then
    out[#out] = nil
  end
  return table.concat(out, "\n") .. "\n"
end
