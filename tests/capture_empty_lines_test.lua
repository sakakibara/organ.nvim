-- Capture's `empty_lines_before` / `empty_lines_after` are template-
-- level knobs that mirror Emacs's `org-capture-empty-lines-before`
-- and `org-capture-empty-lines-after`.  Defaults are 0 (Emacs
-- parity); templates can opt into N blanks before / after the
-- captured body.  This test pins the matrix:
--   * default  (nil/nil)         -> no blanks
--   * before=1                   -> one blank above
--   * after=1                    -> one blank below
--   * before=2 + after=1         -> 2 above + 1 below
--   * file_headline target with empty body + before=0
--                                -> child lands directly under parent
-- Run via: nvim --headless -l tests/capture_empty_lines_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

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
require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
local capture = require("organ.capture")

-- Helper: run a capture against a fresh inbox.org with the given
-- target + empty_lines_before/after, return the resulting lines.
local function run_capture(opts)
  local path = tmp .. "/case.org"
  vim.fn.writefile(opts.initial, path)
  local template = {
    name = "T",
    target = vim.tbl_extend("force", { path = path }, opts.target),
    body = opts.body or "* TODO Captured",
    empty_lines_before = opts.before,
    empty_lines_after = opts.after,
    no_prompts = true,
  }
  capture.start(template, { now = os.time() })
  local bufnr = vim.api.nvim_get_current_buf()
  capture.finalise(bufnr)
  return vim.fn.readfile(path)
end

-- Case 1: default (nil/nil) → no blanks before or after.
do
  local out = run_capture({
    initial = { "* Existing", "  body" },
    target = { kind = "file" },
  })
  check("default: no extra blanks", #out == 3, vim.inspect(out))
  check("default: line 1 = original", out[1] == "* Existing")
  check("default: line 2 = original body", out[2] == "  body")
  check("default: line 3 = captured headline", out[3] == "* TODO Captured")
end

-- Case 2: before=1 → one blank before captured content.
do
  local out = run_capture({
    initial = { "* Existing" },
    target = { kind = "file" },
    before = 1,
  })
  check("before=1: 3 lines total", #out == 3, vim.inspect(out))
  check("before=1: blank at line 2", out[2] == "")
  check("before=1: captured at line 3", out[3] == "* TODO Captured")
end

-- Case 3: after=1 → one blank after captured content.
do
  local out = run_capture({
    initial = { "* Existing" },
    target = { kind = "file" },
    after = 1,
  })
  check(
    "after=1: 3 lines total (existing + captured + trailing blank)",
    #out == 3,
    vim.inspect(out)
  )
  check("after=1: captured at line 2", out[2] == "* TODO Captured")
  check("after=1: blank at line 3", out[3] == "")
end

-- Case 4: before=2 + after=1 → 2 above + 1 below.
do
  local out = run_capture({
    initial = { "* Existing" },
    target = { kind = "file" },
    before = 2,
    after = 1,
  })
  check("before=2 + after=1: 5 lines total", #out == 5, vim.inspect(out))
  check("blank at line 2", out[2] == "")
  check("blank at line 3", out[3] == "")
  check("captured at line 4", out[4] == "* TODO Captured")
  check("trailing blank at line 5", out[5] == "")
end

-- Case 5: file_headline + before=0 + parent has no body
--   → child lands directly under parent (no fold artifact blank).
do
  local out = run_capture({
    initial = { "#+TITLE: Inbox", "", "* Inbox" },
    target = { kind = "file_headline", headline = "Inbox" },
    before = 0,
  })
  check("file_headline empty body: no blank between parent + child", #out == 4, vim.inspect(out))
  check("parent at line 3", out[3] == "* Inbox")
  check("child level bumped to 2", out[4] == "** TODO Captured")
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("capture_empty_lines_test: PASS")
