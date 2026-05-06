-- Behavioral test: end-to-end capture flow.
--
-- Configures a capture template with key "i", opens the capture float
-- via the capture API, types content, finalises with ZZ, and verifies
-- the target file received the captured entry.  Exercises:
--   organ.capture.open({key=...}) -> M.start
--   placeholder expansion (`%?` cursor positioning)
--   capture float lifecycle (popup + ftplugin)
--   buffer-local ZZ keymap (attach_keymaps)
--   M.finalise -> target.resolve (file kind)
--   write_atomic of the target file
--
-- Run via: nvim --headless -l tests/behavioral/capture_flow_test.lua
--
-- IMPORTANT: keep the keystroke sequence small + synchronous.  Each
-- nvim_feedkeys call uses the "x" mode flag so typeahead drains before
-- the next call; without it the ZZ would fire before "Test capture"
-- lands and finalise would write an empty body.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local target = org_dir .. "/inbox.org"
vim.fn.writefile({ "#+TITLE: Inbox", "" }, target)

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  capture = {
    templates = {
      {
        name = "Inbox",
        key = "i",
        body = "* TODO %?",
        target = { kind = "file", path = target },
      },
    },
  },
})

-- Pre-state: target has the title and an empty line, no TODO.
do
  local lines = vim.fn.readfile(target)
  local has_todo = false
  for _, l in ipairs(lines) do
    if l:match("^%* TODO ") then
      has_todo = true
    end
  end
  check("pre-state: inbox has no TODO yet", not has_todo, table.concat(lines, "|"))
end

-- Open a real source buffer before triggering capture.  Real users
-- invoke :Org capture from an org buffer, not from [No Name] -- and
-- capture.build_ctx() reads <cword> via vim.fn.expand which errors on
-- the empty headless [No Name] buffer.
vim.cmd("filetype plugin on")
vim.cmd("edit " .. target)

-- Fire the capture flow.  With key="i" capture.open skips the
-- template-picker popup and goes straight to M.start.
require("organ.capture").open({ key = "i" })

-- Float should be open with a buffer marked organ_capture.
local function find_capture_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].organ_capture then
      return b
    end
  end
  return nil
end

local cap_buf = find_capture_buf()
check("capture float buffer exists", cap_buf ~= nil)

if cap_buf then
  local body = vim.api.nvim_buf_get_lines(cap_buf, 0, -1, false)
  check(
    "capture body starts with `* TODO `",
    body[1] and body[1]:match("^%* TODO ") ~= nil,
    "got: " .. (body[1] or "(empty)")
  )
end

-- capture.open issues `:startinsert`, but in headless `-l` scripts
-- the mode change isn't applied until the loop ticks.  Explicitly
-- append at cursor + type + leave + finalise, all in one feedkeys
-- with the "x" flag so the whole sequence drains synchronously.
local keys = vim.api.nvim_replace_termcodes("aTest capture entry<Esc>ZZ", true, false, true)
vim.api.nvim_feedkeys(keys, "x", false)

-- Finalise wipes the float buffer and writes the target file
-- atomically.  Target file should now contain "* TODO Test capture entry".
local lines_after = vim.fn.readfile(target)
local todo_line
for _, l in ipairs(lines_after) do
  if l:match("^%* TODO ") then
    todo_line = l
    break
  end
end
check(
  "target inbox.org has captured TODO line",
  todo_line ~= nil,
  "lines: " .. table.concat(lines_after, "|")
)
check(
  "captured line matches typed body",
  todo_line == "* TODO Test capture entry",
  "got: " .. tostring(todo_line)
)

-- Capture buffer should be wiped.
check("capture float buffer wiped after finalise", find_capture_buf() == nil)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("capture_flow_test: PASS")
