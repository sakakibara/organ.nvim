-- Unit test for the modern.bullets provider via organ.decoration.
--
-- Verifies that loading organ.modern.bullets registers a decoration
-- provider, the per-buffer row cache is built from on_lines via the
-- tree-sitter headline walk + line scan, and on_line emits the right
-- conceal extmarks for each row (heading bullets, list markers,
-- checkboxes).  Ephemeral marks placed by on_line aren't visible to
-- nvim_buf_get_extmarks outside the real frame-rendering context, so
-- the assertions go through _apply, which shares build_cache with
-- on_lines but writes non-ephemeral marks.
--
-- Run via: nvim --headless -l tests/decoration_modern_bullets_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  modern = { bullets = true },
})
-- Loading the module triggers its top-level decoration.register({...}).
require("organ.modern.bullets")

local decoration = require("organ.decoration")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local providers, _ = decoration._providers()
check("modern_bullets provider registered", providers.modern_bullets ~= nil)
check("provider exposes ns", providers.modern_bullets and providers.modern_bullets.ns ~= nil)
check(
  "provider exposes on_lines + on_line",
  providers.modern_bullets
    and type(providers.modern_bullets.on_lines) == "function"
    and type(providers.modern_bullets.on_line) == "function"
)

-- Three-level nested headlines + list items + checkboxes.
local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Level one",
  "** Level two",
  "*** Level three",
  "- plain item",
  "+ alt-marker item",
  "- [ ] todo box",
  "- [X] done box",
  "- [-] half box",
})

decoration.attach(bufnr)
-- _apply rebuilds the cache + writes non-ephemeral marks so
-- nvim_buf_get_extmarks can see them.  The ephemeral path is exercised
-- by the real decoration-provider callback at frame time.
require("organ.modern.bullets")._apply(bufnr)

local NS = vim.api.nvim_create_namespace("organ_modern_bullets")
local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })

local by_row = {}
for _, m in ipairs(marks) do
  by_row[m[2]] = by_row[m[2]] or {}
  table.insert(by_row[m[2]], m)
end

local function row_conceals(row)
  local out = {}
  for _, m in ipairs(by_row[row] or {}) do
    table.insert(out, (m[4] or {}).conceal)
  end
  return out
end

local function row_has_conceal(row, ch)
  for _, m in ipairs(by_row[row] or {}) do
    if (m[4] or {}).conceal == ch then
      return true
    end
  end
  return false
end

-- Trailing-star glyph at each headline level (default cycle ◉ ○ ◈).
local function last_conceal(row)
  local rmarks = vim.deepcopy(by_row[row] or {})
  table.sort(rmarks, function(a, b)
    return a[3] < b[3]
  end)
  if #rmarks == 0 then
    return nil
  end
  return (rmarks[#rmarks][4] or {}).conceal
end

check("row 0 (* Level one): trailing star -> ◉", last_conceal(0) == "◉")
check("row 1 (** Level two): trailing star -> ○", last_conceal(1) == "○")
check("row 2 (*** Level three): trailing star -> ◈", last_conceal(2) == "◈")

-- Leading stars concealed as spaces.
local function space_conceal_count(row)
  local n = 0
  for _, c in ipairs(row_conceals(row)) do
    if c == " " then
      n = n + 1
    end
  end
  return n
end
check("row 1 (** Level two): 1 leading-star space conceal", space_conceal_count(1) == 1)
check("row 2 (*** Level three): 2 leading-star space conceals", space_conceal_count(2) == 2)

-- List item bullet glyph at the marker column.
local function has_conceal_at(row, col, ch)
  for _, m in ipairs(by_row[row] or {}) do
    local d = m[4] or {}
    if d.conceal == ch and m[3] == col and d.end_col == col + 1 then
      return true
    end
  end
  return false
end
check("row 3 (- plain): list bullet (•) at col 0", has_conceal_at(3, 0, "•"))
check("row 4 (+ alt): list bullet (•) at col 0", has_conceal_at(4, 0, "•"))

-- Checkboxes.
check("row 5 (- [ ]): TODO glyph (˟)", row_has_conceal(5, "˟"))
check("row 6 (- [X]): DONE glyph (✓)", row_has_conceal(6, "✓"))
check("row 7 (- [-]): HALF glyph (▣)", row_has_conceal(7, "▣"))

-- A buffer that is not org filetype should yield no decoration.
local plain = vim.api.nvim_create_buf(false, true)
vim.bo[plain].filetype = "text"
vim.api.nvim_buf_set_lines(plain, 0, -1, false, { "* not actually org", "- not a list either" })
decoration.attach(plain)
require("organ.modern.bullets")._apply(plain)
local plain_marks = vim.api.nvim_buf_get_extmarks(plain, NS, 0, -1, {})
check("non-org buffer: no marks", #plain_marks == 0)

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.api.nvim_buf_delete(plain, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_modern_bullets_test: PASS")
os.exit(0)
