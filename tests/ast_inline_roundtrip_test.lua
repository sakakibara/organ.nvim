-- Inline-object semantic capture: org -> from_org -> AST -> to_org -> org
-- must lose nothing, and each construct must be a typed node (not flat
-- text). assert_roundtrip checks the second-pass AST equals the first.
-- Run via: nvim --headless -l tests/ast_inline_roundtrip_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_org = require("organ.ast.from_org")
local to_org = require("organ.ast.to_org")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

local function lines_of(s)
  return vim.split(s, "\n", { plain = true })
end

local function deep_eq(a, b, path)
  if type(a) ~= type(b) then
    return false, path .. ": type " .. type(a) .. " vs " .. type(b)
  end
  if type(a) ~= "table" then
    if a ~= b then
      return false, path .. ": " .. tostring(a) .. " vs " .. tostring(b)
    end
    return true
  end
  for k, v in pairs(a) do
    local ok, why = deep_eq(v, b[k], path .. "." .. tostring(k))
    if not ok then
      return false, why
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false, path .. "." .. tostring(k) .. ": missing in first"
    end
  end
  return true
end

local function assert_roundtrip(lines, label)
  local ast1 = from_org.from_lines(lines)
  local rendered = to_org.render(ast1)
  local ast2 = from_org.from_lines(lines_of(rendered))
  local ok, why = deep_eq(ast1, ast2, "ast")
  if not ok then
    print("---- rendered ----\n" .. rendered .. "---- divergence: " .. tostring(why))
  end
  check(ok, label)
end

-- Inline nodes of the first paragraph in a parsed snippet.
local function inline_of(lines)
  local doc = from_org.from_lines(lines)
  for _, c in ipairs(doc.children or {}) do
    if c.kind == "paragraph" then
      return c.inline
    end
  end
  return {}
end

-- Find the first inline node of a given kind (deep walk).
local function first_kind(nodes, kind)
  for _, n in ipairs(nodes or {}) do
    if n.kind == kind then
      return n
    end
    local nested = first_kind(n.content or n.description, kind)
    if nested then
      return nested
    end
  end
  return nil
end

-- entity ------------------------------------------------------------
do
  local n = first_kind(inline_of({ "caf\\'e and \\copy here." }), "entity")
  check(n ~= nil, "entity: captured as typed node")
  assert_roundtrip({ "caf\\'e and \\copy here." }, "entity: round-trips")
end

-- subscript / superscript -------------------------------------------
do
  local sub = first_kind(inline_of({ "x_{ij} value" }), "subscript")
  check(sub ~= nil, "subscript: captured")
  assert_roundtrip({ "x_{ij} value" }, "subscript: round-trips")
  local sup = first_kind(inline_of({ "E^{2} value" }), "superscript")
  check(sup ~= nil, "superscript: captured")
  assert_roundtrip({ "E^{2} value" }, "superscript: round-trips")
end

-- statistics cookie -------------------------------------------------
do
  local n = first_kind(inline_of({ "Progress [1/3] today" }), "statistics_cookie")
  check(n ~= nil and n.value == "[1/3]", "statistics_cookie: value captured")
  assert_roundtrip({ "Progress [1/3] today" }, "statistics_cookie [1/3]: round-trips")
  assert_roundtrip({ "Progress [50%] today" }, "statistics_cookie [50%]: round-trips")
end

-- timestamp ---------------------------------------------------------
do
  local n = first_kind(inline_of({ "Meeting <2026-06-14 Sun> soon" }), "timestamp")
  check(n ~= nil and n.variant == "active", "timestamp: active variant captured")
  assert_roundtrip({ "Meeting <2026-06-14 Sun> soon" }, "timestamp active: round-trips")
  assert_roundtrip({ "Logged [2026-06-14 Sun] entry" }, "timestamp inactive: round-trips")
end

-- target ------------------------------------------------------------
do
  local n = first_kind(inline_of({ "Jump <<here>> now" }), "target")
  check(n ~= nil and n.name == "here", "target: name captured")
  assert_roundtrip({ "Jump <<here>> now" }, "target: round-trips")
end

-- macro -------------------------------------------------------------
do
  local n = first_kind(inline_of({ "Color {{{c(red,bold)}}} text" }), "macro")
  check(
    n ~= nil and n.name == "c" and n.args[1] == "red" and n.args[2] == "bold",
    "macro: name+args captured"
  )
  assert_roundtrip({ "Color {{{c(red,bold)}}} text" }, "macro with args: round-trips")
  assert_roundtrip({ "Bare {{{plain}}} macro" }, "macro no args: round-trips")
end

-- footnotes ---------------------------------------------------------
do
  local named = first_kind(inline_of({ "Cite [fn:1] here" }), "footnote_ref")
  check(named ~= nil and named.label == "1" and named.content == nil, "footnote: named label only")
  assert_roundtrip({ "Cite [fn:1] here" }, "footnote named: round-trips")
  local anon = first_kind(inline_of({ "Note [fn::anon body] here" }), "footnote_ref")
  check(
    anon ~= nil and anon.label == nil and anon.content ~= nil,
    "footnote: anonymous body captured"
  )
  assert_roundtrip({ "Note [fn::anon body] here" }, "footnote anonymous: round-trips")
  assert_roundtrip({ "Note [fn:lbl:inline body] here" }, "footnote inline-named: round-trips")
end

-- nested emphasis (the regression this fixes) -----------------------
do
  local inl = inline_of({ "This is *bold /italic/ end* text" })
  local bold = first_kind(inl, "emphasis")
  check(bold ~= nil and bold.style == "bold", "emphasis: outer bold captured")
  local inner = first_kind(bold.content, "emphasis")
  check(inner ~= nil and inner.style == "italic", "emphasis: italic nested inside bold")
  assert_roundtrip({ "This is *bold /italic/ end* text" }, "nested emphasis: round-trips")
end

-- math delimiter families -------------------------------------------
do
  assert_roundtrip({ "Inline $x=1$ math" }, "math dollar inline: round-trips")
  assert_roundtrip({ "Display $$x=1$$ math" }, "math dollar display: round-trips")
  assert_roundtrip({ "Alt \\(x=1\\) math" }, "math paren: round-trips")
  assert_roundtrip({ "Alt \\[x=1\\] math" }, "math bracket: round-trips")
end

-- catch-all: untyped construct survives as raw_inline ---------------
do
  local n = first_kind(inline_of({ "Snippet @@html:<br>@@ here" }), "raw_inline")
  check(n ~= nil, "raw_inline: export snippet preserved as raw_inline")
  assert_roundtrip({ "Snippet @@html:<br>@@ here" }, "export snippet: round-trips")
end

-- mixed line: many objects in one paragraph -------------------------
do
  assert_roundtrip(
    { "x_{i} \\copy [1/3] <<t>> {{{m(a)}}} [fn::b] *bold* end" },
    "mixed inline line: round-trips"
  )
end

-- non-braced superscript must not recurse infinitely (regression) -----
do
  local n = first_kind(inline_of({ "value x^2 here" }), "superscript")
  check(n ~= nil, "superscript non-braced: captured (no stack overflow)")
  assert_roundtrip({ "value x^2 here" }, "superscript non-braced: round-trips")
end

print("ALL PASS: ast_inline_roundtrip")
