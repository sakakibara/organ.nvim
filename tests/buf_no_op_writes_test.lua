-- organ.buf helpers no-op byte-identical writes so operations that
-- don't change content (deadline set to same date, property set to
-- same value, etc.) don't dirty the buffer.
--
-- Run via: nvim --headless -l tests/buf_no_op_writes_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local buf = require("organ.buf")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- A regular (non-scratch) buffer is required so vim actually tracks
-- the `modified` flag.  Scratch buffers (nvim_create_buf(_, true))
-- have buftype=nofile and stay un-modified across writes, which
-- defeats the whole assertion.
local function new_buf()
  return vim.api.nvim_create_buf(true, false)
end

-- 1. buf.set_lines with identical content does NOT mark buffer modified.
do
  local b = new_buf()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* Heading", "body" })
  vim.bo[b].modified = false
  buf.set_lines(b, 0, 1, { "* Heading" })
  check("identical set_lines: modified stays false", vim.bo[b].modified == false)
end

-- 2. buf.set_lines with different content DOES mark modified.
do
  local b = new_buf()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* Heading", "body" })
  vim.bo[b].modified = false
  buf.set_lines(b, 0, 1, { "* New heading" })
  check("changed set_lines: modified becomes true", vim.bo[b].modified == true)
end

-- 3. buf.set_text with identical content does NOT mark modified.
do
  local b = new_buf()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "Hello world" })
  vim.bo[b].modified = false
  buf.set_text(b, 0, 0, 0, 5, { "Hello" })
  check("identical set_text: modified stays false", vim.bo[b].modified == false)
end

-- 4. buf.set_text with different content DOES mark modified.
do
  local b = new_buf()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "Hello world" })
  vim.bo[b].modified = false
  buf.set_text(b, 0, 0, 0, 5, { "World" })
  check("changed set_text: modified becomes true", vim.bo[b].modified == true)
end

-- 5. End-to-end: set_deadline on the same date does NOT mark modified.
do
  local b = new_buf()
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* TODO Task",
    "DEADLINE: <2026-05-15 Fri>",
    "body",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.bo[b].modified = false
  -- Stub the calendar picker to return the SAME date already set.
  require("organ.calendar").pick = function(_, cb)
    cb("2026-05-15")
  end
  require("organ.schedule").set_deadline()
  check(
    "deadline same-date: modified stays false",
    vim.bo[b].modified == false,
    "buffer state: " .. tostring(vim.bo[b].modified)
  )
end

-- 6. End-to-end: set_deadline with a different date DOES mark modified.
do
  local b = new_buf()
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* TODO Task",
    "DEADLINE: <2026-05-15 Fri>",
    "body",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.bo[b].modified = false
  require("organ.calendar").pick = function(_, cb)
    cb("2026-05-20")
  end
  require("organ.schedule").set_deadline()
  check("deadline different-date: modified becomes true", vim.bo[b].modified == true)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("buf_no_op_writes_test: PASS")
os.exit(0)
