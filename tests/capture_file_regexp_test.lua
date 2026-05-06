-- Capture target.kind = "file_regexp" — Emacs `(file+regexp ...)`.
-- Insert at the first line whose text matches `regexp`.
-- Run via: nvim --headless -l tests/capture_file_regexp_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local path = tmp .. "/notes.org"
vim.fn.writefile({
  "* Header A",
  "  body of A",
  "** TODO Insert here",
  "  body",
  "* Header B",
  "  body of B",
}, path)

require("organ").setup({
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local target = require("organ.capture.target")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Default (prepend = false): insert AFTER the matched line.
local p, line = target.resolve({
  kind = "file_regexp",
  path = path,
  regexp = "TODO Insert here",
}, {}, false)
check(
  "file_regexp default: insert at line 4 (after match on line 3)",
  p == path and line == 4,
  "got: path=" .. tostring(p) .. " line=" .. tostring(line)
)

-- prepend = true: insert ABOVE the matched line.
local _, line2 = target.resolve({
  kind = "file_regexp",
  path = path,
  regexp = "TODO Insert here",
}, {}, true)
check(
  "file_regexp prepend: insert at line 3 (above match)",
  line2 == 3,
  "got line=" .. tostring(line2)
)

-- Pattern matches a non-headline body line.
local _, line3 = target.resolve({
  kind = "file_regexp",
  path = path,
  regexp = "body of B",
}, {}, false)
check(
  "file_regexp matches body line: insert after line 6",
  line3 == 7,
  "got line=" .. tostring(line3)
)

-- Missing regex → error (validation).
local ok, err = pcall(target.resolve, {
  kind = "file_regexp",
  path = path,
}, {}, false)
check(
  "file_regexp missing regexp errors",
  ok == false and err and err:find("regexp") ~= nil,
  "got: ok=" .. tostring(ok) .. " err=" .. tostring(err)
)

-- No match → error.
local ok2, err2 = pcall(target.resolve, {
  kind = "file_regexp",
  path = path,
  regexp = "ZZZ_NEVER_MATCHES_ZZZ",
}, {}, false)
check(
  "file_regexp no match errors",
  ok2 == false and err2 and err2:find("not matched") ~= nil,
  "got: ok=" .. tostring(ok2) .. " err=" .. tostring(err2)
)

-- Template validation accepts the new kind.
local tmpl = require("organ.capture.template")
local ok3 = pcall(tmpl.validate_all, {
  {
    name = "Test",
    body = "* %?",
    target = { kind = "file_regexp", path = path, regexp = "TODO" },
  },
})
check("template validation accepts file_regexp", ok3 == true)

-- Template validation rejects file_regexp without regexp.
local ok4, err4 = pcall(tmpl.validate_all, {
  { name = "Bad", body = "* %?", target = { kind = "file_regexp", path = path } },
})
check(
  "template validation rejects file_regexp without regexp",
  ok4 == false and err4 and err4:find("regexp") ~= nil
)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("capture_file_regexp_test: PASS")
