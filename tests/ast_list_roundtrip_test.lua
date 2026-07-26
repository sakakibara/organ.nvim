-- List-item detail capture: org -> from_org -> AST -> to_org -> org
-- loses nothing, and bullet/counter/checkbox/tag/nesting are typed.
-- Run via: nvim --headless -l tests/ast_list_roundtrip_test.lua
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

local function first_list(lines)
  local doc = from_org.from_lines(lines)
  local function find(n)
    if n.kind == "list" then
      return n
    end
    for _, c in ipairs(n.children or n.content or {}) do
      local r = find(c)
      if r then
        return r
      end
    end
    return nil
  end
  return find(doc)
end

-- Bullet markers
do
  -- `-` and `+` are valid unordered bullets at column 0. `*` is a
  -- headline at column 0, so it is only a list bullet when indented;
  -- it is exercised via the nested-list cases below.
  for _, m in ipairs({ "-", "+" }) do
    local l = first_list({ m .. " item" })
    check(l ~= nil and l.items[1].marker == m, "marker captured: " .. m)
    assert_roundtrip({ m .. " item" }, "marker round-trips: " .. m)
  end
  -- `*` bullet as an indented sub-list under a `-` parent.
  local nested = first_list({ "- parent", "  * starred" })
  local inner
  for _, b in ipairs(nested.items[1].content or {}) do
    if b.kind == "list" then
      inner = b
    end
  end
  check(inner ~= nil and inner.items[1].marker == "*", "marker captured: * (nested)")
  assert_roundtrip({ "- parent", "  * starred" }, "marker round-trips: * (nested)")
end

-- Ordered separators + non-1 start
do
  local dot = first_list({ "1. item" })
  check(dot ~= nil and dot.items[1].marker == "1.", "ordered dot marker")
  assert_roundtrip({ "1. item" }, "ordered dot round-trips")
  local paren = first_list({ "1) item" })
  check(paren ~= nil and paren.items[1].marker == "1)", "ordered paren marker")
  assert_roundtrip({ "1) item" }, "ordered paren round-trips")
  assert_roundtrip({ "3. third" }, "non-1 start round-trips")
end

-- Checkbox
do
  local l = first_list({ "- [ ] todo", "- [X] done", "- [-] part" })
  check(
    l.items[1].checkbox == "todo"
      and l.items[2].checkbox == "done"
      and l.items[3].checkbox == "part",
    "checkbox states captured"
  )
  assert_roundtrip({ "- [ ] todo", "- [X] done", "- [-] part" }, "checkbox round-trips")
  assert_roundtrip({ "1. [X] done" }, "ordered + checkbox round-trips")
end

-- Counter
do
  local l = first_list({ "1. [@5] text" })
  check(l ~= nil and l.items[1].counter == "5", "counter captured")
  assert_roundtrip({ "1. [@5] text" }, "counter round-trips")
end

-- Description tag
do
  local l = first_list({ "- term :: definition" })
  check(l ~= nil and l.items[1].tag ~= nil, "description tag captured")
  assert_roundtrip({ "- term :: definition" }, "description tag round-trips")
  assert_roundtrip({ "- *bold* term :: def" }, "description tag with markup round-trips")
end

-- Nested lists (the data-loss regression)
do
  local l = first_list({ "- a", "  - nested", "- b" })
  check(l ~= nil and #l.items == 2, "outer list has 2 items")
  local has_nested = false
  for _, b in ipairs(l.items[1].content or {}) do
    if b.kind == "list" then
      has_nested = true
    end
  end
  check(has_nested, "nested list captured in first item content")
  assert_roundtrip({ "- a", "  - nested", "- b" }, "nested list round-trips")
  assert_roundtrip({ "- a", "  - b", "    - c" }, "two-level nesting round-trips")
end

-- Multi-line item content + flat regression
do
  assert_roundtrip({ "- a", "  continued" }, "multi-line item round-trips")
  assert_roundtrip({ "- one", "- two", "- three" }, "flat unordered round-trips")
  assert_roundtrip({ "1. one", "2. two" }, "flat ordered round-trips")
end

-- Regression: combined + list under a headline
do
  -- counter + checkbox on one ordered item
  assert_roundtrip({ "1. [@3] [X] done with counter" }, "regression: counter + checkbox")
  -- list nested under a headline section
  assert_roundtrip({ "* Heading", "- a", "  - nested", "- b" }, "regression: list under headline")
  -- mixed bullets keep their own marker per item
  local l = first_list({ "- dash", "+ plus" })
  check(
    l.items[1].marker == "-" and l.items[2].marker == "+",
    "regression: per-item markers preserved"
  )
  assert_roundtrip({ "- dash", "+ plus" }, "regression: mixed bullets round-trip")
end

-- Regression: a content-less item is not dropped
do
  local l = first_list({ "- a", "- term ::", "- b" })
  check(l ~= nil and #l.items == 3, "content-less middle item survives in AST")
  assert_roundtrip({ "- a", "- term ::", "- b" }, "content-less description item round-trips")
end

print("ALL PASS: ast_list_roundtrip")
