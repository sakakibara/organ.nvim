-- Visual auto-indent (org-indent-mode) adapts to star-hiding modes
-- and aligns body rows with the title text column.
--
-- Pins the dual formula:
--   heading_pad = (L-1) * shift           when stars render as literal `*`
--               = 0                       when modern.bullets or stars.hide
--   body_pad    = (L-1)*shift + L + 1     when stars render as literal `*`
--               = L + 1                   when modern.bullets or stars.hide
--
-- Body rows always align with the title text column of their enclosing
-- headline, so prose sits under the title rather than under the stars.
--
-- Run via: nvim --headless -l tests/indent_adaptive_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Build a fresh org buffer with `lines` and run indent.refresh under
-- the given config override.  Returns a map of 1-based row -> pad size
-- (number of leading virt-text spaces on that row).  An absent entry
-- means "no virt_text for that row".
local function compute_pads(lines, cfg_override)
  -- Reset organ + indent + decoration so each scenario gets a clean
  -- provider registry.  Without clearing decoration, the second call
  -- hits "provider 'indent' already registered" on indent.lua's
  -- top-level register({...}).
  package.loaded["organ"] = nil
  package.loaded["organ.indent"] = nil
  package.loaded["organ.decoration"] = nil
  require("organ").setup(vim.tbl_deep_extend("force", {
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    watcher = { enabled = false },
    indent = { shift_per_level = 2 },
    modern = { bullets = false },
    stars = { hide = false },
  }, cfg_override or {}))
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  local indent = require("organ.indent")
  indent.attach(b)
  indent.refresh(b)
  local marks = vim.api.nvim_buf_get_extmarks(b, indent._ns, 0, -1, { details = true })
  local pads = {}
  for _, m in ipairs(marks) do
    local row0 = m[2]
    local details = m[4]
    if details and details.virt_text then
      pads[row0 + 1] = #details.virt_text[1][1]
    end
  end
  indent.detach(b)
  vim.api.nvim_buf_delete(b, { force = true })
  return pads
end

-- Shared fixture: three nested headings with one body row each.
local LINES = {
  "* Level 1",
  "body of L1",
  "** Level 2",
  "body of L2",
  "*** Level 3",
  "body of L3",
}

-- 1. Literal stars (modern.bullets off, stars.hide off): classic
-- Emacs formula on headings, body aligned with title column.
do
  local p = compute_pads(LINES, { modern = { bullets = false }, stars = { hide = false } })
  check("literal stars: L1 heading has no pad", (p[1] or 0) == 0, "got " .. tostring(p[1]))
  check("literal stars: L1 body pad = 2", p[2] == 2, "got " .. tostring(p[2]))
  check("literal stars: L2 heading pad = 2", p[3] == 2, "got " .. tostring(p[3]))
  check("literal stars: L2 body pad = 5", p[4] == 5, "got " .. tostring(p[4]))
  check("literal stars: L3 heading pad = 4", p[5] == 4, "got " .. tostring(p[5]))
  check("literal stars: L3 body pad = 8", p[6] == 8, "got " .. tostring(p[6]))
end

-- 2. modern.bullets = true: heading rows take no virt-text pad
-- (the conceal provider supplies its own N-1 spaces), body rows align
-- with title at column L+2.
do
  local p = compute_pads(LINES, { modern = { bullets = true } })
  check("modern bullets: L1 heading has no pad", (p[1] or 0) == 0, "got " .. tostring(p[1]))
  check("modern bullets: L1 body pad = 2", p[2] == 2, "got " .. tostring(p[2]))
  check("modern bullets: L2 heading has no pad", (p[3] or 0) == 0, "got " .. tostring(p[3]))
  check("modern bullets: L2 body pad = 3", p[4] == 3, "got " .. tostring(p[4]))
  check("modern bullets: L3 heading has no pad", (p[5] or 0) == 0, "got " .. tostring(p[5]))
  check("modern bullets: L3 body pad = 4", p[6] == 4, "got " .. tostring(p[6]))
end

-- 3. modern.bullets passed as a table (truthy non-true value): same
-- behavior as bullets = true.
do
  local p = compute_pads(LINES, { modern = { bullets = { glyphs = { "A", "B", "C", "D" } } } })
  check("modern bullets (table): L1 heading has no pad", (p[1] or 0) == 0)
  check("modern bullets (table): L2 body pad = 3", p[4] == 3, "got " .. tostring(p[4]))
end

-- 4. stars.hide = true: identical pad behavior to modern.bullets.
do
  local p = compute_pads(LINES, { stars = { hide = true } })
  check("stars.hide: L1 heading has no pad", (p[1] or 0) == 0, "got " .. tostring(p[1]))
  check("stars.hide: L1 body pad = 2", p[2] == 2, "got " .. tostring(p[2]))
  check("stars.hide: L2 heading has no pad", (p[3] or 0) == 0, "got " .. tostring(p[3]))
  check("stars.hide: L2 body pad = 3", p[4] == 3, "got " .. tostring(p[4]))
  check("stars.hide: L3 heading has no pad", (p[5] or 0) == 0, "got " .. tostring(p[5]))
  check("stars.hide: L3 body pad = 4", p[6] == 4, "got " .. tostring(p[6]))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("indent_adaptive_test: PASS")
os.exit(0)
