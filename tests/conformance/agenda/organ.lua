-- organ side of the agenda conformance gate: renders each case's views
-- in the same shape as emacs.el (a "=== VIEW" line, then the agenda
-- buffer as the window shows it, right-aligned virtual text included).
-- The case format and every setting below are described in NORMALIZE.md.

local root = vim.fn.getcwd()
local KEY = "organ-conformance-agenda"

local state = package.loaded[KEY]
if not state then
  local clock = dofile(root .. "/tests/conformance/_clock.lua")
  clock.pin()
  vim.o.columns = 79
  -- Under -l the first window keeps its width; a new one takes 'columns'.
  vim.cmd("new")
  vim.cmd("only")
  local tmp = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")
  require("organ").setup({
    org_dir = tmp,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    agenda = { sticky = false },
  })
  -- The module captured os.time before the clock was pinned.
  require("organ.query.dates")._now = function()
    return os.time()
  end
  state = { clock = clock, tmp = tmp, n = 0 }
  package.loaded[KEY] = state
end

-- Settings of each option run, applied to the cases that list it.
local OPTIONS = {
  ["prewarning-if-scheduled"] = function(cfg)
    cfg.agenda.skip_deadline_prewarning_if_scheduled = false
  end,
  ["show-done"] = function(cfg)
    cfg.agenda.default_view.todo = {}
  end,
  ["inline-tags-no-marker"] = function(cfg)
    cfg.agenda.tags_virt_align = false
    cfg.agenda.tags_overflow_marker = false
  end,
}

local function parse_case(path)
  local header, files = {}, {}
  local current
  for _, line in ipairs(vim.fn.readfile(path)) do
    local name = line:match("^#%+CONFORMANCE%-FILE: (.+)$")
    if name then
      current = { name = name, lines = {} }
      files[#files + 1] = current
    elseif current then
      current.lines[#current.lines + 1] = line
    else
      local k, v = line:match("^#%+CONFORMANCE%-(%u+): (.*)$")
      if k then
        header[#header + 1] = { key = k, value = v }
      end
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

local function week_start(date)
  local dates = require("organ.agenda.dates")
  local w = tonumber(os.date("%w", dates.iso_to_ts(date)))
  return dates.add_days(date, -(((w == 0) and 7 or w) - 1))
end

local function default_view(extra)
  local cfg = require("organ").config.agenda
  return vim.tbl_extend("force", vim.deepcopy(cfg.default_view or {}), extra)
end

local function open_view(spec)
  local agenda = require("organ.agenda")
  local kind, arg = spec:match("^(%S+)%s*(.*)$")
  if kind == "day" then
    if arg == "" then
      agenda.day()
    else
      agenda.open(default_view({ from = arg, to = arg }), "day")
    end
  elseif kind == "week" then
    if arg == "" then
      agenda.week()
    else
      local from = week_start(arg)
      local to = require("organ.agenda.dates").add_days(from, 6)
      agenda.open(default_view({ from = from, to = to }), "week")
    end
  elseif kind == "month" then
    local view = default_view({ span = "month", start_day = arg })
    view.from, view.to = nil, nil
    agenda.open(view, "month")
  elseif kind == "default" then
    agenda.open(require("organ").config.agenda.default_view, "default_view")
  elseif kind == "todo" then
    agenda.todos()
  elseif kind == "tags" then
    agenda.tags(arg)
  elseif kind == "tags-todo" then
    return false
  elseif kind == "search" then
    agenda.search(arg)
  elseif kind == "stuck" then
    agenda.stuck()
  elseif kind == "composite" then
    agenda.open({
      blocks = {
        vim.tbl_extend("force", default_view({ from = "today", to = "today" }), {
          label = "Today",
        }),
        {
          label = "Global TODOs",
          kind = "todo",
          todo = { exclude = { "DONE", "CANCELLED", "CANCELED", "CLOSED" } },
        },
        { label = "Tag match: home", kind = "tags", tag_match = "home" },
      },
    }, "composite")
  else
    error("unknown view " .. spec)
  end
  return true
end

local function agenda_buffers()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "organ-agenda" then
      out[#out + 1] = b
    end
  end
  return out
end

-- The buffer's lines as its window shows them: right-aligned virtual
-- text drawn at the window's right edge, eol virtual text after a space.
local function visible_lines(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local win = vim.fn.bufwinid(buf)
  local width = vim.o.columns
  if win ~= -1 then
    width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
  end
  local right, eol = {}, {}
  for _, ns in pairs(vim.api.nvim_get_namespaces()) do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local d = m[4]
      if d.virt_text then
        local t = {}
        for _, chunk in ipairs(d.virt_text) do
          t[#t + 1] = chunk[1]
        end
        local text = table.concat(t)
        local row = m[2] + 1
        if d.virt_text_pos == "right_align" then
          right[row] = (right[row] or "") .. text
        elseif d.virt_text_pos == "eol" then
          eol[row] = (eol[row] or "") .. text
        end
      end
    end
  end
  for row, line in ipairs(lines) do
    if eol[row] then
      line = line .. " " .. eol[row]
    end
    if right[row] then
      local w = vim.fn.strdisplaywidth(right[row])
      local lw = vim.fn.strdisplaywidth(line)
      if lw + w <= width then
        line = line .. string.rep(" ", width - w - lw) .. right[row]
      else
        line = vim.fn.strcharpart(line, 0, vim.fn.strchars(line) - (lw + w - width)) .. right[row]
      end
    end
    lines[row] = line
  end
  return lines
end

local function render_view(spec)
  for _, b in ipairs(agenda_buffers()) do
    vim.api.nvim_buf_delete(b, { force = true })
  end
  local ok, res = pcall(open_view, spec)
  if not ok then
    return "ERROR: " .. tostring(res):gsub("\n", " ")
  end
  if res == false then
    return "(no " .. spec:match("^%S+") .. " view)"
  end
  local bufs = agenda_buffers()
  if #bufs == 0 then
    return "(no agenda buffer)"
  end
  local text = table.concat(visible_lines(bufs[#bufs]), "\n")
  for _, b in ipairs(bufs) do
    vim.api.nvim_buf_delete(b, { force = true })
  end
  return text
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
  local now = values(header, "NOW")[1] or "2026-05-04 09:30"
  local y, mo, d, h, mi = now:match("^(%d+)-(%d+)-(%d+) (%d+):(%d+)$")
  state.clock.now = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = 0 })
  local todo = values(header, "TODO")[1]
  if todo then
    cfg.todo.sequence = vim.split(todo, " ", { trimempty = true })
  end
  if values(header, "HABITS")[1] then
    cfg.agenda.show_habit_graphs = true
  end
  for _, chunk in ipairs(values(header, "ORGAN")) do
    assert(loadstring("local cfg = ...; " .. chunk))(cfg)
  end
  if option then
    OPTIONS[option](cfg)
  end
  state.n = state.n + 1
  local dir = state.tmp .. "/" .. state.n
  vim.fn.mkdir(dir, "p")
  local paths = {}
  for _, f in ipairs(files) do
    local p = dir .. "/" .. f.name
    vim.fn.writefile(f.lines, p)
    paths[#paths + 1] = p
  end
  cfg.agenda_files = paths
  organ.scan_blocking(dir, 10000)
  local out = {}
  for _, spec in ipairs(values(header, "VIEW")) do
    out[#out + 1] = "=== " .. spec .. "\n" .. render_view(spec) .. "\n"
  end
  local db = organ.db_handle()
  for _, p in ipairs(paths) do
    require("organ.indexer").forget(db, p)
  end
  for k in pairs(cfg) do
    cfg[k] = nil
  end
  for k, v in pairs(saved) do
    cfg[k] = v
  end
  return table.concat(out)
end

return { render = render }
