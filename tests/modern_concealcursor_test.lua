-- The line under the cursor drops its decorations in the modes that
-- `modern.concealcursor` does not list, so the raw text is editable.
-- Run via: nvim --headless -l tests/modern_concealcursor_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  modern = { blocks = true, checkboxes = true },
})

local render = require("organ.modern.render")

local NS
for name, id in pairs(vim.api.nvim_get_namespaces()) do
  if name:find("modern") then
    NS = id
  end
end
assert(NS, "modern namespace not found")

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* H",
  "#+begin_src lua",
  "print(1)",
  "#+end_src",
  "- [ ] task",
  "after",
})
vim.api.nvim_set_current_buf(b)
vim.bo[b].filetype = "org"

local function marks_on(row)
  return #vim.api.nvim_buf_get_extmarks(b, NS, { row, 0 }, { row, -1 }, {})
end

local real_mode = vim.api.nvim_get_mode
local function render_in(mode)
  vim.api.nvim_get_mode = function()
    return { mode = mode, blocking = false }
  end
  local ok, err = pcall(render._render_now, b)
  vim.api.nvim_get_mode = real_mode
  assert(ok, err)
end

-- Default "nv": decorated in normal, raw in insert.
vim.api.nvim_win_set_cursor(0, { 2, 0 })
render_in("n")
check("begin_src decorated under the cursor in normal mode", marks_on(1) > 0)
render_in("i")
check("begin_src raw under the cursor in insert mode", marks_on(1) == 0)
check("the block's other rows stay decorated", marks_on(3) > 0)

-- A checkbox line behaves the same way.
vim.api.nvim_win_set_cursor(0, { 5, 0 })
render_in("i")
check("checkbox raw under the cursor in insert mode", marks_on(4) == 0)
check("begin_src decorated again once the cursor left it", marks_on(1) > 0)

-- Visual mode keeps the decoration under the default.
vim.api.nvim_win_set_cursor(0, { 2, 0 })
render_in("v")
check("begin_src decorated under the cursor in visual mode", marks_on(1) > 0)

-- An explicit empty string reveals in every mode.
require("organ.buf_config").set(b, "modern.concealcursor", "")
render_in("n")
check('concealcursor "" reveals in normal mode too', marks_on(1) == 0)

-- "nvic" never reveals.
require("organ.buf_config").set(b, "modern.concealcursor", "nvic")
render_in("i")
check('concealcursor "nvic" keeps the decoration in insert mode', marks_on(1) > 0)

vim.api.nvim_buf_delete(b, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_concealcursor_test: PASS")
os.exit(0)
