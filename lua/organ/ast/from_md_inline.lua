-- Second-phase inline parser: re-parses a block's flat text into inline AST
-- nodes.  Runs after the block parse completes (so link reference definitions
-- are fully collected).  A position-advancing scanner: literal characters
-- accumulate into a buffer that flushes to an ast.text node whenever a special
-- construct is recognised.  Handles backslash escapes, code spans, hard/soft
-- line breaks, URI and email autolinks, raw inline HTML, emphasis/strong, and
-- inline links/images via the CommonMark delimiter stack.
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

-- Bytes left unescaped in a normalized link destination.  CommonMark keeps
-- ASCII letters/digits and this reserved/safe punctuation; everything else is
-- percent-encoded.  A pre-existing valid %XX escape is also left intact.
local DEST_SAFE = {}
for ch in ("-_.~:/?#[]@!$&'()*+,;=%"):gmatch(".") do
  DEST_SAFE[ch] = true
end

-- normalize_destination: decode backslash escapes in a raw link destination,
-- then percent-encode it for an href per CommonMark.  An existing valid %XX is
-- preserved; the safe/reserved set above passes through; all other bytes become
-- %XX (uppercase hex).  Operates on bytes (UTF-8 multibyte -> multiple %XX).
local function normalize_destination(raw)
  -- Decode backslash escapes (only before ASCII punctuation, per spec).
  local decoded = {}
  local i, n = 1, #raw
  while i <= n do
    local c = raw:sub(i, i)
    if c == "\\" and i < n and ASCII_PUNCT[raw:sub(i + 1, i + 1)] then
      decoded[#decoded + 1] = raw:sub(i + 1, i + 1)
      i = i + 2
    else
      decoded[#decoded + 1] = c
      i = i + 1
    end
  end
  local s = table.concat(decoded)

  local out = {}
  i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "%" and s:sub(i + 1, i + 2):match("^%x%x$") then
      -- Preserve an existing valid percent-escape verbatim.
      out[#out + 1] = s:sub(i, i + 2)
      i = i + 3
    elseif DEST_SAFE[c] or c:match("[%w]") then
      out[#out + 1] = c
      i = i + 1
    else
      out[#out + 1] = string.format("%%%02X", c:byte())
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Decode backslash escapes (ASCII punctuation only) in a raw title string.
local function decode_escapes(raw)
  local out = {}
  local i, n = 1, #raw
  while i <= n do
    local c = raw:sub(i, i)
    if c == "\\" and i < n and ASCII_PUNCT[raw:sub(i + 1, i + 1)] then
      out[#out + 1] = raw:sub(i + 1, i + 1)
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Parse an inline link destination at text[i].  Returns the raw destination
-- string and the index just past it, or nil.  Two forms: angle-bracketed
-- (<...>, no unescaped <, >, or newline) or bare (no whitespace/control, with
-- balanced parentheses unless backslash-escaped).
local function parse_destination(text, i, n)
  if text:sub(i, i) == "<" then
    local j = i + 1
    while j <= n do
      local ch = text:sub(j, j)
      if ch == "\\" and j < n and ASCII_PUNCT[text:sub(j + 1, j + 1)] then
        j = j + 2
      elseif ch == ">" then
        return text:sub(i + 1, j - 1), j + 1
      elseif ch == "<" or ch == "\n" then
        return nil
      else
        j = j + 1
      end
    end
    return nil
  end
  -- Bare destination: stop at whitespace; track paren balance; control chars
  -- (byte <= 0x1f or 0x7f) terminate the destination as not allowed.
  local j = i
  local depth = 0
  while j <= n do
    local ch = text:sub(j, j)
    local b = ch:byte()
    if ch == "\\" and j < n and ASCII_PUNCT[text:sub(j + 1, j + 1)] then
      j = j + 2
    elseif b <= 0x20 or b == 0x7f then
      break
    elseif ch == "(" then
      depth = depth + 1
      j = j + 1
    elseif ch == ")" then
      if depth == 0 then
        break
      end
      depth = depth - 1
      j = j + 1
    else
      j = j + 1
    end
  end
  -- Unbalanced open parens: not a valid destination.
  if depth ~= 0 then
    return nil
  end
  return text:sub(i, j - 1), j
end

-- Parse an inline link title at text[i] (one of ", ', or ().  Returns the raw
-- (still-escaped) title string and the index just past the closing delimiter,
-- or nil.  The title may not contain its unescaped closing delimiter.
local function parse_title(text, i, n)
  local open = text:sub(i, i)
  local close
  if open == '"' then
    close = '"'
  elseif open == "'" then
    close = "'"
  elseif open == "(" then
    close = ")"
  else
    return nil
  end
  local j = i + 1
  while j <= n do
    local ch = text:sub(j, j)
    if ch == "\\" and j < n and ASCII_PUNCT[text:sub(j + 1, j + 1)] then
      j = j + 2
    elseif ch == close then
      return text:sub(i + 1, j - 1), j + 1
    elseif open == "(" and ch == "(" then
      -- A `(...)` title may not contain an unescaped `(`.
      return nil
    else
      j = j + 1
    end
  end
  return nil
end

-- Flatten a link-text node span to plain text for image alt rendering.  Text
-- and code content concatenate; emphasis and links unwrap to their content's
-- plain text; images contribute their alt; raw inline HTML is dropped.
local function plain_text(node)
  if node.kind == "text" then
    return node.text or ""
  elseif node.kind == "emphasis" and node.style == "code" then
    return (node.content and node.content[1] and node.content[1].text) or ""
  elseif node.kind == "emphasis" then
    local parts = {}
    for _, c in ipairs(node.content or {}) do
      parts[#parts + 1] = plain_text(c)
    end
    return table.concat(parts)
  elseif node.kind == "link" then
    local parts = {}
    for _, c in ipairs(node.description or {}) do
      parts[#parts + 1] = plain_text(c)
    end
    return table.concat(parts)
  elseif node.kind == "image" then
    return node.alt or ""
  elseif node.kind == "linebreak" then
    return "\n"
  end
  return ""
end

-- process_emphasis: the CommonMark phase-2 algorithm over a doubly-linked node
-- list and its delimiter stack.  Each delimiter entry has fields node (its text
-- node), prev/next (stack links), char, length (remaining delim chars),
-- can_open, can_close, and orig_len (run length at scan time, for trimming).
-- Node-list links live on the nodes themselves (lnext/lprev).  Wrapping splices
-- an emphasis node into the list between opener and closer text nodes.
-- stack_bottom (optional) bounds the opener scan: openers at or below it are out
-- of reach.  Used when resolving emphasis within a link-text span so emphasis
-- cannot reach across the bracket opener into earlier delimiters.
local function process_emphasis(head, delim_bottom, stack_bottom)
  -- openers_bottom[char][closer_can_open][len%3] : the lowest opener we may
  -- match for a closer with that key.  nil means stack_bottom (or the real
  -- stack bottom when stack_bottom is nil).
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
      local bottom = key_base[closer.length % 3] or stack_bottom

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

-- Normalize a link label for reference lookup.  MUST match the block parser's
-- ref-def key normalization in from_md.link_ref_def: collapse internal
-- whitespace runs to a single space, trim a leading/trailing space, case-fold.
local function normalize_label(label)
  return (label:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower())
end

function M.parse(text, refmap)
  text = text or ""
  refmap = refmap or {}
  -- Delimiter stack: entries reference their text node, doubly linked.  Bracket
  -- delimiters (`[`, `![`) ride the same stack; they are inert to the emphasis
  -- algorithm (can_open/can_close false) and consumed by the link procedure.
  local delim_top, delim_bottom = nil, nil
  -- The node list is doubly linked (lprev/lnext) as it is built so the inline
  -- link/image procedure can splice nodes mid-scan.
  local head, tail = nil, nil
  local buf = {}
  local n = #text
  local function append(node)
    node.lprev = tail
    node.lnext = nil
    if tail then
      tail.lnext = node
    else
      head = node
    end
    tail = node
  end
  local function flush()
    if #buf > 0 then
      append(ast.text(table.concat(buf)))
      buf = {}
    end
  end

  -- Unlink a bracket-opener delimiter entry from the stack.
  local function remove_opener(opener)
    if opener.prev then
      opener.prev.next = opener.next
    else
      delim_bottom = opener.next
    end
    if opener.next then
      opener.next.prev = opener.prev
    else
      delim_top = opener.prev
    end
  end

  -- Build a link/image node from a resolved bracket opener and dest/title (raw
  -- destination, raw title or nil, link form).  Resolves emphasis within the
  -- link-text span, splices the node in place of the opener and its span, drops
  -- consumed stack entries, and deactivates earlier link openers for a link.
  local function build_link(opener, dest, title, form)
    local is_image = opener.image
    -- Resolve emphasis strictly within the link-text span (above the opener);
    -- the opener bounds the scan so emphasis cannot reach earlier delimiters.
    head = process_emphasis(head, opener.next, opener)

    -- Collect the resolved span: nodes strictly after the opener's `[` node.
    local span = {}
    local cur = opener.node.lnext
    while cur do
      span[#span + 1] = cur
      cur = cur.lnext
    end

    local title_decoded = title and decode_escapes(title) or nil
    local newnode
    if is_image then
      local parts = {}
      for _, sn in ipairs(span) do
        parts[#parts + 1] = plain_text(sn)
      end
      newnode = {
        kind = "image",
        target = normalize_destination(dest),
        alt = table.concat(parts),
        title = title_decoded,
      }
    else
      for k = 1, #span do
        span[k].lprev, span[k].lnext = nil, nil
      end
      newnode = ast.link(normalize_destination(dest), span, form)
      newnode.title = title_decoded
    end

    -- Splice newnode in place of the opener's `[` node and the whole span.
    local before = opener.node.lprev
    newnode.lprev = before
    newnode.lnext = nil
    if before then
      before.lnext = newnode
    else
      head = newnode
    end
    tail = newnode

    -- Drop the opener and every delimiter above it from the stack.
    if opener.prev then
      opener.prev.next = nil
    else
      delim_bottom = nil
    end
    delim_top = opener.prev

    -- A link deactivates all earlier non-image `[` openers (no nested links).
    if not is_image then
      local d = delim_top
      while d do
        if d.char == "[" and not d.image then
          d.active = false
        end
        d = d.prev
      end
    end
  end

  -- "look for link or image" on `]` at text[close_pos].  Returns the index just
  -- past the consumed link syntax on success, or nil to fall through to a
  -- literal `]`.  Tries the inline `(...)` form first, then the reference forms
  -- (full, collapsed, shortcut) against refmap.
  local function look_for_link(close_pos)
    -- Find the nearest bracket opener on the delimiter stack.
    local opener = delim_top
    while opener and opener.char ~= "[" do
      opener = opener.prev
    end
    if not opener then
      return nil
    end
    if not opener.active then
      remove_opener(opener)
      return nil
    end

    -- Try to parse the inline `(dest "title")` form.  char after `]` must be `(`.
    local p = close_pos + 1
    if text:sub(p, p) == "(" then
      p = p + 1
      p = text:match("^[ \t\n]*()", p) or p
      local dest, title = "", nil
      local ok = true
      if text:sub(p, p) ~= ")" then
        local d, after = parse_destination(text, p, n)
        if d then
          dest = d
          p = after
          local ws = text:match("^[ \t\n]+()", p)
          if ws then
            local t, tafter = parse_title(text, ws, n)
            if t then
              title = t
              p = tafter
            end
          end
        else
          ok = false
        end
      end
      if ok then
        p = text:match("^[ \t\n]*()", p) or p
        if text:sub(p, p) == ")" then
          build_link(opener, dest, title, "inline")
          return p + 1
        end
      end
    end

    -- Inline form failed.  Try the reference forms against refmap.  The label
    -- text is the raw source between the opener bracket and this `]`.
    local label_text = text:sub(opener.text_start, close_pos - 1)
    local entry, after

    if text:sub(close_pos + 1, close_pos + 1) == "[" then
      -- A bracket follows: full `[label]` or collapsed `[]`.
      local inner, iend = text:match("^%[(.-)%]()", close_pos + 1)
      if inner ~= nil then
        if inner == "" then
          -- COLLAPSED: lookup the link-text label.
          entry = refmap[normalize_label(label_text)]
        elseif not inner:match("[%[%]]") then
          -- FULL: lookup the explicit (nonempty) label.
          entry = refmap[normalize_label(inner)]
        end
        if entry then
          after = iend
        end
      end
    else
      -- SHORTCUT: no following bracket; lookup the link-text label.
      entry = refmap[normalize_label(label_text)]
      if entry then
        after = close_pos + 1
      end
    end

    if not entry then
      -- Not a reference: drop this opener and fall through to a literal `]`.
      -- For the full form, the trailing `[label]` is reprocessed as text.
      remove_opener(opener)
      return nil
    end

    build_link(opener, entry.destination, entry.title, "reference")
    return after
  end

  local i = 1
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
            append(ast.emphasis("code", { ast.text(normalize_code_span(content)) }))
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
        append(ast.link(uri, uri, "autolink"))
        i = uend
      else
        local addr, eend = match_email_autolink(text, i)
        if addr then
          flush()
          append(ast.link("mailto:" .. addr, addr, "autolink"))
          i = eend
        else
          local hend = match_raw_html(text, i, n)
          if hend then
            flush()
            append(ast.raw_inline(text:sub(i, hend - 1)))
            i = hend
          else
            buf[#buf + 1] = "<"
            i = i + 1
          end
        end
      end

    -- Open bracket: an image opener `![` (when `!` precedes) or a link opener
    -- `[`.  Push a bracket delimiter referencing its text node.
    elseif c == "[" then
      flush()
      local tnode = ast.text("[")
      append(tnode)
      local d = {
        node = tnode,
        char = "[",
        image = false,
        text_start = i + 1,
        active = true,
        can_open = false,
        can_close = false,
        prev = delim_top,
        next = nil,
      }
      if delim_top then
        delim_top.next = d
      else
        delim_bottom = d
      end
      delim_top = d
      i = i + 1

    -- Exclamation: `![` is an image opener; a bare `!` is literal text.
    elseif c == "!" and text:sub(i + 1, i + 1) == "[" then
      flush()
      local tnode = ast.text("![")
      append(tnode)
      local d = {
        node = tnode,
        char = "[",
        image = true,
        text_start = i + 2,
        active = true,
        can_open = false,
        can_close = false,
        prev = delim_top,
        next = nil,
      }
      if delim_top then
        delim_top.next = d
      else
        delim_bottom = d
      end
      delim_top = d
      i = i + 2

    -- Close bracket: run the "look for link or image" procedure.
    elseif c == "]" then
      flush()
      local after = look_for_link(i)
      if after then
        i = after
      else
        buf[#buf + 1] = "]"
        i = i + 1
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
        append(ast.linebreak())
      elseif ends_backslash then
        -- CommonMark: backslash immediately before \n = hard break.
        buf = { buf_str:sub(1, #buf_str - 1) }
        flush()
        append(ast.linebreak())
      else
        -- Soft break: CommonMark strips trailing spaces before a soft break.
        local stripped = buf_str:gsub(" +$", "")
        buf = { stripped }
        flush()
        append(ast.text("\n"))
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

  -- Resolve any emphasis delimiters left on the stack (those not consumed by a
  -- link procedure).  The node list is already doubly linked from append; the
  -- bracket entries on the stack are inert to the emphasis algorithm.
  if not head then
    return {}
  end
  head = process_emphasis(head, delim_bottom)

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
