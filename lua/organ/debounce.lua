-- Simple per-key trailing debounce.  Mirrors what indent.lua already
-- does inline -- a leading edge would fire on every keystroke (back to
-- the freeze we're trying to avoid), so this is trailing-only.
--
-- Usage:
--   local debounce = require("organ.debounce")
--   local trigger = debounce.trailing(150, function(bufnr)
--     -- whatever heavy refresh
--   end)
--   trigger(bufnr)  -- inside autocmd callback
--
-- Each call cancels any pending fire and starts a new timer keyed by
-- the first argument (typically bufnr).  When the timer expires, the
-- function runs once with the latest argument.
--
-- Cleanup: timers self-close on fire.  Buffers that detach without a
-- pending fire leave no leaks; if a fire is mid-flight when the buffer
-- gets wiped, the inner pcall + buf_is_valid guard absorbs it.

local M = {}

function M.trailing(ms, fn)
  local timers = {}
  return function(key, ...)
    local args = { ... }
    local existing = timers[key]
    if existing then
      pcall(function()
        existing:stop()
        existing:close()
      end)
    end
    local t = vim.uv.new_timer()
    timers[key] = t
    t:start(
      ms,
      0,
      vim.schedule_wrap(function()
        if t:is_closing() then
          return
        end
        pcall(function()
          t:stop()
          t:close()
        end)
        if timers[key] == t then
          timers[key] = nil
        end
        pcall(fn, key, unpack(args))
      end)
    )
  end
end

-- Defer `fn(bufnr)` to the next event-loop tick so attach() returns
-- immediately.  Decoration catches up one frame later.  Synchronous
-- apply()s inside attach() walk the whole buffer; under picker
-- previews ftplugin fires per item and N modules' applies stack into
-- a freeze on every cycle.
function M.apply_initial(bufnr, fn)
  require("organ.errors").schedule("organ.debounce", function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      fn(bufnr)
    end
  end)
end

return M
