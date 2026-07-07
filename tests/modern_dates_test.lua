-- Dates renderer: conceals timestamp brackets, prefixes a calendar/clock
-- glyph, mutes the date text; active <...> vs inactive [...] differ by group.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "Number", { fg = 0xfab387 })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x6c7086 })
require("organ").setup({ modern = { dates = true }, todo = { sequence = { "TODO", "|", "DONE" } } })

local render = require("organ.modern.render")
local dates = require("organ.modern.dates")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local b = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "Body with <2025-07-06 Sun> active.",
  "Body with [2025-07-06 Sun] inactive.",
})
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
dates._apply(b)

local marks = vim.api.nvim_buf_get_extmarks(b, render.ns, 0, -1, { details = true })
local function on_row(row, pred)
  local hits = {}
  for _, m in ipairs(marks) do
    if m[2] == row and pred(m[4]) then
      hits[#hits + 1] = m
    end
  end
  return hits
end
local function conceal_count(row)
  return #on_row(row, function(d)
    return d.conceal ~= nil
  end)
end
local function glyph_hl(row)
  local h = on_row(row, function(d)
    return d.virt_text ~= nil
  end)
  return h[1] and h[1][4].virt_text[1][2]
end

check("active row conceals both brackets", conceal_count(0) == 2, "got " .. conceal_count(0))
check("active row prefixes a glyph", glyph_hl(0) ~= nil)
check("active row uses the active date group", glyph_hl(0) == "@organ.modern.date.active", "hl=" .. tostring(glyph_hl(0)))
check("inactive row uses the inactive date group", glyph_hl(1) == "@organ.modern.date.inactive",
  "hl=" .. tostring(glyph_hl(1)))

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_dates_test: PASS")
os.exit(0)
