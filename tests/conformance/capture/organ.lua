-- organ side of the capture conformance gate: copies each case's fixture
-- files into a fresh work directory, runs the operation registered for
-- the case (OPS, keyed by the case basename) and prints the same report
-- and file dump as emacs.el.  The case format, the operations and every
-- setting are described in NORMALIZE.md.

local root = vim.fn.getcwd()
local KEY = "organ-conformance-capture"

local state = package.loaded[KEY]
if not state then
  dofile(root .. "/tests/conformance/_clock.lua").pin()
  dofile(root .. "/plugin/organ.lua")
  vim.cmd("filetype plugin indent on")
  local home = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(home, "p")
  vim.env.HOME = home
  state = { home = home, out = {}, answers = {}, clock = nil, choose = nil, items = {} }
  package.loaded[KEY] = state

  -- The clock persists its state under stdpath("data"); keep it in memory.
  local clock_state = require("organ.clock.state")
  clock_state.load = function()
    return state.clock
  end
  clock_state.save = function(s)
    state.clock = s
  end
  clock_state.clear = function()
    state.clock = nil
  end

  -- The user identity and the clipboard come from the machine; Emacs runs
  -- with user-login-name "tester" and no clipboard.
  -- luacheck: push ignore 122
  vim.uv.os_get_passwd = function()
    return { username = "tester", uid = 1000, gid = 1000, homedir = home }
  end
  local real_getreg = vim.fn.getreg
  vim.fn.getreg = function(r, ...)
    if r == "+" or r == "*" then
      return ""
    end
    return real_getreg(r, ...)
  end
  vim.notify = function(msg, level)
    if level == vim.log.levels.ERROR then
      state.out[#state.out + 1] = "ERROR: " .. tostring(msg):gsub("\n", " ") .. "\n"
    end
  end
  vim.ui.input = function(_, cb)
    cb(table.remove(state.answers, 1) or "")
  end
  vim.ui.select = function(items, opts, cb)
    local a = table.remove(state.answers, 1) or ""
    for i, it in ipairs(items) do
      local label = (opts and opts.format_item) and opts.format_item(it) or tostring(it)
      if label == a or it == a then
        return cb(it, i)
      end
    end
    cb(nil, nil)
  end
  -- luacheck: pop

  require("organ").setup({
    org_dir = home,
    notify = true,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    agenda_files = {},
    find = {
      -- Records the candidates; with state.choose set, runs the default
      -- action on the first candidate it accepts.
      backend = function(items, opts)
        state.items = items
        if state.choose then
          for _, it in ipairs(items) do
            if state.choose(it) then
              return opts.actions[opts.default_action](it)
            end
          end
        end
      end,
    },
  })
  -- Identical notifications are suppressed by the (pinned) clock.
  require("organ.notify").repeat_suppress_seconds = 0
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      vim.fn.delete(home, "rf")
    end,
  })
end

local W -- the current case's work directory

-- Settings of each option run, applied to the cases that list it.
local OPTIONS = {
  ["refile-current-file"] = function(cfg)
    cfg.refile.targets = { { files = "current", max_level = 1 } }
  end,
  ["uuid-v4"] = function(cfg)
    cfg.links.id_method = "uuidv4"
  end,
  ["attach-no-link"] = function(cfg)
    cfg.attach.auto_insert_link = false
  end,
  ["flush-left-drawers"] = function(cfg)
    cfg.todo.planning_indent = 0
  end,
}

local function msg(fmt, ...)
  state.out[#state.out + 1] = string.format(fmt, ...) .. "\n"
end

-- An error organ raises is a crash; the normalizer keeps its text, while
-- an ERROR (organ's or Emacs's refusal) is compared by its presence.
local function crash(err)
  local m = tostring(err):gsub("%S*%.lua:%d+: ", ""):gsub('%[string "[^"]*"%]:%d+: ', "")
  msg("CRASH: %s", (m:gsub("\n", " ")))
end

local function try(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    crash(err)
  end
  return ok, err
end

local function path(file)
  return W .. "/" .. file
end

local function rel(p)
  p = vim.fn.resolve(p)
  if p:sub(1, #W + 1) == W .. "/" then
    return p:sub(#W + 2)
  end
  return p
end

local function read(p)
  local f = io.open(p, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

-- Every file under DIR (default the work dir), sorted by path.
local function files(dir)
  dir = dir or W
  local list = vim.fn.globpath(dir, "**/*", true, true)
  vim.list_extend(list, vim.fn.globpath(dir, "**/.*", true, true))
  local seen, out = {}, {}
  for _, f in ipairs(list) do
    if vim.fn.isdirectory(f) == 0 and not seen[f] then
      seen[f] = true
      out[#out + 1] = f
    end
  end
  table.sort(out)
  return out
end

local function dump(list)
  pcall(vim.cmd, "silent! wall")
  for _, f in ipairs(list or files()) do
    state.out[#state.out + 1] = "=== " .. rel(f) .. "\n" .. (read(f) or "") .. "<<EOF>>\n"
  end
end

local function configure(tbl, dst)
  dst = dst or require("organ").config
  for k, v in pairs(tbl) do
    if type(v) == "table" and not vim.islist(v) and type(dst[k]) == "table" then
      configure(v, dst[k])
    else
      dst[k] = v
    end
  end
end

local function visit(file, search)
  local p = path(file)
  local existing = vim.fn.bufnr(p)
  if existing > 0 and vim.api.nvim_buf_is_loaded(existing) then
    vim.api.nvim_set_current_buf(existing)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(p))
  end
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  if search then
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local s = vim.fn.match(l, search)
      if s >= 0 then
        vim.api.nvim_win_set_cursor(0, { i, s })
        break
      end
    end
  end
  return buf
end

local function index()
  local indexer = require("organ.indexer")
  for _, f in ipairs(vim.fn.globpath(W, "**/*.org", false, true)) do
    local ok, err = pcall(indexer.index_file_sync, f)
    if not ok then
      crash(err)
    end
  end
end

local function line_at(file, lnum)
  local lines = vim.fn.readfile(file)
  return string.format("%s:%d %s", rel(file), lnum, lines[lnum] or "")
end

-- Run FN; returns whether it asked for `startinsert!` (the cursor then
-- sits at the end of its line).  Wrapping vim.cmd is the point.
local function watching_insert(fn)
  local eol = false
  local real_cmd = vim.cmd
  -- luacheck: push ignore 122
  vim.cmd = setmetatable({}, {
    __call = function(_, c)
      if c == "startinsert!" then
        eol = true
      end
      return real_cmd(c)
    end,
    __index = real_cmd,
  })
  local ok, res = pcall(fn)
  vim.cmd = real_cmd
  -- luacheck: pop
  if not ok then
    crash(res)
  end
  return eol
end

-- Type TEXT where the cursor is (at the end of the line after `startinsert!`).
local function type_at_cursor(text, eol)
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_buf_get_lines(buf, cur[1] - 1, cur[1], false)[1] or ""
  local col = eol and #line or cur[2]
  vim.api.nvim_buf_set_text(
    buf,
    cur[1] - 1,
    col,
    cur[1] - 1,
    col,
    vim.split(text, "\n", { plain = true })
  )
end

-- Start a capture; returns the capture buffer (or nil) and the eol flag.
local function start(template, ctx)
  local capture = require("organ.capture")
  local before = vim.api.nvim_get_current_buf()
  local eol = watching_insert(function()
    capture.start(template, ctx or capture.build_ctx())
  end)
  local buf = vim.api.nvim_get_current_buf()
  if buf == before or not vim.b[buf].organ_capture then
    return nil, eol
  end
  return buf, eol
end

local function capture(template, text, ctx)
  local buf, eol = start(template, ctx)
  if not buf then
    return
  end
  if text then
    type_at_cursor(text, eol)
  end
  vim.cmd("stopinsert")
  try(require("organ.capture").finalise, buf)
  -- A failed finalise leaves the capture open; Emacs aborts the capture.
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function headline(file, title)
  return { kind = "file_headline", path = path(file), headline = title }
end

local function clock_in(file, search)
  local buf = visit(file, search)
  try(require("organ.clock").start, { bufnr = buf, line = vim.fn.line(".") })
end

local function clock_out()
  if state.clock then
    try(require("organ.clock").stop)
  end
end

local function shape(s)
  return (s:gsub("[A-F]", "H"):gsub("[0-9a-f]", "h"))
end

local function refile_to(title, opts)
  visit("src.org", "Move me")
  state.choose = function(it)
    return it.title == title
  end
  try(require("organ.refile").refile, opts)
end

local function refile_labels()
  local out = {}
  for _, it in ipairs(state.items) do
    local olp = it.olp and table.concat(it.olp, "/") or ""
    out[#out + 1] = string.format(
      "%s:%s%s",
      vim.fn.fnamemodify(it.file_path, ":t"),
      olp ~= "" and (olp .. "/") or "",
      it.title
    )
  end
  table.sort(out)
  return out
end

local function refile_targets(targets)
  require("organ").config.refile.targets = targets
  visit("src.org", "Move me")
  state.choose = nil
  state.items = {}
  try(require("organ.refile").refile)
  for _, l in ipairs(refile_labels()) do
    msg("%s", l)
  end
end

local function archive(file, search, location)
  if location then
    require("organ").config.archive.location = location
  end
  visit(file, search)
  local err = require("organ.archive").archive_subtree()
  if err then
    msg("ERROR: %s", err)
  end
end

local function publish_listing()
  for _, f in ipairs(files()) do
    local r = rel(f)
    if r:match("sitemap%.org$") then
      msg("=== %s\n%s<<EOF>>", r, read(f))
    elseif r:match("%.html$") then
      local hs = {}
      for h in read(f):gmatch('href="([^"#]*)') do
        hs[#hs + 1] = h
      end
      msg("--- %s hrefs: %s", r, table.concat(hs, " "))
    else
      msg("--- %s", r)
    end
  end
end

local function db_rows(sql, ncol)
  local db = require("organ.db")
  local st = require("organ.runtime").db():prepare(sql)
  local rows = {}
  while st:step() == db.SQLITE_ROW do
    local r = {}
    for i = 0, ncol - 1 do
      r[#r + 1] = st:column_text(i) or "nil"
    end
    rows[#rows + 1] = r
  end
  st:finalize()
  return rows
end

local OPS = {}

-- Capture: template types and placement

OPS["capture-entry-file"] = function()
  capture({
    name = "a",
    target = { kind = "file", path = path("notes.org") },
    body = "* TODO %?\n  %U",
  }, "Buy milk")
  dump()
end

OPS["capture-file-headline"] = function()
  capture({ name = "a", target = headline("a.org", "Tasks"), body = "* TODO %?" }, "first")
  capture({ name = "b", target = headline("b.org", "Inbox"), body = "* TODO %?" }, "second")
  dump()
end

OPS["capture-entry-without-star"] = function()
  capture({ name = "a", target = headline("a.org", "Tasks"), body = "Note %?" }, "x")
  capture({ name = "b", target = { kind = "file", path = path("a.org") }, body = "Loose %?" }, "y")
  dump()
end

OPS["capture-relevel"] = function()
  capture({ name = "a", target = headline("a.org", "Tasks"), body = "** Sub %?\n*** child" }, "x")
  capture({
    name = "b",
    target = { kind = "file", path = path("a.org") },
    body = "*** Deep %?\n**** deeper",
  }, "y")
  dump()
end

OPS["capture-prepend"] = function()
  capture(
    { name = "a", prepend = true, target = headline("a.org", "Tasks"), body = "* NEW %?" },
    "x"
  )
  capture({
    name = "b",
    prepend = true,
    target = { kind = "file", path = path("b.org") },
    body = "* TOP %?",
  }, "y")
  dump()
end

OPS["capture-types"] = function()
  capture(
    { name = "p", type = "plain", target = headline("pl.org", "Plain"), body = "plain %?" },
    "X"
  )
  capture({ name = "i", type = "item", target = headline("li.org", "List"), body = "item %?" }, "X")
  capture({
    name = "c",
    type = "checkitem",
    target = headline("ch.org", "Check"),
    body = "- [ ] %?",
  }, "X")
  capture({
    name = "t",
    type = "table-line",
    target = headline("ta.org", "Table"),
    body = "| %? | z |",
  }, "X")
  capture(
    { name = "e", type = "item", target = headline("em.org", "Empty"), body = "first %?" },
    "X"
  )
  dump()
end

OPS["capture-file-regexp"] = function()
  local function re(file, pattern)
    return { kind = "file_regexp", path = path(file), regexp = pattern }
  end
  capture({ name = "1", target = re("e1.org", "marker"), body = "* E1 %?" }, "x")
  capture({ name = "2", target = re("e2.org", "^%* B"), body = "* E2 %?" }, "x")
  capture({ name = "3", type = "plain", target = re("p1.org", "marker"), body = "P1 %?" }, "x")
  capture({
    name = "4",
    type = "plain",
    prepend = true,
    target = re("p2.org", "marker"),
    body = "P2 %?",
  }, "x")
  dump()
end

OPS["capture-file-olp"] = function()
  local function olp(file, list)
    return { kind = "file_olp", path = path(file), olp = list }
  end
  msg("-- olp")
  capture({ name = "a", target = olp("a.org", { "Projects", "Tasks" }), body = "* NEW %?" }, "x")
  msg("-- duplicate olp")
  capture({ name = "b", target = olp("dup.org", { "Proj", "Dup" }), body = "* D %?" }, "y")
  msg("-- missing olp")
  capture({ name = "c", target = olp("a.org", { "Projects", "Nope" }), body = "* M %?" }, "z")
  dump()
end

OPS["capture-empty-lines"] = function()
  capture(
    { name = "a", empty_lines = 1, target = headline("a.org", "Tasks"), body = "* E %?" },
    "x"
  )
  capture({
    name = "c",
    empty_lines_before = 2,
    empty_lines_after = 1,
    target = headline("c.org", "Tasks"),
    body = "* C %?",
  }, "x")
  dump()
end

OPS["capture-blank-separated-file"] = function()
  capture(
    { name = "b", target = { kind = "file", path = path("blank.org") }, body = "* B %?" },
    "x"
  )
  dump()
end

OPS["capture-template-whitespace"] = function()
  capture({
    name = "a",
    target = headline("n.org", "Inbox"),
    body = "\n\n* W %?\n\tTabbed\nTrail   \n\n\n",
  }, "x")
  capture({ name = "b", target = headline("n.org", "Inbox"), body = "* NoCursor" }, " tail")
  dump()
end

OPS["capture-targets"] = function()
  index()
  msg("-- id target")
  capture({ name = "i", target = { kind = "id", id = "tgt-1" }, body = "* I %?" }, "x")
  msg("-- file+function target")
  capture({
    name = "f",
    target = {
      kind = "file_function",
      fn = function()
        for i, l in ipairs(vim.fn.readfile(path("fn.org"))) do
          if l:match("^%* B") then
            return path("fn.org"), i
          end
        end
      end,
    },
    body = "* F %?",
  }, "x")
  msg("-- clock target")
  clock_in("clk.org", "^\\* Clocked")
  capture({ name = "k", target = { kind = "clock" }, body = "* K %?" }, "x")
  clock_out()
  dump()
end

OPS["capture-missing-directory"] = function()
  capture(
    { name = "n", target = { kind = "file", path = path("sub/new.org") }, body = "* N %?" },
    "x"
  )
  dump()
end

OPS["capture-template-properties"] = function()
  local capture_mod = require("organ.capture")
  local buf = start({
    name = "i",
    immediate_finish = true,
    target = headline("n.org", "Inbox"),
    body = "* IMM done",
  })
  msg("capture buffer open after immediate-finish: %s", buf and "yes" or "no")
  if buf then
    vim.cmd("stopinsert")
    capture_mod.cancel(buf)
  end
  local eol
  buf, eol = start({
    name = "c",
    clock_in = true,
    target = headline("n.org", "Inbox"),
    body = "* CLK %?",
  })
  if buf then
    type_at_cursor("x", eol)
    msg("clocking during capture: %s", state.clock and "yes" or "no")
    vim.cmd("stopinsert")
    try(capture_mod.finalise, buf)
  end
  clock_out()
  capture({
    name = "j",
    jump_to_captured = true,
    target = headline("n.org", "Inbox"),
    body = "* JMP %?",
  }, "x")
  msg(
    "after finalize: buffer=%s line=%s",
    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
    vim.api.nvim_get_current_line()
  )
  dump()
end

-- Capture: %-escapes

OPS["capture-escapes-basic"] = function()
  vim.fn.setreg("0", "KILLED")
  visit("src.org", "some body")
  capture({
    name = "a",
    target = headline("n.org", "Inbox"),
    body = "* E %?\nn=%n\nt=%t\npct=%%\nT=%T\nesc=\\%t\nu=%u\nU=%U\nlt=%<%Y/%m %H>\nf=%f\nF=%F\nx=%x\nc=%c\nunknown=%q %z",
  }, "1")
  dump()
end

OPS["capture-escapes-annotation"] = function()
  index()
  local a = { name = "a", target = headline("n.org", "Inbox"), body = "* A %?\na=%a" }
  visit("src.org", "some body")
  capture(a, "body")
  visit("src.org", "^\\* Source")
  capture(a, "heading")
  visit("src.org", "id body")
  capture(a, "id")
  state.answers = { "DESC" }
  visit("src.org", "some body")
  capture({
    name = "b",
    target = headline("links.org", "Inbox"),
    body = "* B %?\nl=%l\nL=%L\nA=%A\nkw=%:file|%:link|%:description",
  }, "links")
  dump()
end

OPS["capture-escapes-clock-file-sexp"] = function()
  clock_in("src.org", "^\\* Clocked")
  visit("src.org", "region line one")
  local ctx = require("organ.capture").build_ctx()
  -- organ reads %i from Visual mode, which a headless run cannot enter;
  -- the selection is supplied as build_ctx records it.
  ctx.visual_text = "region line one\nregion line two\n"
  capture({
    name = "a",
    target = headline("n.org", "Inbox"),
    body = "* M %?\nk=%k\nK=%K\ninc=%["
      .. path("inc.txt")
      .. "]\nsexp=%(number-to-string (+ 1 2))\n  > %i\n",
  }, "x", ctx)
  clock_out()
  dump()
end

OPS["capture-escapes-prompts"] = function()
  vim.fn.setreg("0", "KILLTEXT")
  local runs = {
    { "* G %? %^g", { "work:home" } },
    {
      "* DATES %?\nt=%^t\nT=%^T\nu=%^u\nU=%^U",
      { "+1d", "2026-05-06 9:15", "fri", "2026-05-07 10:00-11:30" },
    },
    { "* PICK %?\npick=%^{Pick|dflt|c1|c2}", { "" } },
    { "* NAME %?\nname=%^{Name}\nback=%\\1", { "Alice" } },
    { "* WHEN %?\nwhen=%^{When}t", { "2026-05-10" } },
    { "* GCL %?\nG=%^G\nC=%^C\nL=%^L", { "x", "KILLTEXT", "KILLTEXT" } },
    { "* PROP %?\n%^{Effort}p", { "1:30" } },
  }
  for _, r in ipairs(runs) do
    state.answers = vim.deepcopy(r[2])
    capture({ name = "p", target = headline("n.org", "Inbox"), body = r[1] }, "body")
  end
  dump()
end

-- Capture: datetree

local function datetree(file, extra)
  local t = { kind = "file_olp_datetree", path = path(file) }
  return vim.tbl_extend("force", t, extra or {})
end

OPS["capture-datetree"] = function()
  capture({ name = "a", target = datetree("new.org"), body = "* %?" }, "one")
  capture({ name = "b", target = datetree("j.org"), body = "* %?" }, "two")
  capture(
    { name = "c", target = datetree("p.org", { olp = { "Journal" } }), body = "* %?" },
    "three"
  )
  capture({ name = "d", target = datetree("j.org"), body = "* %?" }, "four")
  dump()
end

OPS["capture-datetree-existing"] = function()
  capture({ name = "p", target = datetree("prop.org"), body = "* %?" }, "P")
  capture({ name = "l", target = datetree("loc.org"), body = "* %?" }, "L")
  capture({ name = "t", target = datetree("todo.org"), body = "* %?" }, "T")
  dump()
end

OPS["capture-datetree-week-month"] = function()
  capture({ name = "w", tree_type = "week", target = datetree("w.org"), body = "* %?" }, "wk")
  capture({ name = "m", tree_type = "month", target = datetree("m.org"), body = "* %?" }, "mo")
  dump()
end

OPS["capture-datetree-tree-types"] = function()
  capture({
    name = "q",
    tree_type = { "year", "quarter", "month" },
    target = datetree("q.org"),
    body = "* %?",
  }, "Q")
  state.answers = { "2026-02-14" }
  capture({ name = "p", time_prompt = true, target = datetree("p.org"), body = "* %? %U" }, "P")
  capture({ name = "s", target = datetree("s.org"), body = "* %?" }, "S")
  dump()
end

-- Refile

OPS["refile-default-targets"] = function()
  index()
  refile_targets(require("organ").config.refile.targets)
end

OPS["refile-targets"] = function()
  index()
  msg("-- current file, maxlevel 2")
  refile_targets({ { files = "current", max_level = 2 } })
  msg("-- tgt.org level 1, current file level 3")
  refile_targets({ { files = { path("tgt.org") }, level = 1 }, { files = "current", level = 3 } })
  msg("-- tag t, keyword TODO, regexp Alp")
  refile_targets({
    { files = "current", tag = "t" },
    { files = "current", todo = "TODO" },
    { files = "current", regex = "Alp" },
  })
end

local function to_tgt(extra)
  configure({
    refile = vim.tbl_extend(
      "force",
      { targets = { { files = { path("tgt.org") }, max_level = 3 } } },
      extra or {}
    ),
  })
  index()
end

OPS["refile-move"] = function()
  to_tgt()
  refile_to("Target")
  dump()
end

OPS["refile-copy"] = function()
  to_tgt()
  refile_to("Target", { copy = true })
  dump()
end

OPS["refile-same-file"] = function()
  configure({ refile = { targets = { { files = "current", max_level = 3 } } } })
  index()
  refile_to("Alpha")
  index()
  visit("src.org", "^\\* Done")
  state.choose = function(it)
    return it.title == "Projects"
  end
  try(require("organ.refile").refile)
  dump()
end

OPS["refile-top-level"] = function()
  to_tgt({ use_outline_path = "file" })
  visit("src.org", "Move me")
  state.choose = function(it)
    return it.kind == "file" or it.title == "tgt.org"
  end
  try(require("organ.refile").refile)
  dump()
end

OPS["refile-create-parent"] = function()
  to_tgt({ use_outline_path = "file" })
  refile_to("New Parent")
  dump()
end

OPS["refile-reverse-order"] = function()
  to_tgt()
  refile_to("Target")
  dump()
end

OPS["refile-log"] = function()
  to_tgt()
  configure({ todo = { log_refile = "time", log_into_drawer = true } })
  refile_to("Target")
  dump()
end

-- Archive

OPS["archive-default"] = function()
  for _, s in ipairs({ "Child task", "Sibling", "Top level" }) do
    archive("src.org", s)
  end
  dump()
end

OPS["archive-heading-location"] = function()
  archive("src.org", "Child task", "old.org::* Old Stuff")
  dump()
end

OPS["archive-level-2-heading"] = function()
  archive("src.org", "Sibling", "lvl2.org::** Deep Archive")
  dump()
end

OPS["archive-missing-directory"] = function()
  archive("src.org", "Top level", "arch/%s::")
  dump()
end

OPS["archive-in-file"] = function()
  archive("src.org", "Child task", "::* Archive")
  dump()
end

OPS["archive-keyword-after-line-50"] = function()
  archive("late.org", "^\\* Entry")
  dump()
end

OPS["archive-keyword-first-wins"] = function()
  archive("multi.org", "^\\* Entry")
  dump()
end

OPS["archive-inherited-property"] = function()
  archive("inherit.org", "Child")
  dump()
end

OPS["archive-mark-done"] = function()
  configure({ archive = { mark_done = true } })
  archive("src.org", "Child task")
  dump()
end

-- organ has no archive-all-done command: the files stay as they are.
OPS["archive-all-done"] = function()
  dump()
end

OPS["archive-reversed-order"] = function()
  configure({ archive = { reversed_order = true } })
  archive("src.org", "d1")
  archive("src.org", "d2")
  dump()
end

OPS["archive-location-without-colons"] = function()
  archive("src.org", "d1", "no-colons.org")
  dump()
end

OPS["archive-sibling"] = function()
  for _, s in ipairs({ "Child task", "Sibling", "Other" }) do
    visit("src.org", s)
    local err = require("organ.archive").archive_to_sibling()
    if err then
      msg("ERROR: %s", err)
    end
  end
  dump()
end

OPS["archive-tag-toggle"] = function()
  visit("src.org", "Child task")
  for i = 1, 2 do
    local err = require("organ.archive").set_archive_tag()
    if err then
      msg("ERROR: %s", err)
    end
    msg("after toggle %d: %s", i, vim.api.nvim_get_current_line())
  end
  dump()
end

OPS["archive-datetree"] = function()
  archive("src.org", "Child task", "%s_archive::datetree/")
  dump()
end

-- Attach

OPS["attach-id-layouts"] = function()
  local att = require("organ.attach")
  for _, p in ipairs({ "UUID heading", "TS heading", "Short heading", "Dir heading", "Child no id" }) do
    local b = visit("a.org", p)
    local err = att.attach(b, vim.fn.line("."), path("file.txt"))
    if err then
      msg("ERROR: %s", err)
    else
      local d = att.dir(b, vim.fn.line("."), { create = false })
      msg("%s: dir=%s", p, d and rel(d) or "nil")
    end
  end
  visit("a.org", "UUID heading")
  local r = require("organ.link").open("attachment:file.txt", path("a.org"))
  msg("attachment:file.txt -> %s", r.path and rel(r.path) or ("ERROR: " .. tostring(r.reason)))
  dump()
end

OPS["attach-existing-dirs"] = function()
  for _, p in ipairs({ "TS heading", "Short" }) do
    local b = visit("a.org", p)
    local d, err = require("organ.attach").dir(b, vim.fn.line("."), { create = false })
    if d then
      msg("%s: existing dir=%s", p, rel(d))
    else
      msg("ERROR: %s", tostring(err))
    end
    local r = require("organ.link").open("attachment:old.txt", path("a.org"))
    if r.path then
      msg("%s: attachment:old.txt -> %s", p, rel(r.path))
    else
      msg("ERROR: %s", tostring(r.reason))
    end
  end
end

-- org-id

OPS["id-create"] = function()
  local id = require("organ.id")
  local cfg = require("organ").config.links
  local b = visit("a.org", "Plain heading")
  local v = id.get_or_create(b, vim.fn.line("."))
  msg("-- uuid\n%s version %s", shape(v), v:sub(15, 15))
  for _, s in ipairs({ "Planned heading", "With drawer", "Intro" }) do
    visit("a.org", s)
    try(id.get_or_create, b, vim.fn.line("."))
  end
  local method = cfg.id_method
  cfg.id_method = "ts"
  local ts = id.generate()
  msg("-- ts method\n%s%s", ts:sub(1, 15), (ts:sub(16):gsub("%d", "d")))
  cfg.id_method = "org"
  msg("-- org method")
  try(function()
    msg("%s", shape(id.generate()))
  end)
  cfg.id_method = method
  msg("-- prefix\n%s", shape(id.generate()))
  dump()
end

OPS["id-duplicate"] = function()
  msg("-- index")
  index()
  msg("-- lookup")
  local q = require("organ.query")
  for _, i in ipairs({ "same-id", "file-level-id" }) do
    local r = q.get_by_id(i)
    msg("%s -> %s", i, r and line_at(r.file_path, r.line_start + 1) or "nil")
  end
  msg("-- file-level attach")
  local b = visit("d.org")
  local err = require("organ.attach").attach(b, 1, path("file.txt"))
  if err then
    msg("ERROR: %s", err)
  else
    local d = require("organ.attach").dir(b, 1, { create = false })
    msg("dir=%s", d and rel(d) or "nil")
  end
  dump()
end

OPS["id-links-locations"] = function()
  configure({ links = { id_locations_file = path("id-locations") } })
  index()
  require("organ.id").export_locations()
  for _, l in ipairs({
    "id:aaa-111",
    "id:aaa-111::*Sub two",
    "id:file-b",
    "id:dup-1",
    "id:missing-1",
  }) do
    local r = require("organ.link").open(l, path("a.org"))
    if r.kind == "jump_headline" then
      msg("[[%s]] -> %s", l, line_at(r.file_path, r.line))
    else
      msg("ERROR: %s", tostring(r.reason))
    end
  end
  dump()
end

-- org-roam

OPS["roam-nodes"] = function()
  index()
  msg("-- nodes")
  for _, r in
    ipairs(
      db_rows("SELECT id, level, title FROM headlines WHERE id NOT LIKE '%#L%' ORDER BY id", 3)
    )
  do
    msg("node %s\n  level %s\n  title %s", r[1], r[2], r[3])
  end
  msg("-- aliases")
  for _, r in ipairs(db_rows("SELECT headline_id, alias FROM aliases ORDER BY 1, 2", 2)) do
    msg("%s %s", r[1], r[2])
  end
  msg("-- refs")
  msg("-- id links (source -> target)")
  local links = {}
  for _, r in
    ipairs(db_rows("SELECT source_headline_id, target FROM links WHERE target_type = 'id'", 2))
  do
    links[#links + 1] = r[1] .. " -> " .. r[2]
  end
  table.sort(links)
  for _, l in ipairs(links) do
    msg("%s", l)
  end
  msg("-- org-id lookup")
  for _, i in ipairs({ "n1", "n2", "id-three" }) do
    local r = require("organ.query").get_by_id(i)
    msg("%s -> %s", i, r and line_at(r.file_path, r.line_start + 1) or "nil")
  end
end

-- Open today's daily and type TEXT at the end of the line organ puts the
-- cursor on.
local function daily(text)
  try(require("organ.roam.dailies").today)
  type_at_cursor(text, true)
  vim.cmd("stopinsert")
  vim.cmd("silent write")
end

OPS["roam-create-node"] = function()
  configure({ roam = { dir = W } })
  try(require("organ.roam").create_node, "My First Note")
  pcall(vim.cmd, "silent write")
  daily("daily entry")
  msg("-- slugs")
  for _, s in ipairs(vim.fn.readfile(path("slugs.txt"))) do
    msg('"%s" -> "%s"', s, require("organ.slug").slugify(s))
  end
  local list = vim.tbl_filter(function(f)
    return not f:match("/slugs%.txt$")
  end, files())
  dump(list)
end

OPS["roam-daily-existing"] = function()
  configure({ roam = { dir = W } })
  index()
  daily("second")
  dump()
end

OPS["roam-links"] = function()
  configure({ roam = { dir = W } })
  index()
  for _, l in ipairs({ "roam:Note One", "roam:Alias One" }) do
    local r = require("organ.link").open(l, path("l.org"))
    if r.kind == "jump_headline" then
      msg("[[%s]] -> %s", l, line_at(r.file_path, r.line))
    else
      msg("[[%s]] -> (%s)", l, tostring(r.kind))
    end
  end
end

-- Publish

OPS["publish-recursive-sitemap"] = function()
  configure({
    publish = {
      projects = {
        flat = {
          base_directory = path("src"),
          publishing_directory = path("pub-flat"),
          publishing_function = "html",
        },
        full = {
          base_directory = path("src"),
          publishing_directory = path("pub-full"),
          recursive = true,
          exclude = "draft",
          with_sitemap = true,
          publishing_function = "html",
        },
      },
    },
  })
  local pub = require("organ.publish")
  for _, n in ipairs({ "flat", "full" }) do
    local r, err = pub.publish(n)
    if not r then
      msg("ERROR: %s", tostring(err))
    end
  end
  publish_listing()
  vim.fn.writefile({ "STALE" }, path("pub-flat/index.html"))
  pub.publish("flat")
  msg(
    "after re-publish, pub-flat/index.html starts: %s",
    read(path("pub-flat/index.html")):sub(1, 5)
  )
end

OPS["publish-exclude"] = function()
  for _, ex in ipairs({ "^draft", "draft\\.org", "old.draft" }) do
    local seen = {}
    require("organ").config.publish.projects = {
      p = {
        base_directory = path("src"),
        publishing_directory = path("pub"),
        exclude = ex,
        publishing_function = function(src)
          seen[#seen + 1] = vim.fn.fnamemodify(src, ":t")
          return src
        end,
      },
    }
    require("organ.publish").publish("p")
    table.sort(seen)
    msg("exclude %s -> %s", ex, table.concat(seen, " "))
  end
end

OPS["publish-components"] = function()
  configure({
    publish = {
      projects = {
        idx = {
          base_directory = path("src"),
          publishing_directory = path("pub"),
          makeindex = true,
          include = { "extra.txt" },
          publishing_function = "html",
        },
        static = {
          base_directory = path("src"),
          base_extension = "css",
          publishing_directory = path("pub"),
          publishing_function = "attachment",
        },
        site = { components = { "idx", "static" } },
      },
    },
  })
  local r, err = require("organ.publish").publish("site")
  if not r then
    msg("ERROR: %s", tostring(err))
  end
  for _, f in ipairs(files()) do
    msg("%s", rel(f))
  end
end

-- Driver

local function parse_case(p)
  local header, list = {}, {}
  local current
  for _, line in ipairs(vim.fn.readfile(p)) do
    local name = line:match("^#%+CONFORMANCE%-FILE: (.+)$")
    if name then
      current = { name = name, lines = {} }
      list[#list + 1] = current
    elseif current then
      current.lines[#current.lines + 1] = line
    else
      local k, v = line:match("^#%+CONFORMANCE%-(%u+): (.*)$")
      if k then
        header[#header + 1] = { key = k, value = v }
      end
    end
  end
  return header, list
end

local function values(header, key)
  local out = {}
  for _, h in ipairs(header) do
    if h.key == key then
      out[#out + 1] = h.value
    end
  end
  return out
end

local function replace_plain(s, from, to)
  local out, i = {}, 1
  while true do
    local a, b = s:find(from, i, true)
    if not a then
      break
    end
    out[#out + 1] = s:sub(i, a - 1) .. to
    i = b + 1
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out)
end

-- Config snapshot that keeps list values (and their identity) as they
-- are; organ compares some of them against the defaults by reference.
local function snapshot(t)
  local c = {}
  for k, v in pairs(t) do
    if type(v) == "table" and (next(v) == nil or not vim.islist(v)) then
      c[k] = { dict = snapshot(v) }
    else
      c[k] = { value = v }
    end
  end
  return c
end

local function restore(dst, snap)
  for k in pairs(dst) do
    if snap[k] == nil then
      dst[k] = nil
    end
  end
  for k, s in pairs(snap) do
    if s.dict then
      if type(dst[k]) ~= "table" then
        dst[k] = {}
      end
      restore(dst[k], s.dict)
    else
      dst[k] = s.value
    end
  end
end

local function reset()
  pcall(require("organ").drain_blocking, 5000)
  require("organ.runtime").reset()
  vim.cmd("enew!")
  local keep = vim.api.nvim_get_current_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= keep and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  state.clock = nil
  state.answers = {}
  state.choose = nil
  state.items = {}
  vim.fn.setreg("0", "")
end

local function render(p, option)
  local header, list = parse_case(p)
  local listed = vim.split(values(header, "OPTIONS")[1] or "", " ", { trimempty = true })
  if option and not vim.tbl_contains(listed, option) then
    return "(not in the " .. option .. " run)\n"
  end
  local name = vim.fn.fnamemodify(p, ":t:r")
  local organ = require("organ")
  local saved = snapshot(organ.config)
  local case_dir = state.home .. "/" .. name
  W = case_dir .. "/work"
  vim.fn.delete(case_dir, "rf")
  vim.fn.mkdir(W, "p")
  for _, d in ipairs(values(header, "DIR")) do
    vim.fn.mkdir(path(d), "p")
  end
  for _, f in ipairs(list) do
    vim.fn.mkdir(vim.fn.fnamemodify(path(f.name), ":h"), "p")
    local fh = assert(io.open(path(f.name), "wb"))
    fh:write(#f.lines > 0 and (table.concat(f.lines, "\n") .. "\n") or "")
    fh:close()
  end
  configure({
    org_dir = W,
    db_path = case_dir .. "/organ.db",
    agenda_files = { W .. "/*.org" },
  })
  if option then
    OPTIONS[option](organ.config)
  end
  require("organ.runtime").reset()
  state.out = {}
  local op = OPS[name]
  if op then
    local ok, err = pcall(op)
    if not ok then
      msg("CASE-ERROR: %s", tostring(err):gsub("\n", " "))
    end
  else
    msg("CASE-ERROR: no operation for %s", name)
  end
  local text = table.concat(state.out)
  reset()
  restore(organ.config, saved)
  text = replace_plain(text, W, "$WORK")
  return replace_plain(text, vim.fn.fnamemodify(W, ":~"), "~$WORK")
end

return { render = render }
