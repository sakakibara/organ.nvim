-- macOS notifier backend.
--
-- Design (post-redesign): ONE persistent LaunchAgent
-- (`sh.organ.tick`) whose plist carries an array of
-- `StartCalendarInterval` entries — one per upcoming reminder's exact
-- fire time. launchd wakes the agent at each of those times and only
-- those times, so:
--   * Settings → Login Items & Extensions has ONE entry, not N.
--   * Zero polling (no battery drain between fires).
--   * Survives reboot (launchd persists agents across logout/boot).
--
-- The agent invokes the bundled `organ-notify` binary with the path to
-- our state file. The binary reads pending entries, fires those whose
-- `at` matches the current minute (±grace), marks them fired, and
-- exits. Notification attribution is "Organ" (our bundle id), not
-- "Script Editor".
--
-- The bundle binary is built at install time via `swiftc` (Xcode CLT).
-- If swiftc isn't available, we fall back to a shell script that calls
-- osascript — notifications still fire but attribution becomes
-- "Script Editor" (so the user has to permit Script Editor instead).
-- Doctor diagnoses this.

local M = {}

local TICK_LABEL = "sh.organ.tick"
local LEGACY_PFX = "sh.organ.reminder." -- old per-reminder agents (cleanup)
local BUNDLE_ID = "sh.organ.notifier"

-- Paths ---------------------------------------------------------------------

local function home()
  return vim.uv.os_homedir() or os.getenv("HOME")
end

local function uid()
  return tostring(vim.uv.getuid())
end

local function launchagents_dir()
  return home() .. "/Library/LaunchAgents"
end
local function bundle_dir()
  return home() .. "/Library/Application Support/organ/Organ.app"
end
local function bundle_exec()
  return bundle_dir() .. "/Contents/MacOS/organ-notify"
end
local function bundle_icon()
  return bundle_dir() .. "/Contents/Resources/Organ.icns"
end
local function bundle_plist()
  return bundle_dir() .. "/Contents/Info.plist"
end
local function tick_plist()
  return launchagents_dir() .. "/" .. TICK_LABEL .. ".plist"
end

local function state_path()
  return require("organ.notifier.state").path()
end

local function source_icns()
  local hits = vim.api.nvim_get_runtime_file("assets/icons/Organ.icns", false)
  return hits[1]
end

local function source_swift()
  local hits = vim.api.nvim_get_runtime_file("assets/macos-notifier/main.swift", false)
  return hits[1]
end

-- Bundle install ------------------------------------------------------------

local INFO_PLIST = [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>       <string>]] .. BUNDLE_ID .. [[</string>
  <key>CFBundleName</key>             <string>Organ</string>
  <key>CFBundleDisplayName</key>      <string>Organ</string>
  <key>CFBundleExecutable</key>       <string>organ-notify</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleIconFile</key>         <string>Organ.icns</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key>              <true/>
</dict>
</plist>
]]

-- Fallback executable when `swiftc` isn't available — calls osascript.
-- Same arg shape as the Swift binary (state file path), but the body
-- ignores it and just shells out for whichever entry id was passed in
-- the legacy callsite. Kept minimal because users who hit this fallback
-- get worse attribution anyway.
local NOTIFY_FALLBACK_SH = [[#!/bin/sh
# Fallback: notifications attribute to Script Editor (the osascript
# runtime), not "Organ", because we don't have a bundled binary that
# links UserNotifications. Install Xcode Command Line Tools and re-run
# `:Org notifier test` to upgrade — see `:h organ-notifier`.
exec env STATE="$1" osascript -e \
  'display notification "Organ scheduled reminder fired" with title "Organ"'
]]

local function write_file(path, contents, mode)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd, err = io.open(path, "w")
  if not fd then
    return false, err
  end
  fd:write(contents)
  fd:close()
  if mode then
    vim.uv.fs_chmod(path, mode)
  end
  return true
end

local function copy_file(src, dst)
  vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")
  local ok, err = vim.uv.fs_copyfile(src, dst)
  return ok ~= nil, err
end

local function run(cmd, opts)
  return vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait()
end

-- Wrap vim.system in pcall AND chain :wait() correctly. Returns the
-- system result (with .code, .stderr, .stdout) on success, or { code = -1,
-- stderr = err } on failure. Used for best-effort sites where we don't
-- want a missing binary (e.g. lsregister on Linux during tests) to throw.
local function try_run(cmd, opts)
  opts = vim.tbl_extend("force", { text = true }, opts or {})
  local ok, handle = pcall(vim.system, cmd, opts)
  if not ok then
    return { code = -1, stderr = tostring(handle), stdout = "" }
  end
  return handle:wait()
end

-- Fire-and-forget async run. Never blocks. Use from any code path that
-- runs on the UI loop (indexed-event handler, scan timer, set_batch).
-- Optional cb gets the system result.
local function run_async(cmd, cb)
  local ok, _ =
    pcall(vim.system, cmd, { text = true }, cb and vim.schedule_wrap(cb) or function() end)
  if not ok and cb then
    require("organ.errors").schedule("organ.notifier.macos", function()
      cb({ code = -1, stderr = "spawn failed", stdout = "" })
    end)
  end
end

-- Compile main.swift to a universal binary in the bundle's MacOS dir.
-- Returns true on success, false + reason on failure.
local function build_swift_binary()
  if vim.fn.executable("swiftc") ~= 1 then
    return false, "swiftc not found (install Xcode Command Line Tools: `xcode-select --install`)"
  end
  local src = source_swift()
  if not src then
    return false, "main.swift not found on runtimepath"
  end
  vim.fn.mkdir(vim.fn.fnamemodify(bundle_exec(), ":h"), "p")
  local r = run({
    "swiftc",
    "-O",
    "-target",
    "arm64-apple-macos11", -- arm64 baseline; we add x86_64 below
    src,
    "-o",
    bundle_exec() .. ".arm64",
  })
  if r.code ~= 0 then
    return false, "swiftc arm64 failed: " .. (r.stderr or "")
  end
  -- Build x86_64 too.
  r = run({
    "swiftc",
    "-O",
    "-target",
    "x86_64-apple-macos11",
    src,
    "-o",
    bundle_exec() .. ".x86_64",
  })
  if r.code ~= 0 then
    -- Apple Silicon may not have x86_64 SDK; fall back to single-arch arm64.
    pcall(os.rename, bundle_exec() .. ".arm64", bundle_exec())
    return true
  end
  -- Lipo to a fat binary so the same bundle works on Intel + ARM.
  if vim.fn.executable("lipo") == 1 then
    r = run({
      "lipo",
      "-create",
      bundle_exec() .. ".arm64",
      bundle_exec() .. ".x86_64",
      "-output",
      bundle_exec(),
    })
    pcall(os.remove, bundle_exec() .. ".arm64")
    pcall(os.remove, bundle_exec() .. ".x86_64")
    if r.code ~= 0 then
      return false, "lipo failed: " .. (r.stderr or "")
    end
  else
    -- No lipo (very rare on macOS) → ship just arm64.
    pcall(os.rename, bundle_exec() .. ".arm64", bundle_exec())
    pcall(os.remove, bundle_exec() .. ".x86_64")
  end
  vim.uv.fs_chmod(bundle_exec(), 493) -- 0755
  return true
end

-- Re-sign the whole bundle ad-hoc with the bundle's CFBundleIdentifier
-- so Info.plist + resources get sealed into the signature.  Required
-- for `UNUserNotificationCenter.requestAuthorization` to recognise
-- the binary as part of the bundle and grant the bundle's
-- notification permissions.  Without this step, swiftc's
-- "linker-signed" output uses a default identifier (`organ-notify.arm64`)
-- and `Info.plist=not bound`, which modern macOS treats as a loose
-- tool — permission requests silently deny and no entry appears in
-- System Settings -> Notifications.
local function sign_bundle()
  if vim.fn.executable("codesign") ~= 1 then
    return false, "codesign not found"
  end
  local r = run({
    "codesign",
    "--force",
    "--sign",
    "-", -- ad-hoc; works without an Apple Developer cert
    "--identifier",
    BUNDLE_ID,
    bundle_dir(),
  })
  if r.code ~= 0 then
    return false, "codesign failed: " .. (r.stderr or "")
  end
  return true
end

-- Idempotent. Lays down Info.plist + icon + the executable. The
-- executable is the Swift-compiled binary if swiftc is available,
-- otherwise the shell-script fallback.
--
-- True when the bundle exists AND its signature is bound to the
-- bundle id (i.e. notifications will attribute correctly).  Used as
-- the fast-path predicate so we re-sign automatically on the next
-- install when an old/broken bundle is detected.
local function bundle_signature_ok()
  if vim.fn.executable("codesign") ~= 1 then
    return true -- can't verify; assume ok rather than re-sign on every scan
  end
  local r = try_run({ "codesign", "-dv", bundle_dir() }, { stderr = true })
  if r.code ~= 0 then
    return false
  end
  local out = (r.stderr or "") .. (r.stdout or "")
  -- The bundle is properly signed iff the signature's Identifier is
  -- the bundle's CFBundleIdentifier (linker-signed swiftc output uses
  -- a binary-specific id like `organ-notify.arm64`) AND the Info.plist
  -- is bound (linker-signed has `Info.plist=not bound`).
  if not out:find("Identifier=" .. BUNDLE_ID, 1, true) then
    return false
  end
  if out:find("Info.plist=not bound", 1, true) then
    return false
  end
  return true
end

-- Run the helper once via `open -gj -a Organ.app` so it launches as
-- a proper foreground app session.  That's the only context in which
-- macOS's `UNUserNotificationCenter.requestAuthorization` shows the
-- permission prompt; CLI subprocess invocations (the way launchd or
-- `vim.system({bundle_exec, ...})` runs the binary) silently default
-- to "denied" if no decision is on file, leaving the Organ entry in
-- System Settings -> Notifications stuck in the off position with no
-- way for the user to know they had to enable it.  Calling this once
-- at install time is enough for the lifetime of the bundle: macOS
-- caches the permission decision against the bundle id.
--   `-g` keep backgrounded (don't steal focus from nvim)
--   `-j` launch hidden (no Dock bounce; LSUIElement makes it permanent)
-- Fire-and-forget: the helper waits up to 30s for the user to act on
-- the prompt and then exits on its own.  The tmp state is empty so
-- nothing fires visibly other than the permission dialog.
local function prime_app_session()
  local tmp = vim.fn.tempname() .. ".json"
  local f = io.open(tmp, "w")
  if not f then
    return
  end
  f:write('{"version":1,"platform":"macos","entries":[]}')
  f:close()
  pcall(vim.system, {
    "open",
    "-g",
    "-j",
    "-a",
    bundle_dir(),
    "--args",
    tmp,
  }, { text = true })
end

-- Fast path: if Info.plist + executable are both on disk AND the
-- signature is bound to the bundle id, skip the whole function
-- (including the lsregister sync shell call).  This runs on every
-- alarms.scan via install_bundle so the cost matters.  When the
-- signature check fails (old install with a linker-signed binary),
-- fall through to the full rebuild path so the next scan / explicit
-- `:Org notifier install` repairs the bundle.
local function ensure_bundle()
  if
    vim.fn.filereadable(bundle_plist()) == 1
    and vim.fn.filereadable(bundle_exec()) == 1
    and bundle_signature_ok()
  then
    return true
  end

  -- Info.plist
  if vim.fn.filereadable(bundle_plist()) == 0 then
    local ok, err = write_file(bundle_plist(), INFO_PLIST)
    if not ok then
      return false, "Info.plist: " .. tostring(err)
    end
  end

  -- Icon
  local src_icon = source_icns()
  if src_icon then
    local need = vim.fn.filereadable(bundle_icon()) == 0
    if not need then
      local s_src = vim.uv.fs_stat(src_icon)
      local s_dst = vim.uv.fs_stat(bundle_icon())
      if s_src and s_dst and s_src.mtime.sec > s_dst.mtime.sec then
        need = true
      end
    end
    if need then
      copy_file(src_icon, bundle_icon())
    end
  end

  -- Executable: try Swift binary, fall back to shell.
  if vim.fn.filereadable(bundle_exec()) == 0 then
    local ok, err = build_swift_binary()
    if not ok then
      require("organ.notify").warn(
        "organ.notifier: Swift build failed; falling back to osascript "
          .. "(notifications will attribute to Script Editor, not Organ). "
          .. "Reason: "
          .. tostring(err)
      )
      local ok2, werr = write_file(bundle_exec(), NOTIFY_FALLBACK_SH, 493)
      if not ok2 then
        return false, "fallback exec: " .. tostring(werr)
      end
    end
  end

  -- Re-sign the whole bundle ad-hoc with the bundle's
  -- CFBundleIdentifier.  swiftc's linker-signed output uses a default
  -- identifier and doesn't seal Info.plist; UNUserNotificationCenter
  -- treats that as a loose tool and silently denies permission.  This
  -- step binds the binary to the bundle so notifications attribute
  -- correctly.  Failure to sign isn't fatal (notifications may still
  -- work for users with relaxed Gatekeeper / macOS < 12), but we
  -- surface the warning so a debugging user sees the cause.
  local ok_sign, sign_err = sign_bundle()
  if not ok_sign then
    require("organ.notify").warn(
      "organ.notifier: bundle codesign failed: "
        .. tostring(sign_err)
        .. " — notifications may not appear; run :Org notifier doctor"
    )
  end

  -- Register with LaunchServices so macOS knows about the bundle id.
  -- Fire-and-forget: registration is purely for app attribution; the
  -- LaunchAgent fires regardless. Was sync (~500ms-1s) and blocking the
  -- UI on first install.  Once registered, prime an app session so
  -- the permission prompt fires (lsregister + prime are scheduled in
  -- order: prime runs after lsregister returns so the bundle is
  -- discoverable by `open -a`).
  run_async({
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
      .. "LaunchServices.framework/Support/lsregister",
    "-f",
    bundle_dir(),
  }, function(_)
    require("organ.errors").schedule("organ.notifier.macos", prime_app_session)
  end)

  return true
end

function M.install_bundle()
  return ensure_bundle()
end

-- Tick agent ----------------------------------------------------------------

local function escape_xml(s)
  s = tostring(s or "")
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  s = s:gsub('"', "&quot;"):gsub("'", "&apos;")
  return s
end

-- Build the StartCalendarInterval-array plist for the tick agent.
-- `entries` is the same shape as organ.notifier.set_pending receives.
-- One <dict> per entry, each fully-specified (Year/Month/Day/Hour/Minute)
-- so it matches exactly once.
local function tick_plist_body(entries)
  local now = os.time()
  local intervals = {}
  for _, e in ipairs(entries or {}) do
    if type(e.at) == "number" and e.at > now then
      local d = os.date("*t", e.at)
      intervals[#intervals + 1] = string.format(
        [[
    <dict>
      <key>Year</key>   <integer>%d</integer>
      <key>Month</key>  <integer>%d</integer>
      <key>Day</key>    <integer>%d</integer>
      <key>Hour</key>   <integer>%d</integer>
      <key>Minute</key> <integer>%d</integer>
    </dict>]],
        d.year,
        d.month,
        d.day,
        d.hour,
        d.min
      )
    end
  end

  -- If there are no future entries, we still install a minimal plist
  -- with no triggers so launchctl bootstrap succeeds. The agent will
  -- never fire until set_pending() rewrites it.
  local interval_xml = #intervals > 0
      and "  <key>StartCalendarInterval</key>\n  <array>\n" .. table.concat(intervals, "\n") .. "\n  </array>"
    or ""

  return string.format(
    [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>%s</string>
  </array>
%s
  <key>RunAtLoad</key> <false/>
  <key>StandardErrorPath</key> <string>%s</string>
</dict>
</plist>
]],
    escape_xml(TICK_LABEL),
    escape_xml(bundle_exec()),
    escape_xml(state_path()),
    interval_xml,
    escape_xml(home() .. "/Library/Logs/organ-notifier.log")
  )
end

local function bootstrap(path)
  return run({ "launchctl", "bootstrap", "gui/" .. uid(), path })
end

local function bootout(path)
  return run({ "launchctl", "bootout", "gui/" .. uid(), path })
end

-- Best-effort: remove every plist matching the LEGACY per-reminder
-- prefix from the previous design.
--
-- Async + once-per-session. The previous version ran on every
-- set_batch / set_pending call (so once per save when alarms enabled),
-- doing N synchronous launchctl bootouts — major UI freeze source.
-- Cleanup is purely a one-time migration cost; running it once at first
-- batch dispatch is enough for any session.
local _legacy_cleanup_scheduled = false
local function cleanup_legacy_agents_async()
  if _legacy_cleanup_scheduled then
    return
  end
  _legacy_cleanup_scheduled = true
  local fd = vim.uv.fs_scandir(launchagents_dir())
  if not fd then
    return
  end
  while true do
    local name, t = vim.uv.fs_scandir_next(fd)
    if not name then
      break
    end
    if t == "file" and name:sub(1, #LEGACY_PFX) == LEGACY_PFX and name:sub(-6) == ".plist" then
      local p = launchagents_dir() .. "/" .. name
      run_async({ "launchctl", "bootout", "gui/" .. uid(), p }, function(_)
        pcall(os.remove, p)
      end)
    end
  end
end

-- Synchronous legacy cleanup, used only by uninstall_bundle (user-
-- initiated, blocking is fine).
local function cleanup_legacy_agents_sync()
  local fd = vim.uv.fs_scandir(launchagents_dir())
  if not fd then
    return 0
  end
  local removed = 0
  while true do
    local name, t = vim.uv.fs_scandir_next(fd)
    if not name then
      break
    end
    if t == "file" and name:sub(1, #LEGACY_PFX) == LEGACY_PFX and name:sub(-6) == ".plist" then
      local p = launchagents_dir() .. "/" .. name
      pcall(bootout, p)
      pcall(os.remove, p)
      removed = removed + 1
    end
  end
  return removed
end

-- Public: rewrite the tick agent's plist to fire at the given entries'
-- exact times. Old plist (and the agent it bootstrapped) is replaced.
-- Per-platform contract: returns (handle | nil), err.
--
-- Note: organ.notifier.set_pending iterates entries one at a time and
-- calls backend.schedule per entry — that doesn't fit a "one tick-agent
-- holds the whole batch" design. We expose a backend-level API that
-- the orchestrator can call instead, AND keep `M.schedule(entry)` as a
-- compatibility shim that recomputes the full batch each call (slightly
-- redundant but safe).

-- Persisted local state of the current batch in memory; merged with
-- whatever the orchestrator has on disk on each call.
local _current_batch = {}

-- Async tick rewrite. Chain: bootout (best-effort, may not be loaded)
-- → write plist → bootstrap. Each step's vim.system runs without
-- :wait(), so the UI never blocks. cb (optional) gets (handle|nil, err).
--
-- Was sync per-entry: 30+ launchctl shell calls per save with 10
-- reminders = 1-2 seconds of UI freeze. Now: zero blocking, regardless
-- of batch size.
local function rewrite_tick_async(entries, cb)
  local ok, err = ensure_bundle()
  if not ok then
    if cb then
      cb(nil, err)
    end
    return
  end
  cleanup_legacy_agents_async()

  local body = tick_plist_body(entries)
  local wrote, werr = write_file(tick_plist(), body)
  if not wrote then
    if cb then
      cb(nil, "tick plist write: " .. tostring(werr))
    end
    return
  end

  -- bootout (may fail if not loaded — that's OK, we ignore code) →
  -- bootstrap. Both async; chain via callback.
  run_async({ "launchctl", "bootout", "gui/" .. uid(), tick_plist() }, function(_)
    run_async({ "launchctl", "bootstrap", "gui/" .. uid(), tick_plist() }, function(res)
      if cb then
        if res.code == 0 then
          cb(tick_plist(), nil)
        else
          cb(
            nil,
            "launchctl bootstrap: code=" .. tostring(res.code) .. " stderr=" .. tostring(res.stderr)
          )
        end
      end
    end)
  end)
end

-- Public batch API. Replaces the entire scheduled batch with `entries`.
-- Async — returns immediately; cb (optional) fires when bootstrap
-- completes. The orchestrator prefers this over per-entry schedule().
function M.set_batch(entries, cb)
  if vim.fn.filereadable(bundle_exec()) ~= 1 then
    if cb then
      cb(nil, "Organ notifier bundle is not installed. " .. "Run :Org notifier install.")
    end
    return
  end
  _current_batch = {}
  for _, e in ipairs(entries or {}) do
    if e and e.at then
      _current_batch[e.id or tostring(e.at)] = e
    end
  end
  local list = {}
  for _, e in pairs(_current_batch) do
    list[#list + 1] = e
  end
  rewrite_tick_async(list, cb)
end

-- Compatibility: `schedule(entry)` adds one entry to the batch and
-- rewrites the tick agent. Returns the tick plist path as a sentinel
-- handle (per-entry handles aren't meaningful in the tick-agent design).
--
-- Now async-internally: returns the path immediately, lets bootout/
-- bootstrap complete in the background. Used only by orchestrators
-- without set_batch awareness.
function M.schedule(entry)
  if not entry or not entry.at then
    return nil, "missing at"
  end
  if vim.fn.filereadable(bundle_exec()) ~= 1 then
    return nil,
      "Organ notifier bundle is not installed. "
        .. "Run :Org notifier install to install (creates "
        .. bundle_dir()
        .. ", builds a Swift helper binary, and "
        .. "registers with macOS LaunchServices)."
  end
  _current_batch[entry.id or tostring(entry.at)] = entry
  local list = {}
  for _, e in pairs(_current_batch) do
    list[#list + 1] = e
  end
  rewrite_tick_async(list) -- fire-and-forget
  return tick_plist()
end

function M.cancel(_handle)
  -- Per-entry cancel doesn't apply in the tick-agent design — entries
  -- are removed by set_pending replacing the batch. Treat as no-op so
  -- the orchestrator's pre-set_pending cleanup loop succeeds.
  return true
end

function M.cancel_all()
  _current_batch = {}
  pcall(bootout, tick_plist())
  pcall(os.remove, tick_plist())
  cleanup_legacy_agents_sync()
  return true
end

-- One-shot: write a tmp state JSON with the entry's `at` clamped to
-- now (well within the Swift helper's [now-30, now+5] grace window),
-- then invoke organ-notify directly on it.  Bypasses launchd entirely
-- so `:Org notifier test` doesn't trigger macOS's "Background item
-- added" alert that fires whenever a new launch agent is bootstrapped.
function M.fire_now(entry)
  if not entry or not entry.title then
    return nil, "missing entry / title"
  end
  if vim.fn.filereadable(bundle_exec()) ~= 1 then
    return nil, "Organ notifier bundle is not installed. Run :Org notifier install first."
  end
  local now = os.time()
  local payload = {
    version = 1,
    platform = "macos",
    entries = {
      {
        id = entry.id or "organ-notifier-test",
        at = now,
        title = entry.title,
        body = entry.body or "",
        fired = false,
      },
    },
  }
  local tmp = vim.fn.tempname() .. ".json"
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    return nil, "json encode failed: " .. tostring(encoded)
  end
  local f = io.open(tmp, "w")
  if not f then
    return nil, "cannot write " .. tmp
  end
  f:write(encoded)
  f:close()
  -- Async with completion callback: the helper waits up to 10s for
  -- the user's notification permission prompt, so we don't block
  -- nvim — but we DO want the result so the user sees a clear
  -- failure message instead of silence.  Common failure modes:
  --   * Permission denied (user dismissed the macOS popup)
  --   * Bundle unsigned / quarantined (Gatekeeper blocks delivery)
  --   * Helper crashed (Swift binary mismatch with macOS version)
  vim.system({ bundle_exec(), tmp }, { text = true }, function(res)
    require("organ.errors").schedule("organ.notifier.macos", function()
      if res.code == 0 then
        return -- success path; user saw the notification
      end
      local msg = ("organ.notifier helper exited %d"):format(res.code or -1)
      if res.stderr and res.stderr ~= "" then
        msg = msg .. ": " .. res.stderr
      end
      msg = msg .. "\nIf you didn't see a notification, try `:Org notifier doctor`."
      require("organ.notify").error(msg)
    end)
  end)
  return tmp
end

-- Test/diagnostic accessors. Underscore-prefixed; not part of the stable API.
M._escape_xml = escape_xml
M._tick_plist_body = tick_plist_body
M._notify_script = NOTIFY_FALLBACK_SH
M._info_plist = INFO_PLIST

-- Status / diagnose ---------------------------------------------------------

function M.status()
  local function which(cmd)
    return vim.fn.executable(cmd) == 1
  end
  local installed = vim.uv.fs_stat(tick_plist()) ~= nil
  return {
    bundle_installed = vim.fn.filereadable(bundle_exec()) == 1,
    bundle_path = bundle_dir(),
    icon_installed = vim.fn.filereadable(bundle_icon()) == 1,
    tick_agent_installed = installed,
    tick_plist_path = tick_plist(),
    swiftc = which("swiftc"),
    launchctl = which("launchctl"),
    osascript = which("osascript"),
    source_icns = source_icns(),
    source_swift = source_swift(),
  }
end

function M.diagnose()
  local out = {}
  local function add(ok, label, detail)
    out[#out + 1] = { ok = ok, label = label, detail = detail }
  end

  local function which(cmd)
    return vim.fn.executable(cmd) == 1
  end
  add(
    which("launchctl"),
    "launchctl available",
    which("launchctl") and "yes" or "missing — required"
  )
  add(
    which("osascript"),
    "osascript available",
    which("osascript") and "yes" or "missing — required"
  )
  add(
    which("swiftc"),
    "swiftc available (Xcode CLT)",
    which("swiftc") and "yes — bundled binary uses native UNUserNotificationCenter API"
      or "no — install via `xcode-select --install` for native attribution; "
        .. "otherwise we fall back to osascript (attribution: Script Editor)"
  )

  add(
    vim.fn.filereadable(bundle_exec()) == 1,
    "bundle installed at " .. bundle_dir(),
    vim.fn.filereadable(bundle_exec()) == 1 and "yes (organ-notify executable present)"
      or "missing — run `:Org notifier test` to install"
  )

  -- Detect whether bundle_exec is the Swift binary or the shell fallback.
  do
    local fd = io.open(bundle_exec(), "rb")
    if fd then
      local first = fd:read(4) or ""
      fd:close()
      local is_macho = first:sub(1, 4) == "\xCF\xFA\xED\xFE"
        or first:sub(1, 4) == "\xCA\xFE\xBA\xBE" -- universal
      add(
        is_macho,
        "executable type",
        is_macho and "native Swift binary (notifications attribute to 'Organ')"
          or "shell fallback (notifications attribute to 'Script Editor')"
      )
    end
  end

  add(
    vim.uv.fs_stat(tick_plist()) ~= nil,
    "tick LaunchAgent installed at " .. tick_plist(),
    vim.uv.fs_stat(tick_plist()) and "yes" or "no — call set_pending or :Org scan to install"
  )

  -- Bundle registered with LaunchServices?
  do
    local lsr = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
      .. "LaunchServices.framework/Support/lsregister"
    if vim.fn.filereadable(lsr) == 1 then
      local r = vim.system({ lsr, "-dump" }, { text = true }):wait()
      local found = (r.stdout or ""):find(BUNDLE_ID, 1, true) ~= nil
      add(
        found,
        "bundle registered with LaunchServices",
        found and "yes (sh.organ.notifier in lsregister -dump)"
          or "no — run :Org notifier test to register"
      )
    end
  end

  -- Code signature bound to the bundle id?  If not, modern macOS
  -- silently denies notification permission and no entry appears in
  -- System Settings → Notifications.  This is the most common cause
  -- of "test fired but I never saw it" reports.
  if which("codesign") and vim.fn.filereadable(bundle_exec()) == 1 then
    local r = try_run({ "codesign", "-dv", bundle_dir() }, { stderr = true })
    local out = (r.stderr or "") .. (r.stdout or "")
    local id_ok = out:find("Identifier=" .. BUNDLE_ID, 1, true) ~= nil
    local plist_bound = not out:find("Info.plist=not bound", 1, true)
    local ok = id_ok and plist_bound
    local detail
    if ok then
      detail = "Identifier=" .. BUNDLE_ID .. ", Info.plist sealed"
    else
      local reasons = {}
      if not id_ok then
        reasons[#reasons + 1] = "Identifier doesn't match bundle id"
      end
      if not plist_bound then
        reasons[#reasons + 1] = "Info.plist not bound"
      end
      detail = table.concat(reasons, "; ")
        .. " — run `:Org notifier uninstall` then `:Org notifier install` to re-sign"
    end
    add(ok, "code signature bound to bundle id", detail)
  end

  -- Foreground notification probe (skipped if osascript isn't on PATH —
  -- e.g. when running tests under Linux).
  if which("osascript") then
    local r = vim
      .system({
        "osascript",
        "-e",
        'display notification "diagnose probe" with title "Organ"',
      }, { text = true })
      :wait()
    if r.code == 0 then
      add(
        true,
        "osascript display-notification probe",
        "succeeded (you should have seen a notification just now)"
      )
    else
      add(
        false,
        "osascript display-notification probe FAILED",
        "stderr: " .. (r.stderr or "(no stderr)")
      )
    end
  end

  return out
end

-- Safe uninstall ------------------------------------------------------------

-- Removes the tick agent + every legacy per-reminder agent + the bundle
-- + deregisters from LaunchServices. Refuses to delete a SYMLINK at the
-- bundle path (somebody could have repurposed it). Returns a list of
-- step-description strings.
function M.uninstall_bundle()
  local steps = {}
  local function note(s)
    steps[#steps + 1] = s
  end

  -- 1. Tick agent
  pcall(bootout, tick_plist())
  if vim.uv.fs_stat(tick_plist()) then
    pcall(os.remove, tick_plist())
    note("removed tick agent " .. tick_plist())
  else
    note("no tick agent to remove (" .. tick_plist() .. " not present)")
  end

  -- 2. Legacy per-reminder agents
  local fd = vim.uv.fs_scandir(launchagents_dir())
  local removed = 0
  while fd do
    local name, t = vim.uv.fs_scandir_next(fd)
    if not name then
      break
    end
    if t == "file" and name:sub(1, #LEGACY_PFX) == LEGACY_PFX and name:sub(-6) == ".plist" then
      local p = launchagents_dir() .. "/" .. name
      pcall(bootout, p)
      pcall(os.remove, p)
      removed = removed + 1
    end
  end
  note(("removed %d legacy sh.organ.reminder.* agents"):format(removed))

  -- 3. Bundle dir — paranoia guards.
  local bdir = bundle_dir()
  local home_prefix = home() .. "/Library/Application Support/organ/"
  if bdir:sub(1, #home_prefix) ~= home_prefix then
    note("REFUSED to delete " .. bdir .. ": outside expected prefix " .. home_prefix)
    return steps
  end
  local lst = vim.uv.fs_lstat(bdir)
  if lst and lst.type == "link" then
    note(
      "REFUSED to delete "
        .. bdir
        .. ": SYMLINK (would follow elsewhere). "
        .. "Remove manually if intended."
    )
    return steps
  end

  if lst then
    -- Deregister from LaunchServices BEFORE deleting.
    try_run({
      "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
        .. "LaunchServices.framework/Support/lsregister",
      "-u",
      bdir,
    })
    note("deregistered bundle from LaunchServices")

    local rc = vim.fn.delete(bdir, "rf")
    if rc == 0 then
      note("deleted bundle " .. bdir)
    else
      note("FAILED to delete " .. bdir .. ": vim.fn.delete returned " .. rc)
    end
  else
    note("no bundle to delete (" .. bdir .. " not present)")
  end

  -- 4. Empty parent dir (best-effort — only succeeds if empty).
  pcall(vim.uv.fs_rmdir, home() .. "/Library/Application Support/organ")

  -- 5. Clear the in-memory batch.
  _current_batch = {}

  -- 6. Refresh System Settings cache so the entry drops off the list.
  try_run({ "killall", "cfprefsd" })
  note("nudged cfprefsd; the Settings UI should refresh shortly")

  return steps
end

return M
