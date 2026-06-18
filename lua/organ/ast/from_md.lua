-- Markdown importer: md text -> organ AST.  Hand-written CommonMark + GFM
-- parser (no third-party dependency).  This is the Stage 0 scaffold: it
-- recognises only blank-line-separated paragraphs; later stages add block
-- and inline structure.  Never throws on content -- unrecognised input
-- degrades to literal paragraph text.
local ast = require("organ.ast")

local M = {}

-- Split into lines without a trailing empty element for a final newline.
local function split_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

function M.parse(text)
  local lines = split_lines(text or "")
  local children = {}
  local para = {}
  local function flush()
    if #para > 0 then
      children[#children + 1] = ast.paragraph({ ast.text(table.concat(para, "\n")) })
      para = {}
    end
  end
  for _, line in ipairs(lines) do
    if is_blank(line) then
      flush()
    else
      para[#para + 1] = line
    end
  end
  flush()
  return ast.document(children)
end

return M
