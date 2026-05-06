-- Tiny pub/sub for organ.nvim. Listeners registered via on() fire in
-- registration order when emit() is called. Errors raised by a listener
-- are swallowed (pcall-isolated) so a misbehaving subscriber can't kill
-- the publisher or other subscribers.

local M = {}

local listeners = {}

function M.on(event, fn)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
  return fn
end

function M.off(event, fn)
  local l = listeners[event]
  if not l then
    return
  end
  for i, f in ipairs(l) do
    if f == fn then
      table.remove(l, i)
      return
    end
  end
end

function M.emit(event, payload)
  local l = listeners[event]
  if not l then
    return
  end
  for _, fn in ipairs(l) do
    pcall(fn, payload)
  end
end

function M.clear(event)
  if event then
    listeners[event] = nil
  else
    listeners = {}
  end
end

return M
