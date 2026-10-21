-- organ side of the todo-time conformance gate: runs each case's
-- operations (see emacs.el and NORMALIZE.md) through organ and prints the
-- buffer, then a "--- log" section, in the same shape as the Emacs side.

local root = vim.fn.getcwd()
local KEY = "organ-conformance-todo-time"

local state = package.loaded[KEY]
if not state then
  local clock = dofile(root .. "/tests/conformance/_clock.lua")
  clock.pin()
  local tmp = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")
  -- Buffer keymaps come from ftplugin/org.lua; counts reach organ through them.
  vim.cmd("filetype plugin indent on")
  require("organ").setup({
    org_dir = tmp,
    notify = true,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  })
  require("organ.notify").repeat_suppress_seconds = 0
  -- The running clock lives in memory: the real module writes
  -- <stdpath data>/organ/clock.json, which belongs to the user.
  local clock_state = require("organ.clock.state")
  local active = nil
  clock_state.load = function()
    return active and vim.deepcopy(active) or nil
  end
  clock_state.save = function(s)
    active = vim.deepcopy(s)
  end
  clock_state.clear = function()
    active = nil
  end
  state = { clock = clock, tmp = tmp, n = 0, clear_clock = clock_state.clear }
  package.loaded[KEY] = state
  -- A case's warnings and errors are its refusals; outside a case only
  -- they are shown (the indexer reports finished scans at INFO).
  local real_notify = vim.notify
  -- Replacing the UI entry points is the point, hence the ignored warning.
  -- luacheck: push ignore 122
  vim.notify = function(msg, level)
    level = level or vim.log.levels.INFO
    if state.ctx then
      if level >= vim.log.levels.WARN then
        state.ctx.refused = true
      end
    elseif level >= vim.log.levels.WARN then
      real_notify(msg, level)
    end
  end
  -- luacheck: pop
end

-- Settings of each option run, applied to the cases that list it.
local OPTIONS = {
  ["log-done-off"] = function(cfg)
    cfg.todo.log_done = false
  end,
  ["log-into-drawer-off"] = function(cfg)
    cfg.todo.log_into_drawer = false
  end,
  ["planning-indent-flush"] = function(cfg)
    cfg.todo.planning_indent = 0
  end,
}

local function parse_case(path)
  local header, files = {}, {}
  local current
  local in_header = true
  for _, line in ipairs(vim.fn.readfile(path)) do
    local name = line:match("^#%+CONFORMANCE%-FILE: (.+)$")
    local k, v = line:match("^#%+CONFORMANCE%-(%u+): ?(.*)$")
    if name then
      in_header = false
      current = { name = name, lines = {} }
      files[#files + 1] = current
    elseif in_header and k then
      header[#header + 1] = { key = k, value = v }
    else
      in_header = false
      if not current then
        current = { name = "t.org", lines = {} }
        files[#files + 1] = current
      end
      current.lines[#current.lines + 1] = line
    end
  end
  return header, files
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

local function iso_to_time(s)
  local y, mo, d, h, mi = s:match("^(%d+)-(%d+)-(%d+) (%d+):(%d+)$")
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = 0 })
end

local function fmt_number(x)
  if x == math.floor(x) then
    return string.format("%d", x)
  end
  return tostring(x)
end

local ctx

local function log(fmt, ...)
  ctx.log[#ctx.log + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

local function pop_input()
  return table.remove(ctx.inputs, 1)
end

local function cursor_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function columns()
  local cv = require("organ.column_view")
  local line = cursor_line()
  local view = cv.open(ctx.buf, line)
  if not view then
    return
  end
  vim.api.nvim_buf_delete(view, { force = true })
  vim.api.nvim_set_current_buf(ctx.buf)
  local spec, root_line = cv.find_spec(ctx.buf, line)
  local cols = cv.parse_spec(spec)
  local rows = cv.collect(ctx.buf, root_line, cols)
  cv.apply_summaries(rows, cols)
  for _, row in ipairs(rows) do
    local cells = {}
    for ci, col in ipairs(cols) do
      cells[ci] = string.format("%s=%q", col.property, row.values[ci] or "")
    end
    log("L%d: %s", row.hl_line, table.concat(cells, "  "))
  end
end

local function read_date(input)
  local da = require("organ.capture.date_answer")
  local r = da.parse(input, os.time())
  local shown = input == "" and "<EMPTY>" or input
  if not r then
    log("read-date %s -> unrecognised", shown)
    return
  end
  log(
    "read-date %s -> %s%s%s",
    shown,
    os.date("%Y-%m-%d %a %H:%M", r.time),
    r.with_time and " T" or " -",
    r.end_hm and (" end=" .. r.end_hm) or ""
  )
end

local OPS = {}

OPS.cycle = function()
  return require("organ.todo").cycle(ctx.buf, cursor_line())
end
OPS["cycle-repeat"] = OPS.cycle
OPS.right = OPS.cycle
OPS.left = function()
  return require("organ.todo").cycle_back(ctx.buf, cursor_line())
end
OPS.todo = function(arg)
  require("organ.todo").commands.todo.fn({ args = arg })
end
OPS.priority = function(arg)
  require("organ.inline_edit").set_priority(ctx.buf, cursor_line(), arg)
end
OPS.note = function()
  require("organ.logbook").commands.add_note.fn({ args = "" })
end
OPS["goto"] = function(arg)
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false)
  for i, l in ipairs(lines) do
    local s = l:find(arg, 1, true)
    if s then
      vim.api.nvim_win_set_cursor(0, { i, s - 1 })
      return
    end
  end
  error("goto: no line holds " .. arg)
end
OPS.at = function(arg)
  local l, c = arg:match("^(%d+):(%d+)$")
  vim.api.nvim_win_set_cursor(0, { tonumber(l), tonumber(c) })
end
OPS.adv = function(arg)
  state.clock.now = state.clock.now + tonumber(arg)
end
OPS["clock-in"] = function()
  require("organ.clock").commands["clock in"].fn()
end
OPS["clock-out"] = function()
  require("organ.clock").commands["clock out"].fn()
end
OPS["clock-cancel"] = function()
  require("organ.clock").commands["clock cancel"].fn()
end
OPS["clocking?"] = function()
  log("clocking=%s", require("organ.clock").status() and "t" or "nil")
end
OPS["modified?"] = function()
  log("modified=%s", vim.bo[ctx.buf].modified and "t" or "nil")
end
OPS.schedule = function(arg)
  require("organ.schedule").set_schedule({ date = arg })
end
OPS.deadline = function(arg)
  require("organ.schedule").set_deadline({ date = arg })
end
OPS["schedule-prompt"] = function()
  require("organ.schedule").set_schedule()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
end
local function shift(direction, arg)
  if arg then
    local key = direction == "inc" and "<C-a>" or "<C-x>"
    vim.cmd("normal " .. arg .. vim.api.nvim_replace_termcodes(key, true, false, true))
  else
    require("organ.inline_edit").dispatch(direction)
  end
end
OPS.up = function(arg)
  shift("inc", arg)
end
OPS.down = function(arg)
  shift("dec", arg)
end
OPS["eval-range"] = function()
  require("organ.timestamp").commands.evaluate_time_range.fn({ bang = true })
end
OPS["update-dblock"] = function()
  require("organ.dblock").commands.update_dblock.fn()
end
OPS["update-all-dblocks"] = function()
  require("organ.dblock").commands.update_all_dblocks.fn()
end
OPS["clock-report"] = function()
  require("organ.clock").commands["clock report"].fn({ args = "" })
end
OPS["set-effort"] = function()
  require("organ.property").set_effort_interactive(ctx.buf, cursor_line())
end
OPS.columns = columns
OPS["columns-global"] = function()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  columns()
end
OPS.duration = function(arg)
  local m = require("organ.effort").parse(arg)
  log("duration %q -> %s", arg, m and fmt_number(m) or "invalid")
end
OPS["read-date"] = function(arg)
  read_date(arg == "<EMPTY>" and "" or arg)
end
OPS.timer = function()
  local timer = require("organ.timer")
  timer.start(pop_input())
  local r = timer.remaining()
  log("timer=%s", r and tostring(r) or "none")
  timer.stop()
end

local function run_op(spec)
  local op, arg = spec:match("^(%S+) (.*)$")
  op = op or spec
  local fn = OPS[op]
  if not fn then
    error("conformance: unknown op " .. op)
  end
  ctx.refused = false
  local ok, err = pcall(fn, arg)
  if not ok then
    log(
      "! crash: "
        .. tostring(err)
          :gsub("%S*%.lua:%d+: ", "")
          :gsub('%[string "[^"]*"%]:%d+: ', "")
          :gsub("\n", " ")
    )
  elseif type(err) == "string" then
    ctx.refused = true
  end
  if ctx.refused then
    log("! refused")
  end
  if vim.api.nvim_buf_is_valid(ctx.buf) and vim.api.nvim_get_current_buf() ~= ctx.buf then
    local pos = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_set_current_buf(ctx.buf)
    pcall(vim.api.nvim_win_set_cursor, 0, pos)
  end
end

local function render(path, option)
  local header, files = parse_case(path)
  local listed = vim.split(values(header, "OPTIONS")[1] or "", " ", { trimempty = true })
  if option and not vim.tbl_contains(listed, option) then
    return "(not in the " .. option .. " run)\n"
  end
  local organ = require("organ")
  local saved = vim.deepcopy(organ.config)
  local cfg = organ.config
  if values(header, "PROFILE")[1] ~= "defaults" then
    cfg.todo.sequence = { "TODO", "|", "DONE" }
    cfg.todo.log_done = false
    cfg.todo.planning_indent = 0
  end
  for _, chunk in ipairs(values(header, "ORGAN")) do
    assert(loadstring("local cfg = ...; " .. chunk))(cfg)
  end
  if option then
    OPTIONS[option](cfg)
  end
  state.clock.now = iso_to_time(values(header, "NOW")[1] or "2026-05-04 09:30")
  state.clear_clock()
  state.n = state.n + 1
  local dir = state.tmp .. "/" .. state.n
  vim.fn.mkdir(dir, "p")
  local paths, cursor = {}, nil
  for _, f in ipairs(files) do
    for i, l in ipairs(f.lines) do
      local s = l:find("<CURSOR>", 1, true)
      if s and not cursor then
        cursor = { i, s - 1 }
        f.lines[i] = l:sub(1, s - 1) .. l:sub(s + 8)
      end
    end
    local p = dir .. "/" .. f.name
    vim.fn.writefile(f.lines, p)
    paths[#paths + 1] = p
  end
  cfg.agenda_files = paths

  ctx = {
    log = {},
    inputs = values(header, "INPUT"),
    keys = values(header, "KEYS")[1] or "",
    refused = false,
  }
  state.ctx = ctx
  -- luacheck: push ignore 122
  local saved_ui = {
    input = vim.ui.input,
    select = vim.ui.select,
    getcharstr = vim.fn.getcharstr,
  }
  vim.ui.input = function(_, cb)
    cb(pop_input())
  end
  vim.ui.select = function(items, opts, cb)
    local labels = {}
    for i, it in ipairs(items) do
      labels[i] = opts and opts.format_item and opts.format_item(it) or tostring(it)
    end
    log("? choices: %s", table.concat(labels, " "))
    local want = pop_input()
    for i, l in ipairs(labels) do
      if l == want then
        return cb(items[i], i)
      end
    end
    cb(nil)
  end
  vim.fn.getcharstr = function()
    local c = ctx.keys:sub(1, 1)
    ctx.keys = ctx.keys:sub(2)
    return c
  end
  -- luacheck: pop

  organ.scan_blocking(dir, 10000)
  vim.cmd("edit " .. vim.fn.fnameescape(paths[1]))
  ctx.buf = vim.api.nvim_get_current_buf()
  if cursor then
    vim.api.nvim_win_set_cursor(0, cursor)
  end
  local ok, err = pcall(function()
    for _, spec in ipairs(values(header, "OP")) do
      run_op(spec)
    end
  end)
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false)
  -- luacheck: push ignore 122
  vim.ui.input, vim.ui.select = saved_ui.input, saved_ui.select
  vim.fn.getcharstr = saved_ui.getcharstr
  -- luacheck: pop
  state.ctx = nil

  state.clear_clock()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find(dir, 1, true) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  -- Reindexing queued by the case's own writes must not outlive it.
  require("organ.queue").drain_blocking(10000)
  local db = organ.db_handle()
  for _, p in ipairs(paths) do
    require("organ.indexer").forget(db, p)
  end
  vim.fn.delete(dir, "rf")
  for k in pairs(cfg) do
    cfg[k] = nil
  end
  for k, v in pairs(saved) do
    cfg[k] = v
  end
  if not ok then
    error(err)
  end

  local out = table.concat(lines, "\n") .. "\n"
  if #ctx.log > 0 then
    out = out .. "--- log\n" .. table.concat(ctx.log, "\n") .. "\n"
  end
  return (out:gsub(vim.pesc(dir) .. "/", "<DIR>/"))
end

return { render = render }
