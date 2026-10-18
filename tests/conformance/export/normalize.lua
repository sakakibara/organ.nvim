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

local function texinfo(text)
  text = text:gsub("\n\n\n+", "\n\n"):gsub("^\\input texinfo%s+@c [^\n]*", "\\input texinfo")
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

local function markdown(text)
  local named = require("organ.ast.html5_entities")
  text = text:gsub("&(%a+%d*);", function(name)
    if not MARKUP[name] then
      return named[name]
    end
  end)
  text = text:gsub("&#([xX]?)(%x+);", function(x, digits)
    local code = tonumber(digits, x ~= "" and 16 or 10)
    if code and not MARKUP_CODES[code] then
      return vim.fn.nr2char(code, true)
    end
  end)
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
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
