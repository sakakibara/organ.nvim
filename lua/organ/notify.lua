-- Centralized notification helper for organ.nvim.
--
-- All user-facing messages should go through this module so:
--   * The "organ:" prefix is consistent (no double-prefix when callers
--     forget; no missing prefix when callers omit it).
--   * `cfg.notify == false` mutes everything (call sites no longer
--     have to remember the gating boilerplate).
--   * Repeat-suppression keeps a busy loop or chatty timer from
--     spamming the user.
--
-- Public surface: M.info / M.warn / M.error / M.debug. Callers pass the
-- raw message body; "organ:" is prepended automatically.

local M = {}

-- Suppression window: identical (level, body) tuples within this many
-- seconds collapse into one notification. Set 0 to disable.
M.repeat_suppress_seconds = 2

local _last = { level = nil, body = nil, ts = 0 }

local function should_notify(level, body)
  local cfg_ok, organ = pcall(require, "organ")
  if cfg_ok and organ.config and require("organ.buf_config").read(nil, "notify") == false then
    -- Allow ERROR through even when notifications are muted; users still
    -- need to see failures.
    if level ~= vim.log.levels.ERROR then
      return false
    end
  end
  if M.repeat_suppress_seconds > 0 then
    local now = os.time()
    if
      _last.level == level
      and _last.body == body
      and (now - _last.ts) < M.repeat_suppress_seconds
    then
      return false
    end
    _last = { level = level, body = body, ts = now }
  end
  return true
end

local function send(level, body)
  if not should_notify(level, body) then
    return
  end
  vim.notify("organ: " .. body, level)
end

function M.info(body)
  send(vim.log.levels.INFO, body)
end
function M.warn(body)
  send(vim.log.levels.WARN, body)
end
function M.error(body)
  send(vim.log.levels.ERROR, body)
end
function M.debug(body)
  -- Honor cfg.log_level so DEBUG only fires when explicitly opted in.
  local cfg_ok, organ = pcall(require, "organ")
  if cfg_ok and organ.config and require("organ.buf_config").read(nil, "log_level") == "debug" then
    send(vim.log.levels.DEBUG, body)
  end
end

-- Notify with an explicit level (raw constant from vim.log.levels).
-- Useful when the level is dynamic (e.g. INFO on success, WARN on no-op).
function M.notify(level, body)
  send(level, body)
end

return M
