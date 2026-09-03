local M = {}

M.defaults = {
  enabled = false,
  -- Global lead-time list. Used as the fallback for both SCHEDULED
  -- and DEADLINE reminders when `lead_minutes_scheduled` /
  -- `lead_minutes_deadline` are not set explicitly.
  lead_minutes = { 10, 0 },
  -- Per-type lead times (Emacs / nvim-orgmode style). Override
  -- the global `lead_minutes` when set.
  lead_minutes_scheduled = nil, -- e.g. { 10, 0 }
  lead_minutes_deadline = nil, -- e.g. { 60, 30, 10, 0 }
  -- Per-type reminder enable flags. Both default true; set false to
  -- silence one channel while keeping the other.
  scheduled_reminder = true,
  deadline_reminder = true,
  notify = nil,
  scan_interval_seconds = 600,
  -- Route reminders through the OS scheduler (LaunchAgent / at / schtasks)
  -- so they fire even when Neovim is closed. When false, only fires while
  -- Neovim is running (vim.loop timers + in-Neovim notify).
  local_schedule = false,
  -- How far ahead to schedule when local_schedule is on. Longer windows
  -- cover more "Neovim closed" time at the cost of more OS-scheduler
  -- entries. 48 hours is a sane default — covers an overnight + a workday.
  lookahead_hours = 48,
}

local state = {
  timers = {},
  fired = {},
  scan_timer = nil,
  augroup = nil,
}

local function cfg()
  return (require("organ.buf_config").read(nil, "alarms") or {})
end

local function lead_minutes()
  local list = cfg().lead_minutes
  if type(list) ~= "table" or #list == 0 then
    return M.defaults.lead_minutes
  end
  return list
end

-- Per-type lead-times. Falls back to the global lead_minutes when
-- the type-specific list isn't configured.
local function lead_minutes_for(kind)
  local c = cfg()
  local key = "lead_minutes_" .. kind -- "scheduled" | "deadline"
  local list = c[key]
  if type(list) == "table" and #list > 0 then
    return list
  end
  return lead_minutes()
end

local function reminder_enabled(kind)
  local c = cfg()
  if kind == "scheduled" then
    return c.scheduled_reminder ~= false
  end
  if kind == "deadline" then
    return c.deadline_reminder ~= false
  end
  return true
end

local function default_notify(row, lead, fire_ts)
  local minutes_remaining = math.floor((row._fire_for_ts - fire_ts) / 60 + 0.5)
  local title = row.title or "(untitled)"
  local body
  if minutes_remaining > 0 then
    body = string.format("organ: %s in %d min", title, minutes_remaining)
  elseif minutes_remaining == 0 then
    body = string.format("organ: %s — now", title)
  else
    body = string.format("organ: %s — overdue", title)
  end
  local _ = lead
  require("organ.notify").info(body)
end

local function clear_timers()
  for _, t in ipairs(state.timers) do
    pcall(function()
      t:stop()
      t:close()
    end)
  end
  state.timers = {}
end

local function parse_iso_to_ts(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)$")
  if not y then
    return nil
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = 0,
  })
end

local function alarm_key(row, due_ts, lead)
  return table.concat({ row.id or "", tostring(due_ts), tostring(lead) }, "|")
end

-- Schedule firings for one row. `kind` is "scheduled" or "deadline" —
-- determines which timestamp field to read AND which per-type lead-
-- time list / enable flag applies.
local function schedule_for_row(row, now, kind)
  kind = kind or "scheduled"
  if not reminder_enabled(kind) then
    return
  end
  local due = parse_iso_to_ts(row[kind .. "_date"])
  if not due then
    return
  end
  if (row.todo_state or ""):upper() == "DONE" or (row.todo_state or ""):upper() == "CANCELLED" then
    return
  end
  for _, lead in ipairs(lead_minutes_for(kind)) do
    local fire_at = due - lead * 60
    if fire_at >= now then
      local key = alarm_key(row, due, lead) .. "|" .. kind
      if not state.fired[key] then
        local delay_ms = (fire_at - now) * 1000
        local t = vim.loop.new_timer()
        state.timers[#state.timers + 1] = t
        t:start(
          delay_ms,
          0,
          vim.schedule_wrap(function()
            if state.fired[key] then
              return
            end
            state.fired[key] = true
            row._fire_for_ts = due
            row._fire_kind = kind
            local user_notify = cfg().notify or default_notify
            local ok, err = pcall(user_notify, row, lead, os.time())
            if not ok then
              require("organ.notify").warn("alarms: notify error: " .. tostring(err))
            end
          end)
        )
      end
    end
  end
end

local function purge_old_fired(now)
  for key, _ in pairs(state.fired) do
    local ts = key:match("|(%d+)|")
    if ts and tonumber(ts) + 86400 < now then
      state.fired[key] = nil
    end
  end
end

-- Flatten upcoming agenda rows into the entry shape the OS notifier
-- wants. One row can produce multiple entries (one per lead time).
-- Queries SCHEDULED and DEADLINE separately so each respects its own
-- per-type reminder flag + lead times.
local function collect_upcoming(now, hours)
  local ok, query = pcall(require, "organ.query")
  if not ok then
    return {}
  end
  local from = os.date("%Y-%m-%d", now)
  local to = os.date("%Y-%m-%d", now + hours * 3600)

  local function fetch(kind)
    local ok2, rows = pcall(query.agenda, {
      from = from,
      to = to,
      types = { kind },
      todo = { exclude = { "DONE", "CANCELLED" } },
    })
    if not ok2 or not rows then
      return {}
    end
    return rows
  end

  local entries = {}
  local function emit_for(rows, kind, body_label)
    if not reminder_enabled(kind) then
      return
    end
    local leads = lead_minutes_for(kind)
    for _, row in ipairs(rows) do
      local due = parse_iso_to_ts(row[kind .. "_date"])
      if due then
        local title = row.title or "(untitled)"
        for _, lead in ipairs(leads) do
          local fire_at = due - lead * 60
          if fire_at >= now then
            local body
            if lead > 0 then
              body = string.format("organ %s: %s in %d min", body_label, title, lead)
            else
              body = string.format("organ %s: %s — now", body_label, title)
            end
            entries[#entries + 1] = {
              id = alarm_key(row, due, lead) .. "|" .. kind,
              at = fire_at,
              title = title,
              body = body,
            }
          end
        end
      end
    end
  end

  emit_for(fetch("scheduled"), "scheduled", "scheduled")
  emit_for(fetch("deadline"), "deadline", "deadline")
  return entries
end

function M.scan(now)
  if not cfg().enabled then
    return
  end
  now = now or os.time()

  -- OS-scheduling path: collect a flat batch and hand it to the notifier.
  -- Replaces the previously-scheduled batch on every call (idempotent).
  -- The user opted in via `alarms.local_schedule = true`, which is the
  -- explicit consent gate for installing the per-platform notifier
  -- bundle (macOS Organ.app + LaunchAgent, etc.). Install ONCE per
  -- session — not on every scan — because install_bundle calls
  -- `lsregister -f` synchronously (~100ms-1s) which froze the UI on
  -- every save when alarms scan fired.
  if cfg().local_schedule then
    if not state.bundle_install_attempted then
      state.bundle_install_attempted = true
      local u = vim.uv.os_uname()
      if u.sysname == "Darwin" then
        local ok_b, mac = pcall(require, "organ.notifier.macos")
        if ok_b then
          pcall(mac.install_bundle)
        end
      end
    end
    local hours = cfg().lookahead_hours or M.defaults.lookahead_hours
    local entries = collect_upcoming(now, hours)
    local ok, notifier = pcall(require, "organ.notifier")
    if ok then
      pcall(notifier.set_pending, entries)
    end
    return
  end

  -- In-process path (default): vim.loop timers + in-Neovim vim.notify.
  clear_timers()
  purge_old_fired(now)

  local ok, query = pcall(require, "organ.query")
  if not ok then
    return
  end
  local today = os.date("%Y-%m-%d", now)
  local function fetch(kind)
    local ok2, rows = pcall(query.agenda, {
      from = today,
      to = today,
      types = { kind },
      todo = { exclude = { "DONE", "CANCELLED" } },
    })
    return ok2 and rows or {}
  end

  for _, r in ipairs(fetch("scheduled")) do
    schedule_for_row(r, now, "scheduled")
  end
  for _, r in ipairs(fetch("deadline")) do
    schedule_for_row(r, now, "deadline")
  end
end

function M.start()
  if not cfg().enabled then
    return
  end
  M.scan()

  local interval = (cfg().scan_interval_seconds or M.defaults.scan_interval_seconds) * 1000
  if state.scan_timer then
    pcall(function()
      state.scan_timer:stop()
      state.scan_timer:close()
    end)
  end
  local t = vim.loop.new_timer()
  state.scan_timer = t
  t:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      M.scan()
    end)
  )

  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  state.augroup = vim.api.nvim_create_augroup("organ_alarms", { clear = true })
  local events = require("organ.events")
  -- Idempotent: drop any prior listener before re-registering. Without
  -- this, calling setup() twice doubles up — every "indexed" event would
  -- trigger N scans for N setup() calls.
  if state.indexed_listener then
    events.off("indexed", state.indexed_listener)
  end
  state.indexed_listener = function()
    require("organ.errors").schedule("organ.alarms", function()
      M.scan()
    end)
  end
  events.on("indexed", state.indexed_listener)
end

function M.stop()
  clear_timers()
  if state.scan_timer then
    pcall(function()
      state.scan_timer:stop()
      state.scan_timer:close()
    end)
    state.scan_timer = nil
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  if state.indexed_listener then
    require("organ.events").off("indexed", state.indexed_listener)
    state.indexed_listener = nil
  end
  state.fired = {}

  -- Also cancel any OS-level scheduled entries we may have written.
  if cfg().local_schedule then
    local ok, notifier = pcall(require, "organ.notifier")
    if ok then
      pcall(notifier.cancel_all)
    end
  end
end

function M._state()
  return state
end

return M
