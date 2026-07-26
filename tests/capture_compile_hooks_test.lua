-- Capture template compile_hooks + whole_file mode.
--   compile_hooks: list of post-processing functions called with
--     (content, "content", ctx) → string|nil. Each hook may rewrite.
--   whole_file: replace the entire target file with captured body.
-- Run via: nvim --headless -l tests/capture_compile_hooks_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local capture = require("organ.capture")

-- Test 1: compile_hooks rewrite content before insertion
do
  local target = tmp .. "/inbox.org"
  vim.fn.writefile({ "* Inbox" }, target)
  local hook_calls = {}
  capture.start({
    name = "T1",
    target = { kind = "file_headline", path = target, headline = "Inbox" },
    body = "** TODO Buy milk",
    compile_hooks = {
      function(content, kind, _ctx)
        hook_calls[#hook_calls + 1] = { idx = 1, kind = kind, content = content }
        return content:gsub("Buy milk", "BUY MILK")
      end,
      function(content, kind, _ctx)
        hook_calls[#hook_calls + 1] = { idx = 2, kind = kind, content = content }
        return content .. "\n   :PRIORITY: high"
      end,
    },
  }, {})
  -- The capture buffer is now open with the rewritten body. Finalise it.
  local cap_buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].organ_capture then
      cap_buf = b
      break
    end
  end
  check("hook 1 was called with kind='content'", hook_calls[1] and hook_calls[1].kind == "content")
  check(
    "hook 1 saw the original 'Buy milk' substring",
    hook_calls[1] and hook_calls[1].content:find("Buy milk", 1, true) ~= nil
  )
  check(
    "two hooks ran in registration order",
    #hook_calls == 2 and hook_calls[1].idx == 1 and hook_calls[2].idx == 2
  )
  check(
    "hook 2 saw the OUTPUT of hook 1 (chained)",
    hook_calls[2] and hook_calls[2].content:find("BUY MILK", 1, true) ~= nil
  )

  -- The capture buffer should reflect BOTH hooks' transformations.
  local buf_lines = vim.api.nvim_buf_get_lines(cap_buf, 0, -1, false)
  local buf_text = table.concat(buf_lines, "\n")
  check(
    "buffer contains uppercase 'BUY MILK' (hook 1 applied)",
    buf_text:find("BUY MILK", 1, true) ~= nil,
    "got: " .. buf_text
  )
  check(
    "buffer contains ':PRIORITY: high' (hook 2 appended)",
    buf_text:find(":PRIORITY: high", 1, true) ~= nil,
    "got: " .. buf_text
  )

  capture.finalise(cap_buf)

  -- File now contains the rewritten heading.
  local file_text = table.concat(vim.fn.readfile(target), "\n")
  check(
    "target file received uppercase 'BUY MILK'",
    file_text:find("BUY MILK", 1, true) ~= nil,
    "got: " .. file_text
  )
end

-- Test 2: whole_file mode replaces the entire file
do
  local target = tmp .. "/journal.org"
  vim.fn.writefile({ "OLD CONTENT 1", "OLD CONTENT 2" }, target)
  capture.start({
    name = "T2",
    target = { kind = "file", path = target },
    body = "* Today\n  - Wrote a thing.\n",
    whole_file = true,
  }, {})
  local cap_buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].organ_capture then
      cap_buf = b
      break
    end
  end
  capture.finalise(cap_buf)

  local file_lines = vim.fn.readfile(target)
  local file_text = table.concat(file_lines, "\n")
  check(
    "whole_file: 'OLD CONTENT 1' is GONE",
    file_text:find("OLD CONTENT", 1, true) == nil,
    "got: " .. file_text
  )
  check(
    "whole_file: file now starts with '* Today'",
    file_lines[1] == "* Today",
    "got line 1: " .. tostring(file_lines[1])
  )
  check("whole_file: file body line present", file_text:find("Wrote a thing", 1, true) ~= nil)
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("capture_compile_hooks_test: PASS")
