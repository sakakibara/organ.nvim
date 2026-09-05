-- Org-mode formatter.  Composable pure passes that read config from
-- `organ.config.format`.  Format-on-save is intentionally NOT a
-- knob here -- conform.nvim, none-ls, the built-in LSP
-- `textDocument/formatting`, and a 3-line user-wired BufWritePre
-- autocmd all drive `M.format_buffer` cleanly.  See the README
-- "Formatting" section for recipes.

local M = {}

local obuf = require("organ.buf")
local list = require("organ.list")
local block = require("organ.block")
local function is_headline(line)
  return line:match("^%*+%s") ~= nil
end
local function is_planning(line)
  return line:match("^%s*[Ss][Cc][Hh][Ee][Dd][Uu][Ll][Ee][Dd]:") ~= nil
    or line:match("^%s*[Dd][Ee][Aa][Dd][Ll][Ii][Nn][Ee]:") ~= nil
    or line:match("^%s*[Cc][Ll][Oo][Ss][Ee][Dd]:") ~= nil
end
local function is_drawer_open(line)
  return line:match("^%s*:[%w_-]+:%s*$") ~= nil
end
local function is_drawer_close(line)
  return line:match("^%s*:[Ee][Nn][Dd]:%s*$") ~= nil
end
local function is_block_open(line)
  return line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_") ~= nil
end
local function is_block_close(line)
  return line:match("^%s*#%+[Ee][Nn][Dd]_") ~= nil
end
local function is_directive(line)
  return line:match("^%s*#%+") ~= nil
end
local function is_table(line)
  return line:match("^%s*|") ~= nil
end
local function is_list(line)
  return list.parse_item(line) ~= nil
end
local function is_fixed_width(line)
  return line:match("^%s*:%s") ~= nil or line:match("^%s*:$") ~= nil
end
local function is_hrule(line)
  return line:match("^%s*%-%-%-%-%-+%s*$") ~= nil
end
local function is_comment(line)
  return line:match("^%s*#%s") ~= nil or line:match("^%s*#$") ~= nil
end
local function leading_indent(line)
  return line:match("^(%s*)") or ""
end

-- `nil` means "no width available": `textwidth = 0` is Vim for "do not
-- hard-wrap", so only an explicitly requested reflow (`gq`) falls back.
local function effective_width(bufnr, cfg, fallback)
  local explicit = (cfg.wrap or {}).width
  if explicit and explicit > 0 then
    return explicit
  end
  if bufnr then
    local tw = vim.bo[bufnr].textwidth
    if tw and tw > 0 then
      return tw
    end
  end
  return fallback
end

local function format_cfg(bufnr)
  local ok, organ = pcall(require, "organ")
  if ok and organ.config and require("organ.buf_config").read(bufnr, "format") then
    return require("organ.buf_config").read(bufnr, "format")
  end
  return {}
end

local function trim_trailing_whitespace(lines)
  local out = {}
  for i, l in ipairs(lines) do
    -- An empty headline is `*+ ` (stars + one space + empty title).  The
    -- space is structural: strip it and `*` alone is misparsed as prose
    -- and wrapped into the line above.  Keep exactly one space.
    local stars = l:match("^(%*+)%s+$")
    if stars then
      out[i] = stars .. " "
    else
      out[i] = l:gsub("%s+$", "")
    end
  end
  return out
end

local function split_trailing_tags(s)
  local body, tags = s:match("^(.-)%s+(:[%w_@#%%][%w_@#%%:]*:)%s*$")
  if body and tags then
    return body, tags
  end
  return s, nil
end

-- Resolve a `tags_column` config value to a placement directive.
-- Returns either nil (no alignment, caller emits a single-space gap)
-- or a table:
--   { kind = "flush" }                          -> one space between title and tags
--   { kind = "left",  column = N (int >= 1) }   -> tag block's LEFT edge at col N
--   { kind = "right", column = N (int >= 1) }   -> tag block's RIGHT edge at col N
--
-- Accepted shapes for `value`:
--   positive integer N       -> { kind = "left",  column = N }   (Emacs compat)
--   negative integer N       -> { kind = "right", column = |N| } (Emacs compat)
--   0                        -> { kind = "flush" }
--   false                    -> nil (no alignment)
--   "textwidth"              -> right edge at vim.bo[bufnr].textwidth
--                               (falls back to 80 when textwidth is 0/unset)
--   "textwidth+N" / "-N"     -> right edge at textwidth +/- N
--   "winwidth"               -> right edge at nvim_win_get_width(winid)
--   "winwidth+N" / "-N"      -> right edge at winwidth +/- N
--   function                 -> result recursively resolved
--
-- `bufnr` defaults to 0 (current); `winid` defaults to 0 (current).
function M._resolve_tags_column(value, bufnr, winid)
  if type(value) == "function" then
    local ok, inner = pcall(value)
    if not ok then
      return nil
    end
    return M._resolve_tags_column(inner, bufnr, winid)
  end
  if value == nil or value == false then
    return nil
  end
  if value == 0 then
    return { kind = "flush" }
  end
  if type(value) == "number" then
    if value > 0 then
      return { kind = "left", column = math.floor(value) }
    end
    return { kind = "right", column = -math.floor(value) }
  end
  if type(value) == "string" then
    local base, sign, num = value:match("^(%w+)([%+%-]?)(%d*)$")
    if not base then
      return nil
    end
    -- Reject "textwidth+" / "textwidth-" (sign without number) and
    -- "textwidthabc" (no sign, trailing garbage).  Either both empty
    -- (bare "textwidth") or both non-empty is allowed.
    if (sign == "" and num ~= "") or (sign ~= "" and num == "") then
      return nil
    end
    local offset = 0
    if sign ~= "" and num ~= "" then
      offset = tonumber(num) or 0
      if sign == "-" then
        offset = -offset
      end
    end
    local b = bufnr or 0
    local w = winid or 0
    local base_val
    if base == "textwidth" then
      local ok, tw = pcall(function()
        return vim.bo[b].textwidth
      end)
      base_val = (ok and tw) or 0
      if base_val == 0 then
        base_val = 80
      end
    elseif base == "winwidth" then
      local ok, ww = pcall(vim.api.nvim_win_get_width, w)
      base_val = (ok and ww) or 80
    else
      return nil
    end
    local column = base_val + offset
    if column < 1 then
      column = 1
    end
    return { kind = "right", column = column }
  end
  return nil
end

-- `strdisplaywidth` raises E976 on a string holding a NUL byte, which
-- Vimscript takes for a Blob.  nvim renders that byte as `^@`.
local function cell_width(s)
  return vim.fn.strdisplaywidth((s:gsub("%z", "^@")))
end

-- Compute the padded headline string for "<left><pad><tags>".  Aligns
-- the tag block to `opts.tags_column` (or, when nil,
-- `config.format.headline.tags_column`, falling back to "textwidth").
-- See M._resolve_tags_column for accepted value shapes.
--
-- When `tags` is "" or nil, returns `left` unchanged.  Otherwise
-- returns `left .. pad_spaces .. tags` with `pad >= 1` so the tag
-- block never abuts a non-space character.
function M.align_tag_block(left, tags, opts)
  if tags == nil or tags == "" then
    return left
  end
  opts = opts or {}
  local cfg_val = opts.tags_column
  if cfg_val == nil then
    cfg_val = (format_cfg(opts.bufnr).headline or {}).tags_column
    if cfg_val == nil then
      cfg_val = "textwidth"
    end
  end
  local resolved = M._resolve_tags_column(cfg_val, opts.bufnr, opts.winid)
  if resolved == nil or resolved.kind == "flush" then
    return left .. " " .. tags
  end
  local left_w = cell_width(left)
  local tags_w = cell_width(tags)
  local left_edge
  if resolved.kind == "left" then
    left_edge = resolved.column
  else
    -- "right": tag's right edge at resolved.column; left edge at column - tags_w
    left_edge = resolved.column - tags_w
  end
  local pad = left_edge - left_w
  if pad < 1 then
    pad = 1
  end
  return left .. string.rep(" ", pad) .. tags
end

local function normalize_headline(line, opts)
  opts = opts or {}
  local normalize = opts.normalize_whitespace ~= false
  if not normalize and not opts.tags_column then
    return line
  end
  -- Space-only separators throughout, as in Emacs `org-complex-heading-regexp`
  -- and `outline-regexp`: `* TODO<TAB>x` has no TODO keyword and `*<TAB>x` is
  -- not a headline at all, so collapsing either would change what Emacs reads
  -- back.
  local stars, gap, rest = line:match("^(%*+)( +)(.-)%s*$")
  if not stars then
    return line
  end
  local body, tags = split_trailing_tags(rest)
  body = body:gsub("%s+$", "")

  local left
  if not normalize then
    left = body == "" and (stars .. " ") or (stars .. gap .. body)
  else
    local todo_kw_set = {}
    do
      local ok, todo = pcall(require, "organ.todo")
      if ok and type(todo.all_keywords) == "function" then
        for _, k in ipairs(todo.all_keywords()) do
          todo_kw_set[k] = true
        end
      end
    end
    local pieces = {}
    local cursor = 1
    do
      local first, after = body:match("^(%S+) +()")
      if first and todo_kw_set[first] then
        pieces[#pieces + 1] = first
        cursor = after
      end
    end
    do
      local sub = body:sub(cursor)
      local cookie, after = sub:match("^(%[#[%u%d]%]) *()")
      if cookie then
        pieces[#pieces + 1] = cookie
        cursor = cursor + (after - 1)
      end
    end
    do
      local sub = body:sub(cursor)
      local kw, after = sub:match("^(COMMENT) +()")
      if kw then
        pieces[#pieces + 1] = kw
        cursor = cursor + (after - 1)
      end
    end
    -- The title is carried over verbatim: Emacs's fill and align commands
    -- never rewrite title text, and collapsing it can change how Emacs
    -- reads the line back.
    local title = body:sub(cursor)
    if title ~= "" then
      pieces[#pieces + 1] = title
    end

    -- Empty-title headline stays `*+ ` (with the structural space), never a
    -- bare `*+` -- otherwise it is misparsed as prose and wrapped away.
    left = stars .. " "
    if #pieces > 0 then
      left = stars .. " " .. table.concat(pieces, " ")
    end
  end
  if not tags then
    return left
  end
  -- `opts.tags_column == nil` here means "caller did not pass an explicit
  -- target", which inside the formatter pipeline (`normalize_headlines`)
  -- means "leave tags wherever the user typed them"; flip nil to false so
  -- the helper takes the flush-with-one-space branch rather than reading
  -- the config default.
  local target = opts.tags_column
  if target == nil then
    target = false
  end
  return M.align_tag_block(left, tags, { tags_column = target })
end

local function normalize_headlines(lines, cfg)
  local hcfg = cfg.headline or {}
  if hcfg.normalize_whitespace == false and hcfg.tags_column == nil then
    return lines
  end
  local opts = {
    normalize_whitespace = hcfg.normalize_whitespace ~= false,
    tags_column = hcfg.tags_column,
  }
  local out = {}
  for i, line in ipairs(lines) do
    if is_headline(line) then
      out[i] = normalize_headline(line, opts)
    else
      out[i] = line
    end
  end
  return out
end

local function dwidth(s)
  if s:find("[\128-\255\t]") then
    return vim.fn.strdisplaywidth(s)
  end
  return #s
end

-- Codepoints Emacs gives character category `|` ("may start or end a
-- line"), so a run of them is breakable between characters.  Hangul and
-- emoji are deliberately absent -- Emacs leaves those unbroken.
local CJK_BREAK_RANGES = {
  { 0x2E80, 0x312F },
  { 0x3190, 0x9FFF },
  { 0xF900, 0xFAFF },
  { 0xFF01, 0xFF9F },
  { 0x20000, 0x3FFFF },
}

-- Characters Emacs `kinsoku.el` gives category `>` (may not begin a
-- line) and `<` (may not end one), verbatim from its category table.
local KINSOKU_BOL = "!'),-.:;?]_}~¨¯°±´·×÷ˇˉˍ༈་།༎༏༐༑༒༔༴༽ཿ‐–—―‖’”‥…‧′″"
  .. "‾℃℉∶╴、。〃々〆〇〉》」』】〕〗〜〞ぁぃぅぇぉっゃゅょゎ゛゜ゝゞァィゥェォッャュョヮヵヶ・ー"
  .. "ヽヾㄥ仝︰︱︳︴︶︸︺︼︾﹀﹂﹄﹉﹊﹋﹌﹍﹎﹏﹐﹑﹒﹔﹕﹖﹗﹚﹜﹞﹩！＂），．／：；？＼］＾＿｀"
  .. "｜｝～｡｣ｧｨｩｪｫｬｭｮｯｰﾞﾟ￣"
local KINSOKU_EOL = "([`{§°ༀ༁༂༃༄༅༆༇༈༉༊༼྅࿁࿂‘“′″‵℃℉〃〈《「『【〔〖〝ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏ"
  .. "ㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄨ︵︷︹︻︽︿﹁﹃﹙﹛﹝﹫＂（＠［｛｢"
local kinsoku_bol, kinsoku_eol = {}, {}
for _, ch in ipairs(vim.fn.split(KINSOKU_BOL, "\\zs")) do
  kinsoku_bol[ch] = true
end
for _, ch in ipairs(vim.fn.split(KINSOKU_EOL, "\\zs")) do
  kinsoku_eol[ch] = true
end

-- Codepoints Emacs registers in `fill-find-break-point-function-table`,
-- i.e. those whose neighbourhood gets kinsoku treatment.
local KINSOKU_RANGES = {
  { 0x02EA, 0x02EB },
  { 0x2E80, 0x2FDF },
  { 0x3000, 0x312F },
  { 0x31A0, 0x9FFF },
  { 0xF900, 0xFAFF },
  { 0xFE30, 0xFE4F },
  { 0xFF00, 0xFFEF },
  { 0x20000, 0x3FFFF },
}

local function in_ranges(ranges, ch)
  local cp = vim.fn.char2nr(ch)
  for _, r in ipairs(ranges) do
    if cp >= r[1] and cp <= r[2] then
      return true
    end
  end
  return false
end

local function is_break_char(ch)
  return in_ranges(CJK_BREAK_RANGES, ch)
end

local function has_kinsoku_fn(ch)
  return in_ranges(KINSOKU_RANGES, ch)
end

local function push_units(units, word, sep, offset)
  if not word:find("[\226-\244]") then
    units[#units + 1] = { s = word, sep = sep, pos = offset }
    return
  end
  local pending, pending_pos = "", offset
  local pos = offset
  local first = true
  local function emit(s, p, cjk)
    units[#units + 1] = { s = s, sep = first and sep or "", pos = p, cjk = cjk }
    first = false
  end
  for _, ch in ipairs(vim.fn.split(word, "\\zs")) do
    if is_break_char(ch) then
      if pending ~= "" then
        emit(pending, pending_pos)
        pending = ""
      end
      emit(ch, pos, true)
    else
      if pending == "" then
        pending_pos = pos
      end
      pending = pending .. ch
    end
    pos = pos + #ch
  end
  if pending ~= "" then
    emit(pending, pending_pos)
  end
end

local function head_char(u)
  if u.head == nil then
    u.head = (u.s:find("[\128-\255]") and vim.fn.strcharpart(u.s, 0, 1)) or u.s:sub(1, 1)
  end
  return u.head
end

local function tail_char(u)
  if u.tailc == nil then
    if u.s:find("[\128-\255]") then
      u.tailc = vim.fn.strcharpart(u.s, vim.fn.strchars(u.s) - 1, 1)
    else
      u.tailc = u.s:sub(-1)
    end
  end
  return u.tailc
end

local function break_units(text)
  local units = {}
  local i, n = 1, #text
  while i <= n do
    local sep = ""
    local ws_e = select(2, text:find("^%s+", i))
    if ws_e then
      sep = text:sub(i, ws_e)
      i = ws_e + 1
    end
    if i > n then
      break
    end
    local next_ws = text:find("%s", i)
    local word_end = (next_ws and next_ws - 1) or n
    push_units(units, text:sub(i, word_end), sep, i)
    i = word_end + 1
  end
  return units
end

-- Byte spans of org timestamps; a break inside one destroys it.
local function timestamp_spans(text)
  local spans = {}
  for _, pat in ipairs({ "<%d%d%d%d%-%d%d%-%d%d[^<>\n]*>", "%[%d%d%d%d%-%d%d%-%d%d[^%[%]\n]*%]" }) do
    local init = 1
    while true do
      local s, e = text:find(pat, init)
      if not s then
        break
      end
      spans[#spans + 1] = { s, e }
      init = e + 1
    end
  end
  return spans
end

-- Mirrors the alternatives of org's `paragraph-start` that can match
-- mid-paragraph, which is what Emacs's `fill-nobreak-p` consults: a
-- break whose next line would match starts a new element, so wrapping
-- would silently turn prose into a headline, list item or keyword.
-- `is_last` reports whether the regexp's `$` anchor would hold.
local function starts_element(word, is_last)
  if word:match("^%*+$") and not is_last then
    return true
  end
  if word:match("^[-+*]$") or word:match("^%d+[.)]$") then
    return true
  end
  if word:match("^|") or word == ":" or word == "#" then
    return true
  end
  if word:match("^#%+") and #word > 2 then
    if word:match("^#%+[bB][eE][gG][iI][nN]_.") or word:find(":", 3, true) then
      return true
    end
  end
  if word:match("^\\begin{[%w*]+}") or word:match("^%[fn:[%w_-]+%]") or word:match("^%%%%%(") then
    return true
  end
  if is_last then
    if word:match("^:[%w_-]+:$") or word:match("^%-%-%-%-%-+$") then
      return true
    end
    if word:match("^%+%-") and word:match("^[-+]+$") and word:sub(-1) == "+" then
      return true
    end
  end
  return false
end

local function wrap_to_width(text, width, first_indent, cont_indent)
  if width <= 0 then
    return { first_indent .. text }
  end
  local units = break_units(text)
  local n = #units
  if n == 0 then
    return {}
  end
  local spans = timestamp_spans(text)
  local tail, tail_last, suffix = {}, {}, {}
  for u = n, 1, -1 do
    units[u].w = dwidth(units[u].s)
    if u == n then
      tail[u], tail_last[u] = units[u].s, true
      suffix[u] = units[u].w
    else
      suffix[u] = units[u].w + #units[u + 1].sep + suffix[u + 1]
      if units[u + 1].sep == "" then
        tail[u], tail_last[u] = units[u].s .. tail[u + 1], tail_last[u + 1]
      else
        tail[u], tail_last[u] = units[u].s, false
      end
    end
  end
  -- Emacs looks for a break at the fill column and stops when that
  -- position is already the end of the text, so a final wide character
  -- straddling the column is left in place rather than pushed down.
  local last_char_w = dwidth(tail_char(units[n]))

  -- `at_word_end` mirrors Emacs's last-resort scan, which tests the
  -- position before the separating space rather than after it.
  local function may_break(b, at_word_end)
    if b >= n then
      return false
    end
    local pos = at_word_end and (units[b].pos + #units[b].s) or units[b + 1].pos
    for _, sp in ipairs(spans) do
      if pos > sp[1] and pos <= sp[2] + 1 then
        return false
      end
    end
    -- A `.` left at end of line reads as a sentence end on the next
    -- fill; a single following space says it is not one.
    if units[b + 1].sep == " " and units[b].s:sub(-1) == "." then
      return false
    end
    return not starts_element(tail[b + 1], tail_last[b + 1])
  end

  local function bol_blocked(b)
    return kinsoku_bol[head_char(units[b + 1])] ~= nil
  end
  local function eol_blocked(b)
    return kinsoku_eol[tail_char(units[b])] ~= nil
  end
  -- Emacs consults kinsoku only when a character adjacent to the break
  -- carries a break-point function, and never between two ASCII ones.
  local function kinsoku_applies(b)
    local prev = units[b + 1].sep ~= "" and " " or tail_char(units[b])
    local next_ch = head_char(units[b + 1])
    if #prev == 1 and #next_ch == 1 then
      return false
    end
    return has_kinsoku_fn(prev) or has_kinsoku_fn(next_ch)
  end
  -- Emacs scans past positions whose preceding character is neither a
  -- space nor itself breakable: those are not break points at all.
  local function kinsoku_stop(b)
    return not bol_blocked(b) and (units[b + 1].sep ~= "" or units[b].cjk)
  end

  local out = {}
  local i = 1
  local indent = first_indent
  while i <= n do
    local iw = dwidth(indent)
    local w = iw + units[i].w
    local last = i
    while last < n and w + #units[last + 1].sep + units[last + 1].w <= width do
      w = w + #units[last + 1].sep + units[last + 1].w
      last = last + 1
    end
    local b = last
    if iw + suffix[i] - last_char_w < width then
      b = n
    end
    if b < n then
      while b > i and not may_break(b) do
        b = b - 1
      end
      if not may_break(b) then
        while b < n and not may_break(b, true) do
          b = b + 1
        end
      elseif kinsoku_applies(b) then
        -- Kinsoku: run the line long rather than start the next one with
        -- a character that may not begin a line; if that overshoots by
        -- more than Emacs `kinsoku-limit`, pull the break back instead.
        local k, kw, shorter = b, iw + units[i].w, false
        for u = i + 1, b do
          kw = kw + #units[u].sep + units[u].w
        end
        if bol_blocked(k) then
          local j, jw = k, kw
          repeat
            jw = jw + #units[j + 1].sep + units[j + 1].w
            j = j + 1
          until j >= n or kinsoku_stop(j)
          if jw < width + 4 then
            k = j
          else
            shorter = true
          end
        end
        if k < n and (shorter or eol_blocked(k)) then
          local j = k - 1
          while j >= i and (eol_blocked(j) or not kinsoku_stop(j)) do
            j = j - 1
          end
          if j >= i then
            k = j
          end
        end
        if k >= n or may_break(k) then
          b = k
        end
      end
    end
    local parts = {}
    for u = i, b do
      parts[#parts + 1] = units[u].sep
      parts[#parts + 1] = units[u].s
    end
    parts[1] = ""
    out[#out + 1] = indent .. table.concat(parts)
    i = b + 1
    indent = cont_indent
  end
  return out
end

local function wrap_prose(lines, cfg, tail)
  if (cfg.wrap or {}).enabled == false then
    return lines
  end
  local width = cfg._effective_width
  if not width then
    return lines
  end
  local out = {}
  local block_end = nil
  local in_drawer = false
  local para_lines, para_first, para_cont, para_kind = {}, nil, nil, nil
  local para_bullet_col = nil

  local function flush()
    if #para_lines == 0 then
      return
    end
    para_kind = nil
    para_bullet_col = nil
    -- Org's hard-line-break syntax (verified against Emacs `org-mode`
    -- + `fill-paragraph`, GNU Emacs 30.2) is `\\` at end of line, with
    -- optional trailing whitespace.  Lines NOT ending in `\\` are
    -- reflowed into the surrounding paragraph; lines ending in `\\`
    -- terminate the current sub-paragraph and the next line starts a
    -- new one.  Trailing spaces alone (markdown convention) have no
    -- meaning in org.
    local chunks = { {} }
    for _, l in ipairs(para_lines) do
      table.insert(chunks[#chunks], l)
      if l:match("\\\\%s*$") then
        table.insert(chunks, {})
      end
    end
    if #chunks[#chunks] == 0 then
      table.remove(chunks)
    end
    local first = para_first or ""
    local cont = para_cont or ""
    for _, chunk in ipairs(chunks) do
      -- Collapse runs of whitespace, but keep the two spaces Emacs
      -- writes after a sentence end under `sentence-end-double-space`,
      -- so reformatting an Emacs-authored file is a no-op.
      local src = table.concat(chunk, " "):gsub("^%s+", ""):gsub("%s+$", "")
      local joined = src:gsub("()%s+", function(pos)
        if
          src:sub(pos, pos + 1):match("^%s%s") and src:sub(1, pos - 1):match("[.?!][\"'%]%)}]*$")
        then
          return "  "
        end
        return " "
      end)
      if joined == "" then
        out[#out + 1] = (first:gsub("%s+$", ""))
      end
      for _, l in ipairs(wrap_to_width(joined, width, first, cont)) do
        out[#out + 1] = l
      end
      -- After a forced break, the next chunk is still part of the same
      -- paragraph (or list item) -- use cont_indent for its first line
      -- so list-item continuations stay aligned with the post-bullet
      -- column.  For plain paragraphs first == cont, so this is a no-op.
      first = cont
    end
    para_lines, para_first, para_cont = {}, nil, nil
  end

  -- A `:NAME:` line only opens a drawer when a `:END:` closes it before
  -- the next headline; without that org reads it as ordinary text, and
  -- treating it as a drawer would suppress wrapping to end of buffer.
  local function drawer_closed(i)
    for j = i + 1, #lines + #(tail or {}) do
      local l = j <= #lines and lines[j] or tail[j - #lines]
      if is_drawer_close(l) then
        return true
      end
      if is_headline(l) then
        return false
      end
    end
    return false
  end

  for idx, line in ipairs(lines) do
    -- Only a verbatim body is protected from filling.  A quote or center
    -- block holds ordinary paragraphs, and Emacs fills them.
    local open = block.open_name(line)
    local closes_at = open and block.VERBATIM[open] and block.close_row(lines, idx, tail)
    if block_end then
      flush()
      out[#out + 1] = line
      if idx >= block_end then
        block_end = nil
      end
    elseif in_drawer then
      flush()
      out[#out + 1] = line
      if is_drawer_close(line) then
        in_drawer = false
      end
    elseif closes_at then
      flush()
      out[#out + 1] = line
      block_end = closes_at
    elseif is_drawer_open(line) and not is_drawer_close(line) and drawer_closed(idx) then
      flush()
      out[#out + 1] = line
      in_drawer = true
    elseif
      is_headline(line)
      or is_planning(line)
      or is_directive(line)
      or is_table(line)
      or is_fixed_width(line)
      or is_hrule(line)
      or is_drawer_open(line)
      or line == ""
    then
      flush()
      out[#out + 1] = line
    elseif is_comment(line) then
      -- Emacs `org-fill-element` fills a comment under its `# ` prefix;
      -- a bare `#` line splits comment paragraphs.
      local indent, gap, body = line:match("^(%s*)#(%s*)(.*)$")
      if body == "" then
        flush()
        out[#out + 1] = line
      else
        if para_kind ~= "comment" then
          flush()
          para_kind = "comment"
          para_first = indent .. "#" .. (gap ~= "" and gap or " ")
          para_cont = para_first
        end
        para_lines[#para_lines + 1] = body
      end
    elseif is_list(line) then
      flush()
      local item = list.parse_item(line)
      para_kind = "list"
      para_bullet_col = dwidth(item.indent)
      para_first = item.indent .. item.bullet .. " "
      para_cont = string.rep(" ", #para_first)
      para_lines[#para_lines + 1] = item.content
    else
      -- Org ends a list item at a line indented no further than the
      -- bullet; folding such a line into the item would merge two
      -- elements into one.
      if
        para_kind == "comment"
        or (para_kind == "list" and dwidth(leading_indent(line)) <= para_bullet_col)
      then
        flush()
      end
      if not para_first then
        local indent = leading_indent(line)
        para_kind = "text"
        para_first = indent
        para_cont = indent
      end
      para_lines[#para_lines + 1] = line:gsub("^%s+", "")
    end
  end
  flush()
  return out
end

local function adapt_indentation(lines, mode, planning_indent_cfg)
  if not mode or mode == false then
    return lines
  end
  local section = require("organ.section")
  local indent_all = mode == true
  local out = {}
  local current_level = 0
  local in_block = false
  local in_drawer = false
  for _, line in ipairs(lines) do
    local stars = line:match("^(%*+)%s")
    if stars then
      current_level = #stars
      in_drawer = false
      out[#out + 1] = line
    elseif current_level == 0 then
      out[#out + 1] = line
    elseif is_block_open(line) then
      out[#out + 1] = line
      in_block = true
    elseif is_block_close(line) then
      out[#out + 1] = line
      in_block = false
    elseif in_block then
      out[#out + 1] = line
    elseif line == "" then
      out[#out + 1] = line
    else
      local pad = section.section_indent_for(current_level, planning_indent_cfg)
      local stripped = line:gsub("^%s*", "")
      local was_in_drawer = in_drawer
      -- Flip drawer state BEFORE the indent decision so the `:END:` line
      -- is still treated as part of the drawer.  Order matters: `:END:`
      -- ALSO matches the looser drawer-open regex (it's a `:NAME:` with
      -- NAME = "END"), so testing open first would re-set in_drawer.
      if is_drawer_close(line) then
        in_drawer = false
      elseif is_drawer_open(line) then
        in_drawer = true
      end
      local should_indent = indent_all
      if not should_indent then
        if is_planning(line) or is_drawer_open(line) or is_drawer_close(line) or was_in_drawer then
          should_indent = true
        end
      end
      if should_indent then
        out[#out + 1] = pad .. stripped
      else
        out[#out + 1] = line
      end
    end
  end
  return out
end
M._apply_adapt_indentation = adapt_indentation

-- Pad `:KEY:` so values inside a property drawer line up past the
-- longest key.  Lines that don't match `:KEY: value` (LOGBOOK notes
-- etc.) are left alone.
-- Re-align `:KEY: value` property lines inside each drawer to Emacs
-- `org-property-format` ("%-10s %s"), applied per line via the shared
-- property writer -- the SAME function that roam headers, :ID: insertion,
-- and org-set-property use.  Sharing the writer is what makes inserted
-- property drawers a formatter fixpoint (saving a fresh roam file must not
-- shuffle the `:ID:` column).  Emacs formats each line independently; it
-- does NOT align every value to the widest key in the drawer, so neither
-- do we.  `drawers.align_values = false` skips the pass entirely; bare
-- keys (empty value) and non-property lines (LOGBOOK clocks, ...) pass
-- through untouched.
local function align_drawer_values(lines, cfg)
  local dcfg = cfg.drawers or {}
  if dcfg.align_values == false then
    return lines
  end
  local property = require("organ.property")
  local verbatim = block.verbatim_rows(lines)
  local out = {}
  local i, n = 1, #lines
  while i <= n do
    local line = lines[i]
    if verbatim[i] or not is_drawer_open(line) or is_drawer_close(line) then
      out[#out + 1] = line
      i = i + 1
    else
      local body_start = i + 1
      local body_end
      for j = body_start, n do
        if is_drawer_close(lines[j]) then
          body_end = j
          break
        end
      end
      if not body_end then
        out[#out + 1] = line
        i = i + 1
      else
        out[#out + 1] = line
        for j = body_start, body_end - 1 do
          local body_line = lines[j]
          local indent, key, val = body_line:match("^(%s*)(:[%w_-]+:)%s+(.*)$")
          if indent and key and val and val ~= "" then
            out[#out + 1] = indent .. property.format_line(key:sub(2, -2), val)
          else
            out[#out + 1] = body_line
          end
        end
        out[#out + 1] = lines[body_end]
        i = body_end + 1
      end
    end
  end
  return out
end

-- Enforce blank-line policy: `before_headline` / `before_block`
-- (insert / collapse to N blanks before each), and `collapse_runs`
-- (cap runs of consecutive blanks to N).
local function apply_blanks(lines, cfg)
  cfg = cfg or {}
  local before_h = cfg.before_headline
  local before_b = cfg.before_block
  local collapse = cfg.collapse_runs or 0

  local function enforce_n_before(out, n)
    while #out > 0 and out[#out] == "" do
      out[#out] = nil
    end
    if #out == 0 then
      return
    end
    for _ = 1, n do
      out[#out + 1] = ""
    end
  end

  local out = {}
  local blank_run = 0
  for _, line in ipairs(lines) do
    if line == "" then
      blank_run = blank_run + 1
      if not (collapse > 0 and blank_run > collapse) then
        out[#out + 1] = ""
      end
    else
      blank_run = 0
      if is_headline(line) and type(before_h) == "number" then
        enforce_n_before(out, before_h)
      elseif is_block_open(line) and type(before_b) == "number" then
        enforce_n_before(out, before_b)
      end
      out[#out + 1] = line
    end
  end
  return out
end

local function trim_eof(lines, cfg)
  cfg = cfg or {}
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = l
  end
  if cfg.trim_trailing ~= false then
    while #out > 0 and out[#out] == "" do
      out[#out] = nil
    end
  end
  return out
end

-- Realign every pipe-table that intersects [lo, hi].  When lo/hi are
-- nil the whole buffer is walked.  Realign goes through tablature
-- (organ.table.realign -> tablature.realign) so the output matches
-- exactly what pressing Tab in a table cell produces -- consistency
-- across `:Org format`, `:Org format <range>`, `gq`/formatexpr and
-- format-on-save is the contract.
local function realign_tables(bufnr, lo, hi)
  local ok, table_mod = pcall(require, "organ.table")
  if not ok or not table_mod or not table_mod.realign then
    return
  end
  lo = lo or 1
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local verbatim = block.verbatim_rows(lines)
  local i, n = 1, #lines
  while i <= n do
    if not verbatim[i] and lines[i]:match("^%s*|") then
      local table_start = i
      while i <= n and not verbatim[i] and lines[i]:match("^%s*|") do
        i = i + 1
      end
      local table_end = i - 1
      local within = table_end >= lo and (not hi or table_start <= hi)
      if within then
        pcall(table_mod.realign, bufnr, table_start)
      end
    else
      i = i + 1
    end
  end
end

local function normalize_section(bufnr)
  local ok, section = pcall(require, "organ.section")
  if not ok then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local rows = {}
  for i, l in ipairs(lines) do
    if is_headline(l) then
      rows[#rows + 1] = i - 1
    end
  end
  for i = #rows, 1, -1 do
    pcall(section.canonicalize, bufnr, rows[i])
  end
end

local function repair_lists(bufnr)
  local ok, list_mod = pcall(require, "organ.list")
  if not ok or not list_mod or not list_mod.repair then
    return
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, total, false)
  local verbatim = block.verbatim_rows(lines)
  local skip_to = 0
  for i, l in ipairs(lines) do
    if i > skip_to and not verbatim[i] and l:match("^%s*%d+[%.%)]%s") then
      -- repair normalizes the whole structure and reports its range;
      -- everything up to `e` is already canonical.  An unattended sweep
      -- keeps each run's own first number, so prose opening with a year
      -- or a page number is renumbered from itself, i.e. not at all.
      local ok, _, _, e = pcall(list_mod.repair, bufnr, i, { preserve_start = true })
      if ok and e then
        skip_to = e
      end
    end
  end
end

function M.format_lines(lines, cfg, bufnr, opts)
  cfg = cfg or format_cfg(bufnr)
  cfg._effective_width = effective_width(bufnr, cfg, opts and opts.default_width)

  if cfg.trim_trailing_whitespace ~= false then
    lines = trim_trailing_whitespace(lines)
  end
  lines = normalize_headlines(lines, cfg)
  if opts and opts.force_wrap and (cfg.wrap or {}).enabled == false then
    cfg = vim.tbl_deep_extend("force", cfg, { wrap = { enabled = true } })
  end
  lines = wrap_prose(lines, cfg, opts and opts.tail)
  do
    local icfg = require("organ.buf_config").read(bufnr, "indent") or {}
    if icfg.adapt_indentation then
      local pi = (require("organ.buf_config").read(bufnr, "todo") or {}).planning_indent
      lines = adapt_indentation(lines, icfg.adapt_indentation, pi)
    end
  end
  lines = align_drawer_values(lines, cfg)
  lines = apply_blanks(lines, cfg.blanks or {})
  lines = trim_eof(lines, cfg.blanks or {})
  return lines
end

function M.format_range(bufnr, lo, hi, opts)
  bufnr = bufnr or 0
  local total = vim.api.nvim_buf_line_count(bufnr)
  if lo < 1 then
    lo = 1
  end
  if hi > total then
    hi = total
  end
  if hi < lo then
    return
  end
  local cfg = format_cfg(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, lo - 1, hi, false)
  -- A drawer opened inside the range may be closed past its end.
  local range_opts = { tail = vim.api.nvim_buf_get_lines(bufnr, hi, total, false) }
  for k, v in pairs(opts or {}) do
    range_opts[k] = v
  end
  local out = M.format_lines(lines, cfg, bufnr, range_opts)
  obuf.set_lines(bufnr, lo - 1, hi, out)
  if (cfg.tables or {}).realign ~= false then
    realign_tables(bufnr, lo, hi)
  end
end

function M.format_buffer(bufnr)
  bufnr = bufnr or 0
  local cfg = format_cfg(bufnr)
  M.format_range(bufnr, 1, vim.api.nvim_buf_line_count(bufnr))
  if (cfg.section or {}).normalize ~= false then
    normalize_section(bufnr)
  end
  if (cfg.lists or {}).repair_numbering ~= false then
    repair_lists(bufnr)
  end
  if (cfg.blanks or {}).ensure_final_newline ~= false then
    -- Neovim writes the newline after the last line itself; trailing
    -- empty lines would each add another.
    local total = vim.api.nvim_buf_line_count(bufnr)
    local last = total
    while last > 1 and (vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or "") == "" do
      last = last - 1
    end
    if last < total then
      obuf.set_lines(bufnr, last, total, {})
    end
  end
end

function M.formatexpr()
  local lnum = vim.fn.eval("v:lnum")
  local count = vim.fn.eval("v:count")
  if not lnum or not count or count < 1 then
    return 1
  end
  local bufnr = vim.api.nvim_get_current_buf()
  -- `gq` is the explicit reflow request, so it fills whatever
  -- `format.wrap.enabled` says about unattended whole-buffer passes.
  local ok =
    pcall(M.format_range, bufnr, lnum, lnum + count - 1, { default_width = 80, force_wrap = true })
  if ok then
    return 0
  end
  return 1
end

M.commands = {
  format = {
    fn = function(cmd)
      local bufnr = vim.api.nvim_get_current_buf()
      if cmd and cmd.range and cmd.range > 0 then
        M.format_range(bufnr, cmd.line1, cmd.line2)
      else
        M.format_buffer(bufnr)
      end
    end,
    range = true,
    desc = "Format the buffer (or `:'<,'> Org format` for a range)",
  },
}

return M
