-- The org and elisp syntax tables (D9 data) and `scan-sexps' forward by
-- one expression, a port of syntax.c's scan_lists with
-- parse-sexp-ignore-comments, parse-sexp-lookup-properties and
-- multibyte-syntax-as-symbol nil, their values in an org-mode buffer and
-- in the capture template buffer.

local R = require("organ.elisp.run")
local V = require("organ.elisp.value")

local M = {}

local TABLES = {
  org = require("organ.elisp.data.syntax_org"),
  elisp = require("organ.elisp.data.syntax_elisp"),
}

local S_WORD, S_SYMBOL, S_OPEN, S_CLOSE, S_QUOTE, S_STRING, S_MATH = 2, 3, 4, 5, 6, 7, 8
local S_ESCAPE, S_CHARQUOTE, S_STRING_FENCE = 9, 10, 15

--- Raw syntax descriptor (class plus flags) and matching character (or
--- -1) of code point `cp` in table `name` ("org" or "elisp").
function M.lookup(name, cp)
  local t = TABLES[name]
  local lo, hi = 1, #t / 3
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if t[3 * mid - 2] <= cp then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return t[3 * lo - 1], t[3 * lo]
end

function M.has_table(name)
  return TABLES[name] ~= nil
end

local function class_of(syn)
  return syn % 256
end

local function flag(syn, bit_index)
  return math.floor(syn / 2 ^ bit_index) % 2 == 1
end

local Q_SCAN_ERROR = V.intern("scan-error")

local function scan_error(msg, last_good, from)
  R.signal(Q_SCAN_ERROR, V.list({ V.str(msg), last_good, from }))
end

--- The end of the expression at byte `pos` of `src` under syntax table
--- `name`: the byte after it, or nil when only whitespace and
--- punctuation remain.  Scan errors carry Emacs's data: character
--- positions in a buffer holding exactly `src`.
function M.scan_sexp(run, src, pos, name)
  if not TABLES[name] then
    R.refuse("syntax", tostring(name))
  end
  run:check_string(#src)
  local chars, starts = {}, {}
  local i, n = 1, 0
  local from
  while i <= #src do
    local cp, j = V.utf8_next(src, i)
    if not cp then
      R.refuse("charset", "byte " .. i)
    end
    n = n + 1
    chars[n], starts[n] = cp, i
    if not from and i >= pos then
      from = n
    end
    i = j
  end
  run:step(1 + math.floor(#src / 64))
  starts[n + 1] = #src + 1
  from = from or n + 1
  local stop = n + 1
  local syn = {}
  local function syntax(c)
    local s = syn[c]
    if not s then
      s = M.lookup(name, c)
      syn[c] = s
    end
    return s
  end
  local depth, min_depth = 0, 0
  local last_good = from
  local mathexit = false
  while from < stop do
    run:step(1)
    local c = chars[from]
    local s = syntax(c)
    local code = class_of(s)
    if depth == min_depth then
      last_good = from
    end
    from = from + 1
    -- scan_lists reads the next character when C may start a two-character
    -- comment, even with comments not ignored.
    if from < stop and flag(s, 16) then
      c = chars[from]
    end
    if not flag(s, 20) then
      local word = false
      if code == S_ESCAPE or code == S_CHARQUOTE then
        if from == stop then
          scan_error("Unbalanced parentheses", last_good, from)
        end
        from = from + 1
        word = true
      elseif code == S_WORD or code == S_SYMBOL then
        word = true
      end
      if word then
        if depth == 0 then
          while from < stop do
            run:step(1)
            local cc = class_of(syntax(chars[from]))
            if cc == S_CHARQUOTE or cc == S_ESCAPE then
              from = from + 1
              if from == stop then
                scan_error("Unbalanced parentheses", last_good, from)
              end
            elseif not (cc == S_WORD or cc == S_SYMBOL or cc == S_QUOTE) then
              break
            end
            from = from + 1
          end
          return starts[from]
        end
      elseif code == S_MATH or code == S_OPEN or code == S_CLOSE then
        local close = code == S_CLOSE
        if code == S_MATH then
          if from ~= stop and c == chars[from] then
            from = from + 1
          end
          if mathexit then
            mathexit = false
            close = true
          else
            mathexit = true
          end
        end
        if close then
          depth = depth - 1
          if depth == 0 then
            return starts[from]
          end
          if depth < min_depth then
            scan_error("Containing expression ends prematurely", last_good, from)
          end
        else
          depth = depth + 1
          if depth == 0 then
            return starts[from]
          end
        end
      elseif code == S_STRING or code == S_STRING_FENCE then
        local term = chars[from - 1]
        while true do
          if from >= stop then
            scan_error("Unbalanced parentheses", last_good, from)
          end
          run:step(1)
          local cc = chars[from]
          local ccode = class_of(syntax(cc))
          if code == S_STRING and (cc == term and ccode == S_STRING) then
            break
          elseif code == S_STRING_FENCE and ccode == S_STRING_FENCE then
            break
          end
          if ccode == S_CHARQUOTE or ccode == S_ESCAPE then
            from = from + 1
          end
          from = from + 1
        end
        from = from + 1
        if depth == 0 then
          return starts[from]
        end
      end
    end
  end
  if depth ~= 0 then
    scan_error("Unbalanced parentheses", last_good, from)
  end
  return nil
end

return M
