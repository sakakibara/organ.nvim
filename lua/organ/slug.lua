-- Slug generation matching Emacs `org-roam-node-slug`:
--   1. NFKD-equivalent: replace precomposed Latin-with-diacritic
--      chars with their base letter (folded to lowercase), and
--      strip Unicode combining marks (U+0300..U+036F) that appear
--      in NFD-form input.  Covers Latin-1 Supplement, Latin
--      Extended-A, and the diacritic-bearing subset of Latin
--      Extended-B.
--   2. Walk codepoints, keep Unicode `Letter` + `Number` (Latin,
--      Greek, Cyrillic, Hebrew, Arabic, Devanagari, Thai, CJK,
--      Hiragana, Katakana, Hangul, fullwidth alnum), replace
--      everything else with `_`.  CJK punctuation (`？、「」`),
--      fullwidth punctuation, ellipsis (`…`), emoji, ASCII
--      punctuation all strip out via this rule.
--   3. Collapse runs of `_`, strip leading / trailing `_`,
--      lowercase ASCII.

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
  -- Latin Extended-B: diacritic-bearing chars only.  Atomic
  -- letters in this range (ƀ Ɓ Ƃ ƃ ƈ Ƈ ƌ Ƌ ƒ Ƒ etc., used in
  -- IPA / minority languages) lowercase to themselves and are
  -- left to pass through.  Same goes for ǝ Ǝ Ƣ ƣ Ʒ ʒ etc.
  ["Ǎ"] = "a",
  ["ǎ"] = "a",
  ["Ǐ"] = "i",
  ["ǐ"] = "i",
  ["Ǒ"] = "o",
  ["ǒ"] = "o",
  ["Ǔ"] = "u",
  ["ǔ"] = "u",
  ["Ǖ"] = "u",
  ["ǖ"] = "u",
  ["Ǘ"] = "u",
  ["ǘ"] = "u",
  ["Ǚ"] = "u",
  ["ǚ"] = "u",
  ["Ǜ"] = "u",
  ["ǜ"] = "u",
  ["Ǟ"] = "a",
  ["ǟ"] = "a",
  ["Ǡ"] = "a",
  ["ǡ"] = "a",
  ["Ǣ"] = "æ",
  ["ǣ"] = "æ",
  ["Ǥ"] = "g",
  ["ǥ"] = "g",
  ["Ǧ"] = "g",
  ["ǧ"] = "g",
  ["Ǩ"] = "k",
  ["ǩ"] = "k",
  ["Ǫ"] = "o",
  ["ǫ"] = "o",
  ["Ǭ"] = "o",
  ["ǭ"] = "o",
  ["Ǯ"] = "ʒ",
  ["ǯ"] = "ʒ",
  ["Ǵ"] = "g",
  ["ǵ"] = "g",
  ["Ǹ"] = "n",
  ["ǹ"] = "n",
  ["Ǻ"] = "a",
  ["ǻ"] = "a",
  ["Ǽ"] = "æ",
  ["ǽ"] = "æ",
  ["Ǿ"] = "ø",
  ["ǿ"] = "ø",
  ["Ȁ"] = "a",
  ["ȁ"] = "a",
  ["Ȃ"] = "a",
  ["ȃ"] = "a",
  ["Ȅ"] = "e",
  ["ȅ"] = "e",
  ["Ȇ"] = "e",
  ["ȇ"] = "e",
  ["Ȉ"] = "i",
  ["ȉ"] = "i",
  ["Ȋ"] = "i",
  ["ȋ"] = "i",
  ["Ȍ"] = "o",
  ["ȍ"] = "o",
  ["Ȏ"] = "o",
  ["ȏ"] = "o",
  ["Ȑ"] = "r",
  ["ȑ"] = "r",
  ["Ȓ"] = "r",
  ["ȓ"] = "r",
  ["Ȕ"] = "u",
  ["ȕ"] = "u",
  ["Ȗ"] = "u",
  ["ȗ"] = "u",
  ["Ș"] = "s",
  ["ș"] = "s",
  ["Ț"] = "t",
  ["ț"] = "t",
  ["Ȟ"] = "h",
  ["ȟ"] = "h",
  ["Ȧ"] = "a",
  ["ȧ"] = "a",
  ["Ȩ"] = "e",
  ["ȩ"] = "e",
  ["Ȫ"] = "o",
  ["ȫ"] = "o",
  ["Ȭ"] = "o",
  ["ȭ"] = "o",
  ["Ȯ"] = "o",
  ["ȯ"] = "o",
  ["Ȱ"] = "o",
  ["ȱ"] = "o",
  ["Ȳ"] = "y",
  ["ȳ"] = "y",
}

local function strip_diacritics(s)
  -- Replace precomposed Latin chars (2-byte UTF-8 in lead-byte
  -- range 0xC3..0xC9) with their folded base.  Lead bytes:
  --   0xC3       -> U+00C0..U+00FF (Latin-1 Supplement)
  --   0xC4..0xC5 -> U+0100..U+017F (Latin Extended-A)
  --   0xC6..0xC9 -> U+0180..U+024F (Latin Extended-B)
  -- Each is a 2-byte sequence so the pattern matches exactly.
  s = s:gsub("[\xC3-\xC9][\x80-\xBF]", function(c)
    return FOLD[c] or c
  end)
  -- Strip Unicode combining diacritical marks (U+0300..U+036F) for
  -- NFD-form input.  In UTF-8 these are 2-byte: 0xCC 0x80..0xBF
  -- (U+0300..U+033F) and 0xCD 0x80..0xAF (U+0340..U+036F).
  s = s:gsub("\xCC[\x80-\xBF]", "")
  s = s:gsub("\xCD[\x80-\xAF]", "")
  return s
end

-- Approximation of Unicode `Letter` + `Number` general categories.
-- Vim's POSIX `[:alnum:]` is locale-dependent and doesn't reliably
-- classify CJK / Cyrillic / etc. in headless tests, so we walk
-- codepoints ourselves and check against script ranges that cover
-- the bulk of real-world org-roam titles.  Punctuation ranges
-- inside these scripts (e.g. CJK Symbols and Punctuation
-- U+3000..U+303F, Fullwidth ASCII U+FF00..U+FF0F) are deliberately
-- excluded so `？、「」` strip out while letters survive.
local function is_alnum(cp)
  -- ASCII alphanumeric
  if cp <= 0x7F then
    return (cp >= 0x30 and cp <= 0x39) -- 0-9
      or (cp >= 0x41 and cp <= 0x5A) -- A-Z
      or (cp >= 0x61 and cp <= 0x7A) -- a-z
  end
  -- Latin Supplement, Extended-A/B/C, IPA, Spacing modifiers
  if cp >= 0x00C0 and cp <= 0x02AF then
    return true
  end
  -- Greek + Coptic + Cyrillic + Cyrillic Supp + Armenian + Hebrew
  if cp >= 0x0370 and cp <= 0x05FF then
    return true
  end
  -- Arabic + Syriac + Thaana
  if cp >= 0x0600 and cp <= 0x07BF then
    return true
  end
  -- Devanagari .. Tibetan (Indic)
  if cp >= 0x0900 and cp <= 0x0FFF then
    return true
  end
  -- Myanmar, Georgian, Hangul Jamo, Ethiopic, Cherokee, ...
  if cp >= 0x1000 and cp <= 0x1FFF then
    return true
  end
  -- Hiragana, Katakana
  if cp >= 0x3040 and cp <= 0x30FF then
    return true
  end
  -- CJK Unified Ideographs (incl. Extension A)
  if cp >= 0x3400 and cp <= 0x9FFF then
    return true
  end
  -- Hangul Syllables
  if cp >= 0xAC00 and cp <= 0xD7AF then
    return true
  end
  -- Fullwidth ASCII letters / digits
  if
    (cp >= 0xFF10 and cp <= 0xFF19)
    or (cp >= 0xFF21 and cp <= 0xFF3A)
    or (cp >= 0xFF41 and cp <= 0xFF5A)
  then
    return true
  end
  -- Halfwidth Katakana
  if cp >= 0xFF66 and cp <= 0xFF9F then
    return true
  end
  -- CJK Unified Ideographs Extension B and beyond (rare but valid)
  if cp >= 0x20000 and cp <= 0x2FFFF then
    return true
  end
  return false
end

-- Decode the next UTF-8 codepoint at byte position `i`.  Returns
-- (codepoint, byte_length).  Falls back to (byte, 1) on invalid.
local function utf8_cp(s, i)
  local b1 = s:byte(i)
  if not b1 then
    return nil, 0
  end
  if b1 < 0x80 then
    return b1, 1
  end
  if b1 < 0xC0 then
    return b1, 1 -- stray continuation; treat as single byte
  end
  if b1 < 0xE0 then
    local b2 = s:byte(i + 1) or 0
    return ((b1 - 0xC0) * 0x40) + (b2 - 0x80), 2
  end
  if b1 < 0xF0 then
    local b2 = s:byte(i + 1) or 0
    local b3 = s:byte(i + 2) or 0
    return ((b1 - 0xE0) * 0x1000) + ((b2 - 0x80) * 0x40) + (b3 - 0x80), 3
  end
  local b2 = s:byte(i + 1) or 0
  local b3 = s:byte(i + 2) or 0
  local b4 = s:byte(i + 3) or 0
  return ((b1 - 0xF0) * 0x40000) + ((b2 - 0x80) * 0x1000) + ((b3 - 0x80) * 0x40) + (b4 - 0x80), 4
end

function M.slugify(s)
  s = strip_diacritics(s)
  local out = {}
  local i = 1
  while i <= #s do
    local cp, n = utf8_cp(s, i)
    if cp and is_alnum(cp) then
      out[#out + 1] = s:sub(i, i + n - 1)
    else
      out[#out + 1] = "_"
    end
    i = i + n
  end
  s = table.concat(out)
  s = s:gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
  s = vim.fn.tolower(s)
  return s == "" and "untitled" or s
end

return M
