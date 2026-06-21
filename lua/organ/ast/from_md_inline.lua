-- Second-phase inline parser: re-parses a block's flat text into inline AST
-- nodes.  Runs after the block parse completes (so link reference definitions
-- are fully collected).  A position-advancing scanner: literal characters
-- accumulate into a buffer that flushes to an ast.text node whenever a special
-- construct is recognised.  This file currently handles backslash escapes,
-- code spans, and hard/soft line breaks; autolinks, raw HTML are added
-- incrementally.
local ast = require("organ.ast")

local M = {}

local ASCII_PUNCT = {}
for ch in ("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"):gmatch(".") do
  ASCII_PUNCT[ch] = true
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

function M.parse(text, _refmap)
  text = text or ""
  local nodes = {}
  local buf = {}
  local function flush()
    if #buf > 0 then
      nodes[#nodes + 1] = ast.text(table.concat(buf))
      buf = {}
    end
  end
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)

    -- Backtick: open a code span or emit literal backticks.
    if c == "`" then
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

    -- Newline: hard break (2+ trailing spaces or preceding backslash) or soft break.
    elseif c == "\n" then
      -- Check what precedes the newline in the current buffer.
      local buf_str = table.concat(buf)
      local trailing_spaces = #(buf_str:match(" *$") or "")
      local ends_backslash = buf_str:sub(-1) == "\\"

      if trailing_spaces >= 2 then
        -- Hard break: strip trailing spaces, flush, emit linebreak.
        buf = { buf_str:sub(1, #buf_str - trailing_spaces) }
        flush()
        nodes[#nodes + 1] = ast.linebreak()
      elseif ends_backslash then
        -- Hard break: strip trailing backslash, flush, emit linebreak.
        buf = { buf_str:sub(1, #buf_str - 1) }
        flush()
        nodes[#nodes + 1] = ast.linebreak()
      else
        -- Soft break: strip any trailing spaces (CommonMark strips trailing
        -- spaces before a soft break), flush current buf, emit "\n" text.
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
      -- A backslash before a newline is a hard break (handled above since \n
      -- branch checks for trailing backslash).  All other ASCII-punct escapes.
      buf[#buf + 1] = text:sub(i + 1, i + 1)
      i = i + 2
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  flush()
  return nodes
end

return M
