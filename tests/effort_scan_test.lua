-- Verifies organ.effort.scan, :Org migrate_effort and the effort values
-- health section.
-- Run via: nvim --headless -l tests/effort_scan_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("organ").setup({
  db_path = tmp .. "/e.db",
  org_dir = tmp,
  notify = true,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
dofile(root .. "/plugin/organ.lua")
require("organ.notify").repeat_suppress_seconds = 0

local effort = require("organ.effort")

local function eq(got, want, what)
  assert(
    vim.deep_equal(got, want),
    string.format("%s: got %s, want %s", what, vim.inspect(got), vim.inspect(want))
  )
end

local function scan(lines)
  local src = table.concat(lines, "\n") .. "\n"
  local parser = vim.treesitter.get_string_parser(src, "org")
  return effort.scan(parser:parse()[1]:root(), src)
end

-- Findings as "line:col-end_col kind value [replacement|message]".
local function brief(lines)
  local out = {}
  for _, f in ipairs(scan(lines)) do
    out[#out + 1] = ("%d:%d-%d %s %s %s"):format(
      f.line,
      f.col,
      f.end_col,
      f.kind,
      f.value,
      f.replacement or f.message
    )
  end
  return out
end

local function drawer(value)
  return brief({ "* H", ":PROPERTIES:", ":Effort: " .. value, ":END:" })
end

eq(drawer("30m"), { "3:9-12 month 30m 30min" }, "30m")
eq(drawer("1h 30m"), { "3:9-15 month 1h 30m 1h 30min" }, "1h 30m")
eq(drawer("1.5m"), { "3:9-13 month 1.5m 1.5min" }, "1.5m")
eq(drawer("30 m"), { "3:9-13 month 30 m 30 min" }, "30 m keeps spacing")
eq(drawer("30m  "), { "3:9-12 month 30m 30min" }, "trailing blanks are not the value")
eq(drawer("2d 3m 1:30"), { "3:9-19 month 2d 3m 1:30 2d 3min 1:30" }, "mixed form")
eq(drawer("30min"), {}, "30min")
eq(drawer("1:30"), {}, "1:30")
eq(drawer("90"), {}, "bare minutes")
eq(drawer("2hr"), { '3:9-12 invalid 2hr Invalid duration format: "2hr"' }, "2hr")
eq(drawer("1h30"), { '3:9-13 invalid 1h30 Invalid duration format: "1h30"' }, "1h30")
eq(drawer("30M"), { '3:9-12 invalid 30M Unknown unit: "M"' }, "30M")
eq(
  drawer("99999999999999999m"),
  { "3:9-27 invalid 99999999999999999m duration out of range" },
  "out of range"
)
eq(drawer(""), {}, "blank :Effort:")
eq(drawer("   "), {}, "blanks after :Effort:")

eq(
  brief({ "* H", ":PROPERTIES:", ":effort: 30m", ":EFFORT: 2m", ":Effort+: 3m", ":END:" }),
  { "3:9-12 month 30m 30min", "4:9-11 month 2m 2min" },
  "key case; Effort+ is not visited"
)

eq(
  brief({ "* H", ":PROPERTIES:", ":Effort_ALL: 0:10 30m 1h 2hr", ":END:" }),
  { "3:18-21 month 30m 30min", '3:25-28 invalid 2hr Invalid duration format: "2hr"' },
  "Effort_ALL tokens"
)

eq(
  brief({
    "#+PROPERTY: Effort_ALL 30m 1:00",
    "#+property: effort 45m",
    "#+PROPERTY: Effort",
    "#+PROPERTY: Other 5m",
    "* H",
  }),
  { "1:23-26 month 30m 30min", "2:19-22 month 45m 45min" },
  "#+PROPERTY keywords"
)

eq(
  brief({ ":PROPERTIES:", ":Effort: 10m", ":END:", "* H" }),
  { "2:9-12 month 10m 10min" },
  "file-level drawer"
)

eq(
  brief({
    "* H",
    "#+begin_src org",
    ":Effort: 30m",
    "#+PROPERTY: Effort 30m",
    "#+end_src",
    "#+begin_example",
    ":Effort: 30m",
    "#+end_example",
    ":LOGBOOK:",
    ":Effort: 30m",
    ":END:",
    "text",
    ":PROPERTIES:",
    ":Effort: 30m",
    ":END:",
  }),
  {},
  "blocks, other drawers and a drawer not under the headline"
)

-- :Org migrate_effort.
local lines = {
  "#+PROPERTY: Effort_ALL 30m 1:00 2hr",
  "* A",
  ":PROPERTIES:",
  ":Effort: 1h 30m",
  ":END:",
  "* B",
  ":PROPERTIES:",
  ":effort: 30M",
  ":Effort_ALL: 0:10 5m 1h30 1m",
  ":END:",
  "* C",
  ":PROPERTIES:",
  ":Effort: 30min",
  ":END:",
}
local path = tmp .. "/migrate.org"
vim.fn.writefile(lines, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local buf = vim.api.nvim_get_current_buf()
local win = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "trailing" })
vim.bo[buf].undolevels = vim.bo[buf].undolevels
local before = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

local notes = {}
local orig_notify = vim.notify
vim.notify = function(msg)
  notes[#notes + 1] = msg
end
vim.cmd("Org migrate_effort")
vim.notify = orig_notify

eq(notes, { "organ: migrate_effort: rewrote 4 effort value(s)" }, "migrate count")
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
  "#+PROPERTY: Effort_ALL 30min 1:00 2hr",
  "* A",
  ":PROPERTIES:",
  ":Effort: 1h 30min",
  ":END:",
  "* B",
  ":PROPERTIES:",
  ":effort: 30M",
  ":Effort_ALL: 0:10 5min 1h30 1min",
  ":END:",
  "* C",
  ":PROPERTIES:",
  ":Effort: 30min",
  ":END:",
  "trailing",
}, "migrated buffer")

local ll = vim.fn.getloclist(win, { title = 1, items = 1 })
eq(ll.title, ":Org migrate_effort", "loclist title")
local got = {}
for _, it in ipairs(ll.items) do
  assert(it.bufnr == buf, "loclist item buffer")
  got[#got + 1] = ("%d:%d %s"):format(it.lnum, it.col, it.text)
end
eq(got, {
  '1:35 invalid effort: 2hr (Invalid duration format: "2hr")',
  '8:10 invalid effort: 30M (Unknown unit: "M")',
  '9:24 invalid effort: 1h30 (Invalid duration format: "1h30")',
}, "loclist items at their post-rewrite columns")
local qf_open = false
for _, w in ipairs(vim.api.nvim_list_wins()) do
  qf_open = qf_open or vim.fn.getwininfo(w)[1].loclist == 1
end
assert(qf_open, "location list window opened")

vim.api.nvim_set_current_win(win)
vim.cmd("silent undo")
eq(
  table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
  before,
  "one undo restores the buffer"
)

-- A buffer with nothing to change: count 0, no location list.
vim.cmd("lclose")
vim.fn.setloclist(win, {}, "f")
vim.cmd("enew")
vim.bo.filetype = "org"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "* H", ":PROPERTIES:", ":Effort: 1:00", ":END:" })
notes = {}
vim.notify = function(msg)
  notes[#notes + 1] = msg
end
vim.cmd("Org migrate_effort")
vim.notify = orig_notify
eq(notes, { "organ: migrate_effort: rewrote 0 effort value(s)" }, "nothing to migrate")
eq(#vim.fn.getloclist(0), 0, "no location list entries")
eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[3], ":Effort: 1:00", "nothing rewritten")

-- Health: the per-file reader and the section.
local health = require("organ.health")
local hpath = tmp .. "/health.org"
vim.fn.writefile({ "* H", ":PROPERTIES:", ":Effort: 45m", ":Effort_ALL: 2hr", ":END:" }, hpath)
local findings = assert(health._effort_findings(hpath))
eq(#findings, 2, "health findings")
eq(findings[1].kind, "month", "health month finding")
eq(findings[2].kind, "invalid", "health invalid finding")
local none, err = health._effort_findings(tmp .. "/missing.org")
assert(none == nil and err, "an unreadable file reports why")

local idx = require("organ.indexer")
idx.index_file_sync(hpath)
idx.index_file_sync(path)
local missing = tmp .. "/gone.org"
vim.fn.writefile({ "* G" }, missing)
idx.index_file_sync(missing)
local missing_c = require("organ.path").canonical(missing)
vim.fn.delete(missing)
local canonical = require("organ.path").canonical
local hpath_c, path_c = canonical(hpath), canonical(path)

local messages = {}
local saved = {}
for _, level in ipairs({ "start", "ok", "warn", "error", "info" }) do
  saved[level] = vim.health[level]
  vim.health[level] = function(m, advice)
    messages[#messages + 1] = { level, m, advice }
  end
end
health.check()
for level, f in pairs(saved) do
  vim.health[level] = f
end

local section
for i, m in ipairs(messages) do
  if m[1] == "start" and m[2] == "organ effort values" then
    section = i
  end
end
assert(section, "effort values section: " .. vim.inspect(messages))
local body = {}
for i = section + 1, #messages do
  if messages[i][1] == "start" then
    break
  end
  body[#body + 1] = messages[i]
end
local function has(level, needle, advice)
  for _, m in ipairs(body) do
    if
      m[1] == level
      and m[2]:find(needle, 1, true)
      and (not advice or (m[3] and m[3][1]:find(advice, 1, true)))
    then
      return true
    end
  end
  return false
end
assert(
  has("warn", hpath_c .. ":3 45m (month", ":Org migrate_effort"),
  "health month: " .. vim.inspect(body)
)
assert(
  has("warn", hpath_c .. ":4 2hr (invalid", "org-duration cannot read this value"),
  "health invalid: " .. vim.inspect(body)
)
assert(has("warn", path_c .. ":1 30m (month"), "health second file: " .. vim.inspect(body))
assert(has("warn", missing_c .. ": not checked"), "unreadable file: " .. vim.inspect(body))

vim.fn.delete(tmp, "rf")
io.write("effort scan ok\n")
os.exit(0)
