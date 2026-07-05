-- Every function that INSERTS org markup must emit text that is already in
-- its post-format shape: running the formatter over a freshly-inserted
-- element must be a no-op (byte-identical, modulo the final-newline pass).
-- Otherwise a format-on-save silently reshuffles text the user just
-- inserted -- exactly the roam `:ID:` bug.  One block per insertion
-- function; each inserts into a buffer, formats, and asserts a fixpoint.
--
-- Run via: nvim --headless -l tests/format_insertion_stable_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local fmt = require("organ.format")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function new_org(lines)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function trim_trailing_blank(t)
  local n = #t
  while n > 0 and t[n] == "" do
    n = n - 1
  end
  local o = {}
  for i = 1, n do
    o[i] = t[i]
  end
  return o
end

-- Insert via `build`, then assert format_buffer is a fixpoint.
local function stable(label, build)
  local b = build()
  local before = trim_trailing_blank(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  fmt.format_buffer(b)
  local after = trim_trailing_blank(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  local ok = #before == #after
  if ok then
    for i = 1, #before do
      if before[i] ~= after[i] then
        ok = false
        break
      end
    end
  end
  check(
    label,
    ok,
    not ok and ("inserted=" .. vim.inspect(before) .. "\n     formatted=" .. vim.inspect(after))
      or nil
  )
end

stable("property.set writes a format-stable :ID: drawer", function()
  local b = new_org({ "* Heading", "body" })
  require("organ.property").set(b, 1, "ID", "abc-12345")
  return b
end)

stable("section.set_planning writes a format-stable SCHEDULED line", function()
  local b = new_org({ "* Heading", "body" })
  require("organ.section").set_planning(b, 0, "SCHEDULED", "<2026-06-17 Wed>")
  return b
end)

stable("logbook state entry is format-stable", function()
  local b = new_org({ "* TODO Heading", "body" })
  local lb = require("organ.logbook")
  lb.append(b, 1, lb.build_state_entry("TODO", "DONE", nil))
  return b
end)

stable("checkbox.toggle inserts a format-stable [ ]", function()
  local b = new_org({ "- item one", "- item two" })
  require("organ.checkbox").toggle({ bufnr = b, line = 1 })
  return b
end)

-- footnote.insert parks the cursor on an empty `[fn:1] ` stub; that lone
-- trailing space is a transient editing affordance (the formatter trims it
-- to the valid empty def `[fn:1]`, no corruption).  The contract that
-- matters: the reference plus a WRITTEN definition is a fixpoint.
stable("footnote.insert ref + written definition is format-stable", function()
  local b = new_org({ "* Heading", "some text here", "" })
  vim.api.nvim_win_set_cursor(0, { 2, 14 })
  require("organ.footnote").insert({ label = 1 })
  local defline = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(b, defline - 1, defline, false, { "[fn:1] the footnote body." })
  return b
end)

stable("inline_edit.set_priority is format-stable", function()
  local b = new_org({ "* TODO Heading" })
  require("organ.inline_edit").set_priority(b, 1, "A")
  return b
end)

stable("meta_return new headline is format-stable", function()
  local b = new_org({ "* First", "body of first" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  require("organ.meta_return").dispatch({ enter_insert = false })
  return b
end)

stable("tempo src-block expansion is format-stable", function()
  local b = new_org({ "<s" })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  require("organ.tempo").expand(b)
  return b
end)

-- roam node file: whole-file fixpoint (header + any body template).
do
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  require("organ").setup({
    org_dir = tmp,
    db_path = tmp .. "/x.db",
    notify = false,
    scan_on_startup = false,
    watcher = { enabled = false },
    roam = { dir = tmp .. "/roam" },
  })
  require("organ.roam").create_node("Fixpoint Note")
  local path = vim.fn.glob(tmp .. "/roam/*-fixpoint_note.org", false, true)[1]
  local lines = vim.fn.readfile(path)
  local formatted = fmt.format_lines(vim.deepcopy(lines))
  local same = #trim_trailing_blank(lines) == #trim_trailing_blank(formatted)
  if same then
    local a, b2 = trim_trailing_blank(lines), trim_trailing_blank(formatted)
    for i = 1, #a do
      if a[i] ~= b2[i] then
        same = false
        break
      end
    end
  end
  check(
    "roam.create_node file is a format fixpoint",
    same,
    not same and ("file=" .. vim.inspect(lines) .. "\n     formatted=" .. vim.inspect(formatted))
      or nil
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_insertion_stable_test: PASS")
os.exit(0)
