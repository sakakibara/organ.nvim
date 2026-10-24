-- organ side of the elisp conformance gate: reads each item of a case
-- through organ.elisp and prints one line per item in the shape
-- emacs.el prints (see NORMALIZE.md).

local elisp = require("organ.elisp")

local M = {}

local MODES = { read = true }

local function blocks_of(text)
  local blocks, cur = {}, nil
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line == "" then
      if cur then
        blocks[#blocks + 1] = cur
        cur = nil
      end
    else
      cur = cur or {}
      cur[#cur + 1] = line
    end
  end
  if cur then
    blocks[#blocks + 1] = cur
  end
  return blocks
end

--- Header and items of case text: header is a key -> value map of the
--- first block's `; key: value` lines; each item is { naive, source }.
function M.parse(text)
  local blocks = blocks_of(text)
  local header = {}
  for _, l in ipairs(blocks[1] or {}) do
    if l:sub(1, 1) ~= ";" then
      error("case has no header block")
    end
    local k, v = l:match("^; ([a-z_]+): *(.*)$")
    if k then
      header[k] = v
    end
  end
  local items = {}
  for b = 2, #blocks do
    local lines = blocks[b]
    local naive
    local i = 1
    while lines[i] and lines[i]:sub(1, 9) == "; naive: " do
      naive = lines[i]:sub(10)
      i = i + 1
    end
    items[#items + 1] = { naive = naive, source = table.concat(lines, "\n", i) }
  end
  return header, items
end

local function oneline(s)
  return (s:gsub("\n", "\\n"))
end

local function failure_line(r)
  if r.kind == "signal" then
    return "!! " .. (r.text and oneline(r.text) or (r.symbol .. " <unprintable>"))
  elseif r.kind == "refused" then
    return "REFUSED " .. r.code .. (r.detail and (" " .. oneline(r.detail)) or "")
  end
  return "LIMIT " .. r.cap
end

local function read_item(source)
  local r = elisp.read(source, 1)
  if not r.ok then
    return failure_line(r)
  end
  local p = elisp.prin1(r.value, { escape_newlines = true })
  if not p.ok then
    return failure_line(p)
  end
  return "=> " .. p.value
end

function M.render(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  local header, items = M.parse(text)
  if not MODES[header.mode] then
    error("unknown mode " .. tostring(header.mode))
  end
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = read_item(item.source) .. "\n"
  end
  return table.concat(out)
end

return M
