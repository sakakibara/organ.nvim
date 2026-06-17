-- Error-handling primitives.
--
-- Convention (see CONTRIBUTING.md):
--   * return nil for an expected, recoverable absence (not found, no match);
--   * error() with context for an exceptional / invariant failure;
--   * catch only at user-facing boundaries (commands, keymaps, autocmds,
--     and inside scheduled callbacks) via guard().
-- Internal call chains do not pcall; that only swallows context.
local M = {}

-- assert() that requires a context string.  On a falsy `cond` it raises
-- `ctx .. ": " .. msg` blamed at the caller (level 2), so the reported
-- file:line points at the failing call site rather than this helper.
-- Returns `cond` on success so it can be used inline like assert().
function M.check(cond, ctx, msg)
  if not cond then
    error(ctx .. ": " .. (msg or "check failed"), 2)
  end
  return cond
end

-- Wrap a boundary callback so a thrown error is reported once, with
-- context, instead of escaping to the user as a raw traceback (or, for a
-- scheduled callback, to the scheduler where no pcall can catch it).
-- Returns fn's result on success, nil on a caught error.
function M.guard(ctx, fn)
  return function(...)
    local ok, res = pcall(fn, ...)
    if ok then
      return res
    end
    require("organ.notify").error(ctx .. ": " .. tostring(res))
    local organ = package.loaded["organ"]
    if organ and organ.config and organ.config.on_error then
      pcall(organ.config.on_error, res)
    end
    return nil
  end
end

return M
