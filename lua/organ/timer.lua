-- Countdown timer (Emacs `org-timer-set-timer`) for pomodoro-style
-- work sessions. One timer per nvim instance.
--
-- Commands:
--   :Org timer start [duration]  -- start (default 25m)
--   :Org timer stop              -- stop / clear
--   :Org timer pause             -- pause / resume
--   :Org timer status            -- print remaining time
--
-- Duration formats: "25", "25m", "1h", "90s", "1h30m", "0:25:00".
--
-- Statusline integration: organ.timer.statusline() returns a single
-- string like "⏲ 18:42" suitable for embedding in 'statusline' or
-- a lualine component.
--
-- On expiry: emits an `organ.timer.expired` event AND a vim.notify.
-- Listeners can hook in (e.g. play a sound). The timer auto-clears
-- after expiry; user must run :Org timer start to begin a new one.

local M = {}

local state = {
  -- One of nil | "running" | "paused"
  status = nil,
  started_at = nil, -- os.time() when last running started
  duration_s = nil, -- total length in seconds (configured)
  remaining_s = nil, -- when paused, seconds left at pause
  expiry_timer = nil, -- uv timer for fire-on-expiry callback
}

-- Parse "25", "25m", "1h", "90s", "1h30m", "0:25:00" to seconds.
local function parse_duration(s)
  s = tostring(s or ""):lower():gsub("%s+", "")
  if s == "" then
    return nil
  end

  -- Plain number (no unit) → minutes (Emacs convention).
  if s:match("^%d+$") then
    return tonumber(s) * 60
  end

  -- "0:25:00" or "25:00" form (h:m:s or m:s).
  local h, m, sec = s:match("^(%d+):(%d+):(%d+)$")
  if h then
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec)
  end
  m, sec = s:match("^(%d+):(%d+)$")
  if m then
    return tonumber(m) * 60 + tonumber(sec)
  end

  -- Compound units: 1h30m / 90s / 1h / 25m.
  local total = 0
  local matched = 0
  for n, unit in s:gmatch("(%d+)([hms])") do
    matched = matched + 1
    n = tonumber(n)
    if unit == "h" then
      total = total + n * 3600
    elseif unit == "m" then
      total = total + n * 60
    else
      total = total + n
    end
  end
  return matched > 0 and total or nil
end
M._parse_duration = parse_duration

local function clear_timer()
  if state.expiry_timer then
    pcall(function()
      state.expiry_timer:stop()
      state.expiry_timer:close()
    end)
    state.expiry_timer = nil
  end
end

local function fire_expiry()
  pcall(function()
    require("organ.notify").info("⏲ Organ timer expired")
  end)
  pcall(function()
    require("organ.events").emit("organ.timer.expired", { duration_s = state.duration_s })
  end)
  state.status = nil
  state.started_at = nil
  state.duration_s = nil
  state.remaining_s = nil
  clear_timer()
  -- Refresh any rendering that watches timer status.
  pcall(vim.cmd, "redrawstatus")
end

local function arm_expiry(seconds)
  clear_timer()
  if not seconds or seconds <= 0 then
    -- Already expired — fire on the next loop tick.
    vim.schedule(fire_expiry)
    return
  end
  local t = vim.uv.new_timer()
  state.expiry_timer = t
  t:start(
    seconds * 1000,
    0,
    vim.schedule_wrap(function()
      if t:is_closing() then
        return
      end
      pcall(function()
        t:stop()
        t:close()
      end)
      if state.expiry_timer == t then
        state.expiry_timer = nil
      end
      fire_expiry()
    end)
  )
end

function M.start(duration)
  local secs
  if duration == nil or duration == "" then
    local cfg = (require("organ").config.timer or {})
    secs = cfg.default_seconds or (25 * 60) -- 25-minute pomodoro default
  else
    secs = parse_duration(duration)
    if not secs then
      require("organ.notify").error("organ.timer: can't parse duration: " .. tostring(duration))
      return
    end
  end
  state.status = "running"
  state.started_at = os.time()
  state.duration_s = secs
  state.remaining_s = secs
  arm_expiry(secs)
  require("organ.notify").info(
    ("⏲ Organ timer: %d:%02d"):format(math.floor(secs / 60), secs % 60)
  )
  pcall(vim.cmd, "redrawstatus")
end

function M.stop()
  if not state.status then
    return
  end
  state.status = nil
  state.started_at = nil
  state.duration_s = nil
  state.remaining_s = nil
  clear_timer()
  require("organ.notify").info("⏲ Organ timer stopped")
  pcall(vim.cmd, "redrawstatus")
end

function M.pause()
  if state.status == "running" then
    -- Pause: capture remaining seconds, drop the uv timer.
    local elapsed = os.time() - state.started_at
    state.remaining_s = math.max(0, state.duration_s - elapsed)
    state.status = "paused"
    state.started_at = nil
    clear_timer()
    require("organ.notify").info("⏲ Organ timer paused")
  elseif state.status == "paused" then
    -- Resume.
    state.status = "running"
    state.started_at = os.time()
    state.duration_s = state.remaining_s -- restart countdown from remaining
    arm_expiry(state.remaining_s)
    require("organ.notify").info(
      ("⏲ Organ timer resumed (%d:%02d)"):format(
        math.floor(state.remaining_s / 60),
        state.remaining_s % 60
      )
    )
  end
  pcall(vim.cmd, "redrawstatus")
end

-- Returns remaining seconds, or nil if no timer is running/paused.
function M.remaining()
  if not state.status then
    return nil
  end
  if state.status == "paused" then
    return state.remaining_s
  end
  -- running
  local elapsed = os.time() - state.started_at
  return math.max(0, state.duration_s - elapsed)
end

function M.status()
  return {
    status = state.status,
    duration_s = state.duration_s,
    remaining = M.remaining(),
  }
end

-- Statusline component. Returns "" when no timer active so it can be
-- safely concatenated into a 'statusline'.
function M.statusline()
  local r = M.remaining()
  if not r then
    return ""
  end
  local prefix = state.status == "paused" and "⏸" or "⏲"
  return string.format("%s %d:%02d", prefix, math.floor(r / 60), r % 60)
end

return M
