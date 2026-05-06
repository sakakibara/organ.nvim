-- Unit tests for capture.template — validation, key lookup, normalisation.
-- Run via: nvim --headless -l tests/capture_template_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local template = require("organ.capture.template")

-- 1. validate_all raises on missing name.
do
  local ok, err = pcall(template.validate_all, {
    { target = { kind = "file", path = "/tmp/x.org" }, body = "x" },
  })
  assert(not ok, "expected error on missing name")
  assert(err:find("name", 1, true), "err should mention 'name': " .. tostring(err))
end

-- 2. validate_all raises on missing target.
do
  local ok, err = pcall(template.validate_all, {
    { name = "X", body = "y" },
  })
  assert(not ok, "expected error on missing target")
  assert(err:find("target", 1, true), "err should mention 'target': " .. tostring(err))
end

-- 3. validate_all raises on unknown target.kind.
do
  local ok, err = pcall(template.validate_all, {
    { name = "X", target = { kind = "bogus", path = "/x" }, body = "y" },
  })
  assert(not ok)
  assert(
    err:find("target.kind", 1, true) or err:find("bogus", 1, true),
    "err should name the bad kind: " .. tostring(err)
  )
end

-- 4. validate_all raises on duplicate keys.
do
  local ok, err = pcall(template.validate_all, {
    { name = "A", key = "j", target = { kind = "file", path = "/a" }, body = "a" },
    { name = "B", key = "j", target = { kind = "file", path = "/b" }, body = "b" },
  })
  assert(not ok, "expected error on duplicate key")
  assert(err:find("duplicate", 1, true) or err:find("key", 1, true))
end

-- 5. validate_all accepts well-formed templates.
do
  template.validate_all({
    { name = "A", key = "a", target = { kind = "file", path = "/a" }, body = "x" },
    {
      name = "B",
      target = { kind = "file_headline", path = "/b", headline = "Inbox" },
      body = "y",
    },
    {
      name = "C",
      target = { kind = "file_olp", path = "/c", olp = { "X", "Y" } },
      body = "z",
    },
    { name = "D", target = { kind = "file_olp_datetree", path = "/d" }, body = "w" },
    {
      name = "E",
      target = {
        kind = "file_function",
        fn = function()
          return "/e", 1
        end,
      },
      body = "v",
    },
  })
end

-- 6. validate_all raises on missing target.fn for file_function.
do
  local ok, err = pcall(template.validate_all, {
    { name = "X", target = { kind = "file_function" }, body = "y" },
  })
  assert(not ok)
  assert(err:find("fn", 1, true) or err:find("file_function", 1, true))
end

-- 7. validate_all raises on missing target.headline for file_headline.
do
  local ok, err = pcall(template.validate_all, {
    { name = "X", target = { kind = "file_headline", path = "/x" }, body = "y" },
  })
  assert(not ok)
  assert(err:find("headline", 1, true))
end

-- 8. validate_all raises on missing target.olp for file_olp.
do
  local ok, err = pcall(template.validate_all, {
    { name = "X", target = { kind = "file_olp", path = "/x" }, body = "y" },
  })
  assert(not ok)
  assert(err:find("olp", 1, true))
end

-- 9. find_by_key returns matching template.
do
  local templates = {
    { name = "A", key = "a", target = { kind = "file", path = "/a" }, body = "x" },
    { name = "B", key = "b", target = { kind = "file", path = "/b" }, body = "y" },
  }
  local t = template.find_by_key(templates, "b")
  assert(t and t.name == "B", "expected B; got " .. tostring(t and t.name))
end

-- 10. find_by_key returns nil for unknown key.
do
  local templates = {
    { name = "A", key = "a", target = { kind = "file", path = "/a" }, body = "x" },
  }
  assert(template.find_by_key(templates, "z") == nil)
end

-- 11. normalise applies defaults.
do
  local n = template.normalise({
    name = "X",
    target = { kind = "file", path = "/x" },
    body = "y",
  })
  -- Default is 0 to match Emacs's org-capture-empty-lines-before
  -- (organ used to default to 1 for visual breathing room, but
  -- that inserted a stray blank between an empty-bodied parent
  -- headline and a child capture, surfacing as a fold artifact).
  assert(n.empty_lines_before == 0, "default empty_lines_before should be 0 (Emacs parity)")
  assert(n.empty_lines_after == 0)
  assert(n.prepend == false)
end

-- 12. normalise preserves explicit values.
do
  local n = template.normalise({
    name = "X",
    target = { kind = "file", path = "/x" },
    body = "y",
    empty_lines_before = 0,
    empty_lines_after = 2,
    prepend = true,
  })
  assert(n.empty_lines_before == 0)
  assert(n.empty_lines_after == 2)
  assert(n.prepend == true)
end

io.write("capture template ok\n")
os.exit(0)
