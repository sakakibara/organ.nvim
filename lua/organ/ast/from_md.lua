-- Markdown importer: md text -> organ AST.  Hand-written CommonMark + GFM
-- parser (no third-party dependency).  Never throws on content -- unrecognised
-- input degrades to literal paragraph text.
--
-- Architecture: CommonMark's open-blocks stack.  The document is parsed one
-- line at a time against a stack of currently-open blocks.  Currently the
-- stack contains the root `document` container plus at most one open leaf
-- block (the `tip`).  Per-container continuation and marker-stripping for
-- block quotes and lists are not yet handled; only the document container
-- is present.  Each line tries block starts against the current tip, then
-- feeds text to an open paragraph (lazy continuation).  Closing a block
-- finalises it to the same `ast.*` node the renderer expects.
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

local function strip(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Leaf recognisers.  Each inspects the marker-stripped line and, when it begins
-- a block, returns a fresh open-block table (see Block types below); otherwise
-- nil.  The regexes and edge cases are the proven CommonMark behaviour; only the
-- delivery (per-line, returning an open block instead of mutating a parser)
-- differs.

-- ATX heading: up to 3 leading spaces, 1-6 '#', then a space or EOL.  Closed
-- immediately (single-line leaf).
local function atx_heading(line)
  local hashes, rest = line:match("^ ? ? ?(#+)%s+(.*)$")
  if not hashes then
    hashes = line:match("^ ? ? ?(#+)%s*$") -- empty heading
    if hashes then
      rest = ""
    end
  end
  if not hashes or #hashes > 6 then
    return nil
  end
  -- Strip an optional closing run of '#' (preceded by space) and trim.
  local content = strip((rest or ""):gsub("%s+#+%s*$", ""))
  -- A content that is entirely '#' characters (no preceding space, e.g.
  -- "### ###") is itself a closing run per CommonMark; treat it as empty.
  if content:match("^#+%s*$") then
    content = ""
  end
  return {
    type = "heading",
    level = #hashes,
    content = content,
    children = {},
    closed_immediately = true,
  }
end

-- Thematic break: <=3 spaces, then >=3 of a single '-', '*' or '_' (spaces
-- allowed between).  A '-' run under an open paragraph is deferred to setext.
local function thematic_break(line, tip_is_paragraph)
  local body = line:match("^ ? ? ?([%-%*_].*)$")
  if not body then
    return nil
  end
  local stripped = body:gsub("%s", "")
  local ch = stripped:sub(1, 1)
  if #stripped < 3 or stripped:match("[^" .. "%" .. ch .. "]") then
    return nil
  end
  if ch == "-" and tip_is_paragraph then
    return nil -- "---" under a paragraph is a setext underline, not a break
  end
  return { type = "thematic_break", children = {}, closed_immediately = true }
end

-- Fenced code: <=3 space indent, then >=3 backticks or tildes, then an info
-- string.  Opens a leaf that accumulates body lines until its closing fence.
local function fenced_code(line)
  local indent, fence, info = line:match("^( ? ? ?)([`~][`~][`~]+)%s*(.*)$")
  if not fence then
    return nil
  end
  local fence_char = fence:sub(1, 1)
  -- Backtick info strings cannot contain a backtick.
  if fence_char == "`" and info:find("`", 1, true) then
    return nil
  end
  local lang = info:match("^(%S+)")
  return {
    type = "code_block",
    variant = "fenced",
    fence_char = fence_char,
    fence_len = #fence,
    indent = #indent,
    lang = lang,
    body = {},
    closed = false,
    children = {},
  }
end

-- A fenced code block's closing fence: same char, length >= the opener, <=3
-- space indent, nothing else but trailing whitespace.
local function is_closing_fence(block, line)
  local close = line:match("^ ? ? ?([`~]+)%s*$")
  return close and close:sub(1, 1) == block.fence_char and #close >= block.fence_len
end

-- Indented code: a line indented >=4 spaces that does not continue a paragraph.
-- Opens a leaf that accumulates indented and interior-blank lines.
local function indented_code(line)
  if not line:match("^    ") then
    return nil
  end
  return { type = "code_block", variant = "indented", body = {}, children = {} }
end

-- Setext underline: '=' (level 1) or '-' (level 2) run under an open paragraph.
-- Returns the heading level, or nil.
local function setext_level(line)
  if line:match("^ ? ? ?=+%s*$") then
    return 1
  elseif line:match("^ ? ? ?%-+%s*$") then
    return 2
  end
  return nil
end

-- Link reference definition: [label]: destination optional-title, at a fresh
-- block position (cannot interrupt a paragraph).  Records into `refmap` and
-- emits no block.  Returns true when consumed.
local function link_ref_def(line, refmap)
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
  local key = label:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower()
  if refmap[key] == nil then -- first definition wins
    refmap[key] = { destination = dest, title = title }
  end
  return true
end

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

-- HTML block opener.  Kinds 1-6 may interrupt a paragraph; kind 7 may not.
-- Opens a leaf that accumulates lines until the kind's end condition.
local function html_block(line, tip_is_paragraph)
  local s = line:match("^ ? ? ?(<.*)$")
  if not s then
    return nil
  end
  local kind, ends, inclusive = html_block_start(s)
  if not kind then
    return nil
  end
  if kind == 7 and tip_is_paragraph then
    return nil
  end
  return {
    type = "html_block",
    kind = kind,
    ends = ends,
    inclusive = inclusive,
    body = {},
    closed = false,
    children = {},
  }
end

-- Finalising an open block to the AST node the renderer consumes.  These mirror
-- the previous leaf-by-leaf output exactly so the renderer and roundtrip are
-- unchanged.

local function trim_trailing_blank(lines)
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
end

local function finalize(block)
  local t = block.type
  if t == "paragraph" then
    return ast.paragraph({ ast.text(table.concat(block.lines, "\n")) })
  elseif t == "heading" then
    return ast.headline({
      level = block.level,
      title = { ast.text(block.content) },
      children = {},
    })
  elseif t == "thematic_break" then
    return ast.rule()
  elseif t == "code_block" then
    local body_lines = block.body
    if block.variant == "fenced" then
      -- Unclosed fence ran to EOF; the doubled-newline split artifact leaves a
      -- trailing blank line that is not part of the body.
      if not block.closed then
        trim_trailing_blank(body_lines)
      end
      local body = #body_lines > 0 and (table.concat(body_lines, "\n") .. "\n") or ""
      return ast.code_block(block.lang, body)
    else
      trim_trailing_blank(body_lines)
      return ast.code_block(nil, table.concat(body_lines, "\n") .. "\n")
    end
  elseif t == "html_block" then
    local body_lines = block.body
    -- Unclosed inclusive kinds (1-5) run to EOF; drop the split artifact blank.
    if block.inclusive and not block.closed then
      trim_trailing_blank(body_lines)
    end
    return ast.block("export", { body = table.concat(body_lines, "\n") .. "\n", backend = "html" })
  end
  return nil
end

-- Parser state: an open-blocks stack rooted at `document`.  `stack[1]` is the
-- document container; the last element is the `tip`.  Containers hold `children`
-- (already-finalised child blocks); the tip leaf accumulates raw text.
local Parser = {}
Parser.__index = Parser

function Parser.new()
  local doc = { type = "document", children = {} }
  return setmetatable({ stack = { doc }, refmap = {} }, Parser)
end

function Parser:tip()
  return self.stack[#self.stack]
end

-- Finalise and pop the tip leaf, attaching its node to its parent container.
function Parser:close_tip()
  local n = #self.stack
  if n <= 1 then
    return
  end
  local block = self.stack[n]
  self.stack[n] = nil
  local node = finalize(block)
  if node then
    local parent = self.stack[#self.stack]
    parent.children[#parent.children + 1] = node
  end
end

-- Close every open block above the document, deepest first.
function Parser:close_to_document()
  while #self.stack > 1 do
    self:close_tip()
  end
end

function Parser:push(block)
  self.stack[#self.stack + 1] = block
end

-- Try the leaf starters, in proven CommonMark precedence, against the
-- marker-stripped `line`.  Returns true if the line opened (and possibly closed)
-- a block or was consumed as a reference definition.
function Parser:try_starts(line)
  local tip = self:tip()
  local tip_para = tip.type == "paragraph"

  -- Setext underline converts an open paragraph in place; check before other
  -- starts so "---" under a paragraph becomes an h2 rather than a break.
  if tip_para then
    local level = setext_level(line)
    if level then
      local n = #self.stack
      local para = self.stack[n]
      self.stack[n] = nil
      local parent = self.stack[#self.stack]
      parent.children[#parent.children + 1] = ast.headline({
        level = level,
        title = { ast.text(strip(table.concat(para.lines, "\n"))) },
        children = {},
      })
      return true
    end
  end

  local block = atx_heading(line)
    or thematic_break(line, tip_para)
    or fenced_code(line)
    or (not tip_para and indented_code(line))
    or html_block(line, tip_para)
  if block then
    if tip_para then
      self:close_tip()
    end
    self:push(block)
    if block.closed_immediately then
      self:close_tip()
    elseif block.type == "code_block" and block.variant == "indented" then
      -- The opening line is itself the first body line.
      block.body[#block.body + 1] = line:gsub("^    ", "")
    elseif block.type == "html_block" then
      -- The opening line is part of the verbatim body; it may also already
      -- satisfy the end condition (a one-line comment, a closed pre, etc.).
      self:feed_open_leaf(line)
    end
    return true
  end

  -- Link reference definitions only at a fresh block position.
  if not tip_para and link_ref_def(line, self.refmap) then
    return true
  end

  return false
end

-- Feed one line to the tip when it is an open leaf still accumulating across
-- lines (fenced code or an html block).  Returns true if the line was consumed.
function Parser:feed_open_leaf(line)
  local tip = self:tip()
  if tip.type == "code_block" and tip.variant == "fenced" then
    if is_closing_fence(tip, line) then
      tip.closed = true
      self:close_tip()
    else
      tip.body[#tip.body + 1] = line:gsub("^" .. string.rep(" ", tip.indent), "")
    end
    return true
  elseif tip.type == "html_block" then
    if tip.ends(line) then
      if tip.inclusive then
        tip.body[#tip.body + 1] = line -- kinds 1-5: end line is part of the block
      end
      -- Kinds 6/7: end condition is a blank line, not included in the block.
      tip.closed = true
      self:close_tip()
    else
      tip.body[#tip.body + 1] = line
    end
    return true
  end
  return false
end

function Parser:add_line(line)
  -- Step 1: an open accumulating leaf (fenced code / html block) swallows the
  -- line directly.
  if self:feed_open_leaf(line) then
    return
  end

  local tip = self:tip()

  -- An open indented-code leaf keeps absorbing indented and interior-blank
  -- lines; any other non-blank line ends it and is reprocessed as a start.
  if tip.type == "code_block" and tip.variant == "indented" then
    if line:match("^    ") then
      tip.body[#tip.body + 1] = line:gsub("^    ", "")
      return
    elseif is_blank(line) then
      tip.body[#tip.body + 1] = ""
      return
    else
      self:close_tip()
      tip = self:tip()
    end
  end

  if is_blank(line) then
    -- A blank line closes an open paragraph; otherwise it is just consumed.
    if tip.type == "paragraph" then
      self:close_tip()
    end
    return
  end

  -- Step 2: new block starts.
  if self:try_starts(line) then
    return
  end

  -- Step 3: lazy continuation / paragraph text.
  tip = self:tip()
  if tip.type == "paragraph" then
    tip.lines[#tip.lines + 1] = line
  else
    self:push({ type = "paragraph", lines = { line }, children = {} })
  end
end

function M.parse(text)
  local p = Parser.new()
  for _, line in ipairs(split_lines(text or "")) do
    p:add_line(line)
  end
  p:close_to_document()
  local doc = ast.document(p.stack[1].children)
  doc.reference_map = p.refmap
  return doc
end

return M
