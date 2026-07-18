-- Emacs parity: list repair (whole-structure normalization).
--
-- `org-list-repair` rebuilds the list struct at point and rewrites the
-- WHOLE structure: indentation (each item at its parent's indent +
-- parent bullet width), one bullet style per list (the first item's),
-- and numbering restarting at 1 unless an `[@N]` counter overrides
-- (honored on any member, not just the first).  organ's `list.repair`
-- targets the same semantics.  Probed against Emacs 30.2.
--
-- Run via: nvim --headless -l tests/parity_list_repair_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parity = dofile(root .. "/tests/_emacs_parity.lua")
parity.skip_if_no_emacs()

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local list = require("organ.list")

local function our_repair(input)
  local stripped, cursor = parity.parse_cursor(input)
  local b = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(stripped, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  list.repair(b, cursor[1])
  local out_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.api.nvim_buf_delete(b, { force = true })
  return table.concat(out_lines, "\n") .. "\n"
end

local cases = {
  {
    label = "renumber a flat ordered list",
    input = "3. <CURSOR>a\n7. b\n5. c\n",
  },
  {
    label = "normalize a misindented mixed structure",
    input = "1. one\n  3. <CURSOR>x\n  7. y\n   - z\n5. five\n",
  },
  {
    label = "renumber across a single blank (loose list)",
    input = "3. <CURSOR>a\n\n7. b\n",
  },
  {
    label = "honor an [@N] counter on a later member",
    input = "1. <CURSOR>one\n2. [@7] seven\n3. next\n",
  },
  {
    label = "unify a mixed-bullet sub-list to its first item's style",
    input = "- one\n  - <CURSOR>a\n  + b\n  1. c\n",
  },
  {
    label = "leave a canonical structure untouched",
    input = "1. one\n   1. <CURSOR>a\n   2. b\n2. two\n",
  },
  {
    label = "sibling runs severed by a paragraph number independently",
    input = "- parent\n  1. <CURSOR>one\n  2. two\n\n  para\n  1. uno\n  2. dos\n",
  },
  {
    label = "an unordered severed run keeps its bullets",
    input = "- parent\n  1. <CURSOR>one\n  2. two\n\n  para\n  - uno\n  - dos\n",
  },
}

for _, c in ipairs(cases) do
  local emacs_out = parity.run("list-repair", c.input)
  local our_out = our_repair(c.input)
  check(c.label, emacs_out == our_out, string.format("emacs=%q\n     ours= %q", emacs_out, our_out))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("parity_list_repair_test: PASS")
