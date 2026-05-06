-- E2E test for capture.start + capture.finalise (programmatic).
-- Run via: nvim --headless -l tests/capture_finalise_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local target_path = vim.fn.resolve(tmp .. "/inbox.org")
local f = assert(io.open(target_path, "w"))
f:write("* Existing\n  body\n")
f:close()

require("organ").setup({
  db_path = tmp .. "/c.db",
  org_dir = tmp,
  notify = true,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local capture = require("organ.capture")

-- 1. start opens a float with the expanded body and cursor positioned at %?.
do
  local template = {
    name = "Inbox",
    target = { kind = "file", path = target_path },
    body = "* TODO %?\n  notes",
  }
  local ctx = {
    source_bufnr = 0,
    source_win = vim.api.nvim_get_current_win(),
    source_cursor = { 1, 0 },
    source_file = "",
    cword = "",
    visual_text = "",
    prompts = { text = {}, dates = {} },
    now = os.time(),
  }
  capture.start(template, ctx)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  assert(
    lines[1] == "* TODO " and lines[2] == "  notes",
    "expected expanded body; got " .. vim.inspect(lines)
  )
  local cur = vim.api.nvim_win_get_cursor(0)
  assert(
    cur[1] == 1 and cur[2] == #"* TODO ",
    "cursor should be at %? position; got " .. vim.inspect(cur)
  )
  local meta = vim.b[bufnr].organ_capture
  assert(meta and meta.template_name == "Inbox", "meta missing or wrong: " .. vim.inspect(meta))

  vim.api.nvim_buf_set_text(bufnr, 0, #"* TODO ", 0, #"* TODO ", { "Buy milk" })

  capture.finalise(bufnr)

  -- Default empty_lines_before is 0 (Emacs parity); the captured
  -- entry appends directly after the existing section.  Templates
  -- that want a blank separator opt in via empty_lines_before = 1.
  local result = vim.fn.readfile(target_path)
  assert(#result == 4, "expected 4 lines; got " .. #result .. ": " .. vim.inspect(result))
  assert(result[1] == "* Existing")
  assert(result[2] == "  body")
  assert(result[3] == "* TODO Buy milk")
  assert(result[4] == "  notes")
end

-- 2. Empty buffer at finalise → notify-WARN, file untouched.
do
  vim.fn.writefile({ "* Existing", "  body" }, target_path)

  local template = {
    name = "Empty",
    target = { kind = "file", path = target_path },
    body = "%?",
  }
  local ctx = {
    source_bufnr = 0,
    source_win = vim.api.nvim_get_current_win(),
    source_cursor = { 1, 0 },
    source_file = "",
    prompts = { text = {}, dates = {} },
    now = os.time(),
  }
  capture.start(template, ctx)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })

  local notified
  local original_notify = vim.notify
  vim.notify = function(msg, lvl)
    notified = { msg = msg, lvl = lvl }
  end

  capture.finalise(bufnr)

  vim.notify = original_notify
  assert(
    notified and notified.msg:find("nothing to capture"),
    "expected nothing-to-capture notify; got " .. tostring(notified and notified.msg)
  )
  local result = vim.fn.readfile(target_path)
  assert(#result == 2, "target should be unchanged; got " .. #result .. " lines")
end

-- 3. jump_after_finalise = true → buffer is the target file at insert line.
do
  vim.fn.writefile({ "* Existing" }, target_path)

  local template = {
    name = "Jump",
    target = { kind = "file", path = target_path },
    body = "* Captured",
    jump_after_finalise = true,
  }
  local ctx = {
    source_bufnr = 0,
    source_win = vim.api.nvim_get_current_win(),
    source_cursor = { 1, 0 },
    source_file = "",
    prompts = { text = {}, dates = {} },
    now = os.time(),
  }
  capture.start(template, ctx)
  local bufnr = vim.api.nvim_get_current_buf()
  capture.finalise(bufnr)

  local cur_path = vim.fn.resolve(vim.api.nvim_buf_get_name(0))
  assert(cur_path == target_path, "expected target_path; got " .. cur_path)
  local cur = vim.api.nvim_win_get_cursor(0)
  local text = vim.api.nvim_buf_get_lines(0, cur[1] - 1, cur[1], false)[1]
  assert(
    text == "* Captured",
    "expected cursor on '* Captured'; got line " .. cur[1] .. " = " .. text
  )
end

-- 4. datetree target: captured "* test" becomes "**** test" under level-3 leaf.
do
  local journal_path = vim.fn.resolve(tmp .. "/journal_relevel.org")
  vim.fn.writefile({}, journal_path)

  local now = os.time({ year = 2026, month = 4, day = 27, hour = 10, min = 0, sec = 0 })

  local template = {
    name = "Journal",
    target = { kind = "file_olp_datetree", path = journal_path },
    body = "* test",
  }
  local ctx = {
    source_bufnr = 0,
    source_win = vim.api.nvim_get_current_win(),
    source_cursor = { 1, 0 },
    source_file = "",
    prompts = { text = {}, dates = {} },
    now = now,
  }
  capture.start(template, ctx)
  local bufnr = vim.api.nvim_get_current_buf()
  capture.finalise(bufnr)

  local result = vim.fn.readfile(journal_path)
  -- File should contain the 3-level datetree spine + a level-4 "* test" → "**** test"
  local found_level4 = false
  local found_level1 = false
  for _, l in ipairs(result) do
    if l:match("^%*%*%*%* test") then
      found_level4 = true
    end
    if l:match("^%* test") then
      found_level1 = true
    end
  end
  assert(found_level4, "expected **** test under datetree leaf; lines: " .. vim.inspect(result))
  assert(not found_level1, "* test at level 1 should NOT appear; lines: " .. vim.inspect(result))
end

vim.fn.delete(tmp, "rf")
io.write("capture finalise ok\n")
os.exit(0)
