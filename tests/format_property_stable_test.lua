-- Property drawer lines that organ WRITES must survive the formatter
-- byte-for-byte.  The writer (organ.property.format_line, used by roam
-- headers, :ID: insertion, org-set-property, ...) reproduces Emacs
-- `org-property-format` ("%-10s %s"), ground-truthed against GNU Emacs
-- 30.1 / org 9.7.11:
--
--   :ID:       abc        (key < 10 cols -> value at column 12)
--   :CATEGORY: work       (key = 10 cols -> value at column 12)
--   :ROAM_EXCLUDE: t      (key > 10 cols -> one space, no alignment)
--
-- The formatter's drawer-value alignment must produce the SAME thing, so
-- saving a freshly-written roam file (or any org-set-property result)
-- doesn't shuffle the columns.  Emacs formats each property line
-- independently -- it does NOT align every value to the widest key in the
-- drawer.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local fmt = require("organ.format")
local note = require("organ.roam.note")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function eq_lines(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- 1. The roam file header is a formatter fixpoint (the exact bug report:
--    <M-CR> writes a header, save must not move the :ID:).
do
  local header = note.header("A1B2C3D4-1111-2222-3333-444455556666", "My New Note")
  local formatted = fmt.format_lines(vim.deepcopy(header))
  check(
    "roam header survives format_lines byte-for-byte",
    eq_lines(header, formatted),
    ("header=%s\n     formatted=%s"):format(vim.inspect(header), vim.inspect(formatted))
  )
end

-- 2. A lone :ID: drawer keeps its 7-space org-property-format alignment
--    (dynamic max-key alignment would collapse it to one space).
do
  local input = { ":PROPERTIES:", ":ID:       the-id", ":END:" }
  local out = fmt.format_lines(vim.deepcopy(input))
  check(
    "lone :ID: stays 7-space aligned",
    out[2] == ":ID:       the-id",
    "got [" .. tostring(out[2]) .. "]"
  )
end

-- 3. Multi-property drawer: each line is org-property-format independently
--    (values are NOT aligned to the widest key -- matches Emacs).
do
  local input = {
    ":PROPERTIES:",
    ":ID:       the-id",
    ":CATEGORY: work",
    ":ROAM_EXCLUDE: t",
    ":END:",
  }
  local out = fmt.format_lines(vim.deepcopy(input))
  check(
    "multi: :ID: -> value at col 12",
    out[2] == ":ID:       the-id",
    "got [" .. tostring(out[2]) .. "]"
  )
  check(
    "multi: :CATEGORY: -> value at col 12",
    out[3] == ":CATEGORY: work",
    "got [" .. tostring(out[3]) .. "]"
  )
  check(
    "multi: :ROAM_EXCLUDE: -> one space",
    out[4] == ":ROAM_EXCLUDE: t",
    "got [" .. tostring(out[4]) .. "]"
  )
end

-- 4. The formatter re-aligns a mis-written (tight) property line up to the
--    org-property-format column, so it converges to the writer's form.
do
  local input = { ":PROPERTIES:", ":ID: tight", ":END:" }
  local out = fmt.format_lines(vim.deepcopy(input))
  check(
    "tight :ID: is re-aligned to 7 spaces",
    out[2] == ":ID:       tight",
    "got [" .. tostring(out[2]) .. "]"
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_property_stable_test: PASS")
os.exit(0)
