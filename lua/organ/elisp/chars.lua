-- Character data (D9) as organ's lookups: case mappings and display
-- widths in an org-mode buffer, decoded from data/case.lua and
-- data/width.lua.

local CASE = require("organ.elisp.data.case")
local WIDTH = require("organ.elisp.data.width")

local M = {}

local function pair_map(flat)
  local m = {}
  for i = 1, #flat, 2 do
    m[flat[i]] = flat[i + 1]
  end
  return m
end

local UP = pair_map(CASE.upcase)
local DOWN = pair_map(CASE.downcase)
local TITLE = pair_map(CASE.capitalize)

local MAPS = { upcase = UP, downcase = DOWN, capitalize = TITLE }
local SPECIAL = {
  upcase = CASE.special_upcase,
  downcase = CASE.special_downcase,
  capitalize = CASE.special_capitalize,
}

--- `upcase', `downcase' or `capitalize' (`kind') of character `c'.
function M.case_char(kind, c)
  return MAPS[kind][c] or c
end

--- The string `kind' maps the one-character string of `c' to, when
--- that is not the character mapping (special casing), else nil.
function M.case_special(kind, c)
  return SPECIAL[kind][c]
end

--- The case-fold canonical form of `c' (the case table's
--- canonicalize, which is downcase of upcase of downcase).
function M.canon(c)
  local d = DOWN[c] or c
  local u = UP[d] or d
  return DOWN[u] or u
end

local IMAGE = {}
for _, m in pairs({ UP, DOWN }) do
  for _, v in pairs(m) do
    IMAGE[v] = true
  end
end

--- Whether `c' shares a case-fold class with another character.
function M.cased(c)
  return UP[c] ~= nil or DOWN[c] ~= nil or IMAGE[c] == true
end

local function range_value(t, c)
  local lo, hi = 1, #t / 2
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if t[2 * mid - 1] <= c then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return t[2 * lo]
end

--- `char-width' of code point `c' in an org-mode buffer.
function M.char_width(c)
  return range_value(WIDTH.width, c)
end

--- Whether composition-function-table holds a rule for `c'.
function M.composes(c)
  return range_value(WIDTH.composition, c) == 1
end

--- Whether a CJK locale's width table gives `c' another width.
function M.cjk(c)
  return range_value(WIDTH.cjk, c) == 1
end

--- The width of `c' every user's Emacs gives it, or nil: control
--- characters follow ctl-arrow, TAB tab-width, and CJK-dependent ones
--- the language environment.  A newline is 0 everywhere.
function M.fixed_width(c)
  if c == 10 then
    return 0
  elseif c < 32 or c == 127 or M.cjk(c) then
    return nil
  end
  return M.char_width(c)
end

return M
