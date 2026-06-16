-- Radio resolution end-to-end through export.
-- Run via: nvim --headless -l tests/export_radio_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_org = require("organ.ast.from_org")
local radio = require("organ.ast.radio")
local to_html = require("organ.ast.to_html")
local to_ascii = require("organ.ast.to_ascii")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

local lines = { "Define <<<my phrase>>> here.", "", "Later: my phrase again." }
local ast = radio.resolve(from_org.from_lines(lines))

local html = to_html.render(ast, {})
check(html:find('id="my-phrase"', 1, true) ~= nil, "html: definition has anchor id")
check(html:find('href="#my-phrase"', 1, true) ~= nil, "html: occurrence links to anchor")

local ascii = to_ascii.render(ast, {})
check(ascii:find("my phrase again", 1, true) ~= nil, "ascii: occurrence shows the words")
check(ascii:find("<<<", 1, true) == nil, "ascii: no leftover radio markers")

-- non-ASCII (e.g. Japanese) radio targets get distinct, non-empty anchors
-- that the occurrence href matches, instead of all collapsing to id="".
do
  local jp = {
    "Define <<<\230\151\165\230\156\172>>> and <<<\229\136\165\232\170\158>>>.",
    "",
    "Use \230\151\165\230\156\172 once and \229\136\165\232\170\158 too.",
  }
  local h = to_html.render(radio.resolve(from_org.from_lines(jp)), {})
  check(h:find('id=""', 1, true) == nil, "html: non-ASCII target has a non-empty id")
  local id1 = h:match('id="([^"]+)"')
  check(
    id1 ~= nil and h:find('href="#' .. id1 .. '"', 1, true) ~= nil,
    "html: non-ASCII occurrence links to its target id"
  )
  local n = 0
  for _ in h:gmatch('id="') do
    n = n + 1
  end
  local ids = {}
  for v in h:gmatch('id="([^"]+)"') do
    ids[v] = (ids[v] or 0) + 1
  end
  local distinct = 0
  for _ in pairs(ids) do
    distinct = distinct + 1
  end
  check(distinct == n and n == 2, "html: two non-ASCII targets get two distinct ids")
end

print("ALL PASS: export_radio")
