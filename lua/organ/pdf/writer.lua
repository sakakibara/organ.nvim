-- Pure-Lua PDF object-model writer. Emits a PDF 1.7 document as a
-- byte string: header, indirect objects in allocation order, xref
-- table with correct byte offsets, and trailer. No content semantics
-- (no fonts, no pages, no text positioning) -- callers build those
-- on top by composing dicts, arrays, and streams.
--
-- MVP omits compression: streams are written uncompressed. /Filter is
-- never injected; callers must not pass /Filter /FlateDecode.

local M = {}

-- Encoding primitives.

-- Escape a literal string body per PDF 7.3.4.2: backslash, open paren,
-- close paren get backslash-prefixed. Other bytes pass through (the
-- writer doesn't try to escape control chars; callers that need them
-- should use hex_string instead).
local function escape_literal(s)
  return (s:gsub("\\", "\\\\"):gsub("%(", "\\("):gsub("%)", "\\)"))
end

-- Number formatting: integers as decimal, floats with no trailing
-- zeros (PDF tolerates both; minimizing bytes is enough).
local function encode_number(n)
  if n % 1 == 0 and n > -1e15 and n < 1e15 then
    return tostring(math.floor(n))
  end
  -- Float: %.10g trims trailing zeros and avoids scientific for the
  -- magnitudes a PDF actually uses (coordinates, widths, scales).
  local s = string.format("%.10g", n)
  -- string.format may emit "1e+05" for large numbers; PDF readers
  -- accept that but the spec prefers plain decimal. The MVP keeps %g
  -- output -- if it ever bites, this is the spot to fix.
  return s
end

-- Detect array-shape vs dict-shape. An array has a non-nil [1]; an
-- empty table serializes as empty array (PDF doesn't distinguish).
local function is_array(t)
  return t[1] ~= nil or next(t) == nil
end

-- Forward decl so encode_value and encode_dict / encode_array can
-- recurse.
local encode_value

local function encode_dict(t)
  -- Iterate keys in sorted order for deterministic output (the PDF
  -- spec doesn't care about key order, but stable bytes help tests
  -- and diffs). Skip __pdf_kind sentinel and any non-string keys.
  local keys = {}
  for k in pairs(t) do
    if type(k) == "string" and k ~= "__pdf_kind" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  if #keys == 0 then
    return "<< >>"
  end
  local parts = { "<<" }
  for _, k in ipairs(keys) do
    parts[#parts + 1] = " /" .. k .. " " .. encode_value(t[k])
  end
  parts[#parts + 1] = " >>"
  return table.concat(parts)
end

local function encode_array(t)
  local parts = { "[" }
  for i = 1, #t do
    parts[#parts + 1] = " " .. encode_value(t[i])
  end
  parts[#parts + 1] = " ]"
  return table.concat(parts)
end

-- Stream serialization: dict gets /Length auto-injected from #data;
-- never /Filter (uncompressed only). Output is dict + LF + "stream" +
-- LF + raw data + LF + "endstream".
local function encode_stream(t)
  local dict = {}
  for k, v in pairs(t.dict or {}) do
    dict[k] = v
  end
  dict.Length = #t.data
  return encode_dict(dict) .. "\nstream\n" .. t.data .. "\nendstream"
end

encode_value = function(v)
  local tv = type(v)
  if tv == "boolean" then
    return v and "true" or "false"
  elseif tv == "nil" then
    return "null"
  elseif tv == "number" then
    return encode_number(v)
  elseif tv == "string" then
    local first = v:sub(1, 1)
    if first == "/" or first == "<" then
      -- Pre-encoded name or hex/dict literal: pass through.
      return v
    end
    return "(" .. escape_literal(v) .. ")"
  elseif tv == "table" then
    -- Indirect ref: { num = N } (and ONLY num + optional gen).
    if type(v.num) == "number" and v.__pdf_kind == nil then
      -- Distinguish refs from dicts that happen to have a "num" key.
      -- Refs are produced exclusively by writer.ref / w:alloc, both
      -- of which set num only. A user-built dict carrying a "num"
      -- field would also have other keys; refs never do.
      local only_num = true
      for k in pairs(v) do
        if k ~= "num" then
          only_num = false
          break
        end
      end
      if only_num then
        return v.num .. " 0 R"
      end
    end
    if v.__pdf_kind == "stream" then
      return encode_stream(v)
    end
    if v.__pdf_kind == "array" then
      return encode_array(v)
    end
    if v.__pdf_kind == "dict" then
      return encode_dict(v)
    end
    if is_array(v) then
      return encode_array(v)
    end
    -- Tables with __tostring metamethod: defer to it.
    local mt = getmetatable(v)
    if mt and mt.__tostring then
      return tostring(v)
    end
    return encode_dict(v)
  end
  error("cannot encode value of type " .. tv)
end

-- Public helpers.

function M.name(s)
  return "/" .. s
end

function M.string(s)
  return "(" .. escape_literal(s) .. ")"
end

function M.hex_string(s)
  return "<"
    .. (s:gsub(".", function(c)
      return string.format("%02x", string.byte(c))
    end))
    .. ">"
end

function M.stream(data, dict_extra)
  return { __pdf_kind = "stream", dict = dict_extra or {}, data = data }
end

function M.dict(t)
  -- Semantic alias; the encoder treats plain tables with string keys
  -- as dicts already. Tagging makes intent explicit when the dict is
  -- empty (which would otherwise serialize as an empty array).
  t.__pdf_kind = "dict"
  return t
end

function M.array(t)
  t.__pdf_kind = "array"
  return t
end

function M.ref(num)
  return { num = num }
end

M.helpers = {
  name = M.name,
  string = M.string,
  hex_string = M.hex_string,
  stream = M.stream,
  dict = M.dict,
  array = M.array,
  ref = M.ref,
}

-- Writer instance.

local Writer = {}
Writer.__index = Writer

function M.new()
  return setmetatable({
    -- objects[i] = { num = i, value = ... | nil if not yet set }
    objects = {},
    root_num = nil,
  }, Writer)
end

-- Allocate the next sequential object number. Returns a ref table.
function Writer:alloc()
  local num = #self.objects + 1
  self.objects[num] = { num = num, value = nil }
  return { num = num }
end

function Writer:set(ref, value)
  if type(ref) ~= "table" or type(ref.num) ~= "number" then
    error("set: expected a ref table { num = N }")
  end
  local slot = self.objects[ref.num]
  if not slot then
    error("set: unknown object number " .. tostring(ref.num))
  end
  slot.value = value
end

function Writer:add(value)
  local ref = self:alloc()
  self:set(ref, value)
  return ref
end

function Writer:set_root(ref)
  if type(ref) ~= "table" or type(ref.num) ~= "number" then
    error("set_root: expected a ref table { num = N }")
  end
  self.root_num = ref.num
end

-- Serialize the document. Throws if any allocated ref has no value
-- or if set_root wasn't called.
function Writer:bytes()
  if not self.root_num then
    error("bytes: set_root was not called")
  end
  for i = 1, #self.objects do
    if self.objects[i].value == nil then
      error("bytes: object " .. i .. " was allocated but never set")
    end
  end

  -- PDF header: %PDF-1.7 + LF + a comment line whose 4 high-bit bytes
  -- mark this file as binary for transport-layer sniffers.
  local chunks = { "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n" }
  local offset = #chunks[1]

  -- Each object: remember its starting offset for the xref table.
  local offsets = {}
  for i = 1, #self.objects do
    offsets[i] = offset
    local body = encode_value(self.objects[i].value)
    local s = i .. " 0 obj\n" .. body .. "\nendobj\n"
    chunks[#chunks + 1] = s
    offset = offset + #s
  end

  -- xref table starts at this offset.
  local xref_offset = offset
  local n = #self.objects
  local xref_parts = { "xref\n", string.format("0 %d\n", n + 1), "0000000000 65535 f \n" }
  for i = 1, n do
    xref_parts[#xref_parts + 1] = string.format("%010d 00000 n \n", offsets[i])
  end
  chunks[#chunks + 1] = table.concat(xref_parts)

  -- Trailer.
  chunks[#chunks + 1] = string.format(
    "trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n",
    n + 1,
    self.root_num,
    xref_offset
  )

  return table.concat(chunks)
end

return M
