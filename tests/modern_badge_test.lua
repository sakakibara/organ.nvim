-- tests/modern_badge_test.lua
-- The shared badge primitive builds a reversed body group (NOT link+attr, so
-- gui reverse actually applies) + a matching solid cap group, and emits the
-- body over the range with INLINE caps that preserve the surrounding spaces.
-- Run via: nvim --headless -l tests/modern_badge_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})
local badge = require("organ.modern.badge")

local fails = 0
local function check(label, ok, detail)
  if ok then print("PASS  " .. label)
  else fails = fails + 1; print("FAIL  " .. label .. (detail and ("\n     " .. detail) or "")) end
end

-- groups(): reversed body with explicit fg (reverse actually applies), cap
-- shares the color without reverse.
vim.api.nvim_set_hl(0, "SomeColor", { fg = 0xEE1122 })
local body_hl, cap_hl = badge.groups("t1", "SomeColor")
check("returns body + cap group names", body_hl == "@organ.modern.badge.t1" and cap_hl == "@organ.modern.badgecap.t1")
local bh = vim.api.nvim_get_hl(0, { name = body_hl, link = false })
check("body has gui reverse=true", bh.reverse == true, vim.inspect(bh))
check("body colored from the source group", bh.fg == 0xEE1122)
local ch = vim.api.nvim_get_hl(0, { name = cap_hl, link = false })
check("cap shares color, no reverse", ch.fg == 0xEE1122 and not ch.reverse)

-- emit(): body extmark over [sc,ec) + inline caps at sc and ec.
local ns = vim.api.nvim_create_namespace("badge_test")
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* TODO Buy milk" })
badge.emit(ns, b, 0, 2, 6, { body_hl = body_hl, cap_hl = cap_hl, left_cap = "L", right_cap = "R" })
local marks = vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })
local body, left, right
for _, m in ipairs(marks) do
  local d = m[4]
  if d.hl_group == body_hl then body = m
  elseif d.virt_text and d.virt_text_pos == "inline" and m[3] == 2 then left = d
  elseif d.virt_text and d.virt_text_pos == "inline" and m[3] == 6 then right = d end
end
check("body extmark spans the range", body ~= nil and body[3] == 2 and body[4].end_col == 6)
check("left cap is INLINE at sc (preserves the space before)", left ~= nil, "no inline cap at col 2")
check("right cap is INLINE at ec (preserves the space after)", right ~= nil, "no inline cap at col 6")

-- Empty-string caps -> flat label (no cap extmarks).
local ns2 = vim.api.nvim_create_namespace("badge_test2")
badge.emit(ns2, b, 0, 2, 6, { body_hl = body_hl, cap_hl = cap_hl, left_cap = "", right_cap = "" })
local n_caps = 0
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns2, 0, -1, { details = true })) do
  if m[4].virt_text then n_caps = n_caps + 1 end
end
check("empty caps -> flat label (no cap marks)", n_caps == 0, "got " .. n_caps)

if fails > 0 then print("\nFAILED " .. fails .. " checks"); os.exit(1) end
print("\nmodern_badge_test: PASS"); os.exit(0)
