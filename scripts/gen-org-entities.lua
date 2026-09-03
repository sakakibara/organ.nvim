-- Regenerate lua/organ/ast/org_entities.lua.  Pure Lua plus stylua, which
-- formats the result:
--   nvim -l scripts/gen-org-entities.lua path/to/unicode.xml
--
-- Sources, none of them GPL:
--   * lua/organ/ast/html5_entities.lua -- name -> character for every HTML5
--     named reference (WHATWG entities.json, via gen-html5-entities.lua).
--   * unicode.xml from the W3C note "XML Entity Definitions for Characters"
--     (https://www.w3.org/2003/entities/2007xml/unicode.xml, W3C Software
--     Notice and License) -- character, LaTeX and math-LaTeX form, text/math
--     mode and the canonical decomposition for every SGML/XML entity name.
--   * The NAMES and CURATED tables below: the org entity names, which are
--     user-facing markup syntax, and the values the two sources above cannot
--     supply or get wrong for org's purpose.
local UNICODE_XML = arg[1] or "unicode.xml"
local OUT = arg[2] or "lua/organ/ast/org_entities.lua"
local HTML5 = arg[3] or "lua/organ/ast/html5_entities.lua"

-- Org entity names, grouped the way org's "Special Symbols" documentation
-- groups them.  A name is the markup a user types (`\alpha`, `\nbsp`), so the
-- list is an interface, not data lifted from an implementation.
local NAMES = {
  latin = [[
    Agrave agrave Aacute aacute Acirc acirc Atilde atilde Auml auml
    Aring aring AA aa AElig aelig Ccedil ccedil
    Egrave egrave Eacute eacute Ecirc ecirc Euml euml
    Igrave igrave Iacute iacute Icirc icirc Iuml iuml Ntilde ntilde
    Ograve ograve Oacute oacute Ocirc ocirc Otilde otilde Ouml ouml
    Oslash oslash OElig oelig Scaron scaron szlig
    Ugrave ugrave Uacute uacute Ucirc ucirc Uuml uuml
    Yacute yacute Yuml yuml fnof ordf ordm
  ]],
  latin_special = [[ real image weierp ell imath jmath ]],
  greek = [[
    alpha beta gamma delta epsilon varepsilon zeta eta theta thetasym
    vartheta iota kappa lambda mu nu xi omicron pi piv varpi rho sigmaf
    varsigma sigma tau upsih upsilon phi varphi chi psi omega
    Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda Mu Nu
    Xi Omicron Pi Rho Sigma Tau Upsilon Phi Chi Psi Omega
  ]],
  hebrew = [[ alefsym aleph gimel beth dalet ]],
  dead = [[ ETH eth THORN thorn ]],
  punctuation = [[
    dots cdots hellip middot iexcl iquest shy ndash mdash
    quot acute ldquo rdquo bdquo lsquo rsquo sbquo laquo raquo lsaquo rsaquo
    circ vert vbar brvbar S sect amp lt gt tilde slash plus under
    uml cedil macr oline
  ]],
  currency = [[ cent pound yen curren euro EUR dollar USD ]],
  property = [[ copy reg trade ]],
  math = [[
    minus pm plusmn times frasl colon div frac12 frac14 frac34 permil
    sup1 sup2 sup3 radic sum prod micro deg prime Prime infin infty
    prop propto not neg land wedge lor vee cap cup smile frown
    int integral there4 therefore because
    sim simeq cong asymp approx ne neq equiv triangleq
    le leq ge geq lessgtr lesseqgtr ll Ll lll gg Gg ggg
    prec preceq preccurlyeq succ succeq succcurlyeq
    sub subset sup supset nsub nsup sube nsube supe nsupe setminus
    forall exist exists nexist nexists empty emptyset
    isin in notin ni notni
    oplus ominus otimes osol star sdot cdot ast lowast
    nabla partial Box Diamond loz lozenge hbar mho
    lceil rceil lfloor rfloor lang rang langle rangle
    ang angle perp parallel mp
  ]],
  arrows = [[
    to gets larr lArr uarr uArr rarr rArr darr dArr harr hArr crarr
    leftarrow Leftarrow uparrow Uparrow rightarrow Rightarrow
    downarrow Downarrow leftrightarrow Leftrightarrow iff hookleftarrow
    nlarr nlArr nrarr nrArr nharr nhArr
    nleftarrow nLeftarrow nrightarrow nRightarrow
    nleftrightarrow nLeftrightarrow mapsto
  ]],
  functions = [[
    arccos arcsin arctan cos cosh cot coth csc det dim exp gcd hom inf ker
    lg lim liminf limsup ln log max min Pr sec sin sinh tan tanh
  ]],
  signs = [[
    bull bullet check checkmark dag dagger ddag ddagger Dagger P para
    spadesuit spades clubsuit clubs heartsuit hearts diamondsuit diams
    diamond flat natural sharp smiley blacksmile sad frowny
  ]],
  whitespace = [[ nbsp ensp emsp thinsp zwnj zwj lrm rlm ]],
}

local GROUP_ORDER = {
  "latin",
  "latin_special",
  "greek",
  "hebrew",
  "dead",
  "punctuation",
  "currency",
  "property",
  "math",
  "arrows",
  "functions",
  "signs",
  "whitespace",
}

-- Hand-written entries.  Five reasons appear, and nothing else:
--   (a) no source carries the name at all (`AA`, `EUR`, `P`, `S`, the LaTeX
--       operator names, the smileys);
--   (b) the sourced LaTeX needs a package org's preamble does not load
--       (pifont's `\ding{...}`, textgreek's `\texttheta`, mathabx's
--       `\verymuchless`, wasysym's `\smiley`) and a command from the LaTeX
--       kernel, amsmath or amssymb says the same thing;
--   (c) the sourced LaTeX is not a command at all (`fnof` -> "f"), is a
--       ligature hack (`bdquo` -> ",,") or is missing entirely;
--   (d) the entity name IS a LaTeX command name, and honouring the name the
--       user typed matters more than the character a database happens to
--       attach to that name (`\cdot`, `\circ`, `\hbar`, and the uppercase
--       Greek letters LaTeX spells as Latin capitals);
--   (e) the W3C mode attribute is wrong for org's usage: it calls `nbsp`
--       math, and leaves the delimiters `lang`/`rang` unknown.
-- `utf8` is only ever given when no source has the name or when (d) applies;
-- anything else would be second-guessing the character databases.
local CURATED = {}

local function curate(t)
  for name, e in pairs(t) do
    CURATED[name] = vim.tbl_extend("force", CURATED[name] or {}, e)
  end
end

-- (a) Names carried by neither source.
curate({
  AA = { utf8 = "Å", latex = "\\AA", math = false, ascii = "A" },
  aa = { utf8 = "å", latex = "\\aa", math = false, ascii = "a" },
  dalet = { utf8 = "ℸ", latex = "\\daleth", math = true, ascii = "dalet" },
  dots = { utf8 = "…", latex = "\\dots", math = false, ascii = "..." },
  cdots = { utf8 = "⋯", latex = "\\cdots", math = true, ascii = "..." },
  S = { utf8 = "§", latex = "\\S", math = false, ascii = "section" },
  P = { utf8 = "¶", latex = "\\P", math = false, ascii = "paragraph" },
  slash = { utf8 = "/", latex = "/", math = false, ascii = "/" },
  under = { utf8 = "_", latex = "\\_", math = false, ascii = "_" },
  vbar = { utf8 = "|", latex = "\\vert", math = true, ascii = "|" },
  EUR = { utf8 = "€", latex = "\\texteuro", math = false, ascii = "EUR" },
  USD = { utf8 = "$", latex = "\\$", math = false, ascii = "$" },
  infty = { utf8 = "∞", latex = "\\infty", math = true, ascii = "infinity" },
  neg = { utf8 = "¬", latex = "\\neg", math = true, ascii = "!" },
  land = { utf8 = "∧", latex = "\\land", math = true, ascii = "and" },
  lor = { utf8 = "∨", latex = "\\lor", math = true, ascii = "or" },
  integral = { utf8 = "∫", latex = "\\int", math = true, ascii = "integral" },
  neq = { utf8 = "≠", latex = "\\neq", math = true, ascii = "!=" },
  lll = { utf8 = "⋘", latex = "\\lll", math = true, ascii = "<<<" },
  exists = { utf8 = "∃", latex = "\\exists", math = true, ascii = "exists" },
  partial = { utf8 = "∂", latex = "\\partial", math = true, ascii = "partial" },
  Box = { utf8 = "□", latex = "\\Box", math = true, ascii = "[]" },
  to = { utf8 = "→", latex = "\\to", math = true, ascii = "->" },
  gets = { utf8 = "←", latex = "\\gets", math = true, ascii = "<-" },
  dag = { utf8 = "†", latex = "\\textdagger", math = false, ascii = "+" },
  ddag = { utf8 = "‡", latex = "\\textdaggerdbl", math = false, ascii = "++" },
  smiley = { utf8 = "☺", ascii = ":-)" },
  blacksmile = { utf8 = "☻", ascii = ":-)" },
  sad = { utf8 = "☹", ascii = ":-(" },
  frowny = { utf8 = "☹", ascii = ":-(" },
})

-- (a) LaTeX operator names.  These render as their own name in every
-- non-LaTeX backend, so the name is the character data.
local OPERATORS = [[
  arccos arcsin arctan cos cosh cot coth csc det dim exp gcd hom inf ker
  lg lim liminf limsup ln log max min Pr sec sin sinh tan tanh
]]
for op in OPERATORS:gmatch("%S+") do
  CURATED[op] = { utf8 = op, latex = "\\" .. op, math = true, ascii = op }
end

-- (b) Sourced LaTeX needs a package org's preamble does not load.
curate({
  theta = { latex = "\\theta", math = true },
  thetasym = { latex = "\\vartheta", math = true, ascii = "theta" },
  vartheta = { latex = "\\vartheta", math = true, ascii = "theta" },
  sigmaf = { latex = "\\varsigma", math = true, ascii = "sigma" },
  varsigma = { latex = "\\varsigma", math = true, ascii = "sigma" },
  upsih = { latex = "\\Upsilon", math = true, ascii = "upsilon" },
  Ll = { latex = "\\lll", math = true },
  Gg = { latex = "\\ggg", math = true },
  ggg = { latex = "\\ggg", math = true },
  empty = { latex = "\\emptyset", math = true },
  emptyset = { latex = "\\emptyset", math = true },
  check = { latex = "\\checkmark", math = true },
  checkmark = { latex = "\\checkmark", math = true },
  spadesuit = { latex = "\\spadesuit", math = true },
  spades = { latex = "\\spadesuit", math = true },
  clubsuit = { latex = "\\clubsuit", math = true },
  clubs = { latex = "\\clubsuit", math = true },
  heartsuit = { latex = "\\heartsuit", math = true },
  hearts = { latex = "\\heartsuit", math = true },
  diamondsuit = { latex = "\\diamondsuit", math = true },
  diams = { latex = "\\diamondsuit", math = true },
  star = { utf8 = "⋆", latex = "\\star", math = true, ascii = "*" },
  -- wasysym has \smiley and \frownie; base math spells them with an accent.
  smiley = { latex = "\\ddot\\smile", math = true },
  blacksmile = { latex = "\\ddot\\smile", math = true },
  sad = { latex = "\\ddot\\frown", math = true },
  frowny = { latex = "\\ddot\\frown", math = true },
})

-- (c) Sourced LaTeX is not a usable command.
curate({
  fnof = { latex = "\\textit{f}", math = false, ascii = "f" },
  tilde = { latex = "\\~{}", math = false, ascii = "~" },
  quot = { latex = "\\textquotedbl", math = false, ascii = '"' },
  bdquo = { latex = "\\quotedblbase", math = false },
  sbquo = { latex = "\\quotesinglbase", math = false, ascii = "," },
  jmath = { latex = "\\jmath", math = true, ascii = "j" },
  frasl = { latex = "/", math = false, ascii = "/" },
  crarr = { latex = "\\hookleftarrow", math = true, ascii = "<-'" },
  hookleftarrow = { ascii = "<-'" },
  ne = { latex = "\\neq", math = true },
  notin = { latex = "\\notin", math = true },
  lowast = { latex = "\\ast", math = true, ascii = "*" },
  dollar = { latex = "\\$", math = false },
  euro = { latex = "\\texteuro", math = false },
  sect = { latex = "\\S", math = false, ascii = "section" },
  para = { latex = "\\P", math = false, ascii = "paragraph" },
  sup1 = { latex = "\\textsuperscript{1}", math = false, ascii = "^1" },
  sup2 = { latex = "\\textsuperscript{2}", math = false, ascii = "^2" },
  sup3 = { latex = "\\textsuperscript{3}", math = false, ascii = "^3" },
  -- LaTeX has no overline character; the macron is the same glyph.
  oline = { latex = "\\textasciimacron", math = false, ascii = "-" },
  -- Unstarred \hspace is discarded at a line break, which is the one place a
  -- spacing entity has to survive.  Half an em per unit matches `_ `.
  ensp = { latex = "\\hspace*{0.5em}", math = false },
  emsp = { latex = "\\hspace*{1em}", math = false },
  thinsp = { latex = "\\hspace*{0.2em}", math = false },
})

-- (c) Invisible formatting characters.  LaTeX has no equivalent; an empty
-- group is the zero-width nothing that also breaks a ligature.
for _, name in ipairs({ "zwnj", "zwj", "lrm", "rlm" }) do
  CURATED[name] = { latex = "{}", math = false, ascii = "" }
end

-- (d) Honour the LaTeX command the entity name spells.
curate({
  Alpha = { latex = "A", math = false },
  Beta = { latex = "B", math = false },
  Epsilon = { latex = "E", math = false },
  Zeta = { latex = "Z", math = false },
  Eta = { latex = "H", math = false },
  Iota = { latex = "I", math = false },
  Kappa = { latex = "K", math = false },
  Mu = { latex = "M", math = false },
  Nu = { latex = "N", math = false },
  Omicron = { latex = "O", math = false },
  Rho = { latex = "P", math = false },
  Tau = { latex = "T", math = false },
  Chi = { latex = "X", math = false },
  -- LaTeX's epsilon/phi variant naming is the reverse of HTML5's, so the
  -- command that draws the named character is the "wrong" looking one.
  epsilon = { latex = "\\varepsilon", math = true },
  varepsilon = { latex = "\\epsilon", math = true, ascii = "epsilon" },
  phi = { latex = "\\varphi", math = true },
  varphi = { latex = "\\phi", math = true, ascii = "phi" },
  piv = { ascii = "pi" },
  varpi = { ascii = "pi" },
  imath = { latex = "\\imath", math = true, ascii = "i" },
  real = { latex = "\\Re", math = true, ascii = "R" },
  image = { latex = "\\Im", math = true, ascii = "I" },
  ell = { latex = "\\ell", math = true, ascii = "l" },
  hbar = { latex = "\\hbar", math = true },
  circ = { utf8 = "∘", latex = "\\circ", math = true },
  cdot = { utf8 = "⋅", latex = "\\cdot", math = true, ascii = "." },
  ast = { utf8 = "*", latex = "*", math = false, ascii = "*" },
  middot = { latex = "\\textperiodcentered", math = false, ascii = "." },
  Diamond = { utf8 = "◇", latex = "\\Diamond", math = true, ascii = "<>" },
})

-- (e) Modes the W3C attribute gets wrong for org's usage.
curate({
  nbsp = { math = false, ascii = " " },
  shy = { math = false, ascii = "" },
  minus = { math = true, ascii = "-" },
  plus = { math = false, ascii = "+" },
  lang = { math = true, ascii = "<" },
  rang = { math = true, ascii = ">" },
  langle = { math = true, ascii = "<" },
  rangle = { math = true, ascii = ">" },
})

-- Conventional plain-ASCII renderings.  Everything not listed falls back to
-- the character itself when it is ASCII, then to its ASCII base letter, then
-- to the entity name.
curate({
  copy = { ascii = "(c)" },
  reg = { ascii = "(r)" },
  trade = { ascii = "(tm)" },
  mdash = { ascii = "--" },
  ndash = { ascii = "-" },
  ldquo = { ascii = '"' },
  rdquo = { ascii = '"' },
  bdquo = { ascii = '"' },
  lsquo = { ascii = "'" },
  rsquo = { ascii = "'" },
  laquo = { ascii = "<<" },
  raquo = { ascii = ">>" },
  lsaquo = { ascii = "<" },
  rsaquo = { ascii = ">" },
  acute = { ascii = "'" },
  uml = { ascii = '"' },
  cedil = { ascii = "," },
  brvbar = { ascii = "|" },
  ordf = { ascii = "a" },
  ordm = { ascii = "o" },
  hellip = { ascii = "..." },
  iexcl = { ascii = "!" },
  iquest = { ascii = "?" },
  times = { ascii = "*" },
  div = { ascii = "/" },
  pm = { ascii = "+-" },
  plusmn = { ascii = "+-" },
  mp = { ascii = "-+" },
  ne = { ascii = "!=" },
  le = { ascii = "<=" },
  leq = { ascii = "<=" },
  ge = { ascii = ">=" },
  geq = { ascii = ">=" },
  ll = { ascii = "<<" },
  gg = { ascii = ">>" },
  Ll = { ascii = "<<<" },
  Gg = { ascii = ">>>" },
  ggg = { ascii = ">>>" },
  equiv = { ascii = "==" },
  approx = { ascii = "~" },
  asymp = { ascii = "~" },
  sim = { ascii = "~" },
  simeq = { ascii = "~=" },
  cong = { ascii = "~=" },
  infin = { ascii = "infinity" },
  radic = { ascii = "sqrt" },
  frac12 = { ascii = "1/2" },
  frac14 = { ascii = "1/4" },
  frac34 = { ascii = "3/4" },
  permil = { ascii = "o/oo" },
  prime = { ascii = "'" },
  Prime = { ascii = "''" },
  sdot = { ascii = "." },
  bull = { ascii = "*" },
  bullet = { ascii = "*" },
  dagger = { ascii = "+" },
  ddagger = { ascii = "++" },
  Dagger = { ascii = "++" },
  ["not"] = { ascii = "!" },
  wedge = { ascii = "and" },
  vee = { ascii = "or" },
  loz = { ascii = "<>" },
  lozenge = { ascii = "<>" },
  diamond = { ascii = "<>" },
  parallel = { ascii = "||" },
  there4 = { ascii = "therefore" },
  alefsym = { ascii = "aleph" },
  isin = { ascii = "in" },
  notin = { ascii = "not in" },
  nexist = { ascii = "not exists" },
  nexists = { ascii = "not exists" },
  exist = { ascii = "exists" },
  ETH = { ascii = "D" },
  eth = { ascii = "d" },
  THORN = { ascii = "TH" },
  thorn = { ascii = "th" },
  AElig = { ascii = "AE" },
  aelig = { ascii = "ae" },
  OElig = { ascii = "OE" },
  oelig = { ascii = "oe" },
  Oslash = { ascii = "O" },
  oslash = { ascii = "o" },
  szlig = { ascii = "ss" },
  weierp = { ascii = "P" },
  cent = { ascii = "cent" },
  pound = { ascii = "pound" },
  yen = { ascii = "yen" },
  euro = { ascii = "EUR" },
  curren = { ascii = "curr" },
  ensp = { ascii = " " },
  emsp = { ascii = " " },
  thinsp = { ascii = " " },
  larr = { ascii = "<-" },
  leftarrow = { ascii = "<-" },
  rarr = { ascii = "->" },
  rightarrow = { ascii = "->" },
  uarr = { ascii = "^" },
  uparrow = { ascii = "^" },
  darr = { ascii = "v" },
  downarrow = { ascii = "v" },
  harr = { ascii = "<->" },
  leftrightarrow = { ascii = "<->" },
  lArr = { ascii = "<=" },
  Leftarrow = { ascii = "<=" },
  rArr = { ascii = "=>" },
  Rightarrow = { ascii = "=>" },
  uArr = { ascii = "^" },
  Uparrow = { ascii = "^" },
  dArr = { ascii = "v" },
  Downarrow = { ascii = "v" },
  hArr = { ascii = "<=>" },
  Leftrightarrow = { ascii = "<=>" },
  iff = { ascii = "<=>" },
  mapsto = { ascii = "|->" },
  nlarr = { ascii = "<-/-" },
  nleftarrow = { ascii = "<-/-" },
  nrarr = { ascii = "-/->" },
  nrightarrow = { ascii = "-/->" },
  nharr = { ascii = "<-/->" },
  nleftrightarrow = { ascii = "<-/->" },
  nlArr = { ascii = "<=/=" },
  nLeftarrow = { ascii = "<=/=" },
  nrArr = { ascii = "=/=>" },
  nRightarrow = { ascii = "=/=>" },
  nhArr = { ascii = "<=/=>" },
  nLeftrightarrow = { ascii = "<=/=>" },
})

-- Variable-width horizontal space.  The name is "_" followed by N spaces; one
-- space is half an em, so every backend says the same thing N times.
local SPACE_WIDTHS = 20
local SPACING = {}
for k = 1, SPACE_WIDTHS do
  local name = "_" .. string.rep(" ", k)
  SPACING[#SPACING + 1] = name
  local em = k * 0.5
  CURATED[name] = {
    utf8 = string.rep("\226\128\130", k),
    latex = "\\hspace*{" .. ((em % 1 == 0) and string.format("%d", em) or tostring(em)) .. "em}",
    math = false,
    html = string.rep("&ensp;", k),
    ascii = string.rep(" ", k),
  }
end

local function ordered_names()
  local seen, out = {}, {}
  for _, g in ipairs(GROUP_ORDER) do
    for n in NAMES[g]:gmatch("%S+") do
      if not seen[n] then
        seen[n] = true
        out[#out + 1] = n
      end
    end
  end
  for _, n in ipairs(SPACING) do
    out[#out + 1] = n
  end
  return out
end

local function unescape(s)
  s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
  return (s:gsub("&amp;", "&"))
end

-- name -> { utf8, latex, mathlatex, mode, base } from the W3C note.
local function load_w3c(path)
  local fh = assert(io.open(path, "r"), "cannot read " .. path)
  local xml = fh:read("*a")
  fh:close()
  local out = {}
  for block in xml:gmatch("<character%s.-</character>") do
    local head = block:match("^<character[^>]*>")
    local dec, mode = head:match('dec="([^"]*)"'), head:match('mode="([^"]*)"')
    local cps = {}
    for part in (dec or ""):gmatch("[^-]+") do
      cps[#cps + 1] = tonumber(part)
    end
    if #cps > 0 then
      local char = {}
      for i, cp in ipairs(cps) do
        char[i] = vim.fn.nr2char(cp)
      end
      local decomp = block:match('<unicodedata[^>]-decomp="([^"]*)"')
      local hex = decomp and decomp:match("^(%x+)")
      local base = hex and tonumber(hex, 16)
      local rec = {
        utf8 = table.concat(char),
        mode = mode,
        latex = block:match("<latex[^>]*>(.-)</latex>"),
        mathlatex = block:match("<mathlatex[^>]*>(.-)</mathlatex>"),
        base = (base and base < 128) and string.char(base) or nil,
      }
      rec.latex = rec.latex and vim.trim(unescape(rec.latex))
      rec.mathlatex = rec.mathlatex and vim.trim(unescape(rec.mathlatex))
      for id in block:gmatch('<entity id="([^"]*)"') do
        out[id] = out[id] or rec
      end
    end
  end
  return out
end

local w3c = load_w3c(UNICODE_XML)
local html5 = dofile(HTML5)

-- character -> the HTML5 names that expand to it.
local by_char = {}
for name, ch in pairs(html5) do
  by_char[ch] = by_char[ch] or {}
  table.insert(by_char[ch], name)
end

local names = ordered_names()
local is_org_name = {}
for _, n in ipairs(names) do
  is_org_name[n] = true
end

local function ascii_only(s)
  return s ~= "" and s:match("^[\32-\126]*$") ~= nil
end

local function pick_html(name, ch)
  if html5[name] == ch then
    return "&" .. name .. ";"
  end
  if ascii_only(ch) then
    local special = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }
    return (ch:gsub("[&<>]", special))
  end
  local cands = by_char[ch] or {}
  local function best(filter)
    local pick
    for _, c in ipairs(cands) do
      if filter(c) and (not pick or #c < #pick or (#c == #pick and c < pick)) then
        pick = c
      end
    end
    return pick
  end
  local alias = best(function(c)
    return is_org_name[c]
  end) or best(function(c)
    return c == c:lower()
  end) or best(function()
    return true
  end)
  if alias then
    return "&" .. alias .. ";"
  end
  local refs = {}
  for i, cp in ipairs(vim.fn.str2list(ch)) do
    refs[i] = string.format("&#x%X;", cp)
  end
  return table.concat(refs)
end

local entries, gaps = {}, {}
for _, name in ipairs(names) do
  local cur = CURATED[name] or {}
  local w = w3c[name]
  local utf8 = cur.utf8 or html5[name] or (w and w.utf8)
  local latex, math = cur.latex, cur.math
  if not latex and w then
    latex = w.latex
    if not latex then
      latex, math = w.mathlatex, true
    end
  end
  if math == nil then
    math = w and w.mode == "math" or false
  end
  if not utf8 or not latex then
    gaps[#gaps + 1] = name
  else
    if not math and latex:match("^\\%a+$") then
      latex = latex .. "{}"
    end
    local ascii = cur.ascii
    if not ascii then
      if ascii_only(utf8) then
        ascii = utf8
      elseif w and w.base and w.base:match("%a") then
        ascii = w.base
      else
        ascii = name
      end
    end
    entries[#entries + 1] = {
      name = name,
      latex = latex,
      math = math,
      html = cur.html or pick_html(name, utf8),
      ascii = ascii,
      utf8 = utf8,
    }
  end
end

table.sort(entries, function(a, b)
  return a.name < b.name
end)

local function q(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local o = assert(io.open(OUT, "w"))
o:write([[
-- Org entity names -> their LaTeX, HTML, plain-ASCII and UTF-8 forms.
-- Generated by scripts/gen-org-entities.lua; regenerate with that script
-- rather than editing here.
--
-- Provenance: characters come from the WHATWG HTML5 named character
-- reference list (via lua/organ/ast/html5_entities.lua) and from unicode.xml
-- of the W3C note "XML Entity Definitions for Characters", which also
-- supplies the LaTeX and math-LaTeX forms, the text/math mode and the
-- canonical decompositions the ASCII column falls back to.  The entity names
-- and the entries neither source carries are listed in the generator.
--
-- `latex` is the LaTeX form and `math` says whether it needs math mode;
-- `html` is a named character reference where one exists for the character
-- and a numeric one otherwise; `ascii` is a plain-ASCII fallback.
]])
o:write("return {\n")
for _, e in ipairs(entries) do
  o:write(
    string.format(
      "  [%s] = { latex = %s, math = %s, html = %s, ascii = %s, utf8 = %s },\n",
      q(e.name),
      q(e.latex),
      tostring(e.math),
      q(e.html),
      q(e.ascii),
      q(e.utf8)
    )
  )
end
o:write("}\n")
o:close()

local styled = vim.system({ "stylua", OUT }):wait()
if styled.code ~= 0 then
  error("stylua failed on " .. OUT .. ": " .. (styled.stderr or ""))
end

print(string.format("wrote %d entities to %s", #entries, OUT))
if #gaps > 0 then
  print("unsourced: " .. table.concat(gaps, " "))
end
