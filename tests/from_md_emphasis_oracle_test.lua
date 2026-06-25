-- Differential test: organ's emphasis/strikethrough resolution must match
-- cmark-gfm byte for byte over a large corpus of unbalanced "delimiter soup".
-- The bundled spec.json fixtures cover only well-formed emphasis; the rule-of-3,
-- openers_bottom barrier, and GFM strikethrough length-equality rules were
-- developed against this differential, where organ used to OVER-pair runs that
-- cmark leaves literal.
--
-- Opt-in: set ORGAN_CMARK_GFM to a cmark-gfm binary built with the autolink and
-- strikethrough extensions.  A run without it -- including the normal `make
-- test` -- skips.  CI builds a pinned cmark-gfm and sets the variable.
--
-- The corpus is fully deterministic (no os.time / os.random), so a failure is
-- always reproducible.  Its size is fixed, so the test cannot run away.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_md = require("organ.ast.from_md")
local cmark = dofile(root .. "/tests/cmark/html.lua")

local oracle = os.getenv("ORGAN_CMARK_GFM")
if not oracle or oracle == "" then
  print("from_md_emphasis_oracle_test: SKIP (set ORGAN_CMARK_GFM to a cmark-gfm binary to run)")
  return
end

local ORACLE_CMD = oracle .. " -e autolink -e strikethrough --unsafe < "

-- cmark-gfm 0.29's HTML renderer suppresses a <strong> nested directly inside a
-- <strong> (node->parent->type != STRONG); CommonMark 0.31.2, organ's target,
-- does not.  Both ASTs are identical, so collapsing strong-in-strong on each
-- side isolates true parse divergences from this rendering-only artifact.
local function collapse_strong(html)
  local out, depth = {}, 0
  local i, n = 1, #html
  while i <= n do
    if html:sub(i, i + 7) == "<strong>" then
      depth = depth + 1
      if depth == 1 then
        out[#out + 1] = "<strong>"
      end
      i = i + 8
    elseif html:sub(i, i + 8) == "</strong>" then
      if depth == 1 then
        out[#out + 1] = "</strong>"
      end
      if depth > 0 then
        depth = depth - 1
      end
      i = i + 9
    else
      out[#out + 1] = html:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out)
end

local corpus = {}
local seen = {}
local function add(s)
  if not seen[s] then
    seen[s] = true
    corpus[#corpus + 1] = s .. "\n"
  end
end

-- Structured cross-product: every ordered 4-tuple over a small alphabet of
-- delimiter runs and fillers.  `[`/`]` are intentionally absent -- they pull in
-- link-reference-definition parsing, where cmark-gfm 0.29 and CommonMark 0.31.2
-- legitimately differ on unbalanced-paren destinations (not an emphasis bug).
local alpha = { "*", "**", "***", "_", "__", "___", "~", "~~", "a", ".", "(", " " }
for _, a in ipairs(alpha) do
  for _, b in ipairs(alpha) do
    for _, c in ipairs(alpha) do
      for _, d in ipairs(alpha) do
        add(a .. b .. c .. d)
      end
    end
  end
end

-- Seeded random supplement: longer runs of the same fragments, across several
-- independent Park-Miller streams.  The LCG product stays below 2^53, so the
-- sequence is identical on any IEEE-754 platform.
local frags = {
  "*",
  "**",
  "***",
  "_",
  "__",
  "___",
  "~",
  "~~",
  "~~~",
  "a",
  "b",
  "foo",
  " ",
  ".",
  ",",
  "!",
  "(",
  ")",
  "'",
  '"',
  "-",
  ":",
  ";",
  "/",
  "\\",
  "x*",
  "*x",
  "_y",
  "y_",
}
for _, seed0 in ipairs({ 1, 7, 42, 1000, 31337, 161803, 271828, 99991 }) do
  local seed = seed0
  local function rnd(m)
    seed = (seed * 16807) % 2147483647
    return seed % m
  end
  for _ = 1, 8000 do
    local parts = rnd(8) + 2
    local t = {}
    for k = 1, parts do
      t[k] = frags[rnd(#frags) + 1]
    end
    add(table.concat(t))
  end
end

-- Run the oracle once per input (a tiny local binary).
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
  local organ = collapse_strong(cmark.render(from_md.parse(md, { extended_autolinks = true })))
  local ref = collapse_strong(oracle_html(md))
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
      "from_md_emphasis_oracle_test: %d/%d inputs diverge from cmark-gfm",
      #diverged,
      #corpus
    )
  )
end

print(string.format("from_md_emphasis_oracle_test: PASS (%d inputs match cmark-gfm)", #corpus))
