-- Second-phase inline parser: re-parses a block's flat text into inline AST
-- nodes.  Runs after the block parse completes (so link reference definitions
-- are fully collected).  A position-advancing scanner: literal characters
-- accumulate into a buffer that flushes to an ast.text node whenever a special
-- construct is recognised.  This file currently handles backslash escapes;
-- code spans, breaks, autolinks, raw HTML are added incrementally.
local ast = require("organ.ast")

local M = {}

local ASCII_PUNCT = {}
for ch in ("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"):gmatch(".") do
  ASCII_PUNCT[ch] = true
end

function M.parse(text, _refmap)
  text = text or ""
  local nodes = {}
  local buf = {}
  local function flush()
    if #buf > 0 then
      nodes[#nodes + 1] = ast.text(table.concat(buf))
      buf = {}
    end
  end
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == "\\" and i < n and ASCII_PUNCT[text:sub(i + 1, i + 1)] then
      buf[#buf + 1] = text:sub(i + 1, i + 1)
      i = i + 2
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  flush()
  return nodes
end

return M
