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

-- Schedule fn on the main loop wrapped in guard(ctx).  A throw on the
-- (fresh) scheduled stack is then reported via on_error / notify with
-- context instead of nvim's generic callback-error traceback.
function M.schedule(ctx, fn)
  return vim.schedule(M.guard(ctx, fn))
end

-- nvim_create_autocmd with the callback guarded.  An error in the callback
-- is reported with context rather than as a raw autocmd traceback; the
-- autocmd's own return value (e.g. true to self-delete) is preserved on
-- success, and a caught error yields nil so the autocmd is not deleted.
function M.autocmd(event, opts)
  if type(opts.callback) == "function" then
    local ev = type(event) == "table" and table.concat(event, ",") or tostring(event)
    opts.callback = M.guard("organ.autocmd " .. (opts.desc or ev), opts.callback)
  end
  return vim.api.nvim_create_autocmd(event, opts)
end

return M
