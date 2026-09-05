-- Window options must be written WINDOW-LOCAL, never globally.
--
-- `nvim_set_option_value(name, v, { win = w })` with no `scope` and
-- `vim.wo[w].name = v` both behave like `:set` -- they write the GLOBAL
-- value too -- whenever `w` is the current window.  A plugin that
-- configures its own window while that window is focused therefore
-- poisons the global value, and every window opened afterwards, of any
-- filetype, inherits it.
--
-- The feature list below is not the guard.  This class of bug escaped
-- twice already because the guard enumerated call sites by hand, so
-- `lua/`, `plugin/` and `ftplugin/` are swept first: any unscoped
-- window-option write fails here whether or not anyone remembers to add
-- a section for it.
--
-- Run via: nvim --headless -l tests/window_option_scope_test.lua

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

-- Source sweep

local function strip_comment_lines(lines)
  local kept = {}
  for _, line in ipairs(lines) do
    if not line:match("^%s*%-%-") then
      kept[#kept + 1] = line
    end
  end
  return kept
end

-- `vim.wo` may be READ but never written or aliased.  An alias
-- (`local wo = vim.wo[w]`) hides the write from any textual scan, so it
-- is rejected outright rather than followed.
local function scan_vim_wo(lines)
  local hits = {}
  for n, line in ipairs(lines) do
    if not line:match("^%s*%-%-") then
      local at = line:find("vim%.wo")
      local comment = line:find("%-%-")
      if at and not (comment and comment < at) then
        local rest = line:sub(at)
        local tail = rest:match("^vim%.wo%[[^%]]*%]%.[%w_]+(.*)$")
          or rest:match("^vim%.wo%.[%w_]+(.*)$")
        local is_write = tail == nil
          or tail:match("^%s*=[^=]") ~= nil
          or tail:match("^%s*=$") ~= nil
        if is_write then
          hits[#hits + 1] = n .. ": " .. vim.trim(line)
        end
      end
    end
  end
  return hits
end

-- Argument text of the call whose name ends at `e`, for both spellings
-- that appear in this codebase: `f(...)` and `pcall(f, ...)`.
local function call_args(text, e)
  local k = e + 1
  while text:sub(k, k) == " " do
    k = k + 1
  end
  if text:sub(k, k) == "(" then
    k = k + 1
  end
  local depth = 0
  for j = k, #text do
    local c = text:sub(j, j)
    if c == "(" or c == "{" or c == "[" then
      depth = depth + 1
    elseif c == ")" or c == "}" or c == "]" then
      if depth == 0 then
        return text:sub(k, j - 1)
      end
      depth = depth - 1
    end
  end
  return text:sub(k)
end

-- Any `nvim_set_option_value` targeting a window must say
-- `scope = "local"`.  Buffer-targeted calls are a different option class
-- and out of this test's remit.
local function scan_set_option_value(lines)
  local hits = {}
  local text = table.concat(strip_comment_lines(lines), " ")
  local from = 1
  while true do
    local s, e = text:find("nvim_set_option_value", from, true)
    if not s then
      break
    end
    from = e + 1
    local args = call_args(text, e)
    if args:match("win%s*=") and not args:match('scope%s*=%s*"local"') then
      hits[#hits + 1] = vim.trim(args)
    end
  end
  return hits
end

-- Self-test: a sweep that cannot fail is not a guard.
local BAD = {
  { "vim.wo[win].wrap = false", scan_vim_wo },
  { "vim.wo.foldmethod = 'expr'", scan_vim_wo },
  { "local wo = vim.wo[winid]", scan_vim_wo },
  { 'vim.api.nvim_set_option_value("wrap", false, { win = winid })', scan_set_option_value },
  { 'pcall(vim.api.nvim_set_option_value, "foldlevel", 99, { win = w })', scan_set_option_value },
}
for _, case in ipairs(BAD) do
  check("sweep rejects: " .. case[1], #case[2]({ case[1] }) == 1)
end

local GOOD = {
  { "if vim.wo[winid].conceallevel == 0 then", scan_vim_wo },
  { "local nu = vim.wo.number", scan_vim_wo },
  { '-- vim.wo.winbar = "..."', scan_vim_wo },
  {
    'vim.api.nvim_set_option_value("wrap", false, { win = winid, scope = "local" })',
    scan_set_option_value,
  },
  {
    'vim.api.nvim_set_option_value("indentkeys", "o,O,!^F", { buf = bufnr })',
    scan_set_option_value,
  },
}
for _, case in ipairs(GOOD) do
  check("sweep accepts: " .. case[1], #case[2]({ case[1] }) == 0)
end

-- A multi-line call must be read as one call, and the scan must stop at
-- that call's own closing paren -- not run on into a later, correctly
-- scoped one and borrow its `scope = "local"`.
local MULTILINE = {
  "vim.api.nvim_set_option_value(",
  '  "foldexpr",',
  "  \"v:lua.require'organ.sparse'.foldexpr(v:lnum)\",",
  "  { win = winid }",
  ")",
  'vim.api.nvim_set_option_value("foldmethod", "expr", { win = winid, scope = "local" })',
}
check("sweep rejects an unscoped multi-line call", #scan_set_option_value(MULTILINE) == 1)

local source_files = {}
do
  local seen = {}
  for _, dir in ipairs({ "/lua", "/plugin", "/ftplugin" }) do
    for _, pat in ipairs({ "/*.lua", "/**/*.lua" }) do
      for _, f in ipairs(vim.fn.glob(root .. dir .. pat, true, true)) do
        if not seen[f] then
          seen[f] = true
          source_files[#source_files + 1] = f
        end
      end
    end
  end
  table.sort(source_files)
end
check("sweep found source files", #source_files > 50, "got " .. #source_files)

local unscoped = {}
for _, file in ipairs(source_files) do
  local lines = vim.fn.readfile(file)
  local rel = file:sub(#root + 2)
  for _, hit in ipairs(scan_vim_wo(lines)) do
    unscoped[#unscoped + 1] = rel .. ":" .. hit
  end
  for _, hit in ipairs(scan_set_option_value(lines)) do
    unscoped[#unscoped + 1] = rel .. ": " .. hit
  end
end
check(
  "no unscoped window-option write in plugin source",
  #unscoped == 0,
  table.concat(unscoped, "\n     ")
)

-- Behavioural regressions
--
-- Every global below is deliberately set to a value the code under test
-- does NOT write, so an unchanged global cannot be mistaken for a clean
-- run.  A window opened in a new tab takes its window-local options from
-- the global values, which is exactly what a `:set`-style leak hands
-- every later window.

local GLOBALS = {
  foldmethod = "manual",
  foldexpr = "0",
  foldlevel = 5,
  wrap = true,
  cursorline = true,
  winhighlight = "",
  number = true,
  relativenumber = true,
  signcolumn = "yes",
  foldcolumn = "2",
  colorcolumn = "80",
  spell = true,
  list = true,
  winfixwidth = false,
  statuscolumn = "%l ",
}

local function fresh()
  vim.cmd("silent! tabonly")
  vim.cmd("silent! only")
  for name, value in pairs(GLOBALS) do
    vim.go[name] = value
  end
end

local function global_leaks(names)
  local bad = {}
  for _, name in ipairs(names) do
    if vim.go[name] ~= GLOBALS[name] then
      bad[#bad + 1] =
        string.format("%s: %s -> %s", name, tostring(GLOBALS[name]), tostring(vim.go[name]))
    end
  end
  return table.concat(bad, " | ")
end

local function inherited_by_new_window(names)
  vim.cmd("tabnew")
  local bad = {}
  for _, name in ipairs(names) do
    if vim.wo[name] ~= GLOBALS[name] then
      bad[#bad + 1] = string.format("%s=%s", name, tostring(vim.wo[name]))
    end
  end
  vim.cmd("tabclose")
  return table.concat(bad, " | ")
end

local function assert_no_leak(label, names)
  check(label .. ": global values untouched", global_leaks(names) == "", global_leaks(names))
  local inherited = inherited_by_new_window(names)
  check(label .. ": a new window inherits nothing", inherited == "", inherited)
end

local function win_local(winid, name)
  return vim.api.nvim_get_option_value(name, { win = winid, scope = "local" })
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

local base = {
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
}

-- Each section opens a fixture file of its own: re-editing an already
-- loaded buffer does not re-run the ftplugin, so the feature under test
-- would silently never attach and the section would pass for the wrong
-- reason.
local function open_org(name)
  vim.fn.writefile({ "* TODO one", "* two", "** TODO three" }, dir .. "/" .. name)
  vim.cmd("edit " .. dir .. "/" .. name)
  if vim.bo.filetype ~= "org" then
    vim.bo.filetype = "org"
  end
  vim.wait(100)
  return vim.api.nvim_get_current_buf()
end

local FOLD = { "foldmethod", "foldexpr", "foldlevel" }

-- Sparse tree: `:Org sparse` swaps the window onto its own foldexpr.
fresh()
require("organ").setup(base)
local sparse_buf = open_org("sparse.org")
require("organ.sparse").show_todo(sparse_buf)
local sparse_win = vim.api.nvim_get_current_win()
check(
  "sparse: the org window uses the sparse foldexpr",
  win_local(sparse_win, "foldmethod") == "expr"
    and win_local(sparse_win, "foldexpr"):match("organ%.sparse") ~= nil,
  win_local(sparse_win, "foldmethod") .. " / " .. win_local(sparse_win, "foldexpr")
)
assert_no_leak("sparse.apply", FOLD)

-- The restore path leaks the same way if only the set is scoped.
fresh()
local clear_buf = open_org("sparse-clear.org")
require("organ.sparse").show_todo(clear_buf)
fresh()
require("organ.sparse").clear(clear_buf)
assert_no_leak("sparse.clear", FOLD)

-- Agenda window.
fresh()
require("organ").setup(vim.tbl_extend("force", base, { agenda_files = { dir } }))
require("organ.agenda").open({ span = "day" })
vim.wait(300)
local agenda_win = vim.api.nvim_get_current_win()
check(
  "agenda: the agenda window uses the agenda foldexpr",
  win_local(agenda_win, "foldmethod") == "expr"
    and win_local(agenda_win, "foldlevel") == 99
    and win_local(agenda_win, "wrap") == false,
  win_local(agenda_win, "foldmethod") .. " / " .. tostring(win_local(agenda_win, "wrap"))
)
assert_no_leak("agenda.open", { "foldmethod", "foldexpr", "foldlevel", "wrap" })

-- Capture float: opened with `enter = true`, so it IS the current window.
fresh()
require("organ").setup(vim.tbl_extend("force", base, {
  capture = {
    templates = {
      {
        key = "t",
        name = "T",
        target = { kind = "file", path = dir .. "/captured.org" },
        body = "* TODO scope probe",
      },
    },
  },
}))
local capture = require("organ.capture")
capture.start(require("organ").config.capture.templates[1], capture.build_ctx())
vim.wait(200)
check(
  "capture: the float opens unfolded",
  win_local(vim.api.nvim_get_current_win(), "foldlevel") == 99,
  tostring(win_local(vim.api.nvim_get_current_win(), "foldlevel"))
)
assert_no_leak("capture.start", { "foldlevel" })

-- Calendar float.
fresh()
require("organ").setup(base)
require("organ.calendar").pick({}, function() end)
vim.wait(200)
local cal_win = vim.api.nvim_get_current_win()
check(
  "calendar: the float is pinned and uncursorlined",
  win_local(cal_win, "wrap") == false and win_local(cal_win, "cursorline") == false,
  tostring(win_local(cal_win, "wrap")) .. " / " .. tostring(win_local(cal_win, "cursorline"))
)
assert_no_leak("calendar.pick", { "wrap", "cursorline" })

-- Roam sidebar: eleven window options in one helper.
local SIDEBAR = {
  "number",
  "relativenumber",
  "wrap",
  "signcolumn",
  "foldcolumn",
  "cursorline",
  "colorcolumn",
  "spell",
  "list",
  "winfixwidth",
  "statuscolumn",
  "winhighlight",
}
fresh()
require("organ").setup(vim.tbl_extend("force", base, { roam = { directory = dir } }))
open_org("sidebar.org")
require("organ.roam.sidebar").open()
vim.wait(300)
local side_win = require("organ.roam.sidebar")._state().winid
check(
  "sidebar: the sidebar window is styled",
  win_local(side_win, "number") == false
    and win_local(side_win, "winfixwidth") == true
    and win_local(side_win, "winhighlight"):match("NormalSB") ~= nil,
  tostring(win_local(side_win, "number")) .. " / " .. win_local(side_win, "winhighlight")
)
assert_no_leak("roam.sidebar.open", SIDEBAR)

vim.fn.delete(dir, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("window_option_scope_test: PASS")
os.exit(0)
