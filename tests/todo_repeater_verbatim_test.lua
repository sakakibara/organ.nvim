-- Marking a repeating entry DONE bumps every timestamp org reads AS a
-- timestamp and no others: Emacs guards each candidate in
-- `org-auto-repeat-maybe` with `org-at-timestamp-p 'agenda`, which asks
-- `org-element-context` what the text really is.
--
-- Verified against `emacs --batch -Q -l org` (Org 9.7.11) by marking the
-- same entries DONE: src, example, export and comment blocks, comment and
-- fixed-width lines and `=verbatim=` / `~code~` spans keep their date;
-- quote blocks, verse blocks, drawer bodies and plain paragraphs are
-- bumped.
--
-- Run via: nvim --headless -l tests/todo_repeater_verbatim_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local todo = require("organ.todo")
todo._now_for_test = function()
  return "2026-05-04"
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local HEAD = "* TODO Task\nSCHEDULED: <2026-05-01 Fri +1w>\n"
local KEPT = "<2026-05-01 Fri +1w>"
local MOVED = "<2026-05-08 Fri +1w>"

local case_n = 0
local function mark_done(body)
  case_n = case_n + 1
  local path = org_dir .. "/case" .. case_n .. ".org"
  local h = assert(io.open(path, "w"))
  h:write(HEAD .. body)
  h:close()
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  assert(todo.set(b, 1, "DONE") == nil)
  return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
end

-- Each case also asserts the SCHEDULED repeater moved, so a fix that
-- simply stopped bumping cannot pass.
local function case(label, body, expected)
  local out = mark_done(body)
  check(label .. ": SCHEDULED still bumped", out:find("SCHEDULED: " .. MOVED, 1, true) ~= nil, out)
  check(label, out:find(expected, 1, true) ~= nil, out)
end

case(
  "src block body is left alone",
  "#+begin_src org\nsample " .. KEPT .. " in src\n#+end_src\n",
  "sample " .. KEPT .. " in src"
)
case(
  "example block body is left alone",
  "#+begin_example\nsample " .. KEPT .. " in example\n#+end_example\n",
  "sample " .. KEPT .. " in example"
)
case(
  "export block body is left alone",
  "#+begin_export latex\nsample " .. KEPT .. " in export\n#+end_export\n",
  "sample " .. KEPT .. " in export"
)
case(
  "comment block body is left alone",
  "#+begin_comment\nsample " .. KEPT .. " in comment\n#+end_comment\n",
  "sample " .. KEPT .. " in comment"
)
case("fixed-width line is left alone", ": fixed " .. KEPT .. " width\n", ": fixed " .. KEPT)
case("indented fixed-width line is left alone", "  : " .. KEPT .. " deep\n", "  : " .. KEPT)
case("comment line is left alone", "# comment " .. KEPT .. " line\n", "# comment " .. KEPT)
case("indented comment line is left alone", "  # " .. KEPT .. " deep\n", "  # " .. KEPT)
case("verbatim span is left alone", "verbatim =" .. KEPT .. "= span\n", "=" .. KEPT .. "=")
case("code span is left alone", "code ~" .. KEPT .. "~ span\n", "~" .. KEPT .. "~")

-- The guard must not overshoot: these ARE bumped by Emacs.
case(
  "quote block body is still bumped",
  "#+begin_quote\nquote " .. KEPT .. " body\n#+end_quote\n",
  "quote " .. MOVED .. " body"
)
case(
  "verse block body is still bumped",
  "#+begin_verse\nverse " .. KEPT .. " body\n#+end_verse\n",
  "verse " .. MOVED .. " body"
)
case(
  "LOGBOOK drawer body is still bumped",
  ":LOGBOOK:\nlog " .. KEPT .. " entry\n:END:\n",
  "log " .. MOVED .. " entry"
)
case("plain paragraph is still bumped", "plain " .. KEPT .. " body\n", "plain " .. MOVED .. " body")
case(
  "a `#` that opens no comment is still bumped",
  "#nocomment " .. KEPT .. " here\n",
  "#nocomment " .. MOVED .. " here"
)
case(
  "a property drawer value is still bumped",
  ":PROPERTIES:\n:WHEN: " .. KEPT .. "\n:END:\n",
  ":WHEN: " .. MOVED
)
case(
  "text beside a verbatim span is still bumped",
  "before " .. KEPT .. " =lit " .. KEPT .. " eral= after\n",
  "before " .. MOVED .. " =lit " .. KEPT .. " eral= after"
)

todo._now_for_test = nil
vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("todo_repeater_verbatim_test: PASS")
os.exit(0)
