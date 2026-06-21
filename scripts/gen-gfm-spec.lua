-- Regenerate tests/fixtures/gfm/spec.json from a local copy of the cmark-gfm
-- test spec.txt -- ONLY the GFM extension sections.  Portable pure Lua:
--   nvim -l scripts/gen-gfm-spec.lua path/to/spec.txt
-- Example blocks are fenced with >=3 backticks then `example`; markdown and
-- html are separated by a line of `.`.  U+2192 marks a tab.
local src = arg[1] or "spec.txt"
local out = arg[2] or "tests/fixtures/gfm/spec.json"

local function jstr(s)
  s = s:gsub('[%z\1-\31\\"]', function(c)
    local b = c:byte()
    if c == '"' then
      return '\\"'
    elseif c == "\\" then
      return "\\\\"
    elseif c == "\n" then
      return "\\n"
    elseif c == "\t" then
      return "\\t"
    elseif c == "\r" then
      return "\\r"
    elseif b == 8 then
      return "\\b"
    elseif b == 12 then
      return "\\f"
    else
      return string.format("\\u%04x", b)
    end
  end)
  return '"' .. s .. '"'
end

local function dec(xs)
  return (table.concat(xs, "\n"):gsub("\226\134\146", "\t"))
end

local lines = {}
for line in io.lines(src) do
  lines[#lines + 1] = line
end

local examples = {}
local section = ""
local n = 0
local i = 1
while i <= #lines do
  local h = lines[i]:match("^#+%s+(.*)$")
  if h then
    section = (h:gsub("%s+$", ""))
  end
  local ot = lines[i]:match("^(`+)%s*example")
  if ot and #ot >= 3 then
    local fence_len = #ot
    i = i + 1
    local md = {}
    while i <= #lines and lines[i] ~= "." do
      md[#md + 1] = lines[i]
      i = i + 1
    end
    i = i + 1
    local html = {}
    while i <= #lines do
      local ct = lines[i]:match("^(`+)%s*$")
      if ct and #ct >= fence_len then
        break
      end
      html[#html + 1] = lines[i]
      i = i + 1
    end
    n = n + 1
    if section:find("(extension)", 1, true) then
      examples[#examples + 1] = {
        markdown = dec(md) .. (#md > 0 and "\n" or ""),
        html = dec(html) .. (#html > 0 and "\n" or ""),
        example = n,
        section = section,
      }
    end
  end
  i = i + 1
end

local parts = {}
for _, e in ipairs(examples) do
  parts[#parts + 1] = table.concat({
    "{",
    '"markdown": ' .. jstr(e.markdown) .. ",",
    '"html": ' .. jstr(e.html) .. ",",
    '"example": ' .. e.example .. ",",
    '"section": ' .. jstr(e.section),
    "}",
  }, "\n")
end
local fh = assert(io.open(out, "w"))
fh:write("[\n" .. table.concat(parts, ",\n") .. "\n]")
fh:close()
print(string.format("wrote %d GFM extension examples to %s", #examples, out))
