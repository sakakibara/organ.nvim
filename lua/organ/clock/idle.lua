-- Idle watcher: detects inactivity while a clock is running and prompts the
-- user to keep, subtract, or end the active clock.

local M = {}

local last_activity_ts = nil
local timer = nil
local autocmd_group = nil
local prompt_open = false

local function resolution()
  local cfg = (require("organ.buf_config").read(nil, "clock") or {})
  return cfg.idle_resolution or "prompt"
end

local function _on_idle_threshold(idle_seconds)
  local clock = require("organ.clock")
  local idle_minutes = math.floor(idle_seconds / 60)
  local mode = resolution()

  if mode == "keep" then
    last_activity_ts = os.time()
    require("organ.notify").info(("organ.clock: idle %dm kept as worked time"):format(idle_minutes))
    return
  end
  if mode == "subtract" then
    clock.subtract_idle(idle_seconds)
    last_activity_ts = os.time()
    require("organ.notify").info(
      ("organ.clock: subtracted %dm idle from active clock"):format(idle_minutes)
    )
    return
  end
  if mode == "discard" then
    local idle_start = os.time() - idle_seconds
    clock.stop({ end_ts = idle_start })
    M.stop()
    require("organ.notify").info(
      ("organ.clock: clocked out at idle start (-%dm)"):format(idle_minutes)
    )
    return
  end

  -- "prompt" (default) — interactive selector.
  if prompt_open then
    return
  end
  prompt_open = true
  vim.ui.select({
    "Keep clock running",
    "Subtract " .. idle_minutes .. " idle minutes",
    "End clock now (at idle start)",
  }, { prompt = "organ.clock: idle for " .. idle_minutes .. " min" }, function(choice, idx)
    prompt_open = false
    if not choice then
      last_activity_ts = os.time()
      return
    end
    if idx == 1 then
      last_activity_ts = os.time()
    elseif idx == 2 then
      clock.subtract_idle(idle_seconds)
      last_activity_ts = os.time()
    elseif idx == 3 then
      local idle_start = os.time() - idle_seconds
      clock.stop({ end_ts = idle_start })
      M.stop()
    end
  end)
end

M._on_idle_threshold = _on_idle_threshold

function M.start(threshold_minutes)
  if not threshold_minutes or threshold_minutes <= 0 then
    return
  end
  if timer then
    return
  end
  last_activity_ts = os.time()
  autocmd_group = vim.api.nvim_create_augroup("organ_clock_idle", { clear = true })
  require("organ.errors").autocmd(
    { "CursorMoved", "CursorMovedI", "InsertEnter", "TextChanged", "TextChangedI" },
    {
      group = autocmd_group,
      callback = function()
        last_activity_ts = os.time()
      end,
    }
  )
  timer = vim.loop.new_timer()
  timer:start(
    60000,
    60000,
    vim.schedule_wrap(function()
      if not last_activity_ts then
        return
      end
      local idle = os.time() - last_activity_ts
      if idle >= threshold_minutes * 60 then
        _on_idle_threshold(idle)
      end
    end)
  )
end

function M.stop()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, autocmd_group)
    autocmd_group = nil
  end
  last_activity_ts = nil
end

-- Test hook: directly trigger the prompt without waiting for the timer.
function M._test_trigger(idle_seconds)
  _on_idle_threshold(idle_seconds)
end

return M
