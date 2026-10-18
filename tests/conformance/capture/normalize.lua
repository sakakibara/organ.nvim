-- Capture gate normalization (rules and reasons in NORMALIZE.md):
--   1. An error report keeps only the fact that an error was signalled.
--   2. A UUID the case did not contain is replaced by a label naming the
--      element whose :ID: holds it (file and heading), or by a number in
--      order of appearance when no :ID: line holds it.
--   3. File sections are re-sorted by path once labels replaced the IDs
--      that paths may contain.

local root = vim.fn.getcwd()
local H = "%x"
local UUID = table.concat({ H:rep(8), H:rep(4), H:rep(4), H:rep(4), H:rep(12) }, "%-")

local function plain_gsub(s, from, to)
  local out, i = {}, 1
  while true do
    local a, b = s:find(from, i, true)
    if not a then
      break
    end
    out[#out + 1] = s:sub(i, a - 1) .. to
    i = b + 1
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out)
end

local function heading_text(line)
  local t = line:gsub("^%*+%s*", ""):gsub("%s+:[%w_@#%%:]+:%s*$", ""):gsub("%s+$", "")
  return t
end

-- Labels for generated UUIDs, by the element whose :ID: line holds them.
local function id_labels(text, given)
  local labels, order = {}, {}
  local file, heading = "", nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local f = line:match("^=== (.+)$")
    if f then
      file, heading = f, nil
    elseif line:match("^%*+ ") then
      heading = heading_text(line)
    else
      local id = line:match("^%s*:ID:%s+(" .. UUID .. ")%s*$")
      if id and not labels[id] and not given:find(id, 1, true) then
        labels[id] = "<ID of " .. file .. "::" .. (heading or "") .. ">"
        order[#order + 1] = id
      end
    end
  end
  local n = 0
  for id in text:gmatch(UUID) do
    if not labels[id] and not given:find(id, 1, true) then
      n = n + 1
      labels[id] = "<UUID-" .. n .. ">"
      order[#order + 1] = id
    end
  end
  return labels, order
end

-- Re-sort the trailing "=== path" ... "<<EOF>>" sections by path; text
-- whose tail is not a clean run of sections is left as it is.
local function sort_sections(text)
  local start = text:find("\n=== ", 1, true)
  if text:sub(1, 4) == "=== " then
    start = 0
  end
  if not start then
    return text
  end
  local head, tail = text:sub(1, start), text:sub(start + 1)
  local sections = {}
  local pos = 1
  while pos <= #tail do
    if tail:sub(pos, pos + 3) ~= "=== " then
      return text
    end
    local stop = tail:find("<<EOF>>\n", pos, true)
    if not stop then
      return text
    end
    sections[#sections + 1] = tail:sub(pos, stop + 7)
    pos = stop + 8
  end
  table.sort(sections, function(a, b)
    return a:match("^[^\n]*") < b:match("^[^\n]*")
  end)
  return head .. table.concat(sections)
end

return function(text, _, case)
  local f = io.open(root .. "/tests/conformance/capture/cases/" .. case, "rb")
  local given = f and f:read("*a") or ""
  if f then
    f:close()
  end
  local labels, order = id_labels(text, given)
  for _, id in ipairs(order) do
    text = plain_gsub(text, id:sub(1, 2) .. "/" .. id:sub(3), labels[id] .. " as dir")
    text = plain_gsub(text, id, labels[id])
  end
  text = text:gsub("\nERROR: [^\n]*", "\nERROR"):gsub("^ERROR: [^\n]*", "ERROR")
  return sort_sections(text)
end
