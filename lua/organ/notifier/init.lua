-- OS-level notification scheduling. Survives Neovim closing.
--
-- Each platform backend implements:
--   schedule(entry)  -> handle (string) | nil, error
--   cancel(handle)   -> ok, error
--   cancel_all()     -> ok, error          (safety wipe; not handle-targeted)
--   status()         -> diagnostic table
--   deliver_cmd(...) -> string             (shell command the OS scheduler runs)
--
-- Entry shape: { id, at, title, body }
--   id     stable identifier (e.g., "<headline-id>|<due_ts>|<lead_minutes>")
--   at     Unix timestamp the notification should fire
--   title  short headline
--   body   one-line description

local M = {}

local state = require("organ.notifier.state")

local function detect_platform()
  local uname = vim.uv.os_uname()
  local sys = (uname and uname.sysname) or ""
  if sys == "Darwin" then
    return "macos"
  end
  if sys == "Linux" then
    return "linux"
  end
  if sys == "Windows_NT" then
    return "windows"
  end
  return nil
end

local function load_backend()
  local platform = detect_platform()
  if not platform then
    return nil, "unsupported platform"
  end
  local ok, backend = pcall(require, "organ.notifier." .. platform)
  if not ok then
    return nil, "backend load failed: " .. tostring(backend)
  end
  return backend, nil, platform
end

-- Public

-- Replace the previously scheduled batch with `entries`. Cancels every old
-- handle from the state file, schedules each entry that is still in the
-- future, writes the new handles to the state file. Idempotent: calling
-- with the same entries is a no-op in effect (cancels then re-schedules).
function M.set_pending(entries)
  local backend, err, platform = load_backend()
  if not backend then
    return false, err
  end

  local now = os.time()
  entries = entries or {}

  -- Filter to future entries up front; both paths use this list.
  local future = {}
  for _, entry in ipairs(entries) do
    if entry.at and entry.at > now then
      future[#future + 1] = entry
    end
  end

  -- Batch path: backend implements set_batch (one async call for the
  -- whole list, no per-entry shell-out). Used by macOS and Linux to
  -- avoid the per-save UI freeze that the per-entry schedule loop
  -- caused (N × launchctl bootout/bootstrap synchronous calls).
  if type(backend.set_batch) == "function" then
    backend.set_batch(future) -- fire-and-forget; cb omitted
    local persisted = {}
    for _, e in ipairs(future) do
      persisted[#persisted + 1] = {
        id = e.id,
        at = e.at,
        title = e.title,
        body = e.body,
        handle = "batch", -- sentinel: cancel is a no-op for batch backends
      }
    end
    return state.set_entries(persisted, platform)
  end

  -- Per-entry fallback: backends without set_batch. Cancel previous
  -- handles, schedule new entries one at a time. This path can still
  -- block on backends with synchronous schedule().
  local prev = state.load()
  for _, e in ipairs(prev.entries or {}) do
    if e.handle then
      pcall(backend.cancel, e.handle)
    end
  end

  local new_entries = {}
  for _, entry in ipairs(future) do
    local handle, herr = backend.schedule(entry)
    if handle then
      new_entries[#new_entries + 1] = {
        id = entry.id,
        at = entry.at,
        title = entry.title,
        body = entry.body,
        handle = handle,
      }
    else
      local notify = require("organ.notify")
      notify.warn(
        ("notifier: schedule failed for %q: %s"):format(
          entry.title or entry.id or "?",
          herr or "unknown"
        )
      )
    end
  end

  return state.set_entries(new_entries, platform)
end

function M.list_pending()
  return state.load().entries or {}
end

-- Cancel everything organ has scheduled. Safety wipe — also asks the
-- backend to clean up any stragglers it can identify (in case state was
-- lost / out of sync).
function M.cancel_all()
  local backend, err, platform = load_backend()
  if not backend then
    return false, err
  end

  local prev = state.load()
  for _, e in ipairs(prev.entries or {}) do
    if e.handle then
      pcall(backend.cancel, e.handle)
    end
  end
  pcall(backend.cancel_all)

  return state.set_entries({}, platform)
end

-- Fire a single test notification to validate platform setup.
-- Backends that expose `fire_now` deliver it immediately without
-- touching the persistent scheduling state.  On macOS that means
-- bypassing launchd, which would otherwise raise a "Background
-- item added" system alert every time a new launch agent is
-- bootstrapped.  Backends without fire_now fall back to schedule()
-- with a short delay.
function M.test(seconds_ahead)
  local backend, err = load_backend()
  if not backend then
    return nil, err
  end
  local entry = {
    id = "organ-notifier-test",
    title = "Organ test",
    body = "If you see this, OS notifications are working.",
  }
  if type(backend.fire_now) == "function" then
    return backend.fire_now(entry)
  end
  entry.at = os.time() + (seconds_ahead or 10)
  return backend.schedule(entry)
end

-- Diagnostic. Returns:
--   { platform, supported, entries_count, next_at, backend = { ... } }
function M.status()
  local backend, err, platform = load_backend()
  local pending = state.load().entries or {}

  local next_at
  for _, e in ipairs(pending) do
    if e.at and (not next_at or e.at < next_at) then
      next_at = e.at
    end
  end

  return {
    platform = platform,
    supported = backend ~= nil,
    error = err,
    entries_count = #pending,
    next_at = next_at,
    state_path = state.path(),
    backend = backend and backend.status and backend.status() or nil,
  }
end

local function notifier_status_lines()
  local s = M.status()
  local lines = {
    ("organ.notifier: platform=%s  supported=%s  scheduled=%d"):format(
      s.platform or "?",
      tostring(s.supported),
      s.entries_count
    ),
  }
  if s.error then
    lines[#lines + 1] = ("  error: %s"):format(s.error)
  end
  if s.next_at then
    lines[#lines + 1] = ("  next fire: %s"):format(os.date("%Y-%m-%d %H:%M:%S", s.next_at))
  end
  lines[#lines + 1] = ("  state file: %s"):format(s.state_path)
  if s.backend then
    lines[#lines + 1] = "  backend:"
    local keys = {}
    for k in pairs(s.backend) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      lines[#lines + 1] = ("    %s = %s"):format(k, tostring(s.backend[k]))
    end
  end
  return lines
end

local function platform_name()
  local u = vim.uv.os_uname()
  if u.sysname == "Darwin" then
    return "macos"
  elseif u.sysname == "Linux" then
    return "linux"
  elseif u.sysname == "Windows_NT" then
    return "windows"
  end
  return nil, u.sysname
end

M.commands = {
  ["notifier status"] = {
    fn = function()
      vim.api.nvim_echo({ { table.concat(notifier_status_lines(), "\n"), "None" } }, false, {})
    end,
    desc = "Show organ OS-notification scheduler status",
  },
  ["notifier clear"] = {
    fn = function()
      local ok, err = M.cancel_all()
      if ok then
        require("organ.notify").info("organ.notifier: all OS-scheduled entries cleared")
      else
        require("organ.notify").warn("organ.notifier: clear failed: " .. tostring(err))
      end
    end,
    desc = "Cancel all organ-scheduled OS-level notifications",
  },
  ["notifier install"] = {
    fn = function()
      local plat, sysname = platform_name()
      if plat ~= "macos" then
        require("organ.notify").info(
          "notifier_install: nothing to install on "
            .. tostring(sysname or plat)
            .. " (Linux uses notify-send + at(1)/systemd-run; Windows uses "
            .. "schtasks + WinRT toast — none require a bundle)."
        )
        return
      end
      local backend = require("organ.notifier.macos")
      local ok, err = backend.install_bundle()
      if ok then
        local s = backend.status()
        require("organ.notify").info(
          "notifier_install: bundle installed at "
            .. s.bundle_path
            .. " (Swift binary: "
            .. tostring(s.swiftc and "yes" or "fallback shell")
            .. "). Registered with macOS LaunchServices.\n"
            .. "macOS should display a permission prompt for 'Organ' "
            .. "shortly -- click Allow to enable reminder notifications. "
            .. "If you miss it, enable manually under "
            .. "System Settings -> Notifications -> Organ.\n"
            .. "Run :Org notifier test to validate, "
            .. ":Org notifier uninstall to remove."
        )
      else
        require("organ.notify").error("notifier_install failed: " .. tostring(err))
      end
    end,
    desc = "Install the macOS notifier bundle (opt-in)",
  },
  ["notifier test"] = {
    fn = function()
      local notify = require("organ.notify")
      local handle, err = M.test(10)
      if not handle then
        notify.warn("organ.notifier: test failed: " .. tostring(err))
        return
      end
      vim.defer_fn(function()
        notify.info(
          "organ.notifier test fired. If no system notification appeared:\n"
            .. "  1. Check System Settings → Notifications → Organ (or Script Editor"
            .. " when you don't have Xcode CLT installed).\n"
            .. "  2. Run `:Org notifier doctor` for a step-by-step diagnostic."
        )
      end, 1500)
    end,
    desc = "Fire a test OS notification (verifies the install end-to-end)",
  },
  ["notifier doctor"] = {
    fn = function()
      local plat, sysname = platform_name()
      if not plat then
        require("organ.notify").error("notifier_doctor: unsupported platform " .. tostring(sysname))
        return
      end
      local ok, backend = pcall(require, "organ.notifier." .. plat)
      if not ok then
        require("organ.notify").error("notifier_doctor: backend load failed: " .. tostring(backend))
        return
      end
      if type(backend.diagnose) ~= "function" then
        require("organ.notify").warn(
          "notifier_doctor: "
            .. plat
            .. " backend has no diagnose() — only macOS supports this so far"
        )
        return
      end
      local lines = { "Notifier doctor (" .. plat .. "):", "" }
      for _, s in ipairs(backend.diagnose()) do
        local mark = (s.ok == true and "PASS") or (s.ok == false and "FAIL") or "info"
        lines[#lines + 1] = ("  [%s] %s"):format(mark, s.label)
        if s.detail and s.detail ~= "" then
          lines[#lines + 1] = "         " .. s.detail
        end
      end
      vim.api.nvim_echo({ { table.concat(lines, "\n"), "None" } }, true, {})
    end,
    desc = "Diagnose why OS notifications aren't firing",
  },
  ["notifier uninstall"] = {
    fn = function()
      local plat, sysname = platform_name()
      if plat ~= "macos" then
        require("organ.notify").info(
          "notifier_uninstall: macOS-only (current platform: " .. tostring(sysname or plat) .. ")"
        )
        return
      end
      local backend = require("organ.notifier.macos")
      local home = vim.uv.os_homedir() or os.getenv("HOME")
      local bundle = home .. "/Library/Application Support/organ/Organ.app"
      local prompt = (
        "organ: this will remove every scheduled reminder AND the bundle at\n  %s\n"
        .. "Continue? [y/N] "
      ):format(bundle)
      vim.ui.input({ prompt = prompt }, function(answer)
        if not answer or not answer:lower():match("^y") then
          require("organ.notify").info("notifier_uninstall: cancelled (no changes made)")
          return
        end
        local steps = backend.uninstall_bundle()
        local body = "notifier_uninstall:\n  " .. table.concat(steps, "\n  ")
        vim.api.nvim_echo({ { body, "None" } }, true, {})
      end)
    end,
    desc = "Remove the organ.app bundle + every scheduled reminder (macOS only)",
  },
}

return M
