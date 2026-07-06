-- A TODO keyword must never render in the same color as a heading level,
-- or a `** TODO Foo` is indistinguishable from a plain `** Foo`.
-- register() resolves each heading level's fg and, on collision, swaps the
-- TODO link for a distinct "attention" group.
-- Run via: nvim --headless -l tests/highlights_todo_collision_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local hl = require("organ.highlights")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function fg(name)
  return vim.api.nvim_get_hl(0, { name = name }).fg
end
-- Paint the 8 heading levels with explicit user colors.  register() links
-- @org.heading.N with `default = true`, so an explicit set wins and the
-- resolved fg is fully under the test's control.
local function paint_headings(palette)
  for i = 1, 8 do
    vim.api.nvim_set_hl(0, "@org.heading." .. i, { fg = palette[i] })
  end
end

-- 1. Collision: the default TODO-active color (WarningMsg) equals the
--    level-2 heading color.  register() must move it to a distinct group.
do
  paint_headings({ 0x100001, 0x100002, 0x100003, 0x100004, 0x100005, 0x100006, 0x100007, 0x100008 })
  vim.api.nvim_set_hl(0, "WarningMsg", { fg = 0x100002 }) -- == heading-2 -> collides
  vim.api.nvim_set_hl(0, "Error", { fg = 0xEE0011 }) -- a distinct candidate
  hl.register()
  check(
    "collision: TODO active link moved off WarningMsg",
    hl._todo_active_link ~= "WarningMsg",
    "link=" .. tostring(hl._todo_active_link)
  )
  check(
    "collision: TODO active color differs from heading-2",
    fg(hl._todo_active_link) ~= nil and fg(hl._todo_active_link) ~= 0x100002,
    "active=" .. tostring(fg(hl._todo_active_link))
  )
end

-- 2. No collision: the default color is distinct from every heading, so it
--    stays put (least surprising).
do
  paint_headings({ 0x200001, 0x200002, 0x200003, 0x200004, 0x200005, 0x200006, 0x200007, 0x200008 })
  vim.api.nvim_set_hl(0, "WarningMsg", { fg = 0x999999 }) -- distinct from headings
  hl.register()
  check(
    "no collision: keeps the default WarningMsg link",
    hl._todo_active_link == "WarningMsg",
    "link=" .. tostring(hl._todo_active_link)
  )
end

-- 3. The chosen active color is absent from the WHOLE heading palette.
do
  local pal = { 0xA00001, 0xA00002, 0xA00003, 0xA00004, 0xA00005, 0xA00006, 0xA00007, 0xA00008 }
  paint_headings(pal)
  vim.api.nvim_set_hl(0, "WarningMsg", { fg = 0xA00003 }) -- == heading-3
  vim.api.nvim_set_hl(0, "Error", { fg = 0xBB00CC }) -- distinct from every heading
  hl.register()
  local active = fg(hl._todo_active_link)
  local collides = false
  for _, c in ipairs(pal) do
    if active == c then
      collides = true
    end
  end
  check(
    "TODO active color avoids every heading level",
    active ~= nil and not collides,
    "active=" .. tostring(active)
  )
end

-- 4. Done keyword color also stays off the heading palette and off active.
do
  local pal = { 0xC00001, 0xC00002, 0xC00003, 0xC00004, 0xC00005, 0xC00006, 0xC00007, 0xC00008 }
  paint_headings(pal)
  vim.api.nvim_set_hl(0, "Comment", { fg = 0xC00005 }) -- default done == heading-5
  vim.api.nvim_set_hl(0, "NonText", { fg = 0x555555 }) -- distinct candidate
  hl.register()
  local done = fg(hl._todo_done_link)
  local collides = false
  for _, c in ipairs(pal) do
    if done == c then
      collides = true
    end
  end
  check(
    "TODO done color avoids every heading level",
    done ~= nil and not collides,
    "done=" .. tostring(done)
  )
  check("TODO done color differs from active", done ~= fg(hl._todo_active_link))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("highlights_todo_collision_test: PASS")
os.exit(0)
