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

-- ATX heading: up to 3 leading spaces, 1-6 '#', then a space or EOL.
local function atx_heading(p, line)
  local hashes, rest = line:match("^ ? ? ?(#+)%s+(.*)$")
  if not hashes then
    hashes = line:match("^ ? ? ?(#+)%s*$") -- empty heading
    if hashes then
      rest = ""
    end
  end
  if not hashes or #hashes > 6 then
    return false
  end
  -- Strip an optional closing run of '#' (preceded by space) and trim.
  local content = (rest or ""):gsub("%s+#+%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  p:add_block(ast.headline({ level = #hashes, title = { ast.text(content) }, children = {} }))
  return true
end
M._block_starters[#M._block_starters + 1] = atx_heading

local function thematic_break(p, line)
  local body = line:match("^ ? ? ?([%-%*_].*)$")
  if not body then
    return false
  end
  local stripped = body:gsub("%s", "")
  local ch = stripped:sub(1, 1)
  if #stripped < 3 or stripped:match("[^" .. "%" .. ch .. "]") then
    return false
  end
  -- Defer the "--- under a paragraph = setext h2" case to the setext task.
  if ch == "-" and #p.open_para > 0 then
    return false
  end
  p:add_block(ast.rule())
  return true
end
M._block_starters[#M._block_starters + 1] = thematic_break

local function fenced_code(p, line)
  local indent, fence, info = line:match("^( ? ? ?)([`~][`~][`~]+)%s*(.*)$")
  if not fence then
    return false
  end
  local fence_char = fence:sub(1, 1)
  -- Backtick info strings cannot contain a backtick.
  if fence_char == "`" and info:find("`", 1, true) then
    return false
  end
  local lang = info:match("^(%S+)")
  local body_lines = {}
  local j = p.i + 1
  while j <= #p.lines do
    local l = p.lines[j]
    local close = l:match("^ ? ? ?([`~]+)%s*$")
    if close and close:sub(1, 1) == fence_char and #close >= #fence then
      break
    end
    -- Strip up to `#indent` leading spaces from each body line.
    body_lines[#body_lines + 1] = l:gsub("^" .. string.rep(" ", #indent), "")
    j = j + 1
  end
  -- When unclosed, split_lines appends a trailing "" artifact; remove it.
  if j > #p.lines then
    while #body_lines > 0 and body_lines[#body_lines] == "" do
      body_lines[#body_lines] = nil
    end
  end
  local body = #body_lines > 0 and (table.concat(body_lines, "\n") .. "\n") or ""
  p:add_block(ast.code_block(lang, body))
  p.i = (j <= #p.lines) and j or #p.lines -- land on the closing fence (or last line)
  return true
end
M._block_starters[#M._block_starters + 1] = fenced_code

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
