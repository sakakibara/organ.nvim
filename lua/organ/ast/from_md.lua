-- Markdown importer: md text -> organ AST.  Hand-written CommonMark + GFM
-- parser (no third-party dependency).  Never throws on content -- unrecognised
-- input degrades to literal paragraph text.
local ast = require("organ.ast")

local M = {}

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

-- Ordered block starters. Each is fn(parser, line) and returns true if it
-- consumed the line (opening/continuing its own block). Tasks 2-5 append to
-- this list in CommonMark precedence order. The paragraph fallback runs only
-- when no starter claims the line.
M._block_starters = {}

local Parser = {}
Parser.__index = Parser

function Parser.new()
  return setmetatable({ blocks = {}, open_para = {}, lines = {}, i = 0 }, Parser)
end

function Parser:close_para()
  if #self.open_para > 0 then
    self.blocks[#self.blocks + 1] = ast.paragraph({ ast.text(table.concat(self.open_para, "\n")) })
    self.open_para = {}
  end
end

function Parser:add_block(node)
  self:close_para()
  self.blocks[#self.blocks + 1] = node
end

function M.parse(text)
  local p = Parser.new()
  p.lines = split_lines(text or "")
  p.i = 1
  while p.i <= #p.lines do
    local line = p.lines[p.i]
    local consumed = false
    if is_blank(line) then
      p:close_para()
      consumed = true
    else
      for _, starter in ipairs(M._block_starters) do
        if starter(p, line) then
          consumed = true
          break
        end
      end
    end
    if not consumed then
      p.open_para[#p.open_para + 1] = line
    end
    p.i = p.i + 1
  end
  p:close_para()
  return ast.document(p.blocks)
end

return M
