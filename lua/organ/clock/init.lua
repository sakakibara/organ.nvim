-- Public clocking API: start / stop / cancel / jump / status / setup_resume.

local M = {}

local obuf = require("organ.buf")
local state_mod = require("organ.clock.state")
local writer_mod = require("organ.clock.writer")

local function get_drawer_name()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return "LOGBOOK"
  end
  local clock_cfg = require("organ.buf_config").read(nil, "clock") or {}
  -- `into_drawer` (Emacs `org-clock-into-drawer`):
  --   true (default)  → use drawer (name from log_drawer / fallback)
  --   string          → that drawer name (alias for log_drawer)
  --   false / int N   → not yet wired; falls back to drawer mode.
  --                     The CLOCK writer currently always wraps in a
  --                     drawer; bare-CLOCK + integer-threshold modes
  --                     would require a writer-side refactor.
  local into = clock_cfg.into_drawer
  if type(into) == "string" and into ~= "" then
    return into
  end
  -- Prefer an explicit clock.log_drawer override; otherwise inherit from
  -- todo.log_drawer so a user who customises one place doesn't get split
  -- behaviour between TODO state-change entries and CLOCK entries.
  local explicit = clock_cfg.log_drawer
  if explicit then
    return explicit
  end
  return (require("organ.buf_config").read(nil, "todo") or {}).log_drawer or "LOGBOOK"
end

-- Read the headline at line `line` in `bufnr` directly from the buffer.
-- Returns { line_start, title, id, file_path } or nil if not on a headline.
-- Buffer-driven (rather than DB-driven) so an unsaved or just-modified buffer
-- still resolves correctly — the DB index lags edits until the file is saved
-- and reindexed, which is too late for clock-in on a freshly-edited file.
local function headline_at(bufnr, line)
  local hdr = (vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false) or {})[1] or ""
  if not hdr:match("^%*+%s+") then
    return nil
  end

  local file_path = vim.api.nvim_buf_get_name(bufnr)
  if file_path == "" then
    return nil
  end
  local canon = require("organ.path").canonical(file_path) or file_path

  local title = hdr
    :gsub("^%*+%s+", "")
    :gsub("%s+:[%w_@#%%][%w_@#%%:]*:%s*$", "") -- strip trailing :tag:tag:
    :gsub("%s+$", "")

  -- Walk forward looking for an :ID: in the property drawer (skipping any
  -- planning lines first). Stop at the next headline. Mirrors indexer.id_for.
  local last = vim.api.nvim_buf_line_count(bufnr)
  local id
  local in_props = false
  for i = line + 1, last do
    local l = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if l:match("^%*+%s+") then
      break
    end
    if not in_props then
      if l:match("^%s*:PROPERTIES:%s*$") then
        in_props = true
      elseif l:match("^%s*SCHEDULED:") or l:match("^%s*DEADLINE:") or l:match("^%s*CLOSED:") then
        -- planning line; keep scanning
      elseif l:match("^%s*$") then
        -- blank; keep scanning
      else
        break -- past planning + before any property drawer
      end
    else
      if l:match("^%s*:END:%s*$") then
        break
      end
      local k, v = l:match("^%s*:([^:%s]+):%s*(.-)%s*$")
      if k == "ID" and v ~= "" then
        id = v
        break
      end
    end
  end

  id = id or (canon .. "#L" .. tostring(line - 1))

  return {
    line_start = line - 1,
    title = title,
    id = id,
    file_path = canon,
  }
end

-- Start a clock on the headline that contains `opts.line` in `opts.bufnr`.
-- Both default to the current buffer + cursor line.
function M.start(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")
  local hl = headline_at(bufnr, line)
  if not hl then
    require("organ.notify").warn("no headline at cursor")
    return
  end

  -- Auto-stop any existing active clock first (drift from Emacs).
  local existing = state_mod.load()
  if existing then
    M.stop()
    require("organ.notify").info(
      string.format(
        "stopped previous clock on '%s', starting on '%s'",
        existing.headline_id or "?",
        hl.title
      )
    )
  end

  local now = os.time()
  writer_mod.write_active(bufnr, hl.line_start + 1, get_drawer_name(), now)
  state_mod.save({
    file_path = hl.file_path,
    line_start = hl.line_start,
    headline_id = hl.id,
    start_ts = now,
    started_at = os.date("%Y-%m-%d %H:%M", now),
  })

  local cfg = (require("organ.buf_config").read(nil, "clock") or {})
  if cfg.idle_threshold_minutes and cfg.idle_threshold_minutes > 0 then
    require("organ.clock.idle").start(cfg.idle_threshold_minutes)
  end
end

function M.stop(opts)
  opts = opts or {}
  local s = state_mod.load()
  if not s then
    require("organ.notify").warn("no active clock")
    return
  end
  -- Support nested { active = { ... } } format written by subtract_idle.
  local active = s.active or s
  -- Find or open the file's buffer.
  local bufnr = vim.fn.bufnr(active.file_path)
  if bufnr <= 0 then
    vim.cmd("edit " .. vim.fn.fnameescape(active.file_path))
    bufnr = vim.api.nvim_get_current_buf()
  elseif not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end
  local now = opts.end_ts or os.time()
  local line_start = active.line_start or s.line_start or 0
  local ok = writer_mod.close_active(bufnr, line_start + 1, get_drawer_name(), now)
  if not ok then
    require("organ.notify").warn("clock state out of sync; clearing")
    state_mod.clear()
    require("organ.clock.idle").stop()
    return
  end
  state_mod.clear()
  require("organ.clock.idle").stop()
end

function M.cancel()
  local s = state_mod.load()
  if not s then
    require("organ.notify").warn("no active clock")
    return
  end
  local bufnr = vim.fn.bufnr(s.file_path)
  if bufnr <= 0 then
    vim.cmd("edit " .. vim.fn.fnameescape(s.file_path))
    bufnr = vim.api.nvim_get_current_buf()
  elseif not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end
  writer_mod.cancel_active(bufnr, s.line_start + 1, get_drawer_name())
  state_mod.clear()
  require("organ.clock.idle").stop()
end

function M.jump()
  local s = state_mod.load()
  if not s then
    require("organ.notify").warn("no active clock")
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(s.file_path))
  pcall(vim.api.nvim_win_set_cursor, 0, { (s.line_start or 0) + 1, 0 })
end

function M.status()
  return state_mod.load()
end

-- Validate persisted state against the file; clear on stale pointer.
function M.setup_resume()
  local s = state_mod.load()
  if not s then
    return
  end
  if not vim.loop.fs_stat(s.file_path) then
    require("organ.notify").warn("active clock file vanished; clearing")
    state_mod.clear()
    return
  end
  local lines = vim.fn.readfile(s.file_path)
  local target = lines[(s.line_start or 0) + 1]
  if not target or not target:match("^%*+%s+") then
    require("organ.notify").warn("active clock pointed at a vanished headline; clearing")
    state_mod.clear()
    return
  end

  local cfg = (require("organ.buf_config").read(nil, "clock") or {})
  if cfg.idle_threshold_minutes and cfg.idle_threshold_minutes > 0 then
    require("organ.clock.idle").start(cfg.idle_threshold_minutes)
  end
end

-- Advance the active clock's start_ts by idle_seconds, effectively subtracting
-- idle time from the recorded duration.
-- Returns nil on success, or an error string if there is no active clock.
function M.subtract_idle(idle_seconds)
  local s = require("organ.clock.state").load()
  if not s or not s.active then
    return "no active clock"
  end
  s.active.start_ts = (s.active.start_ts or 0) + idle_seconds
  require("organ.clock.state").save(s)
  return nil
end

-- Render a clock report into the current buffer at the cursor row.
-- `opts.range` accepts a string ("today" | "week" | "month" | "<from>"
-- | "<from> <to>") or a table { from = "YYYY-MM-DD", to = "YYYY-MM-DD" }.
-- Defaults to the current week (Mon..Sun, ISO).  `opts.bufnr` and
-- `opts.line` default to the current buffer + cursor line.
function M.report(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")

  local function week_range()
    local now = os.time()
    local wday = tonumber(os.date("%w", now))
    local days_since_mon = (wday + 6) % 7
    local mon = now - days_since_mon * 86400
    return os.date("%Y-%m-%d", mon), os.date("%Y-%m-%d", mon + 6 * 86400)
  end

  local from, to
  if type(opts.range) == "table" then
    from, to = opts.range.from, opts.range.to
  else
    local args = {}
    if type(opts.range) == "string" and opts.range ~= "" then
      for tok in opts.range:gmatch("%S+") do
        args[#args + 1] = tok
      end
    end
    if #args == 0 or args[1] == "week" then
      from, to = week_range()
    elseif args[1] == "today" then
      from = os.date("%Y-%m-%d")
      to = from
    elseif args[1] == "month" then
      local now = os.time()
      from = os.date("%Y-%m-01", now)
      to = os.date("%Y-%m-%d", now)
    elseif #args == 1 then
      from, to = args[1], args[1]
    else
      from, to = args[1], args[2]
    end
  end
  if from and to and from > to then
    from, to = to, from
  end

  local rows = require("organ.query").clock_entries({
    from = from,
    to = to,
    group_by = "headline",
    include_active = true,
  })
  local lines = require("organ.clock.report").render(rows, { from = from, to = to })
  obuf.set_lines(bufnr, line, line, lines)
end

-- :Org dispatch entries.  Collected by plugin/organ.lua at startup
-- and registered as `:Org <key>` subcommands.
M.commands = {
  ["clock in"] = {
    fn = function()
      M.start()
    end,
    desc = "Clock in to the headline at cursor",
  },
  ["clock out"] = {
    fn = function()
      M.stop()
    end,
    desc = "Clock out the active clock",
  },
  ["clock cancel"] = {
    fn = function()
      M.cancel()
    end,
    desc = "Cancel the active clock",
  },
  ["clock jump"] = {
    fn = function()
      M.jump()
    end,
    desc = "Jump to the active clock's headline",
  },
  ["clock report"] = {
    fn = function(cmd)
      M.report({ range = (cmd and cmd.args) or "" })
    end,
    nargs = "*",
    desc = "Clock report (today | week | month | <from> [to])",
  },
}

return M
