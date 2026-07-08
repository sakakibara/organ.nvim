-- Dates follow-up: planning-line (SCHEDULED:/DEADLINE:/CLOSED:) and clock
-- timestamps get the same treatment as body/headline stamps -- concealed
-- brackets, a calendar glyph (clock if timed), muted active/inactive color.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.api.nvim_set_hl(0, "Number", { fg = 0xfab387 })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x6c7086 })
require("organ").setup({ modern = { dates = true }, todo = { sequence = { "TODO", "|", "DONE" } } })

local render = require("organ.modern.render")
local dates = require("organ.modern.dates")
local G = require("organ.modern.glyphs")

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
  "* TODO Task",
  "  SCHEDULED: <2025-07-06 Sun>",
  "  CLOCK: [2025-07-06 Sun 09:00]",
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
local function glyph_chunk(row)
  local h = on_row(row, function(d)
    return d.virt_text ~= nil
  end)
  return h[1] and h[1][4].virt_text[1]
end

-- Planning line (SCHEDULED: <...>): active, no time -> calendar glyph.
check(
  "SCHEDULED timestamp conceals both brackets",
  conceal_count(1) == 2,
  "got " .. conceal_count(1)
)
local pg = glyph_chunk(1)
check(
  "SCHEDULED gets the calendar glyph",
  pg ~= nil and pg[1] == G.get("date.calendar", b) .. " ",
  "glyph=" .. (pg and vim.inspect(pg) or "nil")
)
check(
  "SCHEDULED uses the active date group",
  pg ~= nil and pg[2] == "@organ.modern.date.active",
  "hl=" .. (pg and tostring(pg[2]) or "nil")
)

-- Clock line (CLOCK: [... 09:00]): inactive, timed -> clock glyph.
check("CLOCK timestamp conceals both brackets", conceal_count(2) == 2, "got " .. conceal_count(2))
local cg = glyph_chunk(2)
check(
  "CLOCK gets the clock glyph (timed)",
  cg ~= nil and cg[1] == G.get("date.clock", b) .. " ",
  "glyph=" .. (cg and vim.inspect(cg) or "nil")
)
check(
  "CLOCK uses the inactive date group",
  cg ~= nil and cg[2] == "@organ.modern.date.inactive",
  "hl=" .. (cg and tostring(cg[2]) or "nil")
)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_dates_planning_test: PASS")
os.exit(0)
