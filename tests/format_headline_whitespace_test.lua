-- The headline normalizer collapses the separators BETWEEN the structural
-- parts of a headline (stars, TODO keyword, priority cookie, COMMENT
-- marker, title) and leaves the title text alone -- Emacs's fill and align
-- commands never rewrite title text.  Every expectation below is what
-- `org-element-parse-buffer` reads from the input, so formatting a file
-- cannot change how Emacs reads it back.
--
-- Run via: nvim --headless -l tests/format_headline_whitespace_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fmt = require("organ.format")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local FLUSH = { headline = { tags_column = false } }

local function formatted(line, cfg)
  return fmt.format_lines({ line }, cfg or FLUSH)[1]
end

local function case(label, input, want, cfg)
  local got = formatted(input, cfg)
  check(label, got == want, string.format("got %q, want %q", got, want))
end

case(
  "runs inside the title survive",
  "* TODO   many   spaces  in   title",
  "* TODO many   spaces  in   title"
)

case("a tab after the keyword is title text, not a separator", "* TODO\tThing", "* TODO\tThing")

case("a tab after the stars is not a headline separator", "*\tNot a headline", "*\tNot a headline")

case(
  "priority separator collapses, title does not",
  "** [#A]   Title  with   gaps",
  "** [#A] Title  with   gaps"
)

case("COMMENT separator collapses, title does not", "* COMMENT   A  B", "* COMMENT A  B")

case("the separator after the stars collapses", "*    TODO  X   Y", "* TODO X   Y")

case(
  "every structural separator at once",
  "* TODO [#A] COMMENT   T  T2 :tag:",
  "* TODO [#A] COMMENT T  T2 :tag:"
)

case(
  "normalize_whitespace off leaves the separators as typed",
  "*   TODO   [#A]   Title  gaps",
  "*   TODO   [#A]   Title  gaps",
  { headline = { normalize_whitespace = false, tags_column = 40 } }
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_headline_whitespace_test: PASS")
