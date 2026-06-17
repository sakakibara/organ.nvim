-- Property-drawer line formatting parity with Emacs `org-property-format`
-- (default "%-10s %s"), ground-truthed against GNU Emacs 30.1 / org 9.7.11:
--
--   :ID:       abc        (key < 10 cols -> padded; :ID: gets 7 spaces)
--   :CREATED:  x          (:CREATED: is 9 cols -> 2 spaces)
--   :CATEGORY: work       (:CATEGORY: is exactly 10 cols -> 1 space)
--   :ROAM_EXCLUDE: t      (key > 10 cols -> 1 space, no truncation)
--   :FOO:                 (EMPTY value -> bare key, no padding/trailing ws)
--
-- Run via: nvim --headless -l tests/property_align_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, got, want)
  if got == want then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print(("FAIL  %s\n      want [%s]\n      got  [%s]"):format(label, want, got))
  end
end

local property = require("organ.property")

-- format_line(key, value) reproduces org-property-format exactly.
check("ID padded to 7 spaces", property.format_line("ID", "abc"), ":ID:       abc")
check("CREATED (9 cols) -> 2 spaces", property.format_line("CREATED", "x"), ":CREATED:  x")
check("CATEGORY (10 cols) -> 1 space", property.format_line("CATEGORY", "work"), ":CATEGORY: work")
check("long key (>10) -> 1 space", property.format_line("ROAM_EXCLUDE", "t"), ":ROAM_EXCLUDE: t")
check("empty value -> bare key", property.format_line("FOO", ""), ":FOO:")
check("empty value short key -> bare key", property.format_line("ID", ""), ":ID:")
check("value with spaces preserved", property.format_line("ID", "a b"), ":ID:       a b")

-- End-to-end: property.set writes the aligned form into an existing
-- (column-0) drawer.  Drawer indentation is a separate concern; this
-- isolates the colon-value alignment.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* A", ":PROPERTIES:", ":END:" })
  property.set(b, 1, "ID", "abc")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check("set: :ID: aligned (inserted before :END:)", lines[3], ":ID:       abc")
end

-- Replacing an existing key re-aligns it too.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* A", ":PROPERTIES:", ":ID: old", ":END:" })
  property.set(b, 1, "ID", "new")
  check(
    "set: replaced :ID: aligned",
    vim.api.nvim_buf_get_lines(b, 2, 3, false)[1],
    ":ID:       new"
  )
end

-- End-to-end: a second, longer key appends aligned; short value stays bare.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* A", ":PROPERTIES:", ":ID: a", ":END:" })
  property.set(b, 1, "CREATED", "2026-06-17")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check("set: appended :CREATED: aligned", lines[4], ":CREATED:  2026-06-17")
end

if fails > 0 then
  io.write(("FAILED %d checks\n"):format(fails))
  os.exit(1)
end
io.write("property align ok\n")
os.exit(0)
