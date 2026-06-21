-- Regenerate tests/fixtures/commonmark/spec.json from a local copy of the
-- pinned CommonMark spec.txt (version 0.31.2).  Portable pure Lua (no shell):
--   nvim -l scripts/gen-commonmark-spec.lua path/to/spec.txt
-- Example blocks in spec.txt are fenced with >=32 backticks then ` example`;
-- markdown and html are separated by a line of `.`.  U+2192 marks a tab.
local src = arg[1] or "spec.txt"
local out = arg[2] or "tests/fixtures/commonmark/spec.json"

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
  return (table.concat(xs, "\n"):gsub("\226\134\146", "\t")) -- U+2192 -> tab
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
  if lines[i]:match("^`+%s*example%s*$") and #lines[i]:match("^(`+)") >= 32 then
    i = i + 1
    local md = {}
    while i <= #lines and lines[i] ~= "." do
      md[#md + 1] = lines[i]
      i = i + 1
    end
    i = i + 1
    local html = {}
    while i <= #lines do
      local ticks = lines[i]:match("^(`+)")
      if ticks and #ticks >= 32 then
        break
      end
      html[#html + 1] = lines[i]
      i = i + 1
    end
    n = n + 1
    examples[#examples + 1] = {
      markdown = dec(md) .. (#md > 0 and "\n" or ""),
      html = dec(html) .. (#html > 0 and "\n" or ""),
      example = n,
      section = section,
    }
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
print(string.format("wrote %d examples to %s", #examples, out))
