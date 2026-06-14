-- Agenda views and the dispatcher: high-level entry points (day, week,
-- todos, tags, search, stuck, named views), the single-keystroke
-- dispatcher menu, and the :Org command table the cmd.lua shims mount.

local M = {}

local obuf = require("organ.buf")
local dates = require("organ.agenda.dates")
local span = require("organ.agenda.span")

--- Open the day-view agenda (today only).
function M.day()
  local cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  local view = vim.tbl_extend("force", {}, cfg.default_view or {}, {
    from = "today",
    to = "today",
  })
  -- Through the facade: organ.agenda requires this module at load time, and facade dispatch keeps test stubs effective.
  require("organ.agenda").open(view, "day")
end

--- Open the week-view agenda anchored to `agenda.week_starts_on`:
---   "monday".."sunday"   pin the first day of the week (default
---                        "monday", mirroring Emacs's default)
---   "today"              no fixed anchor; window is today..+6d
function M.week()
  local cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  local sow = span.resolve_week_anchor(cfg.week_starts_on)
  local now_ts = os.time()
  local week_start_ts
  if sow == nil then
    week_start_ts = now_ts
  else
    local w = tonumber(os.date("%w", now_ts))
    local iso = (w == 0) and 7 or w
    local back = (iso - sow) % 7
    week_start_ts = now_ts - back * 86400
  end
  local week_end_ts = week_start_ts + 6 * 86400
  local view = vim.tbl_extend("force", {}, cfg.default_view or {}, {
    from = os.date("%Y-%m-%d", week_start_ts),
    to = os.date("%Y-%m-%d", week_end_ts),
  })
  require("organ.agenda").open(view, "week")
end

--- Open the global TODO list (every active TODO across all org files).
function M.todos()
  require("organ.agenda").open({
    blocks = {
      {
        label = "Global TODOs",
        kind = "todo",
        todo = { exclude = { "DONE", "CANCELLED", "CANCELED", "CLOSED" } },
      },
    },
  }, "todos")
end

--- Open a tag-match agenda view.  When `query` is nil/empty, prompts via
--- `vim.ui.input` (Emacs `M-x org-tags-view`).
function M.tags(query)
  local function go(q)
    if not q or q == "" then
      return
    end
    require("organ.agenda").open({
      blocks = { { label = "Tag match: " .. q, kind = "tags", tag_match = q } },
    }, "tags:" .. q)
  end
  if query and query ~= "" then
    go(query)
    return
  end
  vim.ui.input({ prompt = "Tag query (e.g. work&urgent-@home): " }, go)
end

--- Open a title-search agenda view.  When `query` is nil/empty, prompts via
--- `vim.ui.input`.
function M.search(query)
  local function go(q)
    if not q or q == "" then
      return
    end
    require("organ.agenda").open({
      blocks = { { label = "Search: " .. q, kind = "search", title_match = q } },
    }, "search:" .. q)
  end
  if query and query ~= "" then
    go(query)
    return
  end
  vim.ui.input({ prompt = "Search string: " }, go)
end

--- Open the stuck-projects view.
function M.stuck()
  require("organ.agenda").open({ blocks = { { label = "Stuck projects", kind = "stuck" } } })
end

--- Open a user-defined named view from `config.agenda.views[name]`.  Surfaces
--- a notify error if the name is not registered.
function M.named_view(name)
  local views = (require("organ.buf_config").read(nil, "agenda") or {}).views or {}
  local view = views[name]
  if not view then
    require("organ.notify").error("organ: no agenda view named " .. tostring(name))
    return
  end
  require("organ.agenda").open(view, name)
end

-- Build the dispatcher entry list (key, label, action).  Standard entries
-- + every named view + a "default" tail entry on `D` (or space if D is
-- already taken by a user view).
local function build_dispatch_entries()
  -- Through the facade, read at dispatch time, so a stubbed facade
  -- member lands in the menu entry.
  local agenda = require("organ.agenda")
  local entries = {
    { "a", "Week agenda", agenda.week },
    { "d", "Day agenda", agenda.day },
    { "t", "Global TODO list", agenda.todos },
    { "m", "Tag query…", agenda.tags },
    { "s", "Search by string…", agenda.search },
    { "#", "Stuck projects", agenda.stuck },
  }
  local views = (require("organ.buf_config").read(nil, "agenda") or {}).views or {}
  local used = {}
  for _, e in ipairs(entries) do
    used[e[1]] = true
  end
  local view_names = {}
  for k in pairs(views) do
    view_names[#view_names + 1] = k
  end
  table.sort(view_names)
  for _, k in ipairs(view_names) do
    local first = k:sub(1, 1)
    local key = (not used[first]) and first or nil
    if key then
      used[key] = true
    end
    entries[#entries + 1] = {
      key or " ",
      k,
      function()
        require("organ.agenda").open(views[k], k)
      end,
    }
  end
  local def_key = used["D"] and " " or "D"
  used[def_key] = true
  entries[#entries + 1] = {
    def_key,
    "default",
    function()
      require("organ.agenda").open(
        (require("organ.buf_config").read(nil, "agenda") or {}).default_view,
        "default_view"
      )
    end,
  }
  return entries
end

-- Show a single-keystroke menu in a centered floating window and
-- Thin wrapper around `organ.popup_menu.pick` -- the actual
-- single-keystroke popup primitive lives there so the TODO fast-
-- pick can use the same modal-blocking UI.
local function show_popup_menu(entries, title)
  return require("organ.popup_menu").pick(entries, {
    title = title,
    prompt = "Press key for an agenda command:",
  })
end

--- Open the agenda dispatcher menu (Emacs `C-c a`).  Style is controlled
--- by `config.agenda.dispatcher_style`:
---   "popup"  -- single-keystroke menu in a floating window (default;
---              works under noice / snacks / native cmdline alike)
---   "echo"   -- single-keystroke menu via nvim_echo + getchar
---              (terminal-classic; gets intercepted by some UI plugins)
---   "select" -- `vim.ui.select` (telescope / dressing / snacks-pickers)
---   custom   -- `config.agenda.dispatcher_handler({title, entries})`
function M.dispatch()
  local cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  local entries = build_dispatch_entries()

  local handler = cfg.dispatcher_handler
  if type(handler) == "function" then
    local data = {}
    for _, e in ipairs(entries) do
      data[#data + 1] = { key = e[1], label = e[2], action = e[3] }
    end
    handler({ title = "Agenda dispatcher", entries = data })
    return
  end

  if cfg.dispatcher_style == "select" then
    local labels = {}
    for _, e in ipairs(entries) do
      labels[#labels + 1] = string.format("%s   %s", e[1], e[2])
    end
    vim.ui.select(labels, { prompt = "Agenda dispatcher:" }, function(choice, idx)
      if not choice then
        return
      end
      if not idx then
        for i, l in ipairs(labels) do
          if l == choice then
            idx = i
            break
          end
        end
      end
      if not idx then
        return
      end
      local ok, err = pcall(entries[idx][3])
      if not ok then
        require("organ.notify").error("agenda: " .. tostring(err))
      end
    end)
    return
  end

  if cfg.dispatcher_style == "echo" then
    local lines = { "Press key for an agenda command:", "" }
    for _, e in ipairs(entries) do
      lines[#lines + 1] = string.format("  %s   %s", e[1], e[2])
    end
    vim.api.nvim_echo({ { table.concat(lines, "\n"), "Normal" } }, false, {})
    local ok, char = pcall(vim.fn.getcharstr)
    pcall(vim.cmd, "redraw")
    if not ok or not char or char == "" then
      return
    end
    for _, e in ipairs(entries) do
      if e[1] == char then
        local ok2, err = pcall(e[3])
        if not ok2 then
          require("organ.notify").error("agenda: " .. tostring(err))
        end
        return
      end
    end
    require("organ.notify").warn("organ: no agenda view bound to '" .. char .. "'")
    return
  end

  -- Default: floating-window popup.
  local action, char = show_popup_menu(entries, "Agenda dispatcher")
  if action then
    local ok, err = pcall(action)
    if not ok then
      require("organ.notify").error("agenda: " .. tostring(err))
    end
  elseif char and char ~= "" and char ~= "\27" and char ~= "\3" then
    -- Esc (\27) and Ctrl-C (\3) cancel silently; any other unmapped
    -- key reports so the user knows the menu didn't bind it.
    require("organ.notify").warn("organ: no agenda view bound to '" .. char .. "'")
  end
end

-- Exposed for tests; the only call site stays inside this module.
M._show_popup_menu = show_popup_menu

local function complete_agenda_views()
  local out = {}
  for k in pairs((require("organ.buf_config").read(nil, "agenda") or {}).views or {}) do
    out[#out + 1] = k
  end
  return out
end

-- :Org agenda custom <lua-expr> evaluates a Lua expression that returns
-- a view spec (matching the organ.agenda.normalize_view shape) and opens
-- it.  Mirrors
-- Emacs `org-agenda-custom-commands` ad-hoc dispatch but inline.
local function open_custom_view(args)
  local expr = args or ""
  if expr == "" then
    require("organ.notify").warn(":Org agenda custom requires a Lua view-spec expression")
    return
  end
  local chunk, err = loadstring("return " .. expr)
  if not chunk then
    chunk, err = loadstring(expr)
  end
  if not chunk then
    require("organ.notify").error("invalid view-spec expression: " .. tostring(err))
    return
  end
  local ok, view = pcall(chunk)
  if not ok then
    require("organ.notify").error("view-spec evaluation failed: " .. tostring(view))
    return
  end
  if type(view) ~= "table" then
    require("organ.notify").error("view-spec must be a table; got " .. type(view))
    return
  end
  require("organ.agenda").open(view, "custom")
end

-- :Org habits -- list every `:STYLE: habit` headline with status,
-- streak, and a consistency-graph row showing the last N days
-- (default 21).  Builds a popup buffer with the habits report.
local function open_habits_view(days_arg)
  local days = tonumber(days_arg) or 21
  local query = require("organ.query")
  local hab = require("organ.habit")
  local rep = require("organ.todo.repeater")

  local rows = query.habits({ days = days })
  if #rows == 0 then
    require("organ.notify").info("no habits found (no :STYLE: habit properties)")
    return
  end

  local today = dates.today_iso()
  local lines = { string.format("Habits -- %d days ending %s", days, today), "" }
  for _, r in ipairs(rows) do
    local repeater = nil
    if r.scheduled then
      repeater = rep.parse("<" .. r.scheduled:sub(2, -2) .. ">")
    end
    local info = {
      scheduled_date = r.scheduled_date and r.scheduled_date:sub(1, 10) or nil,
      period_days = hab.period_days(repeater),
      alarm_days = hab.alarm_days(repeater),
      completions = r.completions,
    }
    local glyph_row = hab.render_glyph_row(info, today, days)
    local status = hab.status(info, today)
    local streak = hab.streak(r.completions, info.period_days)
    lines[#lines + 1] = string.format(
      "  %s  %-12s  streak=%-3d  %s   %s",
      glyph_row,
      status,
      streak,
      r.title or "(untitled)",
      r.file_path
          and (vim.fn.fnamemodify(r.file_path, ":t") .. ":" .. tostring((r.line_start or 0) + 1))
        or ""
    )
  end

  local buf = vim.api.nvim_create_buf(false, true)
  obuf.set_lines(buf, 0, -1, lines)
  vim.api.nvim_set_option_value("filetype", "organ-habits", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(120, vim.o.columns - 4),
    height = math.min(#lines + 2, vim.o.lines - 4),
    row = 2,
    col = 2,
    border = "rounded",
    title = " Habits ",
  })
end

M.commands = {
  agenda = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      if args ~= "" then
        require("organ.agenda").named_view(args)
      else
        require("organ.agenda").dispatch()
      end
    end,
    nargs = "?",
    complete = complete_agenda_views,
    desc = "Open organ agenda (with optional named view)",
  },
  ["agenda day"] = {
    fn = function()
      require("organ.agenda").day()
    end,
    desc = "Agenda for today (single-day window)",
  },
  ["agenda week"] = {
    fn = function()
      require("organ.agenda").week()
    end,
    desc = "Agenda for the current week",
  },
  ["agenda todos"] = {
    fn = function()
      require("organ.agenda").todos()
    end,
    desc = "Global TODO list across all org files",
  },
  ["agenda tags"] = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      require("organ.agenda").tags(args ~= "" and args or nil)
    end,
    nargs = "?",
    desc = "Tag-query agenda view (Emacs org-match syntax)",
  },
  ["agenda search"] = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      require("organ.agenda").search(args ~= "" and args or nil)
    end,
    nargs = "?",
    desc = "Title-substring search agenda view",
  },
  ["agenda custom"] = {
    fn = function(cmd)
      open_custom_view(cmd and cmd.args)
    end,
    nargs = "+",
    desc = "Open an ad-hoc view from a Lua expression (like Emacs org-agenda-custom-commands)",
  },
  stuck_projects = {
    fn = function()
      require("organ.agenda").stuck()
    end,
    desc = "Open agenda buffer with stuck projects",
  },
  habits = {
    fn = function(cmd)
      open_habits_view(cmd and cmd.args)
    end,
    nargs = "?",
    desc = "Habits view (consistency graph + streaks; arg = days, default 21)",
  },
}

return M
