-- Round-trip fidelity for headline & section metadata: org -> from_org ->
-- AST -> to_org -> org must lose nothing. assert_roundtrip checks the
-- second-pass AST equals the first; presence checks confirm from_org
-- actually captured the construct (round-trip equality alone cannot --
-- a construct dropped on BOTH passes would compare equal).
-- Run via: nvim --headless -l tests/ast_metadata_roundtrip_test.lua

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

-- Structural deep equality, key-order independent. Returns (true) or
-- (false, divergence-path-and-values) for debuggable failures.
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

-- Parse -> render -> re-parse; the two ASTs must match.
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

-- The first headline of a parsed snippet.
local function head(lines)
  return from_org.from_lines(lines).children[1]
end

-- planning ------------------------------------------------------------
do
  local src = {
    "* TODO Task",
    "SCHEDULED: <2026-06-14 Sun> DEADLINE: <2026-06-15 Mon> CLOSED: [2026-06-13 Sat 10:00]",
    "",
    "Body.",
  }
  local h = head(src)
  check(h.planning and h.planning.scheduled == "<2026-06-14 Sun>", "planning: scheduled captured")
  check(h.planning.deadline == "<2026-06-15 Mon>", "planning: deadline captured")
  check(h.planning.closed == "[2026-06-13 Sat 10:00]", "planning: closed captured")
  assert_roundtrip(src, "planning: round-trips")
end

-- properties ----------------------------------------------------------
do
  local src = {
    "* H",
    ":PROPERTIES:",
    ":ID: abc-1",
    ":Effort: 2:00",
    ":END:",
    "",
    "Body.",
  }
  local h = head(src)
  check(h.properties and h.properties.ID == "abc-1", "properties: ID captured")
  check(h.properties.EFFORT == "2:00", "properties: Effort captured (key upper-cased)")
  assert_roundtrip(src, "properties: round-trips")
end

-- generic drawers -----------------------------------------------------
do
  local src = {
    "* H",
    ":LOGBOOK:",
    "CLOCK: [2026-06-14 Sun 09:00]--[2026-06-14 Sun 10:00] => 1:00",
    "- a note",
    ":END:",
    "",
    "Body.",
  }
  local h = head(src)
  local dr
  for _, c in ipairs(h.children or {}) do
    if c.kind == "drawer" then
      dr = c
    end
  end
  check(dr ~= nil, "drawer: LOGBOOK captured as a drawer node")
  check(dr and dr.name == "LOGBOOK", "drawer: name is LOGBOOK")
  check(dr and dr.body:find("CLOCK:", 1, true) ~= nil, "drawer: body preserves CLOCK line")
  check(dr and dr.body:find("- a note", 1, true) ~= nil, "drawer: body preserves note line")
  assert_roundtrip(src, "drawer: LOGBOOK round-trips")
end

do
  local src = { "* H", ":NOTES:", "free text", "more text", ":END:", "", "Body." }
  assert_roundtrip(src, "drawer: custom :NOTES: round-trips")
end

-- comments ------------------------------------------------------------
do
  -- Line comments at top level (before any headline) flow through the
  -- same emit_section_child path.
  local src = { "# a comment", "# second line", "", "Body." }
  local doc = from_org.from_lines(src)
  local cm
  for _, c in ipairs(doc.children or {}) do
    if c.kind == "comment" then
      cm = c
    end
  end
  check(cm ~= nil, "comment: # line captured as a comment node")
  check(cm and cm.body:find("a comment", 1, true) ~= nil, "comment: body preserved")
  assert_roundtrip(src, "comment: # lines round-trip")
end

do
  local src = { "#+begin_comment", "block body 1", "block body 2", "#+end_comment", "", "Body." }
  local doc = from_org.from_lines(src)
  local cb
  for _, c in ipairs(doc.children or {}) do
    if c.kind == "block" and c.style == "comment" then
      cb = c
    end
  end
  check(cb ~= nil, "comment: #+begin_comment captured as block style=comment")
  check(cb and cb.body:find("block body 1", 1, true) ~= nil, "comment: block body preserved")
  assert_roundtrip(src, "comment: comment block round-trips")
end

-- combined + ordering -------------------------------------------------
do
  local src = {
    "* TODO Project :work:",
    "SCHEDULED: <2026-06-14 Sun>",
    ":PROPERTIES:",
    ":ID: p-1",
    ":END:",
    ":LOGBOOK:",
    "CLOCK: [2026-06-14 Sun 09:00]--[2026-06-14 Sun 10:00] => 1:00",
    ":END:",
    "",
    "Body paragraph.",
  }
  assert_roundtrip(src, "combined: planning + properties + logbook + body round-trips")
end

do
  -- Non-canonical source order (logbook before properties). from_org
  -- hoists properties to the headline regardless of position, so the AST
  -- is stable even though to_org re-emits in canonical order.
  local src = {
    "* H",
    ":LOGBOOK:",
    "CLOCK: [2026-06-14 Sun 09:00]",
    ":END:",
    ":PROPERTIES:",
    ":ID: x",
    ":END:",
    "",
    "Body.",
  }
  assert_roundtrip(src, "combined: non-canonical section order is AST-stable")
end

-- drawer edge shapes --------------------------------------------------
do
  -- Empty drawer (no inner lines) round-trips with an empty body.
  local src = { "* H", ":LOGBOOK:", ":END:", "", "Body." }
  local h = head(src)
  local dr
  for _, c in ipairs(h.children or {}) do
    if c.kind == "drawer" then
      dr = c
    end
  end
  check(dr ~= nil and dr.body == "", "drawer: empty drawer has empty body")
  assert_roundtrip(src, "drawer: empty drawer round-trips")
end

do
  -- Interior blank line inside a drawer body is preserved.
  local src = { "* H", ":NOTES:", "line one", "", "line three", ":END:", "", "Body." }
  assert_roundtrip(src, "drawer: interior blank line preserved")
end

-- regression: pre-existing constructs still round-trip ----------------
do
  assert_roundtrip(
    { "Para with *bold* and [[https://x][a link]].", "", "Next." },
    "regression: paragraph inline"
  )
  assert_roundtrip(
    { "#+begin_src lua", "print(1)", "#+end_src", "", "x" },
    "regression: code block"
  )
end

-- table separators ----------------------------------------------------
do
  -- Tree-sitter splits a table into one grammar node per separator line;
  -- merging the segments must not duplicate the separator (which would
  -- compound a new row on every render pass).
  assert_roundtrip(
    { "| a | b |", "|---+---|", "| 1 | 2 |", "", "x" },
    "table: interior separator is not duplicated on round-trip"
  )
end

-- src header-args -----------------------------------------------------
do
  local src = { "#+begin_src python :exports code :tangle no", "print(1)", "#+end_src", "", "x" }
  local doc = from_org.from_lines(src)
  local cb
  for _, c in ipairs(doc.children or {}) do
    if c.kind == "code_block" then
      cb = c
    end
  end
  check(cb ~= nil, "src: code_block captured")
  check(cb and cb.params == ":exports code :tangle no", "src: header-args captured in params")
  assert_roundtrip(src, "src: header-args round-trip")
end

print("ast_metadata_roundtrip_test: PASS")
