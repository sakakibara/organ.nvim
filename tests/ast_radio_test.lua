-- Radio matching core: collect_targets + build_matcher.
-- Run via: nvim --headless -l tests/ast_radio_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local A = require("organ.ast.init")
local radio = require("organ.ast.radio")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

-- collect_targets: dedupe (case-insensitive), sort longest-first.
do
  local doc = A.document({
    A.paragraph({
      A.radio_target("lead"),
      A.radio_target("Lead"),
      A.radio_target("lead developer"),
    }),
  })
  local t = radio.collect_targets(doc)
  check(#t == 2, "collect: deduped case-insensitively to 2")
  check(t[1] == "lead developer", "collect: longest first")
end

-- a whitespace-only / empty target is skipped (it would otherwise build an
-- empty pattern and zero-width match, looping the splitter forever).
do
  local doc = A.document({ A.paragraph({ A.radio_target("   "), A.radio_target("") }) })
  check(#radio.collect_targets(doc) == 0, "collect: whitespace-only target skipped")
end

-- matcher rules.
do
  local m = radio.build_matcher({ "lead developer", "lead" })
  local s1, e1, p1 = m("the lead developer spoke")
  check(p1 == "lead developer" and s1 == 5 and e1 == 18, "match: longest at position, boundaries")
  local _, _, p2 = m("MY LEAD here")
  check(p2 == "lead", "match: case-insensitive")
  check(m("misleading text") == nil, "match: no match inside a word (misleading)")
  check(m("leads the team") == nil, "match: no match inside a word (leads)")
  local s3, e3, p3 = m("the lead\ndeveloper wrote")
  check(p3 == "lead developer", "match: internal whitespace flexible (newline)")
end

-- resolve: split matching text into radio links, respecting scope.
local function deep_eq(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

do
  -- plain occurrence after a definition -> radio link present.
  local doc = A.document({
    A.paragraph({ A.radio_target("foo"), A.text(" see foo now") }),
  })
  local inl = (radio.resolve(doc)).children[1].inline
  local link = nil
  for _, n in ipairs(inl) do
    if n.kind == "link" and n.form == "radio" then
      link = n
    end
  end
  check(
    link ~= nil and link.target == "foo" and link.description[1].text == "foo",
    "resolve: occurrence becomes a radio link"
  )
end

do
  -- inside *bold* gets linked; inside =verbatim= does not.
  local doc = A.document({
    A.paragraph({
      A.radio_target("foo"),
      A.text(" "),
      A.emphasis("bold", { A.text("foo") }),
      A.text(" "),
      A.emphasis("verbatim", { A.text("foo") }),
    }),
  })
  local inl = (radio.resolve(doc)).children[1].inline
  check(inl[3].content[1].kind == "link", "resolve: phrase inside bold is linked")
  check(
    inl[5].content[1].kind == "text" and inl[5].content[1].text == "foo",
    "resolve: phrase inside verbatim is NOT linked"
  )
end

do
  -- existing link description not re-linkified; definition not self-linked.
  local doc = A.document({
    A.paragraph({
      A.radio_target("foo"),
      A.text(" "),
      A.link("http://x", { A.text("foo") }),
    }),
  })
  local inl = (radio.resolve(doc)).children[1].inline
  check(inl[1].kind == "radio_target", "resolve: definition node left intact")
  check(
    inl[3].kind == "link" and inl[3].description[1].kind == "text",
    "resolve: existing link description not re-linkified"
  )
end

do
  -- a sibling field (affiliated) on a paragraph/list is preserved.
  local para = A.paragraph({ A.radio_target("foo"), A.text(" foo x") })
  para.affiliated = { { name = "CAPTION", value = "cap" } }
  local out = radio.resolve(A.document({ para }))
  check(out.children[1].affiliated[1].value == "cap", "resolve: affiliated preserved on paragraph")
end

do
  -- a phrase inside a footnote-definition body is linkified too.
  local doc = A.document({
    A.paragraph({ A.radio_target("foo") }),
    A.footnote_definition("1", { A.paragraph({ A.text("see foo here") }) }),
  })
  local fn = radio.resolve(doc).children[2]
  local linked = false
  for _, b in ipairs(fn.content[1].inline) do
    if b.kind == "link" and b.form == "radio" then
      linked = true
    end
  end
  check(linked, "resolve: phrase inside a footnote definition is linked")
end

do
  -- no targets -> unchanged; idempotent.
  local plain = A.document({ A.paragraph({ A.text("no targets here") }) })
  check(deep_eq(radio.resolve(plain), plain), "resolve: no targets is a no-op")
  local doc = A.document({ A.paragraph({ A.radio_target("foo"), A.text(" foo x") }) })
  local once = radio.resolve(doc)
  local twice = radio.resolve(once)
  check(deep_eq(twice, once), "resolve: idempotent")
end

-- normalize_targets: dedupe (case-insensitive), drop blank, longest-first.
do
  local got = radio.normalize_targets({ "lead", "Lead", "  ", "", "lead developer" })
  check(#got == 2, "normalize: blanks dropped + deduped to 2")
  check(got[1] == "lead developer" and got[2] == "lead", "normalize: longest-first")
end

print("ALL PASS: ast_radio (core)")
