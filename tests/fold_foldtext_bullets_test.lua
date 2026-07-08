-- A closed fold renders `foldtext`, not the real heading line, so the
-- conceal/overlay that `modern.bullets` and `stars.hide` place on OPEN
-- headings don't reach it.  emacs_foldtext must reproduce the star
-- treatment so a collapsed heading looks like an expanded one -- a
-- folded `*** Foo` shows the bullet/hidden-stars, not raw `***`.
--
-- Run via: nvim --headless -l tests/fold_foldtext_bullets_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})

local fold = require("organ.fold")

local G = require("organ.modern.glyphs")
local g1 = G.get("bullet.1") -- nerd (modern.nerd_font defaults true)
local g3 = G.get("bullet.3")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function foldtext_of(lines, foldstart, foldend, cfg_key, cfg_val)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  if cfg_key then
    require("organ.buf_config").set(b, cfg_key, cfg_val)
  end
  pcall(vim.treesitter.start, b, "org")
  vim.cmd("let v:foldstart = " .. foldstart)
  vim.cmd("let v:foldend = " .. foldend)
  local out = fold.foldtext()
  local parts = {}
  if type(out) == "table" then
    for _, seg in ipairs(out) do
      parts[#parts + 1] = seg[1]
    end
  else
    parts[1] = tostring(out)
  end
  return table.concat(parts)
end

-- 1. modern.bullets: a folded deep heading shows the per-level glyph, not
--    raw stars.
do
  local t = foldtext_of({ "*** Deep", "body 1", "body 2" }, 1, 3, "modern.bullets", true)
  check(
    "modern.bullets folded shows glyph, no raw stars",
    t == "  " .. g3 .. " Deep…",
    "[" .. t .. "]"
  )
end

-- 2. modern.bullets level 1 shows the first glyph, no leading spaces.
do
  local t = foldtext_of({ "* Top", "body" }, 1, 2, "modern.bullets", true)
  check("modern.bullets level-1 folded shows first glyph", t == g1 .. " Top…", "[" .. t .. "]")
end

-- 3. stars.hide: a folded deep heading shows (level-1) spaces + one star.
do
  local t = foldtext_of({ "*** Deep", "body" }, 1, 2, "stars.hide", true)
  check("stars.hide folded shows hidden stars", t == "  * Deep…", "[" .. t .. "]")
end

-- 4. stars.hide leaves a level-1 heading's single star intact.
do
  local t = foldtext_of({ "* Top", "body" }, 1, 2, "stars.hide", true)
  check("stars.hide level-1 folded keeps the star", t == "* Top…", "[" .. t .. "]")
end

-- 5. Neither mode on: raw stars are preserved (no regression).
do
  local t = foldtext_of({ "*** Deep", "body" }, 1, 2, nil, nil)
  check("no star mode: raw stars preserved", t == "*** Deep…", "[" .. t .. "]")
end

-- 6. modern.bullets with a tag block: the glyph replaces the stars AND the
--    tag block survives (exercises the tag-align rebuild path).
do
  local t = foldtext_of({ "* Foo :work:", "body" }, 1, 2, "modern.bullets", true)
  check(
    "modern.bullets folded keeps tags",
    t:match("^" .. vim.pesc(g1) .. " Foo") ~= nil and t:match(":work:$") ~= nil,
    "[" .. t .. "]"
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_foldtext_bullets_test: PASS")
os.exit(0)
