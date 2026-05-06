-- Action menu: returns context-appropriate actions for cursor position.
-- Run via: nvim --headless -l tests/action_menu_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local action_menu = require("organ.action_menu")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function with(lines, row, col, fn)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { row, col })
  local r = fn()
  vim.api.nvim_buf_delete(b, { force = true })
  return r
end

local function titles(actions)
  return vim.tbl_map(function(a)
    return a.title
  end, actions)
end

local function contains(t, s)
  for _, v in ipairs(t) do
    if v == s or (type(v) == "string" and v:find(s, 1, true)) then
      return true
    end
  end
  return false
end

-- 1. On a headline: rich set of subtree/headline actions.
local hl_actions = with({ "* TODO Foo", "  body" }, 1, 0, function()
  return action_menu.actions_at_cursor()
end)
local hl_titles = titles(hl_actions)
check("headline: includes Promote subtree", contains(hl_titles, "Promote subtree"))
check("headline: includes Rename headline", contains(hl_titles, "Rename headline"))
check("headline: includes Schedule", contains(hl_titles, "Schedule"))
check("headline: includes Show backlinks", contains(hl_titles, "Show backlinks"))

-- 2. On a list item.
local list_actions = with({ "- [ ] item one" }, 1, 4, function()
  return action_menu.actions_at_cursor()
end)
local list_titles = titles(list_actions)
check("list-item: includes Toggle checkbox", contains(list_titles, "Toggle checkbox"))
check(
  "list-item: NOT promote/demote (those are headline-only)",
  not contains(list_titles, "Promote subtree")
)

-- 3. On a link.
local link_actions = with({ "Plain text [[id:abc][see]] more" }, 1, 14, function()
  return action_menu.actions_at_cursor()
end)
local link_titles = titles(link_actions)
check("link: includes Follow link", contains(link_titles, "Follow link"))
check("link: includes Hover preview", contains(link_titles, "Hover preview"))

-- 4. Plain text line: minimal action set.
local plain_actions = with({ "Just some prose here." }, 1, 5, function()
  return action_menu.actions_at_cursor()
end)
local plain_titles = titles(plain_actions)
check(
  "plain: includes 'Convert line to headline'",
  contains(plain_titles, "Convert line to headline")
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("action_menu_test: PASS")
