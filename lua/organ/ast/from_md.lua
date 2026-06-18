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

-- Ordered block starters, in CommonMark precedence order. Each is
-- fn(parser, line) and returns true if it consumed the line. The paragraph
-- fallback runs only when no starter claims the line.
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
  -- A content that is entirely '#' characters (no preceding space, e.g. "### ###")
  -- is itself a closing run per CommonMark; treat it as empty.
  if content:match("^#+%s*$") then
    content = ""
  end
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

local function indented_code(p, line)
  if #p.open_para > 0 then
    return false -- paragraph continuation, not code
  end
  if not line:match("^    ") then
    return false
  end
  local body_lines = {}
  local j = p.i
  while j <= #p.lines do
    local l = p.lines[j]
    if l:match("^    ") then
      body_lines[#body_lines + 1] = l:gsub("^    ", "")
    elseif is_blank(l) then
      body_lines[#body_lines + 1] = "" -- interior blank kept for now; trimmed below
    else
      break
    end
    j = j + 1
  end
  -- Trim trailing blank lines.
  while #body_lines > 0 and body_lines[#body_lines] == "" do
    body_lines[#body_lines] = nil
  end
  p:add_block(ast.code_block(nil, table.concat(body_lines, "\n") .. "\n"))
  p.i = j - 1 -- loop will +1 to the first non-code line
  return true
end
M._block_starters[#M._block_starters + 1] = indented_code

-- Setext heading: a paragraph underlined by =+ (level 1) or -+ (level 2).
local function setext_heading(p, line)
  if #p.open_para == 0 then
    return false
  end
  local level
  if line:match("^ ? ? ?=+%s*$") then
    level = 1
  elseif line:match("^ ? ? ?%-+%s*$") then
    level = 2
  else
    return false
  end
  local title = table.concat(p.open_para, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  p.open_para = {}
  p.blocks[#p.blocks + 1] =
    ast.headline({ level = level, title = { ast.text(title) }, children = {} })
  return true
end
M._block_starters[#M._block_starters + 1] = setext_heading

-- Link reference definition: [label]: destination optional-title, at block
-- start. Consumed with no output; recorded in p.refmap for later inline use.
local function link_ref_def(p, line)
  if #p.open_para > 0 then
    return false -- a definition cannot interrupt a paragraph
  end
  local label, after = line:match("^ ? ? ?%[(.-)%]:%s*(.*)$")
  if not label or label:match("^%s*$") or label:match("[%[%]]") then
    return false
  end
  local dest, rest = after:match("^(%S+)%s*(.*)$")
  if not dest then
    return false
  end
  dest = dest:gsub("^<(.*)>$", "%1") -- strip optional angle brackets
  local title = rest:match('^"(.-)"%s*$')
    or rest:match("^'(.-)'%s*$")
    or rest:match("^%((.-)%)%s*$")
  if rest ~= "" and not title then
    return false -- trailing junk -> not a definition (treat as paragraph)
  end
  p.refmap = p.refmap or {}
  local key = label:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower()
  if p.refmap[key] == nil then -- first definition wins
    p.refmap[key] = { destination = dest, title = title }
  end
  return true
end
M._block_starters[#M._block_starters + 1] = link_ref_def

local HTML_BLOCK_TAGS = {}
for _, t in ipairs({
  "address",
  "article",
  "aside",
  "base",
  "basefont",
  "blockquote",
  "body",
  "caption",
  "center",
  "col",
  "colgroup",
  "dd",
  "details",
  "dialog",
  "dir",
  "div",
  "dl",
  "dt",
  "fieldset",
  "figcaption",
  "figure",
  "footer",
  "form",
  "frame",
  "frameset",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "head",
  "header",
  "hr",
  "html",
  "iframe",
  "legend",
  "li",
  "link",
  "main",
  "menu",
  "menuitem",
  "nav",
  "noframes",
  "ol",
  "optgroup",
  "option",
  "p",
  "param",
  "search",
  "section",
  "summary",
  "table",
  "tbody",
  "td",
  "tfoot",
  "th",
  "thead",
  "title",
  "tr",
  "track",
  "ul",
}) do
  HTML_BLOCK_TAGS[t] = true
end

-- Returns the lowercased tag name if `s` is a complete open or closing tag
-- filling the whole line (optional trailing whitespace), nil otherwise.
local function is_complete_tag_line(s)
  -- closing tag: </name ws* >
  local close = s:match("^</([a-zA-Z][a-zA-Z0-9%-]*)%s*>%s*$")
  if close then
    return close:lower()
  end
  -- open tag: <name (attrs)* /?>
  -- Use a lazy match on content before the final > to avoid catastrophic
  -- backtracking on lines with multiple >.
  local name, rest = s:match("^<([a-zA-Z][a-zA-Z0-9%-]*)(.-)>%s*$")
  if not name then
    return nil
  end
  -- Strip optional trailing self-close marker.
  rest = rest:gsub("/%s*$", "")
  -- Strip valid attributes one at a time.  Lua patterns do not support |
  -- alternation, so the attribute-value branch is tried in three passes:
  -- double-quoted, single-quoted, unquoted.
  while true do
    local orig = rest
    -- 1. attribute with double-quoted value
    local nr = rest:gsub('^%s+[A-Za-z_:][A-Za-z0-9_.:%-]*%s*=%s*"[^"]*"', "", 1)
    if nr ~= rest then
      rest = nr
    else
      -- 2. attribute with single-quoted value
      nr = rest:gsub("^%s+[A-Za-z_:][A-Za-z0-9_.:%-]*%s*=%s*'[^']*'", "", 1)
      if nr ~= rest then
        rest = nr
      else
        -- 3. attribute with unquoted value (no spaces, quotes, =, <, >, `)
        nr = rest:gsub("^%s+[A-Za-z_:][A-Za-z0-9_.:%-]*%s*=%s*[^%s\"'=<>`]+", "", 1)
        if nr ~= rest then
          rest = nr
        else
          -- 4. valueless attribute
          nr = rest:gsub("^%s+[A-Za-z_:][A-Za-z0-9_.:%-]*", "", 1)
          if nr ~= rest then
            rest = nr
          end
        end
      end
    end
    if rest == orig then
      break
    end
  end
  if rest:match("^%s*$") then
    return name:lower()
  end
  return nil
end

-- Returns kind (1-7), an end-predicate fn(line)->bool, and whether the end line
-- is included; or nil if `s` (the line with leading <=3 spaces removed) does not
-- start an HTML block of kinds 1-7.
local function html_block_start(s)
  local low = s:lower()
  if
    low:match("^<[sptx]")
    and (
      low:match("^<script[%s>]")
      or low:match("^<script$")
      or low:match("^<pre[%s>]")
      or low:match("^<pre$")
      or low:match("^<style[%s>]")
      or low:match("^<style$")
      or low:match("^<textarea[%s>]")
      or low:match("^<textarea$")
    )
  then
    return 1,
      function(l)
        local ll = l:lower()
        return ll:find("</script>", 1, true)
          or ll:find("</pre>", 1, true)
          or ll:find("</style>", 1, true)
          or ll:find("</textarea>", 1, true)
      end,
      true
  elseif s:match("^<!%-%-") then
    return 2, function(l)
      return l:find("%-%->")
    end, true
  elseif s:match("^<%?") then
    return 3, function(l)
      return l:find("%?>")
    end, true
  elseif s:match("^<![a-zA-Z]") then
    return 4, function(l)
      return l:find(">")
    end, true
  elseif s:match("^<!%[CDATA%[") then
    return 5, function(l)
      return l:find("]]>", 1, true)
    end, true
  else
    local tag = low:match("^</?([a-z][a-z0-9]*)")
    if tag and HTML_BLOCK_TAGS[tag] then
      local after = low:match("^</?" .. tag .. "(.?)") or ""
      if after == "" or after == ">" or after:match("%s") or low:match("^</?" .. tag .. "/>") then
        return 6, function(l)
          return l:match("^%s*$")
        end, false
      end
    end
    -- Kind 7: a complete open or closing tag that fills the line, tag name not
    -- in {script, style, pre, textarea}.
    local k7name = is_complete_tag_line(s)
    if
      k7name
      and k7name ~= "script"
      and k7name ~= "style"
      and k7name ~= "pre"
      and k7name ~= "textarea"
    then
      return 7, function(l)
        return l:match("^%s*$")
      end, false
    end
  end
  return nil
end

local function html_block(p, line)
  local s = line:match("^ ? ? ?(<.*)$")
  if not s then
    return false
  end
  local kind, ends, inclusive = html_block_start(s)
  if not kind then
    return false
  end
  -- Kind 7 cannot interrupt a paragraph; kinds 1-6 can.
  if kind == 7 and #p.open_para > 0 then
    return false
  end
  local body_lines = {}
  local j = p.i
  while j <= #p.lines do
    local l = p.lines[j]
    if ends(l) then
      if inclusive then
        body_lines[#body_lines + 1] = l
        j = j + 1
      end
      break
    end
    body_lines[#body_lines + 1] = l
    j = j + 1
  end
  -- Unclosed kinds 1-5 run to EOF; split_lines appends a trailing "" artifact.
  if inclusive and j > #p.lines then
    while #body_lines > 0 and body_lines[#body_lines] == "" do
      body_lines[#body_lines] = nil
    end
  end
  p:add_block(
    ast.block("export", { body = table.concat(body_lines, "\n") .. "\n", backend = "html" })
  )
  p.i = j - 1 -- loop will +1 to the first line after the block
  return true
end
M._block_starters[#M._block_starters + 1] = html_block

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
  local doc = ast.document(p.blocks)
  doc.reference_map = p.refmap or {}
  return doc
end

return M
