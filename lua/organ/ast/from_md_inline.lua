-- Second-phase inline parser: re-parses a block's flat text into inline AST
-- nodes.  Runs after the block parse completes (so link reference definitions
-- are fully collected).  A position-advancing scanner: literal characters
-- accumulate into a buffer that flushes to an ast.text node whenever a special
-- construct is recognised.  Handles backslash escapes, code spans, hard/soft
-- line breaks, URI and email autolinks, raw inline HTML, and emphasis/strong
-- via the CommonMark delimiter stack.  Links/images are not yet handled.
local ast = require("organ.ast")

local M = {}

local ASCII_PUNCT = {}
for ch in ("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"):gmatch(".") do
  ASCII_PUNCT[ch] = true
end

-- Classify a single byte for flanking analysis.  CommonMark treats start/end of
-- text as whitespace; callers pass "" or nil for those positions.
local function is_ws(ch)
  return ch == nil or ch == "" or ch == " " or ch == "\t" or ch == "\n" or ch == "\r" or ch == "\f"
end

local function is_punct(ch)
  return ch ~= nil and ch ~= "" and ASCII_PUNCT[ch] == true
end

-- Normalize code span content per CommonMark spec:
-- 1. Convert all line endings to spaces.
-- 2. If result both begins and ends with a space, and is not all spaces,
--    strip one space from each end.
local function normalize_code_span(s)
  s = s:gsub("\n", " ")
  if s:sub(1, 1) == " " and s:sub(-1) == " " and s:match("[^ ]") then
    s = s:sub(2, -2)
  end
  return s
end

-- Try to match a CommonMark URI autolink starting at text[i] (text[i] == "<").
-- Returns the URI string and the index just past the closing ">", or nil.
local function match_uri_autolink(text, i)
  -- Scheme: ASCII letter then (letter|digit|+|.|-), total 2-32 chars.
  local scheme, after = text:match("^<(%a[%a%d+.-]*):()", i)
  if not scheme or #scheme < 2 or #scheme > 32 then
    return nil
  end
  -- Body: any chars except whitespace, <, >, control chars; then ">".
  local n = #text
  local j = after
  while j <= n do
    local ch = text:sub(j, j)
    if ch == ">" then
      return text:sub(i + 1, j - 1), j + 1
    end
    -- Whitespace, <, or control chars (<= 0x20) terminate without a match.
    if ch == "<" or ch:byte() <= 0x20 then
      return nil
    end
    j = j + 1
  end
  return nil
end

-- Try to match a CommonMark email autolink starting at text[i].  Returns the
-- bare address and the index just past ">", or nil.  Decomposes the spec regex:
-- local-part chars, then @, then dot-separated alnum-bounded labels (<=63 each).
local function match_email_autolink(text, i)
  local close = text:find(">", i + 1, true)
  if not close then
    return nil
  end
  local addr = text:sub(i + 1, close - 1)
  local at = addr:find("@", 1, true)
  if not at then
    return nil
  end
  local local_part = addr:sub(1, at - 1)
  local domain = addr:sub(at + 1)
  if local_part == "" or domain == "" then
    return nil
  end
  -- Local part: one or more of [a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-].
  if local_part:match("^[%w.!#$%%&'*+/=?^_`{|}~-]+$") == nil then
    return nil
  end
  -- Domain: dot-separated labels, each alnum-bounded, hyphens interior, <=63.
  for label in (domain .. "."):gmatch("([^.]*)%.") do
    if #label == 0 or #label > 63 then
      return nil
    end
    if not label:match("^%w[%w-]*$") then
      return nil
    end
    if label:sub(-1) == "-" then
      return nil
    end
  end
  return addr, close + 1
end

-- Skip an attribute-value-spec sequence in a raw-HTML open tag, starting at j.
-- Returns the index after a single attribute, or nil if none matches.
local function match_attribute(text, j)
  -- Require whitespace before an attribute name.
  local k = text:match("^%s+()", j)
  if not k then
    return nil
  end
  -- Attribute name: [a-zA-Z_:] then [a-zA-Z0-9_.:-]*.
  local name_end = text:match("^[%a_:][%w_.:-]*()", k)
  if not name_end then
    return nil
  end
  j = name_end
  -- Optional value spec: ws? = ws? value.
  local eq = text:match("^%s*=%s*()", j)
  if not eq then
    return j
  end
  j = eq
  local ch = text:sub(j, j)
  if ch == '"' then
    local close = text:find('"', j + 1, true)
    if not close then
      return nil
    end
    return close + 1
  elseif ch == "'" then
    local close = text:find("'", j + 1, true)
    if not close then
      return nil
    end
    return close + 1
  else
    -- Unquoted value: one or more chars excluding whitespace, "'=<>`.
    local ue = text:match("^[^%s\"'=<>`]+()", j)
    if not ue then
      return nil
    end
    return ue
  end
end

-- Try to match a raw inline HTML construct starting at text[i] (== "<").
-- Returns the index just past the construct, or nil.  Covers open/closing tags,
-- comments, processing instructions, declarations, and CDATA sections.
local function match_raw_html(text, i, n)
  -- HTML comment: <!--, then any text not ending with -, ending -->.
  if text:sub(i, i + 3) == "<!--" then
    -- <!--> and <!---> are valid empty comments.
    if text:sub(i, i + 4) == "<!-->" then
      return i + 5
    end
    if text:sub(i, i + 5) == "<!--->" then
      return i + 6
    end
    local body_start = i + 4
    local j = body_start
    while j <= n - 2 do
      if text:sub(j, j + 2) == "-->" then
        return j + 3
      end
      j = j + 1
    end
    return nil
  end
  -- CDATA section: <![CDATA[ ... ]]>.
  if text:sub(i, i + 8) == "<![CDATA[" then
    local close = text:find("]]>", i + 9, true)
    if not close then
      return nil
    end
    return close + 3
  end
  -- Declaration: <! ASCII-letter ... >.
  if text:sub(i, i + 1) == "<!" and text:sub(i + 2, i + 2):match("%a") then
    local close = text:find(">", i + 2, true)
    if not close then
      return nil
    end
    return close + 1
  end
  -- Processing instruction: <? ... ?>.
  if text:sub(i, i + 1) == "<?" then
    local close = text:find("?>", i + 2, true)
    if not close then
      return nil
    end
    return close + 2
  end
  -- Closing tag: </ tagname ws? >.
  if text:sub(i, i + 1) == "</" then
    local close = text:match("^</%a[%w-]*%s*>()", i)
    if close then
      return close
    end
    return nil
  end
  -- Open tag: < tagname (attr)* ws? /? >.
  local j = text:match("^<%a[%w-]*()", i)
  if not j then
    return nil
  end
  while true do
    local nj = match_attribute(text, j)
    if not nj then
      break
    end
    j = nj
  end
  -- Optional trailing whitespace, optional self-close slash, then ">".
  j = text:match("^%s*()", j) or j
  if text:sub(j, j) == "/" then
    j = j + 1
  end
  if text:sub(j, j) == ">" then
    return j + 1
  end
  return nil
end

-- process_emphasis: the CommonMark phase-2 algorithm over a doubly-linked node
-- list and its delimiter stack.  Each delimiter entry has fields node (its text
-- node), prev/next (stack links), char, length (remaining delim chars),
-- can_open, can_close, and orig_len (run length at scan time, for trimming).
-- Node-list links live on the nodes themselves (lnext/lprev).  Wrapping splices
-- an emphasis node into the list between opener and closer text nodes.
local function process_emphasis(head, delim_bottom)
  -- openers_bottom[char][closer_can_open][len%3] : the lowest opener we may
  -- match for a closer with that key.  nil means the stack bottom.
  local openers_bottom = {
    ["*"] = { [true] = {}, [false] = {} },
    ["_"] = { [true] = {}, [false] = {} },
  }

  -- Walk the delimiter stack from the bottom looking for closers.
  local closer = delim_bottom
  while closer do
    if not closer.can_close then
      closer = closer.next
    else
      local key_base = openers_bottom[closer.char][closer.can_open]
      local bottom = key_base[closer.length % 3]

      -- Scan back for the nearest matching opener above openers_bottom.
      local opener = closer.prev
      local opener_found = false
      while opener and opener ~= bottom do
        if opener.can_open and opener.char == closer.char then
          -- Rule of 3: if either side can both open and close, the sum of the
          -- ORIGINAL run lengths must not be a multiple of 3 (unless both
          -- original lengths are multiples of 3).
          local odd_match = (closer.can_open or opener.can_close)
            and (opener.orig_len + closer.orig_len) % 3 == 0
            and not (opener.orig_len % 3 == 0 and closer.orig_len % 3 == 0)
          if not odd_match then
            opener_found = true
            break
          end
        end
        opener = opener.prev
      end

      if opener_found then
        local strong = opener.length >= 2 and closer.length >= 2
        local use = strong and 2 or 1

        -- Collect the nodes strictly between opener.node and closer.node.
        local content = {}
        local cur = opener.node.lnext
        while cur and cur ~= closer.node do
          content[#content + 1] = cur
          cur = cur.lnext
        end

        local emph = ast.emphasis(strong and "bold" or "italic", content)

        -- Splice the emphasis node into the list right after opener.node.
        emph.lprev = opener.node
        emph.lnext = closer.node
        opener.node.lnext = emph
        closer.node.lprev = emph

        -- Remove delimiter entries strictly between opener and closer.
        opener.next = closer
        closer.prev = opener

        -- Consume `use` delimiter chars from each side.
        opener.length = opener.length - use
        closer.length = closer.length - use
        opener.node.text = string.rep(opener.char, opener.length)
        closer.node.text = string.rep(closer.char, closer.length)

        if opener.length == 0 then
          -- Remove opener node from the list and its stack entry.
          local p, q = opener.node.lprev, opener.node.lnext
          if p then
            p.lnext = q
          end
          if q then
            q.lprev = p
          end
          if opener.node == head then
            head = q
          end
          if opener.prev then
            opener.prev.next = opener.next
          end
          if opener.next then
            opener.next.prev = opener.prev
          end
          if opener == delim_bottom then
            delim_bottom = opener.next
          end
        end

        if closer.length == 0 then
          local next_closer = closer.next
          local p, q = closer.node.lprev, closer.node.lnext
          if p then
            p.lnext = q
          end
          if q then
            q.lprev = p
          end
          if closer.node == head then
            head = q
          end
          if closer.prev then
            closer.prev.next = closer.next
          end
          if closer.next then
            closer.next.prev = closer.prev
          end
          closer = next_closer
        end
        -- If the closer still has length, keep matching it against earlier
        -- openers on the next loop iteration (e.g. *** -> strong then em).
      else
        -- No match: set openers_bottom to just below this closer, and drop the
        -- closer's stack entry if it cannot also open.
        local next_closer = closer.next
        key_base[closer.length % 3] = closer.prev
        if not closer.can_open then
          if closer.prev then
            closer.prev.next = closer.next
          end
          if closer.next then
            closer.next.prev = closer.prev
          end
          if closer == delim_bottom then
            delim_bottom = closer.next
          end
        end
        closer = next_closer
      end
    end
  end

  return head
end

function M.parse(text, _refmap)
  text = text or ""
  -- Node list with linked-list fields (lprev/lnext) used by process_emphasis.
  local nodes = {}
  -- Delimiter stack: entries reference their text node, doubly linked.
  local delim_top, delim_bottom = nil, nil
  local buf = {}
  local function append(node)
    nodes[#nodes + 1] = node
  end
  local function flush()
    if #buf > 0 then
      append(ast.text(table.concat(buf)))
      buf = {}
    end
  end
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)

    -- Asterisk or underscore: a delimiter run for emphasis/strong.
    if c == "*" or c == "_" then
      local run_start = i
      while i <= n and text:sub(i, i) == c do
        i = i + 1
      end
      local run_len = i - run_start
      local before = run_start > 1 and text:sub(run_start - 1, run_start - 1) or ""
      local after = i <= n and text:sub(i, i) or ""

      local before_ws, before_punct = is_ws(before), is_punct(before)
      local after_ws, after_punct = is_ws(after), is_punct(after)

      -- left-flanking: not followed by ws, and (not followed by punct, or
      -- followed by punct and preceded by ws or punct).
      local left_flank = (not after_ws) and ((not after_punct) or before_ws or before_punct)
      -- right-flanking: not preceded by ws, and (not preceded by punct, or
      -- preceded by punct and followed by ws or punct).
      local right_flank = (not before_ws) and ((not before_punct) or after_ws or after_punct)

      local can_open, can_close
      if c == "*" then
        can_open = left_flank
        can_close = right_flank
      else
        can_open = left_flank and (not right_flank or before_punct)
        can_close = right_flank and (not left_flank or after_punct)
      end

      flush()
      local tnode = ast.text(string.rep(c, run_len))
      append(tnode)
      local d = {
        node = tnode,
        char = c,
        length = run_len,
        orig_len = run_len,
        can_open = can_open,
        can_close = can_close,
        prev = delim_top,
        next = nil,
      }
      if delim_top then
        delim_top.next = d
      else
        delim_bottom = d
      end
      delim_top = d

    -- Backtick: open a code span or emit literal backticks.
    elseif c == "`" then
      -- Count the opening backtick run length.
      local run_start = i
      local run_len = 0
      while i <= n and text:sub(i, i) == "`" do
        run_len = run_len + 1
        i = i + 1
      end
      -- Search for the matching closing run of exactly run_len backticks.
      local found = false
      local j = i
      while j <= n do
        if text:sub(j, j) == "`" then
          -- Count this backtick run.
          local close_start = j
          local close_len = 0
          while j <= n and text:sub(j, j) == "`" do
            close_len = close_len + 1
            j = j + 1
          end
          if close_len == run_len then
            -- Found matching close run.
            local content = text:sub(i, close_start - 1)
            flush()
            nodes[#nodes + 1] = ast.emphasis("code", { ast.text(normalize_code_span(content)) })
            i = j
            found = true
            break
          end
          -- Close run length mismatch: keep scanning from j (already advanced).
        else
          j = j + 1
        end
      end
      if not found then
        -- No matching close: emit the opening backticks as literal text.
        for k = run_start, run_start + run_len - 1 do
          buf[#buf + 1] = text:sub(k, k)
        end
        -- i is already past the opening run; continue scanning from there.
      end

    -- Less-than: autolink (URI then email) or raw inline HTML, else literal <.
    elseif c == "<" then
      local uri, uend = match_uri_autolink(text, i)
      if uri then
        flush()
        nodes[#nodes + 1] = ast.link(uri, uri, "autolink")
        i = uend
      else
        local addr, eend = match_email_autolink(text, i)
        if addr then
          flush()
          nodes[#nodes + 1] = ast.link("mailto:" .. addr, addr, "autolink")
          i = eend
        else
          local hend = match_raw_html(text, i, n)
          if hend then
            flush()
            nodes[#nodes + 1] = ast.raw_inline(text:sub(i, hend - 1))
            i = hend
          else
            buf[#buf + 1] = "<"
            i = i + 1
          end
        end
      end

    -- Newline: hard break (2+ trailing spaces or preceding backslash) or soft break.
    elseif c == "\n" then
      -- Check what precedes the newline in the current buffer.
      local buf_str = table.concat(buf)
      local trailing_spaces = #(buf_str:match(" *$") or "")
      local ends_backslash = buf_str:sub(-1) == "\\"

      if trailing_spaces >= 2 then
        -- CommonMark: 2+ trailing spaces before \n = hard break.
        buf = { buf_str:sub(1, #buf_str - trailing_spaces) }
        flush()
        nodes[#nodes + 1] = ast.linebreak()
      elseif ends_backslash then
        -- CommonMark: backslash immediately before \n = hard break.
        buf = { buf_str:sub(1, #buf_str - 1) }
        flush()
        nodes[#nodes + 1] = ast.linebreak()
      else
        -- Soft break: CommonMark strips trailing spaces before a soft break.
        local stripped = buf_str:gsub(" +$", "")
        buf = { stripped }
        flush()
        nodes[#nodes + 1] = ast.text("\n")
      end
      -- Strip leading spaces from next line.
      i = i + 1
      while i <= n and text:sub(i, i) == " " do
        i = i + 1
      end

    -- Backslash escape: next ASCII punctuation becomes literal.
    elseif c == "\\" and i < n and ASCII_PUNCT[text:sub(i + 1, i + 1)] then
      -- Backslash-before-newline hard break is caught by the \n branch above.
      buf[#buf + 1] = text:sub(i + 1, i + 1)
      i = i + 2
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  -- CommonMark #645: trailing spaces on a paragraph's final line are not
  -- significant and must be stripped.  The newline branch handles interior
  -- lines; this covers the last line, which reaches end-of-input without a \n.
  if #buf > 0 then
    local s = table.concat(buf)
    local stripped = s:gsub(" +$", "")
    buf = { stripped }
  end
  flush()

  -- Link the scanned nodes into a doubly-linked list, then run the emphasis
  -- phase over it.  Wrapping splices emphasis nodes between delimiter text
  -- nodes; leftover delimiter text nodes (length > 0) stay as literal text.
  if #nodes == 0 then
    return nodes
  end
  for k = 1, #nodes do
    nodes[k].lprev = nodes[k - 1]
    nodes[k].lnext = nodes[k + 1]
  end
  local head = process_emphasis(nodes[1], delim_bottom)

  -- Flatten the list back into an array, dropping the link fields and any
  -- empty text nodes left by fully-consumed delimiters.
  local result = {}
  local cur = head
  while cur do
    local nxt = cur.lnext
    cur.lprev, cur.lnext = nil, nil
    if not (cur.kind == "text" and cur.text == "") then
      result[#result + 1] = cur
    end
    cur = nxt
  end
  return result
end

return M
