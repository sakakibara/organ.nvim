-- Second-phase inline parser: re-parses a block's flat text into inline AST
-- nodes.  Runs after the block parse completes (so link reference definitions
-- are fully collected).  A position-advancing scanner: literal characters
-- accumulate into a buffer that flushes to an ast.text node whenever a special
-- construct is recognised.  Handles backslash escapes, code spans, hard/soft
-- line breaks, URI and email autolinks, raw inline HTML, emphasis/strong, and
-- inline links/images via the CommonMark delimiter stack.
local ast = require("organ.ast")
local html5_entities = require("organ.ast.html5_entities")

local M = {}

local ASCII_PUNCT = {}
for ch in ("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"):gmatch(".") do
  ASCII_PUNCT[ch] = true
end

local PUNCT_RANGES = require("organ.ast.unicode_punct")
local CASEFOLD = require("organ.ast.unicode_casefold")

-- Decode the first UTF-8 code point of `s` to a number, or nil if `s` is empty
-- or a truncated/standalone byte (so a lone byte from a byte-scan is harmless).
local function decode_cp(s)
  local b1 = s:byte(1)
  if not b1 then
    return nil
  end
  if b1 < 0x80 then
    return b1
  end
  local b2 = s:byte(2)
  if not b2 then
    return nil
  end
  if b1 < 0xE0 then
    return (b1 - 0xC0) * 64 + (b2 - 0x80)
  end
  local b3 = s:byte(3)
  if not b3 then
    return nil
  end
  if b1 < 0xF0 then
    return (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
  end
  local b4 = s:byte(4)
  if not b4 then
    return nil
  end
  return (b1 - 0xF0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + (b4 - 0x80)
end

-- The full UTF-8 code-point substring starting at byte `i` (or "" past the end).
local function cp_after(text, i, n)
  if i > n then
    return ""
  end
  local b = text:byte(i)
  local len = (b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
  return text:sub(i, math.min(i + len - 1, n))
end

-- The full UTF-8 code-point substring ending at byte `i` (or "" before the
-- start) -- walk back over continuation bytes (0x80-0xBF) to the lead byte.
local function cp_before(text, i)
  if i < 1 then
    return ""
  end
  local j = i
  while j > 1 do
    local b = text:byte(j)
    if b >= 0x80 and b <= 0xBF then
      j = j - 1
    else
      break
    end
  end
  return text:sub(j, i)
end

-- U+FFFD replacement character (UTF-8 encoding).
local REPLACEMENT_CHAR = "\239\191\189"

-- match_entity(text, i) -> (decoded_string, length) | nil
-- At position i where text[i] == '&', try to match a character reference:
--   NAMED:   &name;   where name is a key in html5_entities
--   DECIMAL: &#N;     1-7 digits; invalid/0/surrogate -> U+FFFD
--   HEX:     &#xH; or &#XH;  1-6 hex digits; same validity rules
-- Returns decoded string and total byte length of the reference, or nil.
local function match_entity(text, i)
  -- Must start with '&'.
  if text:sub(i, i) ~= "&" then
    return nil
  end
  local n = #text
  local j = i + 1

  if text:sub(j, j) == "#" then
    j = j + 1
    local hex = false
    if text:sub(j, j):lower() == "x" then
      hex = true
      j = j + 1
    end
    -- Collect digits (max 7 decimal, max 6 hex per CommonMark).
    local max_digits = hex and 6 or 7
    local digit_start = j
    local count = 0
    while j <= n and count < max_digits do
      local ch = text:sub(j, j)
      if hex and ch:match("[%x]") then
        count = count + 1
        j = j + 1
      elseif not hex and ch:match("%d") then
        count = count + 1
        j = j + 1
      else
        break
      end
    end
    if count == 0 then
      return nil
    end
    -- Must be followed by ';'.
    if text:sub(j, j) ~= ";" then
      return nil
    end
    local digits = text:sub(digit_start, j - 1)
    local cp = tonumber(digits, hex and 16 or 10)
    -- Invalid code points: 0, surrogates (D800-DFFF), or > U+10FFFF -> U+FFFD.
    if cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
      return REPLACEMENT_CHAR, j + 1 - i
    end
    return vim.fn.nr2char(cp, true), j + 1 - i
  else
    -- Named entity: collect [A-Za-z0-9] name then ';'.
    local name_start = j
    while j <= n do
      local ch = text:sub(j, j)
      if ch:match("[%a%d]") then
        j = j + 1
      else
        break
      end
    end
    local name = text:sub(name_start, j - 1)
    if name == "" then
      return nil
    end
    if text:sub(j, j) ~= ";" then
      return nil
    end
    local decoded = html5_entities[name]
    if not decoded then
      return nil
    end
    return decoded, j + 1 - i
  end
end

-- CommonMark Unicode whitespace: Zs category plus tab/LF/FF/CR; start/end of
-- input (nil/"") counts as whitespace for flanking.
local function is_ws(s)
  if s == nil or s == "" then
    return true
  end
  local cp = decode_cp(s)
  if not cp then
    return false
  end
  if cp == 0x20 or cp == 0x09 or cp == 0x0A or cp == 0x0C or cp == 0x0D then
    return true
  end
  return cp == 0xA0
    or cp == 0x1680
    or (cp >= 0x2000 and cp <= 0x200A)
    or cp == 0x202F
    or cp == 0x205F
    or cp == 0x3000
end

-- CommonMark Unicode punctuation: ASCII punctuation, or the Unicode P*/S*
-- categories (binary search over the generated code-point ranges).
local function is_punct(s)
  if s == nil or s == "" then
    return false
  end
  if #s == 1 then
    return ASCII_PUNCT[s] == true
  end
  local cp = decode_cp(s)
  if not cp then
    return false
  end
  local R = PUNCT_RANGES
  local lo, hi = 1, #R / 2
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local rlo, rhi = R[2 * mid - 1], R[2 * mid]
    if cp < rlo then
      hi = mid - 1
    elseif cp > rhi then
      lo = mid + 1
    else
      return true
    end
  end
  return false
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
for ch in ("-_.~:/?#@!$&'()*+,;=%"):gmatch(".") do
  DEST_SAFE[ch] = true
end

-- Percent-encode a string for use as an href: a valid existing %XX is kept; the
-- href-safe set and alphanumerics pass through; every other byte becomes %XX.
local function percent_encode(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "%" and s:sub(i + 1, i + 2):match("^%x%x$") then
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

-- normalize_destination: decode backslash escapes and entity references in a
-- raw link destination, then percent-encode it for an href per CommonMark.  An
-- existing valid %XX is preserved; the safe/reserved set above passes through;
-- all other bytes become %XX (uppercase hex).  Operates on bytes (UTF-8
-- multibyte -> multiple %XX).
local function normalize_destination(raw)
  -- Decode backslash escapes (only before ASCII punctuation, per spec) and
  -- entity references.
  local decoded = {}
  local i, n = 1, #raw
  while i <= n do
    local c = raw:sub(i, i)
    if c == "\\" and i < n and ASCII_PUNCT[raw:sub(i + 1, i + 1)] then
      decoded[#decoded + 1] = raw:sub(i + 1, i + 1)
      i = i + 2
    elseif c == "&" then
      local entity, len = match_entity(raw, i)
      if entity then
        decoded[#decoded + 1] = entity
        i = i + len
      else
        decoded[#decoded + 1] = c
        i = i + 1
      end
    else
      decoded[#decoded + 1] = c
      i = i + 1
    end
  end
  return percent_encode(table.concat(decoded))
end

-- Decode backslash escapes (ASCII punctuation only) and entity references in a
-- raw title string.
local function decode_escapes(raw)
  local out = {}
  local i, n = 1, #raw
  while i <= n do
    local c = raw:sub(i, i)
    if c == "\\" and i < n and ASCII_PUNCT[raw:sub(i + 1, i + 1)] then
      out[#out + 1] = raw:sub(i + 1, i + 1)
      i = i + 2
    elseif c == "&" then
      local entity, len = match_entity(raw, i)
      if entity then
        out[#out + 1] = entity
        i = i + len
      else
        out[#out + 1] = c
        i = i + 1
      end
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
    ["~"] = { [true] = {}, [false] = {} },
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
          if closer.char == "~" then
            -- GFM strikethrough: a `~` run matches only a run of the SAME
            -- length (1<->1, 2<->2); the rule of 3 does not apply.
            if opener.length == closer.length then
              opener_found = true
              break
            end
          else
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
        end
        opener = opener.prev
      end

      if opener_found then
        -- For `~`, the matched runs are equal-length (GFM): consume the whole
        -- run (1 or 2) and emit a strike node.  For `*`/`_`, consume 2 (strong)
        -- when both sides have >=2, else 1 (em).
        local style, use
        if closer.char == "~" then
          style = "strike"
          use = closer.length
        elseif opener.length >= 2 and closer.length >= 2 then
          style, use = "bold", 2
        else
          style, use = "italic", 1
        end

        -- Collect the nodes strictly between opener.node and closer.node.
        local content = {}
        local cur = opener.node.lnext
        while cur and cur ~= closer.node do
          content[#content + 1] = cur
          cur = cur.lnext
        end

        local emph = ast.emphasis(style, content)

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

-- Unicode full case fold: replace each code point by its CaseFolding.txt C/F
-- mapping (or itself).  Used for case-insensitive link-label matching.
local function casefold(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = (b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
    local piece = s:sub(i, i + len - 1)
    local cp = decode_cp(piece)
    out[#out + 1] = (cp and CASEFOLD[cp]) or piece
    i = i + len
  end
  return table.concat(out)
end

-- Normalize a link label for reference lookup.  Shared by inline reference
-- lookups and parse_reference's definition keys, so a definition and its use
-- normalize to the same key: collapse internal whitespace runs to a single
-- space, trim a leading/trailing space, case-fold.
local function normalize_label(label)
  return casefold((label:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")))
end

-- GFM extended autolinks (opt-in post-pass).  These operate on a single flat
-- text-node literal, recognising bare `www.`/scheme/email runs and splitting
-- them into `ast.link(..., "autolink")` nodes.  Distinct from the CommonMark
-- `<uri>`/`<email>` autolinks above (which require angle brackets).

-- Valid GFM domain: dot-separated segments of [%w_-], at least one period, and
-- no underscore in either of the last two segments.  Scans s starting at `i`
-- over the [%w_.-] run; a trailing dot (and any path beyond) is excluded from
-- the domain proper and left for the path scan.  Returns the index just past
-- the domain (the first non-domain char), or nil if no valid domain.
local function autolink_domain_end(s, i, n)
  local j = i
  while j <= n and s:sub(j, j):match("[%w_.-]") do
    j = j + 1
  end
  -- j is now one past the last [%w_.-] char.  Trailing dots are not part of the
  -- domain.  Split the run into dot-separated segments for validation.
  local run_end = j - 1
  while run_end >= i and s:sub(run_end, run_end) == "." do
    run_end = run_end - 1
  end
  if run_end < i then
    return nil
  end
  local run = s:sub(i, run_end)
  local segments = {}
  for seg in (run .. "."):gmatch("([^.]*)%.") do
    segments[#segments + 1] = seg
  end
  -- Need >= 2 segments (>= 1 period) and every segment non-empty.
  if #segments < 2 then
    return nil
  end
  for _, seg in ipairs(segments) do
    if seg == "" then
      return nil
    end
  end
  -- No underscore in the last two segments.
  if segments[#segments]:find("_", 1, true) or segments[#segments - 1]:find("_", 1, true) then
    return nil
  end
  return run_end + 1
end

-- Path validation: given the full match extent s[start..stop] (inclusive),
-- trim trailing chars per GFM until stable.  Returns the inclusive end index
-- of the valid extent.  Trailing
-- `?!.,:*_~` are stripped; a trailing `)` is stripped while closing parens
-- outnumber opening parens across the whole extent; a trailing `&alnum+;`
-- entity reference is stripped.  Running paren counts keep this O(n).
local function autolink_trim_path(s, start, stop)
  -- Count parens once across the extent; update incrementally as we trim.
  local opens, closes = 0, 0
  for k = start, stop do
    local ch = s:sub(k, k)
    if ch == "(" then
      opens = opens + 1
    elseif ch == ")" then
      closes = closes + 1
    end
  end
  while stop >= start do
    local last = s:sub(stop, stop)
    if last:match("[%?!.,:*_~]") then
      stop = stop - 1
    elseif last == ")" and closes > opens then
      closes = closes - 1
      stop = stop - 1
    else
      -- A trailing ';' is excluded: as a whole `&alpha+;` entity reference when
      -- it is one (cmark-gfm walks alphabetic, not alphanumeric, characters),
      -- otherwise just the bare ';'.  The stripped span holds no parens, so the
      -- counts are unchanged.
      if last == ";" then
        local amp = stop - 1
        while amp >= start and s:sub(amp, amp):match("%a") do
          amp = amp - 1
        end
        if amp >= start and s:sub(amp, amp) == "&" and amp < stop - 1 then
          stop = amp - 1
        else
          stop = stop - 1
        end
      else
        break
      end
    end
  end
  return stop
end

-- Match a www / scheme URL autolink at s[i].  scheme is nil for www. links
-- (the visible text omits the inserted http://) or the literal scheme string.
-- Returns (link_node, next_index) or nil.
local function match_autolink_url(s, i, n)
  local lower = s:sub(i):lower()
  local scheme_len, is_www
  if lower:sub(1, 4) == "www." then
    is_www = true
    scheme_len = 4
  elseif lower:sub(1, 7) == "http://" then
    scheme_len = 7
  elseif lower:sub(1, 8) == "https://" then
    scheme_len = 8
  elseif lower:sub(1, 6) == "ftp://" then
    scheme_len = 6
  else
    return nil
  end
  local dom_start = i + scheme_len
  local dom_end = autolink_domain_end(s, dom_start, n)
  if not dom_end then
    return nil
  end
  -- Path: consume to whitespace or `<`, then trim trailing chars.
  local stop = dom_end - 1
  local j = dom_end
  while j <= n do
    local ch = s:sub(j, j)
    if is_ws(ch) or ch == "<" then
      break
    end
    stop = j
    j = j + 1
  end
  stop = autolink_trim_path(s, i, stop)
  if stop < dom_end - 1 then
    -- Trimming ate into the domain; reject.
    return nil
  end
  local matched = s:sub(i, stop)
  local node
  if is_www then
    node = ast.link("http://" .. matched, matched, "autolink")
  else
    node = ast.link(matched, matched, "autolink")
  end
  return node, stop + 1
end

-- Match an email autolink at s[i].  Returns (link_node, next_index) or nil.
local function match_autolink_email(s, i, n)
  -- Local part: [%w.+_-]+
  local j = i
  while j <= n and s:sub(j, j):match("[%w.+_-]") do
    j = j + 1
  end
  if j == i or s:sub(j, j) ~= "@" then
    return nil
  end
  j = j + 1
  local dom_start = j
  while j <= n and s:sub(j, j):match("[%w._-]") do
    j = j + 1
  end
  local dom_end = j - 1
  if dom_end < dom_start then
    return nil
  end
  -- Exclude a single trailing '.' (left as following text).
  if s:sub(dom_end, dom_end) == "." then
    dom_end = dom_end - 1
  end
  if dom_end < dom_start then
    return nil
  end
  -- Validate: at least one period, last char not '-'/'_'.
  local domain = s:sub(dom_start, dom_end)
  if not domain:find(".", 1, true) then
    return nil
  end
  local last = domain:sub(-1)
  if last == "-" or last == "_" then
    return nil
  end
  local addr = s:sub(i, dom_end)
  return ast.link("mailto:" .. addr, addr, "autolink"), dom_end + 1
end

-- Split a text literal into text/autolink nodes per the GFM extended-autolinks
-- extension.  A candidate may begin only at a valid boundary: offset 1, or
-- right after whitespace or one of `* _ ~ (`.
local function scan_text(s)
  local nodes = {}
  local n = #s
  local run_start = 1
  local i = 1
  local function flush_run(upto)
    if upto >= run_start then
      nodes[#nodes + 1] = ast.text(s:sub(run_start, upto))
    end
  end
  while i <= n do
    local boundary = i == 1
    if not boundary then
      local prev = s:sub(i - 1, i - 1)
      boundary = is_ws(prev) or prev == "*" or prev == "_" or prev == "~" or prev == "("
    end
    local matched = false
    if boundary then
      local node, next_i = match_autolink_url(s, i, n)
      if not node then
        node, next_i = match_autolink_email(s, i, n)
      end
      if node and next_i and next_i > i then
        flush_run(i - 1)
        -- Record the link's byte span in `s` so a caller can map it back to the
        -- source (used to keep in-URL character references raw).
        node.span_start, node.span_stop = i, next_i - 1
        nodes[#nodes + 1] = node
        run_start = next_i
        i = next_i
        matched = true
      end
    end
    if not matched then
      i = i + 1
    end
  end
  flush_run(n)
  return nodes
end

-- Recursively apply scan_text to text nodes, descending into non-code emphasis;
-- links/images and code spans are left untouched (no autolinks inside).
-- Consecutive text nodes are coalesced first so a candidate that straddles an
-- intraword delimiter split (e.g. `c_d@a.b`, where `_` left a node boundary) is
-- still recognised.
--
-- A character reference is scanned in its RAW `&...;` form (so the GFM
-- trailing-reference and in-URL rules see it), then a reference the scan leaves
-- OUTSIDE a link is decoded while one kept inside a link stays raw, matching
-- cmark-gfm.  A reference node carries its raw source as `.raw`; a literal `&`
-- (e.g. from `\&amp;`) is an ordinary segment and is never decoded.  The map
-- from raw to decoded offsets makes this exact, so non-reference text -- even if
-- it spells out `&amp;` -- is left untouched.
local function extend_autolinks(nodes)
  local out = {}
  local segs, has_ref = {}, false
  local function flush_run()
    if #segs == 0 then
      return
    end
    if not has_ref then
      for _, sub in ipairs(scan_text(table.concat(segs))) do
        -- The byte-span fields are only needed by the reference path below.
        sub.span_start, sub.span_stop = nil, nil
        out[#out + 1] = sub
      end
    else
      -- Build the raw scan string and note where each reference STARTS (its byte
      -- length and decoded value).  Text the scan leaves outside a link is
      -- decoded by replacing only a reference that begins there and fits wholly
      -- in that text -- so a literal `&...;` (no reference start) is left as is,
      -- and a reference the autolink split (its trailing ';' trimmed off) keeps
      -- both parts raw, matching cmark-gfm.
      local raw_parts, ref_start = {}, {}
      local roff = 0
      for _, seg in ipairs(segs) do
        if type(seg) == "table" then
          ref_start[roff + 1] = { len = #seg.raw, dec = seg.dec }
          raw_parts[#raw_parts + 1] = seg.raw
          roff = roff + #seg.raw
        else
          raw_parts[#raw_parts + 1] = seg
          roff = roff + #seg
        end
      end
      local raw = table.concat(raw_parts)
      local function emit_decoded(a, b)
        if a > b then
          return
        end
        local parts, i = {}, a
        while i <= b do
          local rs = ref_start[i]
          if rs and i + rs.len - 1 <= b then
            parts[#parts + 1] = rs.dec
            i = i + rs.len
          else
            parts[#parts + 1] = raw:sub(i, i)
            i = i + 1
          end
        end
        out[#out + 1] = ast.text(table.concat(parts))
      end
      local p = 1
      for _, sub in ipairs(scan_text(raw)) do
        if sub.kind == "link" then
          emit_decoded(p, sub.span_start - 1)
          p = sub.span_stop + 1
          sub.span_start, sub.span_stop = nil, nil
          out[#out + 1] = sub
        end
      end
      emit_decoded(p, #raw)
    end
    segs, has_ref = {}, false
  end
  for _, node in ipairs(nodes) do
    if node.kind == "text" then
      if node.raw then
        segs[#segs + 1] = { raw = node.raw, dec = node.text or "" }
        has_ref = true
      else
        segs[#segs + 1] = node.text or ""
      end
    elseif node.kind == "emphasis" and node.style ~= "code" then
      flush_run()
      node.content = extend_autolinks(node.content or {})
      out[#out + 1] = node
    else
      flush_run()
      out[#out + 1] = node
    end
  end
  flush_run()
  return out
end

-- Scan a link label starting at the `[` at text[i]: returns the raw label
-- content (escapes preserved) and the index just past the closing `]`, or nil.
-- The label ends at the first unescaped `]`; `\[` and `\]` are escaped and stay
-- in the label; an unescaped `[` inside is not a valid label.  Bounded to 999
-- label characters.
local function scan_label(text, i, n)
  if text:sub(i, i) ~= "[" then
    return nil
  end
  local j = i + 1
  local count = 0
  while j <= n and count <= 999 do
    local c = text:sub(j, j)
    if c == "\\" and j < n then
      j = j + 2
      count = count + 2
    elseif c == "]" then
      return text:sub(i + 1, j - 1), j + 1
    elseif c == "[" then
      return nil
    else
      j = j + 1
      count = count + 1
    end
  end
  return nil
end

function M.parse(text, refmap, opts)
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
    -- A link label is at most 999 characters, so a longer link-text label (the
    -- collapsed/shortcut key) can match no definition; skipping the normalize +
    -- lookup avoids quadratic work on deeply nested brackets.  999 chars is at
    -- most 999*4 UTF-8 bytes.
    local label_fits = #label_text <= 999 * 4
    local entry, after

    if text:sub(close_pos + 1, close_pos + 1) == "[" then
      -- A bracket follows: full `[label]` or collapsed `[]`.
      local inner, iend = scan_label(text, close_pos + 1, n)
      if inner ~= nil then
        if inner == "" then
          -- COLLAPSED: lookup the link-text label.
          entry = label_fits and refmap[normalize_label(label_text)] or nil
        else
          -- FULL: lookup the explicit (nonempty) label.
          entry = refmap[normalize_label(inner)]
        end
        if entry then
          after = iend
        end
      end
    else
      -- SHORTCUT: no following bracket; lookup the link-text label.
      entry = label_fits and refmap[normalize_label(label_text)] or nil
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

    -- Asterisk, underscore, or tilde: a delimiter run for emphasis/strong
    -- (`*`/`_`) or GFM strikethrough (`~`).
    if c == "*" or c == "_" or c == "~" then
      local run_start = i
      while i <= n and text:sub(i, i) == c do
        i = i + 1
      end
      local run_len = i - run_start
      local before = run_start > 1 and cp_before(text, run_start - 1) or ""
      local after = i <= n and cp_after(text, i, n) or ""

      local before_ws, before_punct = is_ws(before), is_punct(before)
      local after_ws, after_punct = is_ws(after), is_punct(after)

      -- left-flanking: not followed by ws, and (not followed by punct, or
      -- followed by punct and preceded by ws or punct).
      local left_flank = (not after_ws) and ((not after_punct) or before_ws or before_punct)
      -- right-flanking: not preceded by ws, and (not preceded by punct, or
      -- preceded by punct and followed by ws or punct).
      local right_flank = (not before_ws) and ((not before_punct) or after_ws or after_punct)

      local can_open, can_close
      if c == "*" or c == "~" then
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
        append(ast.link(percent_encode(uri), uri, "autolink"))
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

    -- Ampersand: try to decode a named or numeric character reference.
    elseif c == "&" then
      local entity, len = match_entity(text, i)
      if entity then
        flush()
        local node = ast.text(entity)
        -- Keep the raw reference so the extended-autolink pass can scan it.
        if opts and opts.extended_autolinks then
          node.raw = text:sub(i, i + len - 1)
        end
        append(node)
        i = i + len
      else
        buf[#buf + 1] = c
        i = i + 1
      end
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

  if opts and opts.extended_autolinks then
    result = extend_autolinks(result)
  end
  return result
end

-- Skip spaces/tabs from s[i], crossing AT MOST one line ending, then more
-- spaces/tabs.  Returns the resulting index and whether any whitespace was
-- consumed and whether a line ending was crossed.
local function skip_blanks_one_eol(s, i, n)
  local consumed = false
  local crossed_eol = false
  while i <= n do
    local c = s:sub(i, i)
    if c == " " or c == "\t" then
      i = i + 1
      consumed = true
    elseif c == "\n" and not crossed_eol then
      i = i + 1
      consumed = true
      crossed_eol = true
    else
      break
    end
  end
  return i, consumed, crossed_eol
end

-- True if from s[i] the rest of the current line is only spaces/tabs up to a
-- line ending or end of input.  Returns also the index just past that line
-- ending (or #s + 1 at EOF).
local function rest_of_line_blank(s, i, n)
  local j = i
  while j <= n do
    local c = s:sub(j, j)
    if c == " " or c == "\t" then
      j = j + 1
    elseif c == "\n" then
      return true, j + 1
    else
      return false, nil
    end
  end
  return true, n + 1
end

-- Parse ONE leading link reference definition from `s` starting at index `i`.
-- `s` is the joined paragraph text (lines separated by "\n").  Returns
-- `next_index, key, destination, title` on success, or nil.  Reuses the inline
-- destination/title/label parsers so the grammar is shared with inline links.
function M.parse_reference(s, i)
  local n = #s
  local j = i

  -- Up to three leading spaces.
  local spaces = 0
  while j <= n and s:sub(j, j) == " " and spaces < 3 do
    j = j + 1
    spaces = spaces + 1
  end
  if s:sub(j, j) ~= "[" then
    return nil
  end

  -- Label: scan to the matching unescaped `]`, cap 999 content chars, require a
  -- non-whitespace char.
  local label_start = j + 1
  local k = label_start
  local content = 0
  local label_end
  while k <= n do
    local c = s:sub(k, k)
    if c == "\\" and k < n and ASCII_PUNCT[s:sub(k + 1, k + 1)] then
      content = content + 2
      k = k + 2
    elseif c == "]" then
      label_end = k
      break
    elseif c == "[" then
      -- An unescaped `[` is not allowed inside a label.
      return nil
    else
      content = content + 1
      k = k + 1
    end
    if content > 999 then
      return nil
    end
  end
  if not label_end then
    return nil
  end
  local raw_label = s:sub(label_start, label_end - 1)
  if raw_label:match("^%s*$") then
    return nil
  end
  -- Require `]:`.
  if s:sub(label_end + 1, label_end + 1) ~= ":" then
    return nil
  end

  -- Skip whitespace after `:` (spaces/tabs incl up to one line ending).
  local pos = skip_blanks_one_eol(s, label_end + 2, n)

  -- Destination.  An empty destination is valid only in angle-bracket form
  -- (`<>`); an empty bare form is no destination at all.
  local angle = s:sub(pos, pos) == "<"
  local raw_dest, after = parse_destination(s, pos, n)
  if not raw_dest or (raw_dest == "" and not angle) then
    return nil
  end

  -- Title with backtrack.  Try to read a title separated from the dest by
  -- whitespace (incl up to one line ending); accept only if its line then ends.
  local raw_title = nil
  local title_end = nil
  local tpos, tconsumed = skip_blanks_one_eol(s, after, n)
  if tconsumed and tpos <= n then
    local tc = s:sub(tpos, tpos)
    if tc == '"' or tc == "'" or tc == "(" then
      local rt, tafter = parse_title(s, tpos, n)
      if rt ~= nil then
        local ok, line_end = rest_of_line_blank(s, tafter, n)
        if ok then
          raw_title = rt
          title_end = line_end
        end
      end
    end
  end

  local next_index
  if raw_title ~= nil then
    next_index = title_end
  else
    -- No acceptable title: the dest must end its line (only trailing blanks).
    local ok, line_end = rest_of_line_blank(s, after, n)
    if not ok then
      return nil
    end
    next_index = line_end
  end

  local key = normalize_label(raw_label)
  local destination = normalize_destination(raw_dest)
  local title = raw_title and decode_escapes(raw_title) or nil
  return next_index, key, destination, title
end

M.decode_escapes = decode_escapes

return M
