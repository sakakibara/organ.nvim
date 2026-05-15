-- Regression: <LocalLeader>t must be bound as a standalone fast-TODO-
-- pick action and NOT a prefix to longer bindings.  If anyone
-- reintroduces a binding like <LocalLeader>tX, the test catches it.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
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

-- Create an org buffer and trigger the FileType=org autocmd so all
-- ftplugin attaches run and buffer-local keymaps register.
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_name(b, "/tmp/keymap_t_check.org")
vim.bo[b].filetype = "org"
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* TODO Heading",
  "body",
  "| col1 | col2 |",
  "| a    | b    |",
})
vim.cmd("doautocmd FileType org")

local maps = vim.api.nvim_buf_get_keymap(b, "n")
-- nvim_buf_get_keymap returns lhs with <LocalLeader> already translated to
-- the literal localleader char.  The default localleader is "\" (one
-- backslash), so the cycle binding shows up as the two-byte string "\t"
-- (backslash + lowercase t).  Match by exact equality to avoid Lua-
-- pattern escaping confusion.
local function find_exact(lhs)
  for _, km in ipairs(maps) do
    if km.lhs == lhs then
      return km
    end
  end
  return nil
end

-- 1. The fast-TODO-pick binding exists at \t.
do
  local m = find_exact("\\t")
  check(
    "\\t bound (fast TODO pick)",
    m ~= nil and m.desc == "Fast TODO state pick (one keystroke)",
    m and ("desc=" .. tostring(m.desc)) or "not found"
  )
end

-- 2. No <LocalLeader>t* longer binding exists (would cause timeoutlen delay).
do
  local conflict = nil
  for _, km in ipairs(maps) do
    -- "\t" followed by one or more chars.  string.sub avoids Lua-pattern
    -- escaping: just look at the first two bytes literally.
    if km.lhs and #km.lhs >= 3 and km.lhs:sub(1, 2) == "\\t" then
      conflict = km
      break
    end
  end
  check(
    "no longer <LocalLeader>t* bindings exist",
    conflict == nil,
    conflict
        and ("found conflict: " .. tostring(conflict.lhs) .. " (" .. tostring(conflict.desc) .. ")")
      or nil
  )
end

-- 3. The three relocated bindings exist at their new \z* positions.
do
  local zt = find_exact("\\zt")
  local zi = find_exact("\\zi")
  local zp = find_exact("\\zp")
  check("\\zt bound (table menu)", zt ~= nil)
  check("\\zi bound (toggle inline images)", zi ~= nil)
  check("\\zp bound (toggle pretty entities)", zp ~= nil)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("keymap_t_prefix_test: PASS")
os.exit(0)
