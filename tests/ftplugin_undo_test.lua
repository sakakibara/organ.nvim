-- Changing a buffer's filetype away from org must uninstall the org
-- ftplugin: `b:undo_ftplugin` takes the buffer maps, the buffer and
-- window options and the decoration providers off again.
-- Run via: nvim --headless -l tests/ftplugin_undo_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Script mode does not enable filetype plugins, and `b:undo_ftplugin` is
-- run by Neovim's own ftplugin.vim; turn it on so this exercises the
-- real path rather than calling the teardown directly.
vim.cmd("filetype plugin on")

require("organ").setup({
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  indent = { enabled = true },
  complete = { enabled = true },
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

local MODES = { "n", "i", "v", "x", "s", "o" }

local function keymap_set(bufnr)
  local set = {}
  for _, mode in ipairs(MODES) do
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      set[mode .. " " .. m.lhs] = true
    end
  end
  return set
end

local function keymap_count(bufnr)
  local n = 0
  for _ in pairs(keymap_set(bufnr)) do
    n = n + 1
  end
  return n
end

-- Neovim ships its own ftplugin/markdown.vim; its maps are not organ's to
-- remove, so they are excluded from the "nothing of organ's is left" check.
local function markdown_keymaps()
  local ctl = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_call(ctl, function()
    vim.bo[ctl].filetype = "markdown"
  end)
  local set = keymap_set(ctl)
  vim.api.nvim_buf_delete(ctl, { force = true })
  return set
end

local function extmark_count(bufnr)
  local n = 0
  for _, ns in pairs(vim.api.nvim_get_namespaces()) do
    local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, bufnr, ns, 0, -1, {})
    if ok then
      n = n + #marks
    end
  end
  return n
end

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* H", "  body", "** K", "x" })
local win = vim.api.nvim_get_current_win()

local base_maps = keymap_set(b)
local base_keymaps = keymap_count(b)
local md_maps = markdown_keymaps()
local base_win = {}
local WOPTS = {
  "foldmethod",
  "foldexpr",
  "foldtext",
  "foldminlines",
  "statuscolumn",
  "fillchars",
  "winhighlight",
  "conceallevel",
}
for _, o in ipairs(WOPTS) do
  base_win[o] = vim.api.nvim_get_option_value(o, { win = win, scope = "local" })
end

vim.bo[b].filetype = "org"
vim.wait(50)
require("organ.indent").refresh(b)
check("ftplugin installed keymaps", keymap_count(b) > base_keymaps, "got " .. keymap_count(b))
check(
  "ftplugin installed the foldexpr",
  vim.api.nvim_get_option_value("foldexpr", { win = win, scope = "local" }):find("organ", 1, true)
    ~= nil,
  vim.api.nvim_get_option_value("foldexpr", { win = win, scope = "local" })
)
check("indent placed pads", extmark_count(b) > 0, "got " .. extmark_count(b))
check("b:undo_ftplugin is set", vim.b[b].undo_ftplugin ~= nil)

vim.bo[b].filetype = "markdown"
vim.wait(50)
-- An edit while the buffer is markdown must not re-decorate it.
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* H", "one", "** K", "two", "three" })
require("organ.indent").refresh(b)
vim.wait(50)

local leftover = {}
for k in pairs(keymap_set(b)) do
  if not base_maps[k] and not md_maps[k] then
    leftover[#leftover + 1] = k
  end
end
table.sort(leftover)
check("no organ keymap survives the filetype change", #leftover == 0, table.concat(leftover, ", "))
for _, o in ipairs({ "indentexpr", "formatexpr", "omnifunc" }) do
  local v = vim.api.nvim_get_option_value(o, { buf = b })
  check("'" .. o .. "' no longer points at organ", not v:find("organ", 1, true), v)
end
for _, o in ipairs(WOPTS) do
  local v = vim.api.nvim_get_option_value(o, { win = win, scope = "local" })
  check(
    "window option '" .. o .. "' restored",
    tostring(v) == tostring(base_win[o]),
    ("was %q, now %q"):format(tostring(base_win[o]), tostring(v))
  )
end
check("no organ extmarks left", extmark_count(b) == 0, "got " .. extmark_count(b))
check(
  "indent is detached",
  require("organ.indent")._attached[b] == nil,
  tostring(require("organ.indent")._attached[b])
)

local groups = {}
for _, c in ipairs(vim.api.nvim_get_autocmds({ buffer = b })) do
  if c.group_name and c.group_name:match("^organ") then
    groups[#groups + 1] = c.group_name
  end
end
check("no organ autocmds left on the buffer", #groups == 0, table.concat(groups, ", "))

-- Setting the filetype back to org re-installs everything.
vim.bo[b].filetype = "org"
vim.wait(50)
check("re-attach restores the keymaps", keymap_count(b) > base_keymaps, "got " .. keymap_count(b))
check("re-attach sets b:undo_ftplugin again", vim.b[b].undo_ftplugin ~= nil)

-- organ also attaches from its own FileType autocmd when filetype plugins
-- are off, and nothing runs `b:undo_ftplugin` there; the teardown has to
-- reach that path too.
vim.cmd("filetype plugin off")
local b2 = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b2)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "* H", "  body" })
local b2_base = keymap_set(b2)
vim.bo[b2].filetype = "org"
vim.wait(50)
check("attaches with filetype plugins off", keymap_count(b2) > 0, "got " .. keymap_count(b2))
vim.bo[b2].filetype = "markdown"
vim.wait(50)
local b2_left = {}
for k in pairs(keymap_set(b2)) do
  if not b2_base[k] then
    b2_left[#b2_left + 1] = k
  end
end
check("tears down with filetype plugins off", #b2_left == 0, table.concat(b2_left, ", "))

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
io.write("ftplugin_undo ok\n")
os.exit(0)
