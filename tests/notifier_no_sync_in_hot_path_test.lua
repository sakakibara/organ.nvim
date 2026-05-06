-- Static guard: notifier hot paths must not contain synchronous shell
-- calls (`:wait()` on a vim.system handle).
--
-- The "hot path" is anything reachable from `notifier.set_pending` (which
-- fires from `alarms.scan` on every `indexed` event — i.e. every save
-- when alarms.local_schedule is true). A `:wait()` here freezes the UI
-- for the duration of the launchctl/at/atrm call. With N reminders that
-- compounds to seconds of freeze per save.
--
-- We allow `:wait()` in user-initiated paths (install_bundle, diagnose,
-- status, uninstall_bundle, cancel_all) — those run from explicit
-- commands where the user is awaiting the result.
--
-- Run via: nvim --headless -l tests/notifier_no_sync_in_hot_path_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function read(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local s = fd:read("*a")
  fd:close()
  return s
end

-- Extract the body of a top-level function from a Lua source string.
-- Top-level functions in our notifier files always end with `end` at
-- column 0; inner (anonymous) function `end`s are indented. So we can
-- find the first column-0 `end` after the function header. Handles
-- both `function NAME(...)` and `local function NAME(...)`.
local function extract_function_body(src, fn_name)
  local escaped = fn_name:gsub("[.%-]", "%%%0")
  -- Match either `\nfunction NAME(` (module-level export) or
  -- `\nlocal function NAME(` (file-local helper).
  local p1 = "\nfunction%s+" .. escaped .. "%s*%(.-\nend\n"
  local p2 = "\nlocal function%s+" .. escaped .. "%s*%(.-\nend\n"
  return src:match(p1) or src:match(p2)
end

-- Whitelist: function names that are user-initiated and may :wait().
local USER_INITIATED = {
  ["M.install_bundle"] = true,
  ["M.uninstall_bundle"] = true,
  ["M.diagnose"] = true,
  ["M.status"] = true,
  ["M.cancel_all"] = true,
  ["build_swift_binary"] = true, -- only called from ensure_bundle on first install
  ["ensure_bundle"] = true, -- gated by fast-path; first-install only
  ["bootout"] = true, -- helper used by user-initiated paths
  ["bootstrap"] = true, -- helper used by user-initiated paths
  ["run"] = true, -- generic helper; callers gated above
  ["try_run"] = true, -- generic helper; callers gated above
  ["which"] = true, -- detection helper; callers cache result
  ["atd_active"] = true, -- detection helper; callers cache result
  ["systemd_user_available"] = true, -- detection helper; callers cache result
  ["pick_scheduler"] = true, -- detection helper; callers cache result
  ["schedule_at"] = true, -- legacy sync schedule (used only by M.schedule fallback)
  ["schedule_systemd"] = true, -- legacy sync schedule (used only by M.schedule fallback)
  ["M.schedule"] = true, -- legacy per-entry API (only hit when set_batch absent)
  ["M.cancel"] = true, -- legacy per-entry API (only hit when set_batch absent)
}

-- Functions that MUST be sync-free. These are the ones `notifier.init`
-- calls from set_pending → set_batch.
local HOT_PATH_FNS = {
  "M.set_batch",
  "rewrite_tick_async",
  "cleanup_legacy_agents_async",
  "schedule_at_async",
  "schedule_systemd_async",
  "cancel_async",
  "run_async",
}

local function audit(file_path, fn_names)
  local src = read(file_path)
  if not src then
    check("can read " .. file_path, false, "missing file")
    return
  end
  for _, name in ipairs(fn_names) do
    local body = extract_function_body(src, name)
    if not body then
      -- Not all functions exist in both files; that's OK.
    else
      local has_wait = body:match(":wait%(")
      check(
        ("hot-path-sync: %s :: %s has no :wait()"):format(file_path, name),
        not has_wait,
        has_wait and "found `:wait(` inside function body" or nil
      )
    end
  end
end

audit("lua/organ/notifier/macos.lua", HOT_PATH_FNS)
audit("lua/organ/notifier/linux.lua", HOT_PATH_FNS)

-- Also assert M.set_batch exists on both backends (the orchestrator's
-- batch fast-path requires it).
do
  local mac = require("organ.notifier.macos")
  local lin = require("organ.notifier.linux")
  check("macos backend exposes set_batch", type(mac.set_batch) == "function")
  check("linux backend exposes set_batch", type(lin.set_batch) == "function")
end

-- Cross-check: orchestrator's set_pending uses set_batch when present.
-- Read the source and grep for the dispatch.
do
  local src = read("lua/organ/notifier/init.lua") or ""
  check(
    "orchestrator: set_pending checks for backend.set_batch",
    src:find("backend%.set_batch") ~= nil
  )
end

-- Suppress the "unused" lint for USER_INITIATED — kept as docs.
local _ = USER_INITIATED

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("notifier_no_sync_in_hot_path_test: PASS")
