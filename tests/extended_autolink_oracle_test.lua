-- Differential test: organ's GFM extended-autolink output must match cmark-gfm
-- (the Markdown renderer GitHub uses) byte for byte.  The bundled spec.json
-- fixtures only cover a handful of autolink cases; this checks a large
-- deterministic corpus against the reference binary, which is how the importer's
-- autolink rules were developed in the first place.
--
-- Opt-in: set ORGAN_CMARK_GFM to a cmark-gfm binary (built with the autolink and
-- strikethrough extensions).  A run without it -- including the normal `make
-- test` -- skips.  CI builds a pinned cmark-gfm and sets the variable.
-- Bootstrap: add project lua/ to the path so bare `require` works.  from_md is
-- pure Lua, so this needs neither the tree-sitter grammar nor the runtime deps
-- that tests/_bootstrap.lua gates on.
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local from_md = require("organ.ast.from_md")
local cmark = dofile(root .. "/tests/cmark/html.lua")

local oracle = os.getenv("ORGAN_CMARK_GFM")
if not oracle or oracle == "" then
  print("extended_autolink_oracle_test: SKIP (set ORGAN_CMARK_GFM to a cmark-gfm binary to run)")
  return
end

-- The corpus uses only www/scheme/email/emphasis/strikethrough constructs, so
-- the oracle needs only these two extensions (matching what the comparison
-- renderer in tests/cmark/html.lua implements).
local ORACLE_CMD = oracle .. " -e autolink -e strikethrough --unsafe < "

local corpus = {}
local function add(s)
  corpus[#corpus + 1] = s .. "\n"
end

-- Structured cross-product: every scheme/www prefix against every host against
-- every trailing path, then every preceding/following character against every
-- email shape.  This is the systematic part -- no randomness.
local hosts =
  { "foo.com", "x.y", "www.a.b", "localhost", "a.b.c.d", "under_score.com", "a_b.c.d", "foo.", "x" }
local schemes = { "http://", "https://", "ftp://", "mailto:", "xmpp:", "HTTP://", "" }
local wwws = { "www.", "WWW.", "ww.", "" }
local paths = {
  "",
  "/p",
  "/p?q=1",
  "/a(b)",
  "/a(b))",
  "/x.",
  "/y,",
  "/z!",
  "/p#frag",
  "/a&copy;b",
  "/a&amp;",
  "/a;",
  "/a&#38;",
  "/p)",
}
local emails = {
  "a@b.com",
  "foo@bar.io",
  "x@y",
  "u.v@w.x",
  "a+b@c.de",
  "mailto:q@r.st",
  "_a@b.com",
  "a@b",
  "a@@b.com",
  "a@b.c@d.e",
}
local pres = { "", "x", "*", "_", "~", "(", ":", ";", "/", "#", " ", "[", "]", "\\", "1", ".", "-" }
local posts = { "", "*", "_", ")", "!", ".", ",", ";", ":", "'", '"', "<", "x", "\n" }

for _, sc in ipairs(schemes) do
  for _, h in ipairs(hosts) do
    for _, p in ipairs(paths) do
      add(sc .. h .. p)
    end
  end
end
for _, w in ipairs(wwws) do
  for _, h in ipairs(hosts) do
    for _, p in ipairs(paths) do
      add(w .. h .. p)
    end
  end
end
for _, pr in ipairs(pres) do
  for _, e in ipairs(emails) do
    for _, po in ipairs(posts) do
      add(pr .. e .. po)
    end
  end
end
-- Emphasis / strikethrough / bracket wrapping around an autolink, where the
-- delimiter bytes interact with the match (consumed into the URL, or
-- invalidating the domain, or suppressing it).
for _, u in ipairs({ "www.foo.com", "http://x.y", "a@b.com" }) do
  for _, w in ipairs({
    "*%s*",
    "_%s_",
    "~~%s~~",
    "**%s**",
    "__%s__",
    "*a %s b*",
    "[%s]",
    "(%s)",
    "`%s`",
  }) do
    add(string.format(w, u))
  end
end

-- Seeded randomised supplement.  Park-Miller minimal-standard LCG: the product
-- stays below 2^53, so the sequence is identical on any IEEE-754 platform (no
-- dependence on integer width or os.time).
local seed = 2147483
local function rnd(m)
  seed = (seed * 16807) % 2147483647
  return seed % m
end
-- Emphasis/strikethrough delimiters are intentionally absent here: cmark-gfm
-- 0.29 classifies flanking with CommonMark 0.29 punctuation (P* only) while
-- organ targets 0.31.2 (P* + S*), so the two legitimately disagree on emphasis
-- around a symbol.  Emphasis-vs-autolink interaction is covered by the curated
-- wraps above, which use symbol-free URLs where the two agree.
local frags = {
  "www.",
  "http://",
  "https://",
  "ftp://",
  "mailto:",
  "xmpp:",
  "@",
  "foo",
  "bar.com",
  ".com",
  ".org",
  "/path",
  "&amp;",
  "&copy;",
  "&#38;",
  ";",
  ")",
  "(",
  "[",
  "]",
  " ",
  ".",
  "-",
  "\\",
  "'",
  '"',
  "WWW.",
  "localhost",
  "a.b",
  "a_b",
  "\195\169", -- a multibyte letter (e-acute): ends the domain scan
}
for _ = 1, 6000 do
  local parts = rnd(12) + 2
  local t = {}
  for k = 1, parts do
    t[k] = frags[rnd(#frags) + 1]
  end
  add(table.concat(t))
end

-- Run the oracle once per input (a tiny local binary; ~0.5ms each).
local tmp = os.tmpname()
local function oracle_html(md)
  local f = assert(io.open(tmp, "w"))
  f:write(md)
  f:close()
  local p = assert(io.popen(ORACLE_CMD .. tmp, "r"))
  local out = p:read("*a")
  p:close()
  return out
end

local diverged = {}
for _, md in ipairs(corpus) do
  local organ = cmark.render(from_md.parse(md, { extended_autolinks = true }))
  local ref = oracle_html(md)
  if organ ~= ref then
    diverged[#diverged + 1] = { md = md, organ = organ, ref = ref }
  end
end
os.remove(tmp)

if #diverged > 0 then
  for i = 1, math.min(10, #diverged) do
    local d = diverged[i]
    io.stderr:write(string.format("DIVERGE %q\n  organ: %q\n  cmark: %q\n", d.md, d.organ, d.ref))
  end
  error(
    string.format(
      "extended_autolink_oracle_test: %d/%d inputs diverge from cmark-gfm",
      #diverged,
      #corpus
    )
  )
end

print(string.format("extended_autolink_oracle_test: PASS (%d inputs match cmark-gfm)", #corpus))
