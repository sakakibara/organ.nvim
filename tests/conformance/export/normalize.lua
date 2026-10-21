-- Normalization for the export gate (rules and reasons: NORMALIZE.md).
--
-- 1. iCalendar: CRLF line ends read as plain lines on both sides; a line
--    ended by a bare LF keeps a visible " <bare-LF>" mark.
-- 2. iCalendar: Emacs's random UIDs (UUIDs, and the all-digit UID of a
--    diary entry) are renamed by entry, in order of first appearance, to
--    "<uuid-N>"; every use of one UID gets the same name.
-- 3. icalendar-combine: folded lines are unfolded on both sides and the
--    case's absolute path reads as "<case>".
-- 4. Texinfo: a run of blank lines becomes one blank line; the `@c`
--    comment after `\input texinfo` is dropped; inside @itemize and
--    @enumerate a bare `@item` line joins the line after it.
-- 5. Markdown: trailing blank lines are dropped; a quote line `> `
--    reads as `>`; character references other than the five markup
--    characters read as the characters they name.
-- 6. Bytes that are not valid UTF-8 read as "<0xHH>" on both sides.
-- 7. ASCII: tabs expand to spaces at 8-column stops on both sides.

local function backend(case)
  local area = vim.fn.getcwd() .. "/tests/conformance/export/cases/"
  local first = vim.fn.readfile(area .. case, "", 1)[1] or ""
  return first:match("^# conformance: ([%l-]+) ") or ""
end

-- Texinfo block environments, for the @item rule.
local ENVS = {
  "itemize",
  "enumerate",
  "table",
  "vtable",
  "ftable",
  "multitable",
  "example",
  "lisp",
  "display",
  "quotation",
  "verbatim",
  "float",
  "menu",
  "detailmenu",
  "titlepage",
  "ifnottex",
  "copying",
  "direntry",
  "defun",
  "cartouche",
  "smallexample",
}

local function line_ends(text)
  local out = {}
  local parts = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(parts) do
    if i == #parts then
      out[#out + 1] = line
    elseif line:sub(-1) == "\r" then
      out[#out + 1] = line:sub(1, -2)
    else
      out[#out + 1] = line .. " <bare-LF>"
    end
  end
  return table.concat(out, "\n")
end

local UUID = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

local function uuids(text)
  local names, n = {}, 0
  local function name(id)
    if not names[id] then
      n = n + 1
      names[id] = "<uuid-" .. n .. ">"
    end
    return names[id]
  end
  local out = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local digits = line:match("^UID:(%d+)$")
    if digits then
      line = "UID:" .. name(digits)
    else
      line = line:gsub(UUID, name)
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

local function unfold(text, case)
  local path = vim.fn.getcwd() .. "/tests/conformance/export/cases/" .. case
  text = text:gsub("\n ", "")
  return (text:gsub(vim.pesc(path), "<case>"))
end

-- Texinfo environments whose blank lines print as they are.
local TEXINFO_VERBATIM = {
  example = true,
  smallexample = true,
  lisp = true,
  smalllisp = true,
  display = true,
  smalldisplay = true,
  format = true,
  smallformat = true,
  verbatim = true,
}

-- A run of blank lines becomes one, except inside a verbatim environment.
local function squeeze_texinfo(text)
  local out, blank, verbatim = {}, false, nil
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local env = line:match("^@(%a+)%s*$")
    if not verbatim and env and TEXINFO_VERBATIM[env] then
      verbatim = env
    elseif verbatim and line:match("^@end " .. verbatim .. "%s*$") then
      verbatim = nil
    end
    if line ~= "" or verbatim or not blank then
      out[#out + 1] = line
    end
    blank = line == "" and not verbatim
  end
  return table.concat(out, "\n")
end

local function texinfo(text)
  text = squeeze_texinfo(text):gsub("^\\input texinfo%s+@c [^\n]*", "\\input texinfo")
  local lines = vim.split(text, "\n", { plain = true })
  local out, stack = {}, {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local env = line:match("^@(%a+)")
    local closing = line:match("^@end (%a+)")
    if closing and vim.tbl_contains(ENVS, closing) then
      stack[#stack] = nil
    elseif env and vim.tbl_contains(ENVS, env) then
      stack[#stack + 1] = env
    end
    local top = stack[#stack]
    local nxt = lines[i + 1]
    if
      line == "@item"
      and (top == "itemize" or top == "enumerate")
      and nxt
      and nxt ~= ""
      and not vim.tbl_contains(ENVS, nxt:match("^@end (%a+)") or nxt:match("^@(%a+)") or "")
    then
      out[#out + 1] = "@item " .. nxt
      i = i + 2
    else
      out[#out + 1] = line
      i = i + 1
    end
  end
  return table.concat(out, "\n")
end

local MARKUP = { amp = true, lt = true, gt = true, quot = true, apos = true }
local MARKUP_CODES = { [38] = true, [60] = true, [62] = true, [34] = true, [39] = true }

local function decode_references(text)
  local named = require("organ.ast.html5_entities")
  text = text:gsub("&(%a+%d*);", function(name)
    if not MARKUP[name] then
      return named[name]
    end
  end)
  return (
    text:gsub("&#([xX]?)(%x+);", function(x, digits)
      local code = tonumber(digits, x ~= "" and 16 or 10)
      if code and not MARKUP_CODES[code] then
        return vim.fn.nr2char(code, true)
      end
    end)
  )
end

-- Decode references in a line outside its code spans, which CommonMark
-- shows literally: a run of N backticks opens a span the next run of
-- exactly N backticks closes.
local function decode_outside_spans(line)
  local out, pos = {}, 1
  while true do
    local s, e = line:find("`+", pos)
    if not s then
      break
    end
    local fence = line:sub(s, e)
    local cs, ce = e + 1, nil
    while true do
      local a, b = line:find("`+", cs)
      if not a then
        break
      end
      if b - a + 1 == #fence then
        ce = b
        break
      end
      cs = b + 1
    end
    if not ce then
      out[#out + 1] = decode_references(line:sub(pos, e))
      pos = e + 1
    else
      out[#out + 1] = decode_references(line:sub(pos, s - 1))
      out[#out + 1] = line:sub(s, ce)
      pos = ce + 1
    end
  end
  out[#out + 1] = decode_references(line:sub(pos))
  return table.concat(out)
end

local function markdown(text)
  local lines = vim.split(text, "\n", { plain = true })
  local fence
  for i, line in ipairs(lines) do
    local marker = line:match("^ ? ? ?(```+)") or line:match("^ ? ? ?(~~~+)")
    if fence then
      if marker and marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence then
        fence = nil
      end
    elseif marker then
      fence = marker
    elseif not line:match("^    ") and not line:match("^\t") then
      line = decode_outside_spans(line)
    end
    lines[i] = line:gsub("^(>+) +$", "%1")
  end
  return (table.concat(lines, "\n"):gsub("\n+$", "\n"))
end

local function expand_tabs(text)
  local out = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local col, buf = 0, {}
    for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      if ch == "\t" then
        local n = 8 - col % 8
        buf[#buf + 1] = string.rep(" ", n)
        col = col + n
      else
        buf[#buf + 1] = ch
        col = col + 1
      end
    end
    out[#out + 1] = table.concat(buf)
  end
  return table.concat(out, "\n")
end

local function valid_utf8(text)
  local out = {}
  local i, len = 1, #text
  while i <= len do
    local c = text:byte(i)
    local n = c < 0x80 and 1
      or (c >= 0xC2 and c <= 0xDF) and 2
      or (c >= 0xE0 and c <= 0xEF) and 3
      or (c >= 0xF0 and c <= 0xF4) and 4
      or 0
    local ok = n > 0 and i + n - 1 <= len
    for k = 1, n - 1 do
      local b = ok and text:byte(i + k)
      if not b or b < 0x80 or b > 0xBF then
        ok = false
      end
    end
    if ok then
      out[#out + 1] = text:sub(i, i + n - 1)
      i = i + n
    else
      out[#out + 1] = string.format("<0x%02X>", c)
      i = i + 1
    end
  end
  return table.concat(out)
end

return function(text, side, case)
  local b = backend(case)
  text = valid_utf8(text)
  if b:match("^icalendar") then
    text = line_ends(text)
    if side == "emacs" then
      text = uuids(text)
    end
    if b == "icalendar-combine" then
      text = unfold(text, case)
    end
  elseif b == "texinfo" then
    text = texinfo(text)
  elseif b == "md" then
    text = markdown(text)
  elseif b == "ascii" then
    text = expand_tabs(text)
  end
  return text
end
