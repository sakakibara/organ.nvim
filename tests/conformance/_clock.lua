-- Pin "now" for the organ side of a conformance run to CONFORMANCE_NOW
-- ("YYYY-MM-DD HH:MM", UTC; default 2026-05-04 09:30), the same instant
-- tests/conformance/_clock.el pins Emacs to.  The runner sets TZ=UTC.

local M = {}

local real_time, real_date = os.time, os.date
local spec = os.getenv("CONFORMANCE_NOW") or "2026-05-04 09:30"
local y, mo, d, h, mi = spec:match("^(%d+)-(%d+)-(%d+) (%d+):(%d+)$")
M.now = real_time({ year = y, month = mo, day = d, hour = h, min = mi, sec = 0 })

-- Replacing the clock primitives is the point, hence the ignored warning.
function M.pin()
  -- luacheck: push ignore 122
  os.time = function(t)
    if t == nil then
      return M.now
    end
    return real_time(t)
  end
  os.date = function(fmt, t)
    return real_date(fmt, t or M.now)
  end
  vim.fn.localtime = function()
    return M.now
  end
  -- luacheck: pop
end

return M
