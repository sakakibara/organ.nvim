-- Every place that raises `conceallevel` for an org window must set the
-- WINDOW-LOCAL value only.  Writing the global value leaks it into the
-- next buffer shown in that window (the ftplugin's BufWinLeave reset
-- `setlocal conceallevel<` copies the global back in) and into every
-- new window.
--
-- The list of features below is not the guard -- three of them were
-- missed the first time this was enumerated by hand.  `lua/` is swept
-- for unscoped conceal writes first, so a new call site fails here
-- whether or not anyone remembers to add it.
--
-- Run via: nvim --headless -l tests/modern_conceallevel_scope_test.lua

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

-- Source sweep: nothing under `lua/` may write `conceallevel` or
-- `concealcursor` without `scope = "local"`.  `vim.wo[w].opt = v` and
-- `nvim_set_option_value(..., { win = w })` both behave like `:set` --
-- they write the global value too -- whenever `w` is the current window.
local function unscoped_conceal_writes()
  local hits = {}
  for _, file in ipairs(vim.fn.glob(root .. "/lua/**/*.lua", true, true)) do
    local kept = {}
    for _, line in ipairs(vim.fn.readfile(file)) do
      if not line:match("^%s*%-%-") then
        kept[#kept + 1] = line
        if line:match("vim%.wo[^\n]-conceal%w*%s*=[^=]") then
          hits[#hits + 1] = file .. ": " .. vim.trim(line)
        end
      end
    end
    local text = table.concat(kept, " ")
    local from = 1
    while true do
      local s, e = text:find("nvim_set_option_value", from, true)
      if not s then
        break
      end
      from = e + 1
      local depth, stop = 0, #text
      for i = e + 1, #text do
        local c = text:sub(i, i)
        if c == "(" or c == "{" or c == "[" then
          depth = depth + 1
        elseif c == ")" or c == "}" or c == "]" then
          if depth == 0 then
            stop = i
            break
          end
          depth = depth - 1
        end
      end
      local call = text:sub(e + 1, stop)
      if call:match('"conceal%w*"') and not call:match('scope%s*=%s*"local"') then
        hits[#hits + 1] = file .. ": " .. vim.trim(call)
      end
    end
  end
  return hits
end

local unscoped = unscoped_conceal_writes()
check(
  "no unscoped conceallevel / concealcursor write under lua/",
  #unscoped == 0,
  table.concat(unscoped, "\n     ")
)

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "* A1", "| a | b |", "|---+---|", "| 1 | 2 |" }, dir .. "/a.org")
vim.fn.writefile({ "* A1", "| a | b |", "|---+---|", "| 1 | 2 |" }, dir .. "/t.org")
vim.fn.writefile({ "* A1", "** A2", "*** A3" }, dir .. "/s.org")
vim.fn.writefile({ "* A1", "\\alpha and \\to" }, dir .. "/e.org")
vim.fn.writefile({ "* A1", "** A2", "*** A3" }, dir .. "/x.org")
vim.fn.writefile({ "plain text", "more" }, dir .. "/c.txt")

local function open_org(path)
  vim.cmd("edit " .. path)
  if vim.bo.filetype ~= "org" then
    vim.bo.filetype = "org"
  end
  vim.wait(100)
  return vim.api.nvim_get_current_buf()
end

local base = {
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
}

-- Render engine (bullets).
require("organ").setup(vim.tbl_extend("force", base, { modern = { bullets = true } }))
check("global conceallevel starts at 0", vim.go.conceallevel == 0, "got " .. vim.go.conceallevel)
open_org(dir .. "/a.org")
check(
  "engine: org window conceallevel is 2",
  vim.wo.conceallevel == 2,
  "got " .. vim.wo.conceallevel
)
check(
  "engine: global conceallevel untouched",
  vim.go.conceallevel == 0,
  "got " .. vim.go.conceallevel
)
vim.cmd("edit " .. dir .. "/c.txt")
vim.wait(50)
check(
  "engine: next buffer in the window gets conceallevel 0",
  vim.wo.conceallevel == 0,
  "got " .. vim.wo.conceallevel
)

-- Table conceal (its own attach path).
require("organ").setup({ modern = { bullets = false, table = true } })
open_org(dir .. "/t.org")
check(
  "table: org window conceallevel is 2",
  vim.wo.conceallevel == 2,
  "got " .. vim.wo.conceallevel
)
check(
  "table: global conceallevel untouched",
  vim.go.conceallevel == 0,
  "got " .. vim.go.conceallevel
)
vim.cmd("edit " .. dir .. "/c.txt")
vim.wait(50)
check(
  "table: next buffer in the window gets conceallevel 0",
  vim.wo.conceallevel == 0,
  "got " .. vim.wo.conceallevel
)

-- `:Org conceal toggle`.
require("organ").setup({ modern = { table = false } })
local b = open_org(dir .. "/a.org")
vim.api.nvim_set_option_value("conceallevel", 0, { win = 0, scope = "local" })
local conceal = require("organ.conceal")
local on = conceal.toggle(b)
check(
  "conceal.toggle: turns on",
  on == true and vim.wo.conceallevel == 2,
  "got " .. vim.wo.conceallevel
)
check(
  "conceal.toggle on: global conceallevel untouched",
  vim.go.conceallevel == 0,
  "got " .. vim.go.conceallevel
)
local off = conceal.toggle(b)
check(
  "conceal.toggle: turns off",
  off == false and vim.wo.conceallevel == 0,
  "got " .. vim.wo.conceallevel
)
check(
  "conceal.toggle off: global conceallevel untouched",
  vim.go.conceallevel == 0,
  "got " .. vim.go.conceallevel
)

-- Each section below opens a file of its own: re-editing an already
-- loaded buffer does not re-run the ftplugin, so the feature under test
-- would never attach.  The global values are reset first so a leak from
-- an earlier section cannot stand in for -- or mask -- this one's.
local function fresh()
  vim.cmd("silent! only")
  vim.go.conceallevel = 0
  vim.go.concealcursor = ""
end

-- Hidden leading stars (`stars.hide`), its own attach path.
fresh()
require("organ").setup(
  vim.tbl_extend("force", base, { modern = { bullets = false }, stars = { hide = true } })
)
open_org(dir .. "/s.org")
check(
  "stars: org window conceallevel is 2",
  vim.wo.conceallevel == 2,
  "got " .. vim.wo.conceallevel
)
check(
  "stars: global conceallevel untouched",
  vim.go.conceallevel == 0,
  "got " .. vim.go.conceallevel
)
vim.cmd("edit " .. dir .. "/c.txt")
vim.wait(50)
check(
  "stars: next buffer in the window gets conceallevel 0",
  vim.wo.conceallevel == 0,
  "got " .. vim.wo.conceallevel
)

-- Pretty entities, which claims `concealcursor` as well.
fresh()
require("organ").setup(
  vim.tbl_extend(
    "force",
    base,
    { modern = { bullets = false }, stars = { hide = false }, entities = { enabled = true } }
  )
)
open_org(dir .. "/e.org")
check(
  "entities: org window conceallevel is 2",
  vim.wo.conceallevel == 2,
  "got " .. vim.wo.conceallevel
)
check(
  "entities: global conceallevel untouched",
  vim.go.conceallevel == 0,
  "got " .. vim.go.conceallevel
)
check(
  "entities: global concealcursor untouched",
  vim.go.concealcursor == "",
  "got '" .. vim.go.concealcursor .. "'"
)
vim.cmd("edit " .. dir .. "/c.txt")
vim.wait(50)
check(
  "entities: next buffer in the window gets conceallevel 0",
  vim.wo.conceallevel == 0,
  "got " .. vim.wo.conceallevel
)

-- The treesitter-context sticky header mirrors the parent window's level
-- into the float.  The float can be the current window, which is when an
-- unscoped write lands on the global value.
fresh()
require("organ").setup(
  vim.tbl_extend(
    "force",
    base,
    { modern = { bullets = false }, stars = { hide = true }, entities = { enabled = false } }
  )
)
open_org(dir .. "/x.org")
require("organ.ts_context")
local pwin = vim.api.nvim_get_current_win()
local cbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, { "* A1" })
local cwin = vim.api.nvim_open_win(cbuf, true, {
  relative = "win",
  win = pwin,
  row = 0,
  col = 0,
  width = 20,
  height = 1,
  style = "minimal",
})
vim.w[cwin].treesitter_context = true
vim.api.nvim_set_option_value("conceallevel", 0, { win = cwin, scope = "local" })
vim.go.conceallevel = 0
vim.cmd("redraw")
vim.wait(80)
check(
  "ts_context: the header float follows the parent's conceallevel",
  vim.api.nvim_get_option_value("conceallevel", { win = cwin, scope = "local" }) == 2,
  "got " .. vim.api.nvim_get_option_value("conceallevel", { win = cwin, scope = "local" })
)
check(
  "ts_context: global conceallevel untouched",
  vim.go.conceallevel == 0,
  "got " .. vim.go.conceallevel
)
vim.api.nvim_win_close(cwin, true)

vim.fn.delete(dir, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_conceallevel_scope_test: PASS")
os.exit(0)
