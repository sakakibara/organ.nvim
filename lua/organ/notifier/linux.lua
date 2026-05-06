-- Linux notifier backend.
--
-- Strategy: prefer at(1) — its jobs survive reboot via /var/spool/at on
-- disk. Fall back to `systemd-run --user --on-active=...` (transient timer
-- units) when atd isn't running. Transient timers DON'T survive reboot, so
-- this is a degraded mode; status() reports which path is active.
--
-- Notification delivery via `notify-send --app-name=Organ --icon=organ`.
-- The `organ` icon name resolves against the freedesktop hicolor theme,
-- which we populate at ~/.local/share/icons/hicolor/<size>/apps/organ.png
-- on first use (one-time, idempotent).

local M = {}

local UNIT_PREFIX = "organ-reminder-"

-- Paths ---------------------------------------------------------------------

local function home()
  return vim.uv.os_homedir() or os.getenv("HOME")
end

local function icon_install_dir()
  return home() .. "/.local/share/icons/hicolor"
end

local function source_hicolor_dir()
  local hits = vim.api.nvim_get_runtime_file("assets/icons/linux/hicolor", false)
  return hits[1]
end

-- Tool detection ------------------------------------------------------------

local function which(cmd)
  local r = vim.system({ "command", "-v", cmd }, { text = true }):wait()
  return r.code == 0
end

local function atd_active()
  if not which("at") then
    return false
  end
  -- systemctl is the most reliable probe on systemd systems. Fall back to
  -- `at -l` which exits nonzero if atd isn't reachable.
  if which("systemctl") then
    local r = vim.system({ "systemctl", "is-active", "--quiet", "atd" }):wait()
    if r.code == 0 then
      return true
    end
    -- Some distros call it `atd.service`; also try the user-visible alias.
    r = vim.system({ "systemctl", "is-active", "--quiet", "atd.service" }):wait()
    if r.code == 0 then
      return true
    end
  end
  local r = vim.system({ "at", "-l" }, { text = true }):wait()
  return r.code == 0
end

local function systemd_user_available()
  if not which("systemctl") then
    return false
  end
  local r = vim.system({ "systemctl", "--user", "--version" }):wait()
  return r.code == 0
end

local function pick_scheduler()
  if atd_active() then
    return "at"
  end
  if systemd_user_available() then
    return "systemd"
  end
  return nil
end

-- Cached scheduler choice. The first call pays the (sync) detection
-- cost; subsequent calls return immediately. This matters because
-- set_batch is called from the `indexed` event handler — we cannot
-- block the UI on every save while we re-probe for atd/systemd.
local _scheduler_cache = nil -- nil = unprobed, false = probed-and-none
local function pick_scheduler_cached()
  if _scheduler_cache == nil then
    _scheduler_cache = pick_scheduler() or false
  end
  return _scheduler_cache or nil
end

-- Icon install -------------------------------------------------------------

local function ensure_icons()
  local src = source_hicolor_dir()
  if not src then
    return false, "hicolor icon source not found on runtimepath (assets/icons/linux/hicolor)"
  end

  local dst_root = icon_install_dir()
  for _, size in ipairs({ "16x16", "32x32", "48x48", "64x64", "128x128", "256x256", "512x512" }) do
    local s_path = ("%s/%s/apps/organ.png"):format(src, size)
    if vim.fn.filereadable(s_path) == 1 then
      local d_path = ("%s/%s/apps/organ.png"):format(dst_root, size)
      vim.fn.mkdir(vim.fn.fnamemodify(d_path, ":h"), "p")
      vim.uv.fs_copyfile(s_path, d_path)
    end
  end
  return true
end

-- Helpers ------------------------------------------------------------------

local function uuid()
  local r = math.random
  return string.format("%x%x%x", os.time(), r(0, 0xfffff), r(0, 0xfffff))
end

-- Shell-quote for the at(1) stdin path (which IS shell-evaluated).
local function shquote(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function notify_argv(title, body)
  return { "notify-send", "--app-name=Organ", "--icon=organ", title or "", body or "" }
end

local function notify_shell_command(title, body)
  -- For `at` stdin we need a shell-string form.
  return table.concat({
    "notify-send",
    "--app-name=Organ",
    "--icon=organ",
    shquote(title or ""),
    shquote(body or ""),
  }, " ")
end

-- Schedulers ---------------------------------------------------------------

local function schedule_at(entry)
  local stamp = os.date("%Y%m%d%H%M", entry.at)
  local cmd_str = notify_shell_command(entry.title, entry.body)
  local r = vim.system({ "at", "-t", stamp }, { text = true, stdin = cmd_str .. "\n" }):wait()
  if r.code ~= 0 then
    return nil, "at: " .. (r.stderr or "unknown")
  end
  -- at writes "job 47 at Sat May  3 09:00:00 2026" to stderr.
  local job = (r.stderr or ""):match("job%s+(%d+)")
  if not job then
    return nil, "at: could not parse job number from: " .. (r.stderr or "")
  end
  return "at:" .. job
end

local function schedule_systemd(entry)
  local now = os.time()
  local delay = entry.at - now
  if delay < 1 then
    return nil, "fire time in past"
  end

  local unit = UNIT_PREFIX .. uuid()
  local argv = notify_argv(entry.title, entry.body)
  local cmd = vim.list_extend({
    "systemd-run",
    "--user",
    "--on-active=" .. delay .. "s",
    "--unit=" .. unit,
    "--",
  }, argv)

  local r = vim.system(cmd, { text = true }):wait()
  if r.code ~= 0 then
    return nil, "systemd-run: " .. (r.stderr or "unknown")
  end
  return "systemd:" .. unit
end

-- Async scheduling — used by M.set_batch from hot paths so we never
-- :wait() inside the indexed-event handler. Each call is parallel.
local function run_async(cmd, opts, cb)
  local ok, _ =
    pcall(vim.system, cmd, opts or { text = true }, cb and vim.schedule_wrap(cb) or function() end)
  if not ok and cb then
    vim.schedule(function()
      cb({ code = -1, stderr = "spawn failed", stdout = "" })
    end)
  end
end

-- In-memory handle tracking. The orchestrator's batch path uses a
-- placeholder "batch" handle (cancellation goes through set_batch's
-- own bookkeeping), so we track the real per-entry handles here.
local _at_handles = {} -- set: { ["at:47"] = true, ... }
local _sd_handles = {} -- set: { ["systemd:organ-reminder-x"] = true }

local function schedule_at_async(entry, cb)
  local stamp = os.date("%Y%m%d%H%M", entry.at)
  local cmd_str = notify_shell_command(entry.title, entry.body)
  run_async({ "at", "-t", stamp }, { text = true, stdin = cmd_str .. "\n" }, function(r)
    if r.code ~= 0 then
      if cb then
        cb(nil, "at: " .. (r.stderr or "unknown"))
      end
      return
    end
    local job = (r.stderr or ""):match("job%s+(%d+)")
    if job then
      _at_handles["at:" .. job] = true
    end
    if cb then
      cb(job and ("at:" .. job) or nil)
    end
  end)
end

local function schedule_systemd_async(entry, cb)
  local now = os.time()
  local delay = entry.at - now
  if delay < 1 then
    if cb then
      cb(nil, "fire time in past")
    end
    return
  end
  local unit = UNIT_PREFIX .. uuid()
  local argv = notify_argv(entry.title, entry.body)
  local cmd = vim.list_extend({
    "systemd-run",
    "--user",
    "--on-active=" .. delay .. "s",
    "--unit=" .. unit,
    "--",
  }, argv)
  run_async(cmd, { text = true }, function(r)
    if r.code ~= 0 then
      if cb then
        cb(nil, "systemd-run: " .. (r.stderr or "unknown"))
      end
      return
    end
    _sd_handles["systemd:" .. unit] = true
    if cb then
      cb("systemd:" .. unit)
    end
  end)
end

local function cancel_async(handle)
  local kind, id = handle:match("^(%w+):(.+)$")
  if not kind then
    return
  end
  if kind == "at" then
    run_async({ "atrm", id })
    _at_handles[handle] = nil
  elseif kind == "systemd" then
    run_async({ "systemctl", "--user", "stop", id .. ".timer" })
    run_async({ "systemctl", "--user", "stop", id .. ".service" })
    _sd_handles[handle] = nil
  end
end

-- Public --------------------------------------------------------------------

-- Test/diagnostic accessors. Underscore-prefixed; not part of the stable API.
M._shquote = shquote
M._notify_argv = notify_argv
M._notify_shell_command = notify_shell_command

-- Public batch API. Replaces the entire scheduled batch with `entries`
-- using async per-entry shell-outs (parallel). Fire-and-forget; cb
-- (optional) gets (true, nil) once the dispatch loop has completed.
-- The orchestrator prefers this over per-entry schedule().
function M.set_batch(entries, cb)
  ensure_icons()
  local sched = pick_scheduler_cached()
  if not sched then
    if cb then
      cb(nil, "no scheduler available (need atd running or systemd --user)")
    end
    return
  end

  -- Cancel previous batch (parallel, async).
  for h in pairs(_at_handles) do
    cancel_async(h)
  end
  for h in pairs(_sd_handles) do
    cancel_async(h)
  end

  -- Schedule new entries (parallel, async).
  for _, entry in ipairs(entries or {}) do
    if sched == "at" then
      schedule_at_async(entry)
    elseif sched == "systemd" then
      schedule_systemd_async(entry)
    end
  end

  if cb then
    cb(true, nil)
  end
end

function M.schedule(entry)
  ensure_icons() -- best-effort one-time install

  local sched = pick_scheduler_cached()
  if sched == "at" then
    return schedule_at(entry)
  end
  if sched == "systemd" then
    return schedule_systemd(entry)
  end
  return nil, "no scheduler available (need atd running or systemd --user)"
end

function M.cancel(handle)
  if type(handle) ~= "string" then
    return false, "no handle"
  end
  local kind, id = handle:match("^(%w+):(.+)$")
  if not kind then
    return false, "malformed handle: " .. handle
  end

  if kind == "at" then
    local r = vim.system({ "atrm", id }):wait()
    return r.code == 0
  elseif kind == "systemd" then
    -- systemd-run with --on-active creates a `<unit>.timer` (and matching .service).
    vim.system({ "systemctl", "--user", "stop", id .. ".timer" }):wait()
    vim.system({ "systemctl", "--user", "stop", id .. ".service" }):wait()
    return true
  end
  return false, "unknown handle kind: " .. kind
end

-- Wipe all organ-owned scheduled jobs we can identify by tag/unit name.
function M.cancel_all()
  -- at(1) jobs: we can't tag them, so we can't safely identify ours vs the
  -- user's. Skip — rely on state-file-driven cancellation only for at jobs.
  -- systemd: stop all units matching our prefix.
  if which("systemctl") then
    local r = vim
      .system({
        "systemctl",
        "--user",
        "list-units",
        "--type=timer,service",
        "--all",
        "--no-legend",
        UNIT_PREFIX .. "*",
      }, { text = true })
      :wait()
    for line in (r.stdout or ""):gmatch("[^\n]+") do
      local unit = line:match("^%s*(%S+)")
      if unit then
        vim.system({ "systemctl", "--user", "stop", unit }):wait()
      end
    end
  end
  return true
end

function M.status()
  return {
    notify_send = which("notify-send"),
    at = which("at"),
    atd_active = atd_active(),
    systemctl = which("systemctl"),
    systemd_user = systemd_user_available(),
    chosen_scheduler = pick_scheduler(),
    icons_installed = vim.fn.isdirectory(icon_install_dir() .. "/256x256/apps") == 1,
    icon_install_dir = icon_install_dir(),
    source_hicolor = source_hicolor_dir(),
  }
end

return M
