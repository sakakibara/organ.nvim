-- Verify headline AST nodes carry planning + properties.
-- Run via: nvim --headless -l tests/ast_headline_planning_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local from_org = require("organ.ast.from_org")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- SCHEDULED only
do
  local lines = vim.split(
    [[
* TODO Standup
SCHEDULED: <2026-05-04 Mon 09:00-09:15>
]],
    "\n",
    { plain = true }
  )
  local ast = from_org.from_lines(lines)
  local h = ast.children[1]
  check("headline has planning", h.planning ~= nil, "got: " .. vim.inspect(h))
  check(
    "planning.scheduled matches",
    h.planning and h.planning.scheduled == "<2026-05-04 Mon 09:00-09:15>",
    "got: " .. vim.inspect(h.planning)
  )
  check("planning.deadline absent", h.planning and h.planning.deadline == nil)
end

-- DEADLINE only
do
  local lines = vim.split(
    [[
* TODO Project
DEADLINE: <2026-05-15 Fri>
]],
    "\n",
    { plain = true }
  )
  local ast = from_org.from_lines(lines)
  local h = ast.children[1]
  check(
    "DEADLINE captured",
    h.planning and h.planning.deadline == "<2026-05-15 Fri>",
    "got: " .. vim.inspect(h and h.planning)
  )
end

-- CLOSED
do
  local lines = vim.split(
    [[
* DONE Old task
CLOSED: [2026-05-01 Fri 12:00]
]],
    "\n",
    { plain = true }
  )
  local ast = from_org.from_lines(lines)
  local h = ast.children[1]
  check(
    "CLOSED captured",
    h.planning and h.planning.closed == "[2026-05-01 Fri 12:00]",
    "got: " .. vim.inspect(h and h.planning)
  )
end

-- Lowercase keyword: line-level recognition, no date binding
-- Emacs (org-element) recognizes a lowercase 'scheduled:' line as a
-- planning element but binds no :scheduled property to it -- only
-- exact-uppercase keywords bind dates.
do
  local lines = vim.split(
    [[
* TODO Water plants
scheduled: <2026-05-06 Wed>
]],
    "\n",
    { plain = true }
  )
  local ast = from_org.from_lines(lines)
  local h = ast.children[1]
  check(
    "lowercase 'scheduled:' binds no date",
    h.planning == nil or h.planning.scheduled == nil,
    "got: " .. vim.inspect(h.planning)
  )
end

-- property_drawer
do
  local lines = vim.split(
    [[
* H
:PROPERTIES:
:ID: abc-123
:CUSTOM_ID: alias
:END:
]],
    "\n",
    { plain = true }
  )
  local ast = from_org.from_lines(lines)
  local h = ast.children[1]
  check("headline has properties", h.properties ~= nil, "got: " .. vim.inspect(h))
  check(
    "properties.ID",
    h.properties and h.properties.ID == "abc-123",
    "got: " .. vim.inspect(h.properties)
  )
  check(
    "properties.CUSTOM_ID",
    h.properties and h.properties.CUSTOM_ID == "alias",
    "got: " .. vim.inspect(h.properties)
  )
end

-- Combined planning + properties + body
do
  local lines = vim.split(
    [[
* TODO Combined
SCHEDULED: <2026-05-04>
:PROPERTIES:
:ID: xyz
:END:
Body paragraph here.
]],
    "\n",
    { plain = true }
  )
  local ast = from_org.from_lines(lines)
  local h = ast.children[1]
  check(
    "combined: properties.ID",
    h.properties and h.properties.ID == "xyz",
    "got: " .. vim.inspect(h)
  )
  check("combined: planning.scheduled", h.planning and h.planning.scheduled == "<2026-05-04>")
  -- Body paragraph should still be in children (not consumed by planning/drawer).
  local has_body = false
  for _, c in ipairs(h.children or {}) do
    if c.kind == "paragraph" then
      has_body = true
    end
  end
  check("body paragraph present in headline children", has_body)
end

-- Headline without planning/properties has nil fields
do
  local lines = vim.split("* Just a heading\nbody.\n", "\n", { plain = true })
  local ast = from_org.from_lines(lines)
  local h = ast.children[1]
  check("planning nil when absent", h.planning == nil)
  check("properties nil when absent", h.properties == nil)
end

-- COMMENT keyword is not part of the title (org-element order:
-- todo -> priority -> COMMENT -> title)
do
  local lines = vim.split("* TODO [#A] COMMENT Title text\n", "\n", { plain = true })
  local ast = from_org.from_lines(lines)
  local h = ast.children[1]
  check(
    "COMMENT stripped from title",
    h.title[1] and h.title[1].text == "Title text",
    "got: " .. vim.inspect(h.title)
  )
end

-- "COMMENTARY..." is not the COMMENT keyword (strict equality
-- followed by whitespace only)
do
  local lines = vim.split("* TODO COMMENTARY notes\n", "\n", { plain = true })
  local ast = from_org.from_lines(lines)
  local h = ast.children[1]
  check(
    "'COMMENTARY...' is not stripped as COMMENT",
    h.title[1] and h.title[1].text == "COMMENTARY notes",
    "got: " .. vim.inspect(h.title)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_headline_planning_test: PASS")
os.exit(0)
