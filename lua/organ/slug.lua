-- Slug generation matching Emacs `org-roam-node-slug`:
--   1. NFKD-equivalent: replace precomposed Latin-with-diacritic
--      chars with their base letter (folded to lowercase), and
--      strip Unicode combining marks (U+0300..U+036F) that appear
--      in NFD-form input.
--   2. Replace every non-alphanumeric byte with `_` (Emacs's
--      `[^[:alnum:]]` rule).  Multibyte UTF-8 sequences (>= 0x80)
--      are treated as alphanumeric and pass through, so CJK,
--      Greek, Cyrillic, etc. survive intact.
--   3. Collapse runs of `_`, strip leading / trailing `_`,
--      lowercase ASCII.
--
-- Divergences from Emacs:
--   - Non-Latin Unicode punctuation (e.g. fullwidth `？`,
--     ellipsis `…`) is kept since byte-walker can't tell letter
--     from punctuation without full Unicode-property tables.  In
--     practice org-roam titles rarely include these.
--   - Byte-walker is faster than per-codepoint scanning and is
--     safe because UTF-8 continuation bytes never collide with
--     the ASCII control / punctuation set we strip.

local M = {}

-- Precomposed Latin chars folded to plain lowercase (or to the
-- closest preserved-letter equivalent for atomic letters Emacs
-- keeps -- æ, ð, ø, þ, ł, đ, etc. -- which lowercase to themselves
-- and don't decompose).  Covers Latin-1 Supplement (U+00C0..U+00FF)
-- and Latin Extended-A (U+0100..U+017F) -- the ranges most users'
-- accented Latin titles fall into.  Latin Extended-B (U+0180..)
-- and beyond are rare enough that they pass through unchanged.
local FOLD = {
  -- Latin-1 Supplement uppercase
  ["À"] = "a",
  ["Á"] = "a",
  ["Â"] = "a",
  ["Ã"] = "a",
  ["Ä"] = "a",
  ["Å"] = "a",
  ["Æ"] = "æ",
  ["Ç"] = "c",
  ["È"] = "e",
  ["É"] = "e",
  ["Ê"] = "e",
  ["Ë"] = "e",
  ["Ì"] = "i",
  ["Í"] = "i",
  ["Î"] = "i",
  ["Ï"] = "i",
  ["Ð"] = "ð",
  ["Ñ"] = "n",
  ["Ò"] = "o",
  ["Ó"] = "o",
  ["Ô"] = "o",
  ["Õ"] = "o",
  ["Ö"] = "o",
  ["Ø"] = "ø",
  ["Ù"] = "u",
  ["Ú"] = "u",
  ["Û"] = "u",
  ["Ü"] = "u",
  ["Ý"] = "y",
  ["Þ"] = "þ",
  -- Latin-1 Supplement lowercase (with diacritics)
  ["à"] = "a",
  ["á"] = "a",
  ["â"] = "a",
  ["ã"] = "a",
  ["ä"] = "a",
  ["å"] = "a",
  ["ç"] = "c",
  ["è"] = "e",
  ["é"] = "e",
  ["ê"] = "e",
  ["ë"] = "e",
  ["ì"] = "i",
  ["í"] = "i",
  ["î"] = "i",
  ["ï"] = "i",
  ["ñ"] = "n",
  ["ò"] = "o",
  ["ó"] = "o",
  ["ô"] = "o",
  ["õ"] = "o",
  ["ö"] = "o",
  ["ù"] = "u",
  ["ú"] = "u",
  ["û"] = "u",
  ["ü"] = "u",
  ["ý"] = "y",
  ["ÿ"] = "y",
  -- Latin Extended-A
  ["Ā"] = "a",
  ["ā"] = "a",
  ["Ă"] = "a",
  ["ă"] = "a",
  ["Ą"] = "a",
  ["ą"] = "a",
  ["Ć"] = "c",
  ["ć"] = "c",
  ["Ĉ"] = "c",
  ["ĉ"] = "c",
  ["Ċ"] = "c",
  ["ċ"] = "c",
  ["Č"] = "c",
  ["č"] = "c",
  ["Ď"] = "d",
  ["ď"] = "d",
  ["Đ"] = "đ",
  ["Ē"] = "e",
  ["ē"] = "e",
  ["Ĕ"] = "e",
  ["ĕ"] = "e",
  ["Ė"] = "e",
  ["ė"] = "e",
  ["Ę"] = "e",
  ["ę"] = "e",
  ["Ě"] = "e",
  ["ě"] = "e",
  ["Ĝ"] = "g",
  ["ĝ"] = "g",
  ["Ğ"] = "g",
  ["ğ"] = "g",
  ["Ġ"] = "g",
  ["ġ"] = "g",
  ["Ģ"] = "g",
  ["ģ"] = "g",
  ["Ĥ"] = "h",
  ["ĥ"] = "h",
  ["Ħ"] = "ħ",
  ["Ĩ"] = "i",
  ["ĩ"] = "i",
  ["Ī"] = "i",
  ["ī"] = "i",
  ["Ĭ"] = "i",
  ["ĭ"] = "i",
  ["Į"] = "i",
  ["į"] = "i",
  ["İ"] = "i",
  ["Ĵ"] = "j",
  ["ĵ"] = "j",
  ["Ķ"] = "k",
  ["ķ"] = "k",
  ["ĸ"] = "k",
  ["Ĺ"] = "l",
  ["ĺ"] = "l",
  ["Ļ"] = "l",
  ["ļ"] = "l",
  ["Ľ"] = "l",
  ["ľ"] = "l",
  ["Ŀ"] = "l",
  ["ŀ"] = "l",
  ["Ł"] = "ł",
  ["Ń"] = "n",
  ["ń"] = "n",
  ["Ņ"] = "n",
  ["ņ"] = "n",
  ["Ň"] = "n",
  ["ň"] = "n",
  ["Ŋ"] = "ŋ",
  ["ŋ"] = "ŋ",
  ["Ō"] = "o",
  ["ō"] = "o",
  ["Ŏ"] = "o",
  ["ŏ"] = "o",
  ["Ő"] = "o",
  ["ő"] = "o",
  ["Œ"] = "œ",
  ["Ŕ"] = "r",
  ["ŕ"] = "r",
  ["Ŗ"] = "r",
  ["ŗ"] = "r",
  ["Ř"] = "r",
  ["ř"] = "r",
  ["Ś"] = "s",
  ["ś"] = "s",
  ["Ŝ"] = "s",
  ["ŝ"] = "s",
  ["Ş"] = "s",
  ["ş"] = "s",
  ["Š"] = "s",
  ["š"] = "s",
  ["Ţ"] = "t",
  ["ţ"] = "t",
  ["Ť"] = "t",
  ["ť"] = "t",
  ["Ŧ"] = "ŧ",
  ["Ũ"] = "u",
  ["ũ"] = "u",
  ["Ū"] = "u",
  ["ū"] = "u",
  ["Ŭ"] = "u",
  ["ŭ"] = "u",
  ["Ů"] = "u",
  ["ů"] = "u",
  ["Ű"] = "u",
  ["ű"] = "u",
  ["Ų"] = "u",
  ["ų"] = "u",
  ["Ŵ"] = "w",
  ["ŵ"] = "w",
  ["Ŷ"] = "y",
  ["ŷ"] = "y",
  ["Ÿ"] = "y",
  ["Ź"] = "z",
  ["ź"] = "z",
  ["Ż"] = "z",
  ["ż"] = "z",
  ["Ž"] = "z",
  ["ž"] = "z",
}

local function strip_diacritics(s)
  -- Replace precomposed Latin chars (2-byte UTF-8 in lead-byte
  -- range 0xC3..0xC5) with their folded base.  Lead bytes 0xC3,
  -- 0xC4, 0xC5 cover U+00C0..U+017F (Latin-1 Supplement + Latin
  -- Extended-A); each is a 2-byte sequence so the pattern matches
  -- exactly the right span.
  s = s:gsub("[\xC3-\xC5][\x80-\xBF]", function(c)
    return FOLD[c] or c
  end)
  -- Strip Unicode combining diacritical marks (U+0300..U+036F) for
  -- NFD-form input.  In UTF-8 these are 2-byte: 0xCC 0x80..0xBF
  -- (U+0300..U+033F) and 0xCD 0x80..0xAF (U+0340..U+036F).
  s = s:gsub("\xCC[\x80-\xBF]", "")
  s = s:gsub("\xCD[\x80-\xAF]", "")
  return s
end

function M.slugify(s)
  s = strip_diacritics(s)
  local out = {}
  for i = 1, #s do
    local b = s:byte(i)
    if
      (b >= 48 and b <= 57) -- 0-9
      or (b >= 65 and b <= 90) -- A-Z
      or (b >= 97 and b <= 122) -- a-z
      or b >= 0x80 -- UTF-8 lead or continuation byte (CJK, Cyrillic, etc.)
    then
      out[#out + 1] = s:sub(i, i)
    else
      out[#out + 1] = "_"
    end
  end
  s = table.concat(out)
  s = s:gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
  s = s:lower()
  return s == "" and "untitled" or s
end

return M
