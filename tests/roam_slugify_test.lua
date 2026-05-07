-- Roam slug generation: previous version stripped anything outside
-- `[a-z0-9]`, which slugged a CJK / Cyrillic / accented title down
-- to "untitled".  Emacs org-roam keeps any Unicode letter / digit
-- via `[:alnum:]`; this test pins the Lua approximation that keeps
-- multibyte UTF-8 bytes intact while stripping ASCII whitespace,
-- control chars, and filesystem-reserved punctuation.
--
-- Run via: nvim --headless -l tests/roam_slugify_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local slugify = require("organ.slug").slugify

local fails = 0
local function check(input, expected)
  local got = slugify(input)
  if got == expected then
    print(("PASS  %q -> %q"):format(input, got))
  else
    fails = fails + 1
    print(("FAIL  %q -> %q (expected %q)"):format(input, got, expected))
  end
end

-- ASCII baseline -- matches Emacs `[^[:alnum:]]` -> `_`,
-- collapsed, lowercased.
check("Hello World", "hello_world")
check("Project Atlas", "project_atlas")
check("Hello, World!", "hello_world")
check("Python 3.12 release", "python_3_12_release")

-- CJK preservation (Japanese, Chinese, Korean).
check("プロジェクト", "プロジェクト")
check("日本語のメモ", "日本語のメモ")
check("项目计划", "项目计划")
check("한국어 노트", "한국어_노트")

-- Mixed CJK + ASCII + digits.
check("メモ 5 final", "メモ_5_final")

-- Accented Latin: diacritics stripped (matches Emacs's NFKD +
-- combining-mark removal via a precomposed-Latin fold table).
check("Café Latté", "cafe_latte")
check("Naïve approach", "naive_approach")
check("São Paulo", "sao_paulo")
-- Atomic letters Emacs keeps (æ, ł, ø, ð, þ, đ, etc.) preserve as
-- lowercase; only the diacritics on top are stripped.
check("Łódź", "łodz")
check("Bjørk", "bjørk")
check("Caffè E Æpistola", "caffe_e_æpistola")

-- Whitespace runs collapse to a single `_`.
check("  multiple   spaces  ", "multiple_spaces")

-- All non-alnum becomes `_`, runs collapse, strip leading /
-- trailing `_`.
check("name/with/slashes", "name_with_slashes")
check('illegal:chars*"<>?|', "illegal_chars")

-- Non-Latin punctuation gets stripped (Unicode-aware).  Was kept
-- under the byte-walker; vim's `[:alnum:]` regex strips it.
check("質問？はい！", "質問_はい")
check("「メモ」", "メモ")
check("topic… continued", "topic_continued")
check("emoji 🎉 party", "emoji_party")
-- Ellipsis on its own collapses to fallback.
check("？？？", "untitled")

-- Latin Extended-B with diacritics: stripped to base.
check("Bărdaș", "bardas")
check("Ǎlphǎ", "alpha")

-- Empty / whitespace-only fallback.
check("", "untitled")
check("   ", "untitled")

if fails > 0 then
  print()
  print(("FAILED %d checks"):format(fails))
  os.exit(1)
end
print()
print("roam_slugify_test: PASS")
os.exit(0)
