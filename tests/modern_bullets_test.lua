-- org-modern bullets: leading stars concealed as spaces; trailing
-- star concealed with a level-indexed glyph from the configured cycle.
-- Run via: nvim --headless -l tests/modern_bullets_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  modern = { bullets = true },
})

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Level one",
  "** Level two",
  "*** Level three",
  "Some body text.",
  "**** Level four",
  "***** Level five (cycles back to level 1's glyph)",
})
vim.bo[bufnr].filetype = "org"
vim.api.nvim_set_current_buf(bufnr)

local bullets = require("organ.modern.bullets")
bullets.attach(bufnr)
vim.wait(50) -- drain deferred initial apply

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local NS = require("organ.modern.render").ns
check("namespace registered", NS ~= nil)

local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })

-- Group marks by row.
local by_row = {}
for _, m in ipairs(marks) do
  local row = m[2]
  by_row[row] = by_row[row] or {}
  table.insert(by_row[row], m)
end

-- Default glyph cycle: ◉ ○ ◈ ◇ — verify by reading the conceal char of
-- each row's LAST mark (the trailing-star → glyph one).
local function last_mark(row)
  local rmarks = by_row[row] or {}
  -- Sort by col so the highest-col mark is the trailing star.
  table.sort(rmarks, function(a, b)
    return a[3] < b[3]
  end)
  if #rmarks == 0 then
    return nil
  end
  return rmarks[#rmarks][4] or {}
end
local function last_conceal(row)
  local d = last_mark(row)
  return d and d.conceal
end

local G = require("organ.modern.glyphs")
check("row 0 (* Level one): level-1 glyph", last_conceal(0) == G.get("bullet.1", bufnr))
check("row 1 (** Level two): level-2 glyph", last_conceal(1) == G.get("bullet.2", bufnr))
check("row 2 (*** Level three): level-3 glyph", last_conceal(2) == G.get("bullet.3", bufnr))
check("row 3 (body text): no bullet", last_conceal(3) == nil)
check("row 4 (**** Level four): level-4 glyph", last_conceal(4) == G.get("bullet.4", bufnr))
check(
  "row 5 (***** Level five): cycles to level-1 glyph",
  last_conceal(5) == G.get("bullet.1", bufnr)
)

-- The bullet glyph is colored like the heading title (matches the folded
-- foldtext bullet); the concealed leading stars carry no highlight.
check(
  "row 2 bullet uses the level-3 title hl",
  (last_mark(2) or {}).hl_group == "@org.heading.title.3.org"
)
check(
  "row 0 bullet uses the level-1 title hl",
  (last_mark(0) or {}).hl_group == "@org.heading.title.1.org"
)

-- Each non-trailing star concealed as a single space.
local function leading_count_concealed(row)
  local rmarks = by_row[row] or {}
  table.sort(rmarks, function(a, b)
    return a[3] < b[3]
  end)
  local n = 0
  for i = 1, #rmarks - 1 do
    local d = rmarks[i][4] or {}
    if d.conceal == " " then
      n = n + 1
    end
  end
  return n
end

check("row 1 (** Level two): 1 leading-star space conceal", leading_count_concealed(1) == 1)
check("row 2 (*** Level three): 2 leading-star space conceals", leading_count_concealed(2) == 2)
check("row 4 (**** Level four): 3 leading-star space conceals", leading_count_concealed(4) == 3)

check("conceallevel >= 2 after attach", vim.wo.conceallevel >= 2)

-- detach() removes the marks.
bullets.detach(bufnr)
local after = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, {})
check("detach() clears marks", #after == 0)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_bullets_test: PASS")
