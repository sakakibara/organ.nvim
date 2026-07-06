-- Pills render as ROUNDED badges: a reversed body plus Nerd Font half-circle
-- caps overlaid on the spaces flanking the keyword.  Also guards the fix for
-- the reverse-dropped bug (the body group must carry gui reverse, which
-- nvim_set_hl silently drops when combined with `link`), and box mode
-- (modern.pill_caps = false) which omits the caps.
--
-- Run via: nvim --headless -l tests/pills_rounded_caps_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Give the actionable bucket a known color so we can assert the pill uses it.
vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xEE1122 })
require("organ").setup({
  modern = { pills = true },
  todo = { sequence = { "TODO", "|", "DONE" } },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local pills = require("organ.modern.pills")
local NS = vim.api.nvim_create_namespace("organ_modern_pills")

local function setup_buf()
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* TODO Buy milk" })
  vim.bo[b].filetype = "org"
  pcall(vim.treesitter.start, b, "org")
  return b
end

-- Rounded caps: `* TODO Buy milk` -> left cap on col 1 (space after `*`),
-- body over TODO (cols 2-5), right cap on col 6 (space before title).
-- _apply registers the pill highlight groups (via on_win) as a side effect.
do
  local b = setup_buf()
  pills._apply(b)

  -- Body group: gui reverse actually applied (the bug fix), colored from the
  -- keyword's semantic bucket.
  local hl = vim.api.nvim_get_hl(0, { name = "@organ.modern.pill.todo", link = false })
  check("body group has gui reverse=true", hl.reverse == true, vim.inspect(hl))
  check("body group colored from actionable bucket (red)", hl.fg == 0xEE1122, vim.inspect(hl))
  local capg = vim.api.nvim_get_hl(0, { name = "@organ.modern.pillcap.todo", link = false })
  check("cap group shares the body color, no reverse", capg.fg == 0xEE1122 and not capg.reverse, vim.inspect(capg))

  local marks = vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, { details = true })
  local body, left_cap, right_cap
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.hl_group == "@organ.modern.pill.todo" then
      body = m
    elseif d.virt_text and d.virt_text_pos == "overlay" then
      if m[3] == 1 then
        left_cap = d
      elseif m[3] == 6 then
        right_cap = d
      end
    end
  end
  check("body extmark over the keyword", body ~= nil and body[3] == 2 and body[4].end_col == 6)
  check("left cap overlaid on the space before the keyword", left_cap ~= nil, "no left cap at col 1")
  check("right cap overlaid on the space after the keyword", right_cap ~= nil, "no right cap at col 6")
  check(
    "caps colored like the body",
    left_cap and left_cap.virt_text[1][2] == "@organ.modern.pillcap.todo",
    left_cap and vim.inspect(left_cap.virt_text)
  )
end

-- Box mode: modern.pill_caps = false -> body only, no cap extmarks.
do
  local b = setup_buf()
  require("organ.buf_config").set(b, "modern.pill_caps", false)
  pills._apply(b)
  local caps = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, { details = true })) do
    if m[4].virt_text then
      caps = caps + 1
    end
  end
  check("box mode emits no caps", caps == 0, "got " .. caps .. " cap marks")
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("pills_rounded_caps_test: PASS")
os.exit(0)
