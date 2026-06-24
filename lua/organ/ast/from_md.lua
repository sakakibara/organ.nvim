-- Markdown importer: md text -> organ AST.  Hand-written CommonMark + GFM
-- parser (no third-party dependency).  Never throws on content -- unrecognised
-- input degrades to literal paragraph text.
--
-- Architecture: CommonMark's open-blocks stack.  The document is parsed one
-- line at a time against a stack of currently-open blocks: the root `document`
-- container, zero or more nested containers (block quotes), and at most one open
-- leaf block (the `tip`).  Each line runs four phases: (1) walk the open
-- containers, consuming each one's continuation marker off the line and stopping
-- at the first that does not continue; (3) run block starts on the stripped
-- remainder under the deepest matched container (a start may open a new
-- container, whose content is parsed by the same machinery recursively); (4)
-- otherwise append to an open paragraph (lazy continuation, allowed even when a
-- container marker was missing) or open a fresh one.  Closing a block finalises
-- it to the same `ast.*` node the renderer expects.
local ast = require("organ.ast")

local M = {}

-- Maximum container-nesting depth.  Beyond this, further block-quote / list
-- nesting is not opened and the markers are kept as content.  It bounds the
-- open-blocks stack so per-line work stays linear on pathological input (e.g.
-- thousands of '> - ' on one line) and keeps the produced AST shallow enough
-- for the recursive renderers.  No real document -- and none of the CommonMark
-- spec examples -- nests anywhere near this deep.
local MAX_NESTING = 1000

-- Split into lines on any CommonMark line ending: a carriage return, a line
-- feed, or a carriage return + line feed are all normalized to a single break.
local function split_lines(text)
  text = text:gsub("\r\n?", "\n")
  -- Terminate only an unterminated input, so a trailing newline does not
  -- synthesise a phantom final blank line (which would otherwise show up as
  -- spurious trailing content in an unclosed fenced code block).
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  local lines = {}
  for line in text:gmatch("(.-)\n") do
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

-- Columns spanned by the leading whitespace of `s`, starting at absolute column
-- `base` (a tab advances to the next multiple of 4).  Returns the column count
-- and the byte length of that whitespace run.
local function indent_cols(s, base)
  local cols, i = 0, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == " " then
      cols = cols + 1
    elseif c == "\t" then
      cols = cols + (4 - (base + cols) % 4)
    else
      break
    end
    i = i + 1
  end
  return cols, i - 1
end

-- Remove exactly `n` columns of leading whitespace from `s` (whose first char is
-- at absolute column `base`).  If the n-th column lands inside a tab, the tab's
-- remaining columns become leading spaces on the result.  Returns the remainder
-- string.  Caller guarantees indent_cols(s, base) >= n.
local function drop_cols(s, base, n)
  local col, i = 0, 1
  while col < n and i <= #s do
    local c = s:sub(i, i)
    if c == " " then
      col = col + 1
      i = i + 1
    elseif c == "\t" then
      local w = 4 - (base + col) % 4
      if col + w <= n then
        col = col + w
        i = i + 1
      else
        -- Partial tab: consume it, leave (col + w - n) residual spaces.
        return string.rep(" ", col + w - n) .. s:sub(i + 1)
      end
    else
      break
    end
  end
  return s:sub(i)
end

-- Leaf recognisers.  Each inspects the marker-stripped line and, when it begins
-- a block, returns a fresh open-block table for the open-blocks stack; otherwise
-- nil.

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
  -- Remove an optional closing run of '#': one preceded by whitespace, or -- when
  -- the content is nothing but '#'s (e.g. "## ###") -- a run at the very start.
  -- The second case applies only when no whitespace-preceded run was found, so a
  -- legitimate '#' left after stripping one (e.g. "## ## ##" -> "##") is kept.
  local raw = rest or ""
  local content = raw:gsub("%s+#+%s*$", "")
  if content == raw and raw:match("^#+%s*$") then
    content = ""
  end
  content = strip(content)
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
  -- Defer to setext only when the line is a real setext underline (a contiguous
  -- '-' run); '--- -' has interior space, so it is a thematic break here.
  if ch == "-" and tip_is_paragraph and line:match("^ ? ? ?%-+%s*$") then
    return nil
  end
  return { type = "thematic_break", children = {}, closed_immediately = true }
end

-- Remove up to `n` leading columns from a fenced code body line, matching the
-- opening fence's indent.  A leading tab counts to the next tab stop (width 4);
-- a tab the strip splits leaves its remaining columns behind as spaces.
local function strip_fence_indent(line, n)
  local col, i = 0, 1
  while i <= #line and col < n do
    local ch = line:sub(i, i)
    if ch == " " then
      col, i = col + 1, i + 1
    elseif ch == "\t" then
      local width = 4 - (col % 4)
      if col + width <= n then
        col, i = col + width, i + 1
      else
        return string.rep(" ", col + width - n) .. line:sub(i + 1)
      end
    else
      break
    end
  end
  return line:sub(i)
end

-- Fenced code: <=3 space indent, then >=3 backticks or tildes, then an info
-- string.  Opens a leaf that accumulates body lines until its closing fence.
local function fenced_code(line)
  -- The fence is a run of >= 3 of a SINGLE char (all backticks or all tildes);
  -- a backtick after a tilde run is the info string, not part of the fence.
  local indent, fence, info = line:match("^( ? ? ?)(`+)(.*)$")
  if not fence then
    indent, fence, info = line:match("^( ? ? ?)(~+)(.*)$")
  end
  if not fence or #fence < 3 then
    return nil
  end
  local fence_char = fence:sub(1, 1)
  -- A backtick info string cannot contain a backtick.
  if fence_char == "`" and info:find("`", 1, true) then
    return nil
  end
  local lang = info:match("^%s*(%S+)")
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
  -- The closing fence is a run of the SAME char as the opener (mixed `~~~```
  -- does not close), at least as long, then only trailing whitespace.
  local close = line:match("^ ? ? ?([`~]+)%s*$")
  return close and close == string.rep(block.fence_char, #close) and #close >= block.fence_len
end

-- Indented code: a line indented >=4 columns that does not continue a paragraph.
-- Opens a leaf that accumulates indented and interior-blank lines.  `base` is the
-- absolute column at which `line` begins (after outer container markers).
local function indented_code(line, base)
  if indent_cols(line, base or 0) < 4 then
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

-- A paragraph line's leading whitespace is its own indentation, which
-- CommonMark does not preserve; interior and trailing whitespace stay.
local function para_content(rest)
  return (rest:gsub("^[ \t]+", ""))
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

-- Block quote marker: <=3 leading columns then '>' plus one optional following
-- column of whitespace.  `base` is the absolute column at which `line` begins.
-- Returns the line with the marker stripped and the new absolute base column, or
-- nil when the line has no marker.  Used by both the start recogniser (phase 3)
-- and the continue test (phase 1) -- the marker grammar is identical for opening
-- and continuing.  A tab partially consumed for the post-'>' gap leaves its
-- residual columns as leading spaces on the inner remainder.
local function strip_block_quote_marker(line, base)
  base = base or 0
  -- Up to 3 columns of leading whitespace (a tab column-expands from base) may
  -- precede the '>'.
  local lead = line:match("^[ \t]*")
  local lead_cols = indent_cols(lead, base)
  if lead_cols > 3 or line:sub(#lead + 1, #lead + 1) ~= ">" then
    return nil
  end
  local after = line:sub(#lead + 2)
  base = base + lead_cols + 1
  -- Consume one optional column of whitespace after '>'.  A space drops one
  -- column; a tab drops one of its columns, materializing the rest as spaces.
  local c = after:sub(1, 1)
  if c == " " then
    after = after:sub(2)
    base = base + 1
  elseif c == "\t" then
    after = drop_cols(after, base, 1)
    base = base + 1
  end
  return after, base
end

-- List item marker: <=3 leading spaces, then a bullet ('-', '+', '*') or an
-- ordered marker (1-9 digits then '.' or ')').  Returns a descriptor or nil.
-- `indent` is the item's content indent W = leading + marker width + spaces
-- after the marker (1-4); content starting >4 cols past the marker counts only
-- one space (the rest is content indentation), and a marker followed by nothing
-- or a blank uses W = leading + marker width + 1.  `rest` is the line content
-- to be parsed under the item (with the marker + W's worth of spaces removed).
local function list_marker(line, base)
  base = base or 0
  -- Up to 3 COLUMNS of leading whitespace may precede the marker (a tab is
  -- column-expanded from `base`); more than that is too indented to start a list
  -- here.  The marker must be followed by a space/tab or end-of-line.
  local lead = line:match("^[ \t]*")
  local lead_cols = indent_cols(lead, base)
  if lead_cols > 3 then
    return nil
  end
  local body = line:sub(#lead + 1)
  local ordered, bullet, delim, start, marker, after
  local m, rest = body:match("^([%-%+%*])([ \t].*)$")
  if m then
    bullet, marker, after = m, m, rest
  elseif body:match("^[%-%+%*]$") then
    bullet, marker, after = body, body, ""
  else
    local digits, d
    digits, d, after = body:match("^(%d+)([%.%)])([ \t].*)$")
    if not digits then
      digits, d = body:match("^(%d+)([%.%)])$")
      if digits then
        after = ""
      end
    end
    if not digits or #digits > 9 then
      return nil
    end
    ordered = true
    delim = d
    start = tonumber(digits)
    marker = digits .. d
  end
  if not marker then
    return nil
  end
  -- Absolute column just past the marker glyph (the marker glyphs are ASCII, so
  -- their byte width equals their column width).
  local marker_width = lead_cols + #marker
  local after_base = base + marker_width
  -- Columns and bytes of the whitespace gap after the marker.
  local gap_cols, gap_bytes = indent_cols(after, after_base)
  local content_after = after:sub(gap_bytes + 1)
  local w
  if content_after == "" then
    -- Marker followed by nothing or only blanks: empty item, W = marker + 1.
    w = marker_width + 1
    content_after = ""
  elseif gap_cols >= 1 and gap_cols <= 4 then
    w = marker_width + gap_cols
    -- Re-materialize the exact content indent: drop one column of the gap and
    -- keep the residual columns (a partial tab becomes leading spaces).
    content_after = drop_cols(after, after_base, gap_cols)
  else
    -- >=5 columns: only one column is the marker gap; the rest is indentation.
    w = marker_width + 1
    content_after = drop_cols(after, after_base, 1)
  end
  return {
    ordered = ordered or false,
    bullet = bullet,
    delim = delim,
    start = start,
    indent = w,
    rest = content_after,
    base = base + w,
  }
end

-- GFM pipe table support.  A table row is split on UNESCAPED '|' (a '\|' is a
-- literal pipe in the cell), with optional leading and trailing edge pipes
-- stripped and each cell trimmed.  The scan is bounded by the input length, so
-- pathological all-pipe input terminates.

-- Split `line` into trimmed cells on unescaped '|', un-escaping '\|' to '|'.
-- A single leading and a single trailing edge pipe (with surrounding
-- whitespace) are optional delimiters, not empty cells.
local function table_cells(line)
  -- A lone edge pipe (optionally surrounded by whitespace) is a single edge
  -- delimiter, not a cell: cmark counts it as zero columns, so a `|` row can
  -- head no table.  Doubled or content-bearing pipes still yield cells.
  if line:match("^%s*|%s*$") then
    return {}
  end
  local cells = {}
  local buf = {}
  local i = 1
  local len = #line
  while i <= len do
    local c = line:sub(i, i)
    if c == "\\" and line:sub(i + 1, i + 1) == "|" then
      buf[#buf + 1] = "|"
      i = i + 2
    elseif c == "|" then
      cells[#cells + 1] = strip(table.concat(buf))
      buf = {}
      i = i + 1
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  cells[#cells + 1] = strip(table.concat(buf))
  -- Strip a leading empty cell produced by a leading edge pipe, and a trailing
  -- empty cell produced by a trailing edge pipe.
  if #cells > 1 and cells[1] == "" then
    table.remove(cells, 1)
  end
  if #cells > 1 and cells[#cells] == "" then
    cells[#cells] = nil
  end
  return cells
end

-- True if `line` contains at least one unescaped '|' (the minimal table-row
-- test).  Bounded scan.
local function has_unescaped_pipe(line)
  local i, len = 1, #line
  while i <= len do
    local c = line:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == "|" then
      return true
    else
      i = i + 1
    end
  end
  return false
end

-- If every cell of `line` matches ^:?-+:?$ (a delimiter row), return the list
-- of per-column alignments (":-:"->"c", ":-"->"l", "-:"->"r", "-"->false);
-- otherwise nil.  Requires at least one cell.
local function delimiter_alignments(line)
  if not has_unescaped_pipe(line) and strip(line):match("^:?%-+:?$") == nil then
    -- No pipe and not a bare single delimiter cell -> not a delimiter row.
    return nil
  end
  local cells = table_cells(line)
  if #cells == 0 then
    return nil
  end
  local aligns = {}
  for _, cell in ipairs(cells) do
    local left = cell:sub(1, 1) == ":"
    local right = cell:sub(-1) == ":"
    local core = cell:gsub("^:", ""):gsub(":$", "")
    if core == "" or core:match("^%-+$") == nil then
      return nil
    end
    if left and right then
      aligns[#aligns + 1] = "c"
    elseif left then
      aligns[#aligns + 1] = "l"
    elseif right then
      aligns[#aligns + 1] = "r"
    else
      aligns[#aligns + 1] = false
    end
  end
  return aligns
end

-- Build a table data row from a cell list (from table_cells), padding with empty
-- cells or truncating to `ncols` columns.  Each cell is a one-element inline list
-- `{ ast.text(raw) }`; the inline pass re-parses the raw text into proper nodes.
local function table_data_row(raw, ncols)
  local cells = {}
  for i = 1, ncols do
    cells[i] = { ast.text(raw[i] or "") }
  end
  return { sep = false, cells = cells }
end

-- Finalise an open block into the AST node the renderer consumes.

-- Drop trailing blank (whitespace-only) lines.  An indented code block's
-- trailing blanks are not part of it, and a whitespace-only line that was longer
-- than the strip leaves residual spaces that must go too.
local function trim_trailing_blank(lines)
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    lines[#lines] = nil
  end
end

local function finalize(block)
  local t = block.type
  if t == "block_quote" then
    return ast.block("quote", { content = block.children })
  elseif t == "list" then
    local node = ast.list(block.ordered, block.children)
    node.loose = block.loose or false
    return node
  elseif t == "list_item" then
    local checkbox
    local first = block.children[1]
    if first and first.kind == "paragraph" then
      local text_node = first.inline and first.inline[1]
      if text_node and text_node.kind == "text" then
        local raw = text_node.text or ""
        local marker, rest = raw:match("^(%[[ xX]%]) (.*)$")
        if marker then
          if marker == "[ ]" then
            checkbox = "todo"
          else
            checkbox = "done"
          end
          text_node.text = rest
        end
      end
    end
    return ast.list_item({
      marker = block.bullet,
      counter = block.counter,
      checkbox = checkbox,
      content = block.children,
    })
  elseif t == "paragraph" then
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
      -- Fenced code keeps its body verbatim, including trailing blank lines (an
      -- unclosed fence runs to EOF).
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
  elseif t == "table" then
    return { kind = "table", alignments = block.alignments, rows = block.rows }
  end
  return nil
end

-- Sentinel returned by try_starts when it opened a container and the remaining
-- content must still be placed one level deeper; place_content loops on it
-- instead of recursing, keeping single-line container descent at constant depth.
local DESCEND = {}

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

-- Peel leading link reference definitions off a paragraph's accumulated lines
-- (CommonMark's paragraph-finalization model).  Joins lines with "\n", records
-- each leading definition into self.refmap (first definition of a key wins), and
-- returns the leftover text after the last consumed definition.
function Parser:extract_para_refs(lines)
  local from_md_inline = require("organ.ast.from_md_inline")
  local text = table.concat(lines, "\n")
  local pos = 1
  local n = #text
  while pos <= n do
    local next_index, key, dest, title = from_md_inline.parse_reference(text, pos)
    if not next_index then
      break
    end
    self.refmap[key] = self.refmap[key] or { destination = dest, title = title }
    pos = next_index
  end
  return text:sub(pos)
end

-- Extract leading link reference definitions off a paragraph block, rewriting
-- block.lines to the leftover content.  Returns true if any content remains.
function Parser:extract_refs(block)
  local rest = self:extract_para_refs(block.lines)
  if rest:match("^%s*$") then
    return false
  end
  block.lines = vim.split(rest, "\n", { plain = true })
  return true
end

-- Finalise and pop the tip leaf, attaching its node to its parent container.
function Parser:close_tip()
  local n = #self.stack
  if n <= 1 then
    return
  end
  local block = self.stack[n]
  self.stack[n] = nil
  if block.type == "paragraph" and not self:extract_refs(block) then
    return
  end
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
  -- A block pushed under an open item is that item's content; record it so the
  -- looseness and empty-item-blank rules can tell a still-empty item (begun
  -- blank, no content yet) from one whose first content is merely still open
  -- (not yet finalised into `children`).
  local parent = self.stack[#self.stack]
  if parent and parent.type == "list_item" then
    parent.has_content = true
  end
  self.stack[#self.stack + 1] = block
end

-- Arm a pending blank on every open list, but ONLY when the blank sits in a
-- list context: the deepest container that matched this line is a list or list
-- item.  A blank whose deepest matched container is a block quote (or other
-- non-list block) is interior to that block and loosens no list (e.g. a trailing
-- `>` blank inside a blockquote inside an item).  When the deepest match is a
-- list item -- even one reached through an enclosing blockquote, because a blank
-- line continues the item -- the blank is in the item and may loosen.  The exact
-- owning list is resolved later by confirm_list_loose, which disarms the rest.
function Parser:arm_list_blank(last_matched)
  local deepest = self.stack[last_matched]
  if not (deepest and (deepest.type == "list" or deepest.type == "list_item")) then
    return
  end
  if deepest.type == "list_item" then
    -- A blank before an item's first content (the item began blank and has no
    -- content yet) is not a separator between two blocks: it loosens nothing.
    if not deepest.has_content then
      return
    end
    -- A blank right after a thematic break does not loosen (cmark's
    -- last-line-blank flag is not set on one).  A heading is NOT exempt.  A
    -- thematic break closes immediately, so the item's last block is its last
    -- child unless a later block is still open under it.
    if last_matched >= #self.stack then
      local last = deepest.children[#deepest.children]
      if last and last.kind == "rule" then
        return
      end
    end
  end
  for i = 2, #self.stack do
    if self.stack[i].type == "list" then
      self.stack[i].pending_blank = true
    end
  end
end

-- CommonMark looseness is per-list: a list is loose iff two of ITS OWN items are
-- separated by a blank, or one of its items directly holds two block children
-- separated by a blank.  When post-blank content lands, exactly one list owns
-- that blank -- the list given by `owner` (the list whose item the content is a
-- sibling item of, or whose item directly contains it).  Confirm looseness on
-- that single list; the same blank cannot also belong to any other list, so
-- disarm the pending candidacy on every other open list.  `owner` is nil when no
-- list owns the blank (e.g. a fresh list opening beside a different-kind one);
-- then the blank is purely a separator and loosens nothing.
function Parser:confirm_list_loose(owner)
  for i = 2, #self.stack do
    local block = self.stack[i]
    if block.type == "list" then
      if i == owner and block.pending_blank then
        block.loose = true
      end
      block.pending_blank = false
    end
  end
end

-- Per-container behavior, keyed by block type.  `continue(block, rest)` is the
-- phase-1 marker match: it returns the remainder with this container's
-- continuation marker stripped, or nil when the line does not continue the
-- container.  New container types (lists) register here rather than adding a
-- branch to the phase-1 walk.
-- Each `continue(block, rest, base)` returns the remainder with this container's
-- continuation marker stripped and the new absolute base column, or nil when the
-- line does not continue the container.
local CONTAINER = {
  document = {
    continue = function(_block, rest, base)
      return rest, base
    end,
  },
  block_quote = {
    continue = function(_block, rest, base)
      return strip_block_quote_marker(rest, base)
    end,
  },
  -- A list is transparent in phase 1: the item below it strips the indentation.
  list = {
    continue = function(_block, rest, base)
      return rest, base
    end,
  },
  -- A list item continues when the (already outer-marker-stripped) line is
  -- indented at least W columns -- strip exactly W -- or when it is blank.  Other
  -- lines return nil; phase 4 may still lazily continue an open paragraph.
  list_item = {
    continue = function(block, rest, base)
      local blank = is_blank(rest)
      local cols = indent_cols(rest, base)
      -- "A list item can begin with at most one blank line": an item that began
      -- blank and has no content yet is sealed by a following blank line that
      -- does not reach its content indent.  A blank indented to the content
      -- column (or any blank in an item with content) is interior.
      if blank and block.opened_blank and not block.has_content and cols < block.indent then
        return nil
      end
      -- Strip exactly the content indent when the line reaches it.  This applies
      -- to blank lines too, so indentation beyond the content column (e.g. a
      -- blank line of fenced-code content) is preserved.
      if cols >= block.indent then
        return drop_cols(rest, base, block.indent), base + block.indent
      end
      -- A short blank line still continues the item; any other short line does
      -- not (phase 4 may lazily continue an open paragraph).
      if blank then
        return "", base + block.indent
      end
      return nil
    end,
  },
}

-- Is the stack element at `index` a container (holds finalised children) rather
-- than an accumulating leaf?  `document`, `block_quote`, `list`, and
-- `list_item` are containers.
local function is_container(block)
  return CONTAINER[block.type] ~= nil
end

-- PHASE 1: walk the open containers from the document down, testing each
-- container's continue condition against the progressively marker-stripped line
-- and consuming its marker.  `document` always continues with no marker.  Stops
-- at the first container that does not continue.  Returns the stack index of the
-- deepest still-matched container and the line text with all matched containers'
-- markers stripped.
function Parser:match_continuation(line)
  local last_matched = 1 -- the document container always matches
  local rest, base = line, 0
  for i = 2, #self.stack do
    local block = self.stack[i]
    local container = CONTAINER[block.type]
    if not container then
      break -- a leaf (or non-container) ends the phase-1 walk
    end
    local stripped, new_base = container.continue(block, rest, base)
    if stripped == nil then
      break
    end
    rest, base = stripped, new_base
    last_matched = i
  end
  return last_matched, rest, base
end

-- Close every open block strictly below stack index `keep` (deepest first), so
-- that a new block starting under the matched container does not nest inside
-- now-unmatched siblings.
function Parser:close_below(keep)
  while #self.stack > keep do
    self:close_tip()
  end
end

-- Try the block starters, in proven CommonMark precedence, against the
-- marker-stripped `line`, pushing any new block under the container at stack
-- index `from`.  Returns true if the line opened (and possibly closed) a leaf
-- block or was consumed as a reference definition; returns the DESCEND sentinel
-- plus the deeper (remainder, base column, stack index) when it opened a
-- container (block quote or list item) into which the content must be placed;
-- returns false when no start matched.  The container-descent is reported back
-- to the caller (place_content) rather than recursing, so that interleaved
-- '> - > - ...' markers descend iteratively and the parser depth does not scale
-- with the marker count (a recursive call per marker would overflow the C
-- stack).
function Parser:try_starts(line, base, from)
  -- A leading tab worth <= 3 columns is block-start indentation, not indented
  -- code: expand it to spaces so the recognisers that measure indentation as
  -- literal spaces (ATX, thematic break, setext) handle a tab left by a
  -- container marker (e.g. `> \t## `).  A wider indent stays as is so an
  -- indented code block keeps its body tabs verbatim.
  local lead = line:match("^[ \t]*")
  if lead:find("\t", 1, true) then
    local cols = indent_cols(lead, base)
    if cols <= 3 then
      line = string.rep(" ", cols) .. line:sub(#lead + 1)
    end
  end
  local tip = self:tip()
  local tip_para = #self.stack > from and tip.type == "paragraph"
  -- A block that "cannot interrupt a paragraph" (a setext underline, an empty or
  -- non-1 list, a type-7 HTML block) is only blocked when the paragraph is
  -- DIRECTLY in the matched container.  A paragraph reached only by lazy
  -- continuation (its container marker was missing this line) sits in a deeper,
  -- unmatched container, so a block opening at `from` joins a different container
  -- and neither underlines nor is blocked by it.  (Indented code is the lone
  -- exception: it stays lazy continuation across the boundary, so it keeps the
  -- broader `tip_para`.)
  local para_in_matched = #self.stack == from + 1 and tip.type == "paragraph"

  -- A marker that extends an already-open same-kind list opens its next item
  -- before the setext / thematic-break checks: a bare '-' under a list's
  -- paragraph ('- foo\n-\n- bar') is that list's empty item, not a setext
  -- underline of "foo".  (A bare marker that would START a list still cannot
  -- interrupt a paragraph; that case is handled by the later list start.)
  if not thematic_break(line, para_in_matched) then
    local lm = list_marker(line, base)
    if lm and self:extends_list(lm, from) then
      local rest, new_base, deep = self:open_list_item(lm, from)
      if rest then
        return DESCEND, rest, new_base, deep
      end
      return true
    end
  end

  -- Setext underline converts an open paragraph in place; check before other
  -- starts so "---" under a paragraph becomes an h2 rather than a break.
  if para_in_matched then
    local level = setext_level(line)
    if level then
      local n = #self.stack
      local para = self.stack[n]
      -- A setext underline applies to what REMAINS after stripping leading
      -- reference definitions from the paragraph.  If the paragraph was entirely
      -- definitions, there is nothing to underline: the defs are recorded, the
      -- empty paragraph is dropped, and the underline line is reprocessed with no
      -- paragraph above it (so it becomes ordinary text or a thematic break).
      local remaining = self:extract_para_refs(para.lines)
      self.stack[n] = nil
      if remaining:match("^%s*$") then
        return self:try_starts(line, base, from)
      end
      local parent = self.stack[#self.stack]
      parent.children[#parent.children + 1] = ast.headline({
        level = level,
        title = { ast.text(strip(remaining)) },
        children = {},
      })
      return true
    end
  end

  -- A block quote opens a new container, then its content (the further-stripped
  -- remainder) is placed under it: '> # x' opens a heading inside the quote,
  -- '> > x' nests two quotes, '> a' opens a paragraph inside the quote, and a
  -- bare '>' opens an empty quote.  Consecutive '>' markers on one line are
  -- consumed iteratively -- one container pushed per marker -- so the parser
  -- depth does not scale with the number of '>' on a line (a recursive call per
  -- marker would overflow the C stack on pathological '> > > ...' input).
  local bq_rest, bq_base = strip_block_quote_marker(line, base)
  if bq_rest and #self.stack < MAX_NESTING then
    from = self:leaf_base(from)
    self:close_below(from)
    -- A block quote opening as a second child inside an open item, after an
    -- armed blank, loosens the list that directly contains that item.
    if self.stack[from] and self.stack[from].type == "list_item" then
      self:confirm_list_loose(from - 1)
    end
    repeat
      local quote = { type = "block_quote", children = {} }
      self:push(quote)
      -- Depth cap: a deeper '>' here keeps the rest of the line as content.
      if #self.stack >= MAX_NESTING then
        break
      end
      local next_rest, next_base = strip_block_quote_marker(bq_rest, bq_base)
      if next_rest == nil then
        break
      end
      bq_rest, bq_base = next_rest, next_base
    until false
    return DESCEND, bq_rest, bq_base, #self.stack
  end

  local block = atx_heading(line)
    or thematic_break(line, para_in_matched)
    or fenced_code(line)
    or (not tip_para and indented_code(line, base))
    or html_block(line, para_in_matched)
  if block then
    from = self:leaf_base(from)
    self:close_below(from)
    -- A leaf block opening as a second child inside an open item, after an
    -- armed blank, makes the list that directly contains that item loose.
    if self.stack[from] and self.stack[from].type == "list_item" then
      self:confirm_list_loose(from - 1)
    end
    self:push(block)
    if block.closed_immediately then
      self:close_tip()
    elseif block.type == "code_block" and block.variant == "indented" then
      -- The opening line is itself the first body line.
      block.body[#block.body + 1] = drop_cols(line, base, 4)
    elseif block.type == "html_block" then
      -- The opening line is part of the verbatim body; it may also already
      -- satisfy the end condition (a one-line comment, a closed pre, etc.).
      self:feed_open_leaf(line)
    end
    return true
  end

  -- List item.  Tried after the thematic-break / atx / fenced chain so that
  -- '- - -' and '***' stay thematic breaks, and an indented marker reaching
  -- here under an open item naturally opens a nested list (its content was
  -- parsed under #stack with the outer item's indentation stripped).
  local lm = list_marker(line, base)
  if lm and #self.stack < MAX_NESTING then
    -- A marker that would START a new list (no matching open same-kind list)
    -- may interrupt a paragraph only when its content is non-empty and, for
    -- ordered lists, only when it starts at 1.  Extending an open same-kind
    -- list is always allowed (item 2 of an ordered list, etc.).
    -- A marker whose ordered-ness matches an open list at `from` but whose
    -- delimiter differs (e.g. "." vs ")") closes that list and starts a new
    -- one -- this is not a paragraph-interrupt but a list-type change.
    local extends = self:extends_list(lm, from)
    local bl = self.stack[from]
    local bl1 = self.stack[from + 1]
    local open_list = (bl and bl.type == "list") and bl
      or ((bl1 and bl1.type == "list") and bl1 or nil)
    local closes_open_list = open_list ~= nil and open_list.ordered == lm.ordered
    if
      extends
      or closes_open_list
      or not (para_in_matched and (lm.rest == "" or (lm.ordered and lm.start ~= 1)))
    then
      local rest, new_base, deep = self:open_list_item(lm, from)
      if rest then
        return DESCEND, rest, new_base, deep
      end
      return true
    end
  end

  return false
end

-- Return the stack index of an open same-kind list a marker `lm` would extend,
-- or nil.  It is either the container at `from` itself (phase 1 stopped at the
-- list when its open item did not continue) or a sibling list directly under
-- `from`.
function Parser:extends_list(lm, from)
  local function same_kind(b)
    return b
      and b.type == "list"
      and b.ordered == lm.ordered
      and ((lm.ordered and b.delim == lm.delim) or (not lm.ordered and b.bullet == lm.bullet))
  end
  if same_kind(self.stack[from]) then
    return from
  elseif same_kind(self.stack[from + 1]) then
    return from + 1
  end
  return nil
end

-- Open a list item for marker descriptor `lm` under the container at stack
-- index `from`.  If the container directly under `from` is an open list of the
-- same kind (same bullet char, or same ordered delimiter), the item extends it;
-- otherwise the open blocks below `from` are closed and a fresh list is pushed.
-- Returns the deepest item's still-unparsed remainder, its absolute base column,
-- and its stack index, for the caller to place content under.  The remainder may
-- be blank (an empty marker like `-` or `> -`); place_content absorbs a blank
-- remainder, leaving the item empty.
function Parser:open_list_item(lm, from)
  -- A list item's content may itself begin with a list marker, opening a nested
  -- sublist.  Each such marker is consumed iteratively -- one list + item pushed
  -- per marker -- rather than by re-entering try_starts per marker, so the
  -- parser depth does not scale with the marker count on a line (a recursive
  -- call per marker would overflow the C stack on '  -   -   - ...' input).
  while lm do
    -- Extend an open same-kind list or open a fresh one; in both cases
    -- everything below the target list is closed first, ending any previous
    -- item.  After the first iteration the content is always parsed under the
    -- just-pushed item, so it can only extend lists at #stack, never reopen one.
    local list_index = self:extends_list(lm, from)
    -- Which list, if any, owns a blank that preceded this marker.  Extending an
    -- open list means the marker opens that list's next item: a preceding blank
    -- sat directly between two of its items, so the extended list owns it.  A
    -- fresh list nested inside the item at `from` is a second block child of
    -- that item: a preceding blank sat within the item, so the item's own list
    -- (the container at `from - 1`) owns it.  A fresh list opening beside a
    -- different-kind list (no item parent) owns no blank.
    local owner
    if list_index then
      owner = list_index
      self:close_below(list_index)
    else
      owner = (self.stack[from] and self.stack[from].type == "list_item") and (from - 1) or nil
      -- A different-kind marker ends an open list at `from` (a '+' after a '-'
      -- list, a ')' after a '.' list) before the new list opens beside it.
      from = self:leaf_base(from)
      self:close_below(from)
      self:push({
        type = "list",
        ordered = lm.ordered,
        bullet = lm.bullet,
        delim = lm.delim,
        children = {},
      })
    end
    -- A new item or nested sublist landing after an armed blank confirms that
    -- blank was interior to exactly the owning list (between its items, or
    -- between two block children of one of its items); loosen that one list.
    self:confirm_list_loose(owner)
    self:push({
      type = "list_item",
      indent = lm.indent,
      bullet = lm.bullet,
      counter = lm.ordered and tostring(lm.start) or nil,
      children = {},
    })
    from = #self.stack
    local rest = lm.rest
    local base = lm.base
    -- A blank remainder leaves the item open and empty; a thematic break wins
    -- over a further nested marker (the existing precedence).
    if is_blank(rest) or thematic_break(rest, false) or #self.stack >= MAX_NESTING then
      -- Blank/thematic-break end the descent; the depth cap keeps deeper nested
      -- markers as the item's content rather than opening further sublists.
      lm = nil
    else
      lm = list_marker(rest, base)
    end
    if not lm then
      if is_blank(rest) then
        self.stack[from].opened_blank = true
      end
      return rest, base, from
    end
  end
end

-- A `list` only ever holds `list_item` children; non-marker content (a stray
-- paragraph, a heading, the line after a list-ending blank) cannot attach to it.
-- When the container at `from` is a list, close it and return its parent's index
-- so the content lands in the list's parent instead.  Markers reach the list
-- through open_list_item, not here, so closing is always correct.
function Parser:leaf_base(from)
  if self.stack[from] and self.stack[from].type == "list" then
    self:close_below(from - 1)
    return from - 1
  end
  return from
end

-- Place a marker-stripped remainder under the container at stack index `from`:
-- run block starts (phase 3); failing that, append to or open a paragraph
-- (phase 4).  A blank remainder leaves the container empty.  Shared by the
-- top-level line dispatch and the block-quote / list-item starts (so their
-- content is parsed by the same machinery).  When try_starts opens a container,
-- it reports the deeper (remainder, index) via the DESCEND sentinel and this
-- loop continues there instead of recursing, so single-line container descent
-- ('> - > - ...') runs at constant parser depth.
function Parser:place_content(rest, base, from)
  while true do
    if is_blank(rest) then
      return
    end
    local result, deep_rest, deep_base, deep_from = self:try_starts(rest, base, from)
    if result == DESCEND then
      rest, base, from = deep_rest, deep_base, deep_from
    elseif result then
      return
    else
      break
    end
  end
  local tip = self:tip()
  if #self.stack > from and tip.type == "paragraph" then
    tip.lines[#tip.lines + 1] = para_content(rest)
  else
    from = self:leaf_base(from)
    self:close_below(from)
    -- Fresh content attaching directly inside an open item, after an armed
    -- blank, is a second block child of that item: the list that directly
    -- contains the item is loose.
    if self.stack[from] and self.stack[from].type == "list_item" then
      self:confirm_list_loose(from - 1)
    end
    self:push({ type = "paragraph", lines = { para_content(rest) }, children = {} })
  end
end

-- True if `line` begins a block-level structure that should close an open table
-- body (and then be reprocessed normally).  A table data row is any other
-- non-blank line; only block starts and blanks interrupt it.  `tip_para` is
-- false here (the tip is the table, not a paragraph), so setext does not apply.
local function line_starts_block(line)
  if strip_block_quote_marker(line) then
    return true
  end
  if list_marker(line) then
    return true
  end
  if
    atx_heading(line)
    or thematic_break(line, false)
    or fenced_code(line)
    or indented_code(line)
    or html_block(line, false)
  then
    return true
  end
  return false
end

-- GFM table start: when `rest` is a valid delimiter row, the tip is an open
-- paragraph (directly under the matched container at `from`) of exactly one
-- line, and that header line is a table row whose cell count equals the
-- delimiter's column count, convert the paragraph into an open `table` block.
-- Returns true on conversion; otherwise the line is handled normally.
function Parser:try_table_start(rest, from)
  local tip = self:tip()
  if #self.stack <= from or tip.type ~= "paragraph" then
    return false
  end
  -- cmark gives a paragraph one chance: once a valid delimiter row fails to
  -- match the header's column count, the paragraph can never become a table
  -- (its CMARK_NODE__TABLE_VISITED flag), so later delimiter rows are ignored.
  if tip.table_visited then
    return false
  end
  local aligns = delimiter_alignments(rest)
  if not aligns then
    return false
  end
  -- A bare run of dashes (no pipe, no colon) is a setext-heading underline,
  -- which takes precedence over a single-column table.
  if rest:match("^%s*%-+%s*$") then
    return false
  end
  -- Leading reference definitions are recorded and removed first.  A paragraph
  -- that is entirely definitions leaves nothing to head the table.
  local content = self:extract_para_refs(tip.lines)
  if content:match("^%s*$") then
    self.stack[#self.stack] = nil
    return false
  end
  -- The header is the paragraph's LAST line; any earlier lines stay a paragraph
  -- of their own (cmark splits the table off the paragraph's tail).  A header
  -- with no pipe is a single-column row.
  local pre, header = content:match("^(.*)\n([^\n]*)$")
  if not header then
    pre, header = nil, content
  end
  local header_cells = table_cells(header)
  if #header_cells ~= #aligns then
    tip.table_visited = true
    return false
  end
  local ncols = #aligns
  local rows = { table_data_row(header_cells, ncols), { sep = true, cells = {} } }
  self.stack[#self.stack] = nil -- drop the paragraph; its tail becomes the header
  if pre and not pre:match("^%s*$") then
    -- Re-emit the lines above the header as their own paragraph.
    local parent = self.stack[#self.stack]
    parent.children[#parent.children + 1] = ast.paragraph({ ast.text(pre) })
  end
  self:push({ type = "table", alignments = aligns, ncols = ncols, rows = rows })
  return true
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
      tip.body[#tip.body + 1] = strip_fence_indent(line, tip.indent)
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

-- Phase numbering follows CommonMark's reference algorithm; phase 2 (list-item
-- markers) is reserved for a later stage, so the 1/3/4 gap is intentional.
function Parser:add_line(line)
  -- PHASE 1: walk open containers, consuming their markers.  `last_matched` is
  -- the deepest container whose continuation marker was present on this line;
  -- `rest` is the line with those markers stripped.  An open leaf below
  -- `last_matched` whose containers all matched may still continue (paragraph
  -- lazy continuation, accumulating code/html); a leaf whose containers did NOT
  -- all match is a candidate for lazy continuation or gets closed.
  local last_matched, rest, base = self:match_continuation(line)
  local all_matched = last_matched == #self.stack or not is_container(self.stack[last_matched + 1])

  -- An open accumulating leaf (fenced code / html block) swallows the stripped
  -- line, but only while all its containers continue to match.
  if all_matched and self:feed_open_leaf(rest) then
    return
  end

  local tip = self:tip()

  -- An open indented-code leaf keeps absorbing indented and interior-blank
  -- lines; any other non-blank line ends it and is reprocessed as a start.
  if all_matched and tip.type == "code_block" and tip.variant == "indented" then
    if indent_cols(rest, base) >= 4 then
      tip.body[#tip.body + 1] = drop_cols(rest, base, 4)
      return
    elseif is_blank(rest) then
      tip.body[#tip.body + 1] = ""
      return
    else
      self:close_tip()
    end
  end

  -- An open table absorbs each subsequent non-blank line that does not start a
  -- new block as a data row (padded/truncated to the column count); a blank
  -- line or a block start closes it (and is reprocessed below).  A line with no
  -- cells (a lone `|`) is not a valid row: it ends the table and is reprocessed.
  if all_matched and tip.type == "table" and not is_blank(rest) and not line_starts_block(rest) then
    local cells = table_cells(rest)
    if #cells > 0 then
      tip.rows[#tip.rows + 1] = table_data_row(cells, tip.ncols)
      return
    end
    self:close_tip()
  end

  if is_blank(rest) then
    -- A blank line (after any matched markers) closes everything below the
    -- deepest matched container; in particular an open paragraph ends.  It also
    -- arms a looseness candidacy on every still-open list, because the blank
    -- may turn out to be interior to any one of them.  Which single list the
    -- blank actually belongs to is decided later, when content lands after it
    -- (see confirm_list_loose); a trailing blank after the final item -- never
    -- followed by content -- belongs to no list and leaves every list tight.
    -- The "empty item begins with at most one blank line" rule is enforced in
    -- list_item.continue: an under-indented blank does not match the empty item,
    -- so it is already unmatched (and closed below) by the time we get here.
    self:arm_list_blank(last_matched)
    self:close_below(last_matched)
    return
  end

  -- PHASE 3: new block starts, pushed under the deepest matched container.  A
  -- container opening (block quote, list item) reports its deeper remainder via
  -- the DESCEND sentinel; once descended, the remainder belongs strictly inside
  -- the new container, so place_content owns it (its own descent loop keeps the
  -- depth bounded on interleaved single-line markers).  Only the first,
  -- top-level start gets phase 4's lazy continuation.
  local result, deep_rest, deep_base, deep_from = self:try_starts(rest, base, last_matched)
  if result == DESCEND then
    self:place_content(deep_rest, deep_base, deep_from)
    return
  elseif result then
    return
  end

  -- GFM table start: a delimiter row converts a header paragraph's last line into
  -- an open table.  Checked after phase 3 (so a delimiter that also starts a
  -- block -- e.g. a `- |...` list item -- is taken as that block, matching cmark)
  -- but before phase 4 (so the delimiter row is not a paragraph continuation).
  if all_matched and self:try_table_start(rest, last_matched) then
    return
  end

  -- PHASE 4: lazy continuation / paragraph text.  A non-blank line with no
  -- start appends to an open paragraph even when some container markers were
  -- missing in phase 1 (CommonMark lazy continuation); otherwise it closes the
  -- unmatched blocks and opens a fresh paragraph under the matched container.
  tip = self:tip()
  if tip.type == "paragraph" then
    tip.lines[#tip.lines + 1] = para_content(rest)
  else
    last_matched = self:leaf_base(last_matched)
    self:close_below(last_matched)
    -- A second block child opening inside an open item, after an armed blank,
    -- makes the list that directly contains the item loose.
    if self.stack[last_matched] and self.stack[last_matched].type == "list_item" then
      self:confirm_list_loose(last_matched - 1)
    end
    self:push({ type = "paragraph", lines = { para_content(rest) }, children = {} })
  end
end

-- Walk every block in the document tree and re-parse inline-bearing nodes.
-- Uses an explicit stack to avoid C-stack overflow on deeply-nested input
-- (e.g. 10 000 consecutive block-quote markers on one line).
local function inline_pass(root, refmap, opts)
  local from_md_inline = require("organ.ast.from_md_inline")
  local stack = { root }
  while #stack > 0 do
    local node = table.remove(stack)
    local k = node.kind
    if k == "paragraph" then
      node.inline = from_md_inline.parse(node.inline[1] and node.inline[1].text or "", refmap, opts)
    elseif k == "headline" then
      node.title = from_md_inline.parse(node.title[1] and node.title[1].text or "", refmap, opts)
      for _, c in ipairs(node.children or {}) do
        stack[#stack + 1] = c
      end
    elseif k == "document" then
      for _, c in ipairs(node.children or {}) do
        stack[#stack + 1] = c
      end
    elseif k == "block" then
      -- quote: child blocks live in .content; export: .body is a string, skip.
      for _, c in ipairs(node.content or {}) do
        stack[#stack + 1] = c
      end
    elseif k == "list" then
      for _, it in ipairs(node.items or {}) do
        stack[#stack + 1] = it
      end
    elseif k == "list_item" then
      for _, c in ipairs(node.content or {}) do
        stack[#stack + 1] = c
      end
    elseif k == "table" then
      -- Re-parse each non-separator cell's raw text into inline nodes.
      for _, row in ipairs(node.rows or {}) do
        if row.sep ~= true then
          for ci, cell in ipairs(row.cells) do
            local raw = (cell[1] and cell[1].text) or ""
            row.cells[ci] = from_md_inline.parse(raw, refmap, opts)
          end
        end
      end
    elseif k == "code_block" then
      if node.language and node.language ~= "" then
        node.language = from_md_inline.decode_escapes(node.language)
      end
      -- rule, directive, drawer: literal, not inline-parsed.
    end
  end
end

function M.parse(text, opts)
  local p = Parser.new()
  for _, line in ipairs(split_lines(text or "")) do
    p:add_line(line)
  end
  p:close_to_document()
  local doc = ast.document(p.stack[1].children)
  doc.reference_map = p.refmap
  inline_pass(doc, p.refmap, opts)
  return doc
end

return M
